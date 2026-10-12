-- ==============================================================================
-- AGRA JAYA POS — PRODUCTION MIGRATION: ATOMIC POS SALES CHECKOUT ENGINE
-- Target Database: PostgreSQL (Supabase Production: fjudjicfgvpilvtpsfde)
-- Mode: Safe, Non-Destructive, Idempotent, Single-Transaction Server Authority
-- ==============================================================================

BEGIN;

-- 1. SCHEMA SAFETY GUARDS (IDEMPOTENT COLUMN ADDITIONS)
ALTER TABLE public.invoice_items
    ADD COLUMN IF NOT EXISTS item_type VARCHAR(20) NOT NULL DEFAULT 'barang',
    ADD COLUMN IF NOT EXISTS product_name VARCHAR(255) NULL,
    ADD COLUMN IF NOT EXISTS cost_price NUMERIC(15,2) NOT NULL DEFAULT 0.00;

ALTER TABLE public.invoices
    ADD COLUMN IF NOT EXISTS transaction_id BIGINT NULL REFERENCES public.transactions(id),
    ADD COLUMN IF NOT EXISTS payment_method VARCHAR(50) NULL;

ALTER TABLE public.transactions
    ADD COLUMN IF NOT EXISTS invoice_id BIGINT NULL REFERENCES public.invoices(id);

-- 2. CLEANUP LEGACY / OVERLOADED FUNCTION SIGNATURES
DROP FUNCTION IF EXISTS public.create_pos_transaction_atomic(VARCHAR, VARCHAR, DATE, NUMERIC, NUMERIC, VARCHAR, BIGINT, JSONB, NUMERIC, DATE, VARCHAR, VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS public.create_pos_transaction_atomic(VARCHAR, VARCHAR, DATE, NUMERIC, NUMERIC, VARCHAR, BIGINT, JSONB, NUMERIC, DATE, VARCHAR, VARCHAR, VARCHAR, NUMERIC);

-- 3. HARDENED ATOMIC POS SALES CHECKOUT RPC
CREATE OR REPLACE FUNCTION public.create_pos_transaction_atomic(
    p_trx_code VARCHAR,
    p_party_name VARCHAR,
    p_transaction_date DATE,
    p_total NUMERIC,
    p_profit NUMERIC,
    p_payment_method VARCHAR,
    p_payment_account_id BIGINT DEFAULT NULL,
    p_items JSONB DEFAULT '[]'::JSONB,
    p_dp_amount NUMERIC DEFAULT 0.00,
    p_due_date DATE DEFAULT NULL,
    p_customer_name VARCHAR DEFAULT NULL,
    p_customer_farm VARCHAR DEFAULT NULL,
    p_inv_no VARCHAR DEFAULT NULL,
    p_discount NUMERIC DEFAULT 0.00
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_caller_role VARCHAR;
    v_trx_id BIGINT;
    v_inv_id BIGINT;
    v_rec_id BIGINT := NULL;
    v_inv_no VARCHAR;
    v_cust_name VARCHAR;
    v_cust_farm VARCHAR;
    v_item JSONB;
    v_prod RECORD;
    v_prod_id BIGINT;
    v_item_name VARCHAR;
    v_item_type VARCHAR;
    v_category VARCHAR;
    v_unit VARCHAR;
    v_qty NUMERIC(15,2);
    v_price NUMERIC(15,2);
    v_cost_price NUMERIC(15,2);
    v_disc_type VARCHAR(10);
    v_disc_val NUMERIC(15,2);
    v_disc_amt NUMERIC(15,2);
    v_item_subtotal NUMERIC(15,2);
    v_gross_total NUMERIC(15,2) := 0.00;
    v_items_disc_total NUMERIC(15,2) := 0.00;
    v_trx_discount NUMERIC(15,2) := 0.00;
    v_discount_total NUMERIC(15,2) := 0.00;
    v_calc_net_total NUMERIC(15,2) := 0.00;
    v_total_cost NUMERIC(15,2) := 0.00;
    v_calc_profit NUMERIC(15,2) := 0.00;
    v_old_stock NUMERIC(15,2);
    v_new_stock NUMERIC(15,2);
    v_dp NUMERIC(15,2);
    v_paid NUMERIC(15,2);
    v_remaining NUMERIC(15,2);
    v_status VARCHAR;
    v_stored_method VARCHAR;
    v_pay_acc RECORD;
    v_pay_coa_id BIGINT;
    v_revenue_coa_id BIGINT;
    v_piutang_coa_id BIGINT;
    v_journal_lines JSONB := '[]'::JSONB;
    v_journal_res RECORD;
BEGIN
    -- [1] Authentication & Role Guard
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHENTICATED: Sesi pengguna tidak terautentikasi';
    END IF;

    v_caller_role := public.get_current_user_role();
    IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin', 'kasir') THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Pengguna tidak memiliki izin untuk memproses penjualan POS';
    END IF;

    -- [2] Validasi Parameter Dasar & Anti-Duplikasi
    IF p_trx_code IS NULL OR TRIM(p_trx_code) = '' THEN
        RAISE EXCEPTION 'INVALID_PARAM: Kode transaksi (trx_code) wajib diisi';
    END IF;

    IF EXISTS (SELECT 1 FROM public.transactions WHERE trx_code = p_trx_code) THEN
        RAISE EXCEPTION 'DUPLICATE_TRX_CODE: Kode transaksi % sudah pernah diproses', p_trx_code;
    END IF;

    IF p_transaction_date IS NULL THEN
        RAISE EXCEPTION 'INVALID_PARAM: Tanggal transaksi wajib diisi';
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'EMPTY_ITEMS: Keranjang belanja tidak boleh kosong';
    END IF;

    v_cust_name := COALESCE(NULLIF(TRIM(p_customer_name), ''), NULLIF(TRIM(p_party_name), ''), 'Pelanggan Umum');
    v_cust_farm := COALESCE(NULLIF(TRIM(p_customer_farm), ''), '-');

    -- [3] Iterasi Item, Row Locking Produk, Validasi Nilai & Hitung Ulang Nominal Server-Side
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_prod_id := COALESCE((v_item->>'productId')::BIGINT, (v_item->>'product_id')::BIGINT, (v_item->>'id')::BIGINT);
        IF v_prod_id IS NULL THEN
            RAISE EXCEPTION 'INVALID_ITEM: ID produk pada keranjang belanja tidak valid';
        END IF;

        v_qty := (v_item->>'qty')::NUMERIC;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'INVALID_QUANTITY: Kuantiti produk ID % harus lebih besar dari 0', v_prod_id;
        END IF;

        v_price := (v_item->>'price')::NUMERIC;
        IF v_price IS NULL OR v_price < 0 THEN
            RAISE EXCEPTION 'INVALID_PRICE: Harga produk ID % tidak boleh negatif', v_prod_id;
        END IF;

        -- Lock Baris Produk untuk Proteksi Konkurensi Stok
        SELECT * INTO v_prod FROM public.products WHERE id = v_prod_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PRODUCT_NOT_FOUND: Produk ID % tidak ditemukan di database', v_prod_id;
        END IF;

        -- Hitung Diskon Item
        v_disc_type := COALESCE(v_item->>'discountType', v_item->>'discount_type', 'none');
        v_disc_val := COALESCE((v_item->>'discountValue')::NUMERIC, (v_item->>'discount_value')::NUMERIC, 0.00);
        v_disc_amt := COALESCE((v_item->>'discountAmount')::NUMERIC, (v_item->>'discount_amount')::NUMERIC, 0.00);

        IF v_disc_type IN ('percent', 'percentage') AND v_disc_val > 0 THEN
            v_disc_amt := ROUND((v_qty * v_price * v_disc_val / 100.0), 2);
        ELSIF v_disc_type IN ('nominal', 'fixed', 'rp') AND v_disc_val > 0 AND v_disc_amt = 0 THEN
            v_disc_amt := v_disc_val;
        END IF;

        IF v_disc_amt < 0 OR v_disc_amt > (v_qty * v_price) THEN
            RAISE EXCEPTION 'INVALID_DISCOUNT: Nilai diskon pada produk % tidak valid', v_prod.name;
        END IF;

        v_item_subtotal := (v_qty * v_price) - v_disc_amt;
        v_cost_price := COALESCE(v_prod.cost_price, (v_item->>'costPrice')::NUMERIC, (v_item->>'cost_price')::NUMERIC, 0.00);

        v_gross_total := v_gross_total + (v_qty * v_price);
        v_items_disc_total := v_items_disc_total + v_disc_amt;
        v_total_cost := v_total_cost + (v_qty * v_cost_price);

        -- Periksa & Deduksi Stok Hanya Jika Produk Bertipe 'barang'
        IF v_prod.type = 'barang' THEN
            IF v_prod.stock < v_qty THEN
                RAISE EXCEPTION 'INSUFFICIENT_STOCK: Stok produk "%" tidak mencukupi (Tersedia: %, Diminta: %)',
                    v_prod.name, v_prod.stock, v_qty;
            END IF;

            v_old_stock := v_prod.stock;
            v_new_stock := v_old_stock - v_qty;

            UPDATE public.products
            SET stock = v_new_stock,
                updated_at = NOW()
            WHERE id = v_prod_id;

            INSERT INTO public.stock_logs (
                product_id, product_name, action_type, qty,
                stock_before, stock_after, reference_code, note, created_by
            ) VALUES (
                v_prod_id, v_prod.name, 'SALE', v_qty,
                v_old_stock, v_new_stock, p_trx_code, 'Penjualan POS ' || p_trx_code, v_caller_id
            );
        END IF;
    END LOOP;

    -- Hitung Diskon Transaksi & Net Total
    v_trx_discount := GREATEST(0.00, COALESCE(p_discount, 0.00));
    v_discount_total := v_items_disc_total + v_trx_discount;
    v_calc_net_total := GREATEST(0.00, v_gross_total - v_discount_total);
    v_calc_profit := v_calc_net_total - v_total_cost;

    -- Validasi Total Client vs Total Hitungan Server (Toleransi 0.05 untuk rounding)
    IF p_total IS NOT NULL AND ABS(p_total - v_calc_net_total) > 0.05 THEN
        RAISE EXCEPTION 'TOTAL_MISMATCH: Total transaksi dari client (%) tidak cocok dengan hasil perhitungan server (%)',
            p_total, v_calc_net_total;
    END IF;

    IF v_calc_net_total <= 0 THEN
        RAISE EXCEPTION 'INVALID_TOTAL: Total transaksi POS harus lebih besar dari 0';
    END IF;

    -- [4] Validasi Aturan Pembayaran, DP, Sisa Piutang & Status
    --     Metode yang didukung:
    --     - 'Tunai'               : Lunas via kas (paid = total, remaining = 0, due_date = NULL)
    --     - 'Transfer' / 'QRIS'   : Lunas via bank / gateway (paid = total, remaining = 0, due_date = NULL)
    --     - 'Kredit'              : Tempo / cicilan dengan DP opsional, sisa piutang tercatat, due_date opsional
    IF p_payment_method IN ('Tunai', 'Tunai Lunas', 'TunaiLunas') THEN
        v_paid := v_calc_net_total;
        v_remaining := 0.00;
        v_status := 'Lunas';
        v_stored_method := 'Tunai';
    ELSIF p_payment_method IN ('Transfer', 'QRIS') THEN
        v_paid := v_calc_net_total;
        v_remaining := 0.00;
        v_status := 'Lunas';
        v_stored_method := p_payment_method;
    ELSIF p_payment_method = 'Kredit' THEN
        v_dp := LEAST(v_calc_net_total, GREATEST(0.00, COALESCE(p_dp_amount, 0.00)));
        v_paid := v_dp;
        v_remaining := v_calc_net_total - v_paid;
        IF v_remaining <= 0.001 THEN
            v_status := 'Lunas';
        ELSIF v_paid > 0.001 THEN
            v_status := 'Sebagian';
        ELSE
            v_status := 'Belum Bayar';
        END IF;
        v_stored_method := 'Kredit';
    ELSE
        RAISE EXCEPTION 'INVALID_PAYMENT_METHOD: Metode pembayaran "%" tidak didukung', p_payment_method;
    END IF;

    -- [5] Resolve Bagan Akun (COA) untuk Jurnal Umum Seimbang
    SELECT id INTO v_revenue_coa_id
    FROM public.chart_of_accounts
    WHERE code = '4-1110' AND is_active = TRUE;

    IF v_revenue_coa_id IS NULL THEN
        RAISE EXCEPTION 'COA_NOT_FOUND: Bagan akun Pendapatan Penjualan (4-1110) tidak ditemukan di database';
    END IF;

    IF v_paid > 0 THEN
        IF p_payment_account_id IS NOT NULL THEN
            SELECT id, name, chart_of_account_id INTO v_pay_acc
            FROM public.payment_accounts
            WHERE id = p_payment_account_id AND is_active = TRUE;
            v_pay_coa_id := v_pay_acc.chart_of_account_id;
        ELSE
            SELECT id, name, chart_of_account_id INTO v_pay_acc
            FROM public.payment_accounts
            WHERE type = 'CASH' AND is_active = TRUE
            ORDER BY id ASC LIMIT 1;
            v_pay_coa_id := v_pay_acc.chart_of_account_id;
        END IF;

        IF v_pay_coa_id IS NULL THEN
            RAISE EXCEPTION 'PAYMENT_ACCOUNT_INVALID: Akun kas/bank pembayaran tidak valid atau tidak memiliki COA';
        END IF;

        v_journal_lines := v_journal_lines || jsonb_build_array(
            jsonb_build_object(
                'chart_of_account_id', v_pay_coa_id,
                'debit', v_paid,
                'credit', 0,
                'description', 'Penerimaan kas POS ' || p_trx_code || ' (' || v_cust_name || ')'
            )
        );
    END IF;

    IF v_remaining > 0 THEN
        SELECT id INTO v_piutang_coa_id
        FROM public.chart_of_accounts
        WHERE code = '1-1110' AND is_active = TRUE;

        IF v_piutang_coa_id IS NULL THEN
            RAISE EXCEPTION 'COA_NOT_FOUND: Bagan akun Piutang Usaha (1-1110) tidak ditemukan di database';
        END IF;

        v_journal_lines := v_journal_lines || jsonb_build_array(
            jsonb_build_object(
                'chart_of_account_id', v_piutang_coa_id,
                'debit', v_remaining,
                'credit', 0,
                'description', 'Piutang penjualan POS ' || p_trx_code || ' (' || v_cust_name || ')'
            )
        );
    END IF;

    v_journal_lines := v_journal_lines || jsonb_build_array(
        jsonb_build_object(
            'chart_of_account_id', v_revenue_coa_id,
            'debit', 0,
            'credit', v_calc_net_total,
            'description', 'Penjualan POS ' || p_trx_code || ' (' || v_cust_name || ')'
        )
    );

    -- [6] Insert Record Transactions
    INSERT INTO public.transactions (
        trx_code, transaction_type, party_name, transaction_date, status, total, profit,
        payment_method, payment_account_id, items, created_by
    ) VALUES (
        p_trx_code, 'Jual', v_cust_name, p_transaction_date, 'VALID',
        v_calc_net_total, v_calc_profit, v_stored_method, p_payment_account_id, p_items, v_caller_id
    ) RETURNING id INTO v_trx_id;

    -- [7] Insert Record Invoices Terhubung (transaction_id = v_trx_id)
    v_inv_no := COALESCE(NULLIF(TRIM(p_inv_no), ''), 'INV-' || p_trx_code);
    IF EXISTS (SELECT 1 FROM public.invoices WHERE inv_no = v_inv_no) THEN
        v_inv_no := v_inv_no || '-' || v_trx_id::TEXT;
    END IF;

    INSERT INTO public.invoices (
        inv_no, customer_id, customer_name, customer_farm, due_date, invoice_date, status,
        subtotal, discount_total, total, paid_amount, remaining, project_id, quotation_id,
        transaction_id, created_by, payment_method
    ) VALUES (
        v_inv_no, NULL, v_cust_name, v_cust_farm,
        CASE WHEN p_payment_method IN ('Tunai', 'Tunai Lunas', 'TunaiLunas', 'Transfer', 'QRIS') THEN NULL ELSE p_due_date END,
        p_transaction_date, v_status,
        v_gross_total, v_discount_total, v_calc_net_total, v_paid, v_remaining, NULL, NULL,
        v_trx_id, v_caller_id, v_stored_method
    ) RETURNING id INTO v_inv_id;

    -- Tautkan transaksi dengan invoice_id
    UPDATE public.transactions
    SET invoice_id = v_inv_id
    WHERE id = v_trx_id;

    -- Insert Invoice Items Lengkap dengan item_type, product_name, cost_price
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_prod_id := COALESCE((v_item->>'productId')::BIGINT, (v_item->>'product_id')::BIGINT, (v_item->>'id')::BIGINT);
        SELECT * INTO v_prod FROM public.products WHERE id = v_prod_id;

        v_item_name := COALESCE(v_item->>'name', v_prod.name, 'Item Invoice');
        v_item_type := COALESCE(v_item->>'type', v_prod.type, 'barang');
        v_category := COALESCE(v_item->>'category', v_prod.category, 'General');
        v_unit := COALESCE(v_item->>'unit', v_prod.unit, 'Unit');
        v_qty := (v_item->>'qty')::NUMERIC;
        v_price := (v_item->>'price')::NUMERIC;
        v_cost_price := COALESCE((v_item->>'costPrice')::NUMERIC, (v_item->>'cost_price')::NUMERIC, v_prod.cost_price, 0.00);
        v_disc_type := COALESCE(v_item->>'discountType', v_item->>'discount_type', 'none');
        v_disc_val := COALESCE((v_item->>'discountValue')::NUMERIC, (v_item->>'discount_value')::NUMERIC, 0.00);
        v_disc_amt := COALESCE((v_item->>'discountAmount')::NUMERIC, (v_item->>'discount_amount')::NUMERIC, 0.00);

        INSERT INTO public.invoice_items (
            invoice_id, product_id, product_name, item_type, category, unit, price, cost_price, qty,
            discount_type, discount_value, discount_amount
        ) VALUES (
            v_inv_id, v_prod_id, v_item_name, v_item_type, v_category, v_unit, v_price, v_cost_price, v_qty,
            v_disc_type, v_disc_val, v_disc_amt
        );
    END LOOP;

    -- [8] Insert Receivables HANYA Jika Masih Ada Sisa Piutang (Kredit & Belum Lunas)
    IF v_remaining > 0 THEN
        INSERT INTO public.receivables (
            invoice_id, inv_no, customer_name, due_date, status, total, paid, remaining
        ) VALUES (
            v_inv_id, v_inv_no, v_cust_name, p_due_date, v_status, v_calc_net_total, v_paid, v_remaining
        ) RETURNING id INTO v_rec_id;
    END IF;

    -- [9] Post Jurnal Akuntansi Secara Atomik Melalui Internal post_journal_entry
    SELECT journal_id, journal_no INTO v_journal_res
    FROM public.post_journal_entry(
        p_journal_date := p_transaction_date,
        p_source_type := 'TRANSACTION',
        p_source_id := v_trx_id,
        p_source_code := p_trx_code,
        p_description := 'Transaksi Penjualan POS ' || p_trx_code || ' - ' || v_cust_name,
        p_user_id := v_caller_id,
        p_lines := v_journal_lines
    );

    RETURN jsonb_build_object(
        'success', true,
        'transaction_id', v_trx_id,
        'trx_code', p_trx_code,
        'invoice_id', v_inv_id,
        'inv_no', v_inv_no,
        'receivable_id', v_rec_id,
        'journal_id', v_journal_res.journal_id,
        'journal_no', v_journal_res.journal_no,
        'subtotal', v_gross_total,
        'discount_total', v_discount_total,
        'total', v_calc_net_total,
        'paid_amount', v_paid,
        'remaining', v_remaining,
        'status', v_status
    );
END;
$$;

-- 4. PERMISSIONS & SECURITY HARDENING
REVOKE EXECUTE ON FUNCTION public.create_pos_transaction_atomic FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_pos_transaction_atomic TO authenticated;

COMMIT;

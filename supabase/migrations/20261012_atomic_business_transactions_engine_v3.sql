-- ==============================================================================
-- AGRA JAYA POS — ATOMIC BUSINESS TRANSACTIONS ENGINE V3 (AUDITED & HARDENED)
-- Target: PostgreSQL / Supabase
-- Date: 2026-10-12
--
-- RINGKASAN REVISI AUDIT (V3):
-- 1. DROP FUNCTION IF EXISTS pada seluruh signature lama (v1 & v2) sebelum membuat
--    fungsi baru untuk mencegah ambiguous function overloading di PostgreSQL.
-- 2. Memperluas skema public.invoice_items dengan kolom item_type, product_name,
--    dan cost_price (idempotent & backward-compatible).
-- 3. Menyimpan jenis item (barang vs jasa) serta product_name pada invoice_items di
--    create_pos_transaction_atomic dan convert_quotation_to_invoice_atomic tanpa
--    memasukkan kolom komputasi tersimpan (subtotal).
-- 4. Proteksi ketat pada void_pos_transaction_atomic: Jika invoice terkait memiliki
--    pembayaran piutang berstatus 'VALID' di payment_history, VOID ditolak secara
--    eksplisit dengan pesan informatif.
-- 5. Menjaga aturan bisnis Mas Danang:
--    - Konversi penawaran (quotation) TIDAK MENGUBAH STOK.
--    - Tanggal jatuh tempo invoice pelanggan tetap opsional (dapat NULL).
--    - Jatuh tempo hutang supplier mempertahankan default tempo 30 hari database.
--    - Internal posting jurnal (post_journal_entry & reverse_journal_entry) tetap private.
--    - Transaksi kredit dengan DP 0 tidak membuat penerimaan kas palsu.
-- ==============================================================================

-- [0] Schema Enhancements (Idempotent & Backward-Compatible)
ALTER TABLE public.invoice_items 
    ADD COLUMN IF NOT EXISTS item_type VARCHAR(20) DEFAULT 'barang',
    ADD COLUMN IF NOT EXISTS product_name VARCHAR(255) NULL,
    ADD COLUMN IF NOT EXISTS cost_price NUMERIC(15,2) DEFAULT 0.00;

ALTER TABLE public.invoices 
    ADD COLUMN IF NOT EXISTS transaction_id BIGINT NULL REFERENCES public.transactions(id),
    ADD COLUMN IF NOT EXISTS payment_method VARCHAR(20) NULL;

ALTER TABLE public.transactions 
    ADD COLUMN IF NOT EXISTS invoice_id BIGINT NULL REFERENCES public.invoices(id);

-- Clean up any potentially conflicting or overloaded signatures from previous attempts
DROP FUNCTION IF EXISTS public.create_pos_transaction_atomic(VARCHAR, VARCHAR, DATE, NUMERIC, NUMERIC, VARCHAR, BIGINT, JSONB, NUMERIC, DATE, VARCHAR, VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS public.create_pos_transaction_atomic(VARCHAR, VARCHAR, DATE, NUMERIC, NUMERIC, VARCHAR, BIGINT, JSONB, NUMERIC, DATE, VARCHAR, VARCHAR, VARCHAR, NUMERIC);
DROP FUNCTION IF EXISTS public.create_purchase_atomic(VARCHAR, VARCHAR, DATE, NUMERIC, VARCHAR, BIGINT, JSONB);
DROP FUNCTION IF EXISTS public.create_purchase_atomic(VARCHAR, VARCHAR, DATE, VARCHAR, BIGINT, NUMERIC, JSONB);
DROP FUNCTION IF EXISTS public.create_expense_atomic(VARCHAR, DATE, BIGINT, BIGINT, NUMERIC, VARCHAR, BIGINT, TEXT);
DROP FUNCTION IF EXISTS public.create_equity_transaction_atomic(VARCHAR, DATE, VARCHAR, BIGINT, BIGINT, NUMERIC, TEXT);
-- Drop BOTH old signatures of convert_quotation_to_invoice_atomic (boolean v3 & varchar v4)
DROP FUNCTION IF EXISTS public.convert_quotation_to_invoice_atomic(BIGINT, VARCHAR, DATE, DATE, VARCHAR, VARCHAR, BOOLEAN, BIGINT, NUMERIC, JSONB);
DROP FUNCTION IF EXISTS public.convert_quotation_to_invoice_atomic(BIGINT, VARCHAR, DATE, DATE, VARCHAR, VARCHAR, VARCHAR, BIGINT, NUMERIC, JSONB);
DROP FUNCTION IF EXISTS public.void_pos_transaction_atomic(BIGINT, TEXT);


-- ------------------------------------------------------------------------------
-- 1. ATOMIC POS SALES CHECKOUT ENGINE (REVISED V3)
-- ------------------------------------------------------------------------------
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
    IF p_payment_method IN ('Tunai', 'Transfer', 'QRIS') THEN
        v_paid := v_calc_net_total;
        v_remaining := 0.00;
        v_status := 'Lunas';
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
        v_calc_net_total, v_calc_profit, p_payment_method, p_payment_account_id, p_items, v_caller_id
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
        v_inv_no, NULL, v_cust_name, v_cust_farm, p_due_date, p_transaction_date, v_status,
        v_gross_total, v_discount_total, v_calc_net_total, v_paid, v_remaining, NULL, NULL,
        v_trx_id, v_caller_id, p_payment_method
    ) RETURNING id INTO v_inv_id;

    -- Tautkan transaksi dengan invoice_id
    UPDATE public.transactions
    SET invoice_id = v_inv_id
    WHERE id = v_trx_id;

    -- Insert Invoice Items Lengkap dengan item_type, product_name, cost_price (Omit generated column 'subtotal')
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

    -- [9] Post Jurnal Akuntansi Secara Atomik
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

REVOKE EXECUTE ON FUNCTION public.create_pos_transaction_atomic FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_pos_transaction_atomic TO authenticated;


-- ------------------------------------------------------------------------------
-- 2. ATOMIC SUPPLIER PURCHASE ORDER ENGINE (REVISED V3)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_purchase_atomic(
    p_po_no VARCHAR,
    p_supplier_name VARCHAR,
    p_purchase_date DATE,
    p_payment_method VARCHAR,
    p_payment_account_id BIGINT DEFAULT NULL,
    p_total NUMERIC DEFAULT 0.00,
    p_items JSONB DEFAULT '[]'::JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_caller_role VARCHAR;
    v_purch_id BIGINT;
    v_payable_id BIGINT := NULL;
    v_item JSONB;
    v_prod RECORD;
    v_prod_id BIGINT;
    v_qty NUMERIC(15,2);
    v_cost_price NUMERIC(15,2);
    v_calc_total NUMERIC(15,2) := 0.00;
    v_old_stock NUMERIC(15,2);
    v_new_stock NUMERIC(15,2);
    v_remaining NUMERIC(15,2);
    v_paid NUMERIC(15,2);
    v_inv_coa_id BIGINT;
    v_payment_coa_id BIGINT;
    v_payable_coa_id BIGINT;
    v_pay_acc RECORD;
    v_journal_lines JSONB := '[]'::JSONB;
    v_journal_res RECORD;
BEGIN
    -- [1] Authentication & Role Guard (Owner / Admin Only)
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHENTICATED: Sesi pengguna tidak terautentikasi';
    END IF;

    v_caller_role := public.get_current_user_role();
    IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin') THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Hanya Owner dan Admin yang berhak mencatat Pembelian Supplier';
    END IF;

    -- [2] Parameter Validation & Anti-Duplicate
    IF p_po_no IS NULL OR TRIM(p_po_no) = '' THEN
        RAISE EXCEPTION 'INVALID_PARAM: Nomor PO (po_no) wajib diisi';
    END IF;

    IF EXISTS (SELECT 1 FROM public.purchases WHERE po_no = p_po_no) THEN
        RAISE EXCEPTION 'DUPLICATE_PO_NO: Nomor PO % sudah pernah dicatat', p_po_no;
    END IF;

    IF p_supplier_name IS NULL OR TRIM(p_supplier_name) = '' THEN
        RAISE EXCEPTION 'INVALID_PARAM: Nama supplier wajib diisi';
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'EMPTY_ITEMS: Pembelian harus memiliki minimal 1 item';
    END IF;

    -- [3] Iterasi Item, Validasi Harga/Qty, Hitung Total Server-Side & Row Locking Produk
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_prod_id := COALESCE((v_item->>'productId')::BIGINT, (v_item->>'product_id')::BIGINT, (v_item->>'id')::BIGINT);
        v_qty := (v_item->>'qty')::NUMERIC;
        v_cost_price := COALESCE((v_item->>'costPrice')::NUMERIC, (v_item->>'cost_price')::NUMERIC, 0.00);

        IF v_prod_id IS NULL THEN
            RAISE EXCEPTION 'INVALID_ITEM: ID produk pada rincian pembelian tidak valid';
        END IF;

        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'INVALID_QUANTITY: Kuantiti pembelian harus lebih besar dari 0';
        END IF;

        IF v_cost_price < 0 THEN
            RAISE EXCEPTION 'INVALID_PRICE: Harga modal pembelian tidak boleh negatif';
        END IF;

        SELECT * INTO v_prod FROM public.products WHERE id = v_prod_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PRODUCT_NOT_FOUND: Produk ID % tidak ditemukan', v_prod_id;
        END IF;

        v_calc_total := v_calc_total + (v_qty * v_cost_price);

        -- Tambah Stok & Update Harga Pokok (Cost Price)
        IF v_prod.type = 'barang' THEN
            v_old_stock := v_prod.stock;
            v_new_stock := v_old_stock + v_qty;

            UPDATE public.products
            SET stock = v_new_stock,
                cost_price = CASE WHEN v_cost_price > 0 THEN v_cost_price ELSE cost_price END,
                updated_at = NOW()
            WHERE id = v_prod_id;

            INSERT INTO public.stock_logs (
                product_id, product_name, action_type, qty,
                stock_before, stock_after, reference_code, note, created_by
            ) VALUES (
                v_prod_id, v_prod.name, 'PURCHASE', v_qty,
                v_old_stock, v_new_stock, p_po_no, 'Pembelian Supplier PO ' || p_po_no, v_caller_id
            );
        END IF;
    END LOOP;

    -- Validasi Total Client vs Hitungan Otoritatif Server
    IF p_total IS NOT NULL AND ABS(p_total - v_calc_total) > 0.05 THEN
        RAISE EXCEPTION 'TOTAL_MISMATCH: Total pembelian dari client (%) tidak sesuai perhitungan server (%)',
            p_total, v_calc_total;
    END IF;

    IF v_calc_total <= 0 THEN
        RAISE EXCEPTION 'INVALID_TOTAL: Total pembelian harus lebih besar dari 0';
    END IF;

    -- [4] Resolve COA untuk Jurnal Pembelian (1-1210 Persediaan Barang Dagang di Production, fallback 1-1140)
    SELECT id INTO v_inv_coa_id
    FROM public.chart_of_accounts
    WHERE code IN ('1-1210', '1-1140') AND is_active = TRUE
    ORDER BY (CASE WHEN code = '1-1210' THEN 1 ELSE 2 END)
    LIMIT 1;

    IF v_inv_coa_id IS NULL THEN
        RAISE EXCEPTION 'COA_NOT_FOUND: Bagan akun Persediaan Barang (1-1210 / 1-1140) tidak ditemukan';
    END IF;

    IF p_payment_method IN ('Tunai', 'Transfer') THEN
        IF p_payment_account_id IS NOT NULL THEN
            SELECT id, name, chart_of_account_id INTO v_pay_acc
            FROM public.payment_accounts
            WHERE id = p_payment_account_id AND is_active = TRUE;
        ELSE
            SELECT id, name, chart_of_account_id INTO v_pay_acc
            FROM public.payment_accounts
            WHERE type = (CASE WHEN p_payment_method = 'Tunai' THEN 'CASH' ELSE 'BANK' END)
              AND is_active = TRUE
            ORDER BY id ASC LIMIT 1;
        END IF;

        IF v_pay_acc.id IS NULL OR v_pay_acc.chart_of_account_id IS NULL THEN
            RAISE EXCEPTION 'PAYMENT_ACCOUNT_INVALID: Akun kas/bank ID % tidak valid atau tidak memiliki COA', p_payment_account_id;
        END IF;

        v_payment_coa_id := v_pay_acc.chart_of_account_id;
        v_paid := v_calc_total;
        v_remaining := 0.00;

        v_journal_lines := jsonb_build_array(
            jsonb_build_object(
                'chart_of_account_id', v_inv_coa_id,
                'debit', v_calc_total,
                'credit', 0,
                'description', 'Pembelian persediaan barang PO ' || p_po_no || ' (' || p_supplier_name || ')'
            ),
            jsonb_build_object(
                'chart_of_account_id', v_payment_coa_id,
                'debit', 0,
                'credit', v_calc_total,
                'description', 'Pembayaran kas/bank PO ' || p_po_no || ' via ' || v_pay_acc.name
            )
        );

    ELSIF p_payment_method = 'Kredit' THEN
        SELECT id INTO v_payable_coa_id
        FROM public.chart_of_accounts
        WHERE code = '2-1110' AND is_active = TRUE;
        IF v_payable_coa_id IS NULL THEN
            RAISE EXCEPTION 'COA_NOT_FOUND: Bagan akun Hutang Usaha Supplier (2-1110) tidak ditemukan';
        END IF;

        v_paid := 0.00;
        v_remaining := v_calc_total;

        v_journal_lines := jsonb_build_array(
            jsonb_build_object(
                'chart_of_account_id', v_inv_coa_id,
                'debit', v_calc_total,
                'credit', 0,
                'description', 'Pembelian persediaan barang PO ' || p_po_no || ' (' || p_supplier_name || ')'
            ),
            jsonb_build_object(
                'chart_of_account_id', v_payable_coa_id,
                'debit', 0,
                'credit', v_calc_total,
                'description', 'Hutang pembelian tempo PO ' || p_po_no || ' (' || p_supplier_name || ')'
            )
        );
    ELSE
        RAISE EXCEPTION 'INVALID_PAYMENT_METHOD: Metode pembayaran % tidak didukung untuk PO', p_payment_method;
    END IF;

    -- [5] Insert Purchases Header
    INSERT INTO public.purchases (
        po_no, supplier_id, supplier_name, purchase_date, total, paid_amount, remaining,
        payment_method, payment_account_id, created_by
    ) VALUES (
        p_po_no, NULL, p_supplier_name, p_purchase_date, v_calc_total, v_paid, v_remaining,
        p_payment_method, p_payment_account_id, v_caller_id
    ) RETURNING id INTO v_purch_id;

    -- [6] Insert Purchase Items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_prod_id := COALESCE((v_item->>'productId')::BIGINT, (v_item->>'product_id')::BIGINT, (v_item->>'id')::BIGINT);
        v_qty := (v_item->>'qty')::NUMERIC;
        v_cost_price := COALESCE((v_item->>'costPrice')::NUMERIC, (v_item->>'cost_price')::NUMERIC, 0.00);

        INSERT INTO public.purchase_items (
            purchase_id, product_id, cost_price, qty
        ) VALUES (
            v_purch_id, v_prod_id, v_cost_price, v_qty
        );
    END LOOP;

    -- [7] If Payment Method is Kredit, Insert into Payables (Menjaga default tempo 30 hari database)
    IF p_payment_method = 'Kredit' THEN
        INSERT INTO public.payables (
            purchase_id, po_no, supplier_name, status, total, paid, remaining
        ) VALUES (
            v_purch_id, p_po_no, p_supplier_name, 'Belum Lunas', v_calc_total, 0.00, v_calc_total
        ) RETURNING id INTO v_payable_id;
    END IF;

    -- [8] Post Journal Entry Atomically
    SELECT journal_id, journal_no INTO v_journal_res
    FROM public.post_journal_entry(
        p_journal_date := p_purchase_date,
        p_source_type := 'PURCHASE',
        p_source_id := v_purch_id,
        p_source_code := p_po_no,
        p_description := 'Pembelian Supplier PO ' || p_po_no || ' (' || p_supplier_name || ')',
        p_user_id := v_caller_id,
        p_lines := v_journal_lines
    );

    RETURN jsonb_build_object(
        'success', true,
        'purchase_id', v_purch_id,
        'po_no', p_po_no,
        'payable_id', v_payable_id,
        'journal_id', v_journal_res.journal_id,
        'journal_no', v_journal_res.journal_no,
        'total', v_calc_total,
        'paid', v_paid,
        'remaining', v_remaining
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_purchase_atomic FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_purchase_atomic TO authenticated;


-- ------------------------------------------------------------------------------
-- 3. ATOMIC OPERATIONAL EXPENSE ENGINE
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_expense_atomic(
    p_expense_no VARCHAR,
    p_expense_date DATE,
    p_chart_of_account_id BIGINT,
    p_payment_account_id BIGINT,
    p_amount NUMERIC,
    p_payee VARCHAR,
    p_project_id BIGINT DEFAULT NULL,
    p_note TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_caller_role VARCHAR;
    v_exp_id BIGINT;
    v_expense_coa RECORD;
    v_pay_acc RECORD;
    v_journal_lines JSONB := '[]'::JSONB;
    v_journal_res RECORD;
BEGIN
    -- [1] Authentication & Role Guard (Owner / Admin Only)
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHENTICATED: Sesi pengguna tidak terautentikasi';
    END IF;

    v_caller_role := public.get_current_user_role();
    IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin') THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Hanya Owner dan Admin yang berhak mencatat Beban Operasional';
    END IF;

    -- [2] Parameter Validation
    IF p_expense_no IS NULL OR TRIM(p_expense_no) = '' THEN
        RAISE EXCEPTION 'INVALID_PARAM: Nomor beban (expense_no) wajib diisi';
    END IF;

    IF EXISTS (SELECT 1 FROM public.expenses WHERE expense_no = p_expense_no) THEN
        RAISE EXCEPTION 'DUPLICATE_EXPENSE_NO: Nomor beban % sudah pernah dicatat', p_expense_no;
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: Jumlah nominal beban harus lebih besar dari 0';
    END IF;

    -- [3] COA Verification
    SELECT id, code, name, category INTO v_expense_coa
    FROM public.chart_of_accounts
    WHERE id = p_chart_of_account_id AND is_active = TRUE;

    IF v_expense_coa.id IS NULL OR v_expense_coa.category <> 'EXPENSE' THEN
        RAISE EXCEPTION 'INVALID_COA: Akun beban operasional tidak valid atau bukan kategori EXPENSE';
    END IF;

    SELECT id, name, chart_of_account_id INTO v_pay_acc
    FROM public.payment_accounts
    WHERE id = p_payment_account_id AND is_active = TRUE;

    IF v_pay_acc.id IS NULL OR v_pay_acc.chart_of_account_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_PAYMENT_ACCOUNT: Akun kas/bank pembayaran tidak valid atau tidak memiliki COA';
    END IF;

    -- [4] Insert Expense Record
    INSERT INTO public.expenses (
        expense_no, expense_date, chart_of_account_id, payment_account_id, amount,
        payee, project_id, note, status, created_by
    ) VALUES (
        p_expense_no, p_expense_date, p_chart_of_account_id, p_payment_account_id, p_amount,
        COALESCE(p_payee, '-'), p_project_id, COALESCE(p_note, ''), 'VALID', v_caller_id
    ) RETURNING id INTO v_exp_id;

    -- [5] Post Double-Entry Journal Atomically
    v_journal_lines := jsonb_build_array(
        jsonb_build_object(
            'chart_of_account_id', v_expense_coa.id,
            'debit', p_amount,
            'credit', 0,
            'description', 'Beban ' || v_expense_coa.name || ' (' || p_expense_no || ')'
        ),
        jsonb_build_object(
            'chart_of_account_id', v_pay_acc.chart_of_account_id,
            'debit', 0,
            'credit', p_amount,
            'description', 'Pengeluaran kas/bank untuk ' || p_expense_no || ' via ' || v_pay_acc.name
        )
    );

    SELECT journal_id, journal_no INTO v_journal_res
    FROM public.post_journal_entry(
        p_journal_date := p_expense_date,
        p_source_type := 'EXPENSE',
        p_source_id := v_exp_id,
        p_source_code := p_expense_no,
        p_description := 'Beban Operasional ' || p_expense_no || ' - ' || v_expense_coa.name,
        p_user_id := v_caller_id,
        p_lines := v_journal_lines
    );

    RETURN jsonb_build_object(
        'success', true,
        'expense_id', v_exp_id,
        'expense_no', p_expense_no,
        'journal_id', v_journal_res.journal_id,
        'journal_no', v_journal_res.journal_no
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_expense_atomic FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_expense_atomic TO authenticated;


-- ------------------------------------------------------------------------------
-- 4. ATOMIC EQUITY & DRAWING (MODAL & PRIVE) ENGINE
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_equity_transaction_atomic(
    p_equity_no VARCHAR,
    p_equity_date DATE,
    p_transaction_type VARCHAR,
    p_chart_of_account_id BIGINT,
    p_payment_account_id BIGINT,
    p_amount NUMERIC,
    p_note TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_caller_role VARCHAR;
    v_eq_id BIGINT;
    v_eq_coa RECORD;
    v_pay_acc RECORD;
    v_journal_lines JSONB := '[]'::JSONB;
    v_journal_res RECORD;
    v_normalized_type VARCHAR;
BEGIN
    -- [1] Authentication & Role Guard (Owner Only)
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHENTICATED: Sesi pengguna tidak terautentikasi';
    END IF;

    v_caller_role := public.get_current_user_role();
    IF v_caller_role IS NULL OR v_caller_role <> 'owner' THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Hanya Owner yang berhak mencatat transaksi Modal dan Prive';
    END IF;

    -- [2] Parameter Validation
    IF p_equity_no IS NULL OR TRIM(p_equity_no) = '' THEN
        RAISE EXCEPTION 'INVALID_PARAM: Nomor transaksi ekuitas (equity_no) wajib diisi';
    END IF;

    IF EXISTS (SELECT 1 FROM public.equity_transactions WHERE equity_no = p_equity_no) THEN
        RAISE EXCEPTION 'DUPLICATE_EQUITY_NO: Nomor transaksi ekuitas % sudah pernah dicatat', p_equity_no;
    END IF;

    -- Normalize frontend type identifiers (CAPITAL_IN / DRAWING_OUT) to DB canonical values (MODAL / PRIVE)
    IF p_transaction_type IN ('MODAL', 'CAPITAL_IN') THEN
        v_normalized_type := 'MODAL';
    ELSIF p_transaction_type IN ('PRIVE', 'DRAWING_OUT') THEN
        v_normalized_type := 'PRIVE';
    ELSE
        RAISE EXCEPTION 'INVALID_TYPE: Tipe transaksi harus MODAL/CAPITAL_IN atau PRIVE/DRAWING_OUT';
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: Jumlah nominal ekuitas harus lebih besar dari 0';
    END IF;

    -- [3] Resolve Accounts
    SELECT id, code, name, category INTO v_eq_coa
    FROM public.chart_of_accounts
    WHERE id = p_chart_of_account_id AND is_active = TRUE;

    IF v_eq_coa.id IS NULL OR v_eq_coa.category <> 'EQUITY' THEN
        RAISE EXCEPTION 'INVALID_COA: Akun ekuitas tidak valid atau bukan kategori EQUITY';
    END IF;

    SELECT id, name, chart_of_account_id INTO v_pay_acc
    FROM public.payment_accounts
    WHERE id = p_payment_account_id AND is_active = TRUE;

    IF v_pay_acc.id IS NULL OR v_pay_acc.chart_of_account_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_PAYMENT_ACCOUNT: Akun kas/bank pembayaran tidak valid atau tidak memiliki COA';
    END IF;

    -- [4] Insert Equity Transaction Record (using normalized type)
    INSERT INTO public.equity_transactions (
        equity_no, equity_date, transaction_type, chart_of_account_id, payment_account_id,
        amount, note, status, created_by
    ) VALUES (
        p_equity_no, p_equity_date, v_normalized_type, p_chart_of_account_id, p_payment_account_id,
        p_amount, COALESCE(p_note, ''), 'VALID', v_caller_id
    ) RETURNING id INTO v_eq_id;

    -- [5] Post Double-Entry Journal Atomically (using normalized type)
    IF v_normalized_type = 'MODAL' THEN
        -- Modal Setor: Kas Bertambah (Debit), Modal Bertambah (Credit)
        v_journal_lines := jsonb_build_array(
            jsonb_build_object(
                'chart_of_account_id', v_pay_acc.chart_of_account_id,
                'debit', p_amount,
                'credit', 0,
                'description', 'Penerimaan setoran modal (' || p_equity_no || ') via ' || v_pay_acc.name
            ),
            jsonb_build_object(
                'chart_of_account_id', v_eq_coa.id,
                'debit', 0,
                'credit', p_amount,
                'description', 'Setoran modal pemilik ' || v_eq_coa.name || ' (' || p_equity_no || ')'
            )
        );
    ELSE
        -- Prive: Penarikan Pemilik (Debit Prive 3-1120), Kas Berkurang (Credit)
        v_journal_lines := jsonb_build_array(
            jsonb_build_object(
                'chart_of_account_id', v_eq_coa.id,
                'debit', p_amount,
                'credit', 0,
                'description', 'Prive penarikan pemilik ' || v_eq_coa.name || ' (' || p_equity_no || ')'
            ),
            jsonb_build_object(
                'chart_of_account_id', v_pay_acc.chart_of_account_id,
                'debit', 0,
                'credit', p_amount,
                'description', 'Pengeluaran kas/bank untuk prive (' || p_equity_no || ') via ' || v_pay_acc.name
            )
        );
    END IF;

    SELECT journal_id, journal_no INTO v_journal_res
    FROM public.post_journal_entry(
        p_journal_date := p_equity_date,
        p_source_type := 'EQUITY',
        p_source_id := v_eq_id,
        p_source_code := p_equity_no,
        p_description := 'Transaksi Ekuitas ' || v_normalized_type || ' (' || p_equity_no || ')',
        p_user_id := v_caller_id,
        p_lines := v_journal_lines
    );

    RETURN jsonb_build_object(
        'success', true,
        'equity_id', v_eq_id,
        'equity_no', p_equity_no,
        'journal_id', v_journal_res.journal_id,
        'journal_no', v_journal_res.journal_no
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_equity_transaction_atomic FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_equity_transaction_atomic TO authenticated;


-- ------------------------------------------------------------------------------
-- 5. ATOMIC QUOTATION TO INVOICE CONVERSION ENGINE (REVISED V3)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.convert_quotation_to_invoice_atomic(
    p_quotation_id BIGINT,
    p_inv_no VARCHAR,
    p_inv_date DATE,
    p_due_date DATE DEFAULT NULL,
    p_customer_name VARCHAR DEFAULT NULL,
    p_customer_farm VARCHAR DEFAULT NULL,
    p_payment_method VARCHAR DEFAULT 'Kredit',
    p_payment_account_id BIGINT DEFAULT NULL,
    p_paid_amount NUMERIC DEFAULT 0.00,
    p_items JSONB DEFAULT '[]'::JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_caller_role VARCHAR;
    v_qt RECORD;
    v_inv_id BIGINT;
    v_rec_id BIGINT := NULL;
    v_item JSONB;
    v_prod_id BIGINT;
    v_prod RECORD;
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
    v_discount_total NUMERIC(15,2) := 0.00;
    v_net_total NUMERIC(15,2) := 0.00;
    v_barang_net NUMERIC(15,2) := 0.00;
    v_jasa_net NUMERIC(15,2) := 0.00;
    v_paid NUMERIC(15,2);
    v_remaining NUMERIC(15,2);
    v_status VARCHAR;
    v_stored_method VARCHAR;
    v_sales_coa_id BIGINT;
    v_service_coa_id BIGINT;
    v_piutang_coa_id BIGINT;
    v_pay_coa_id BIGINT;
    v_pay_acc RECORD;
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
        RAISE EXCEPTION 'UNAUTHORIZED: Pengguna tidak memiliki hak untuk mengonversi penawaran';
    END IF;

    -- [2] Lock & Validate Source Quotation (Row Locking FOR UPDATE)
    IF p_quotation_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_PARAM: quotation_id wajib diisi';
    END IF;

    SELECT * INTO v_qt FROM public.quotations WHERE id = p_quotation_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'QUOTATION_NOT_FOUND: Penawaran ID % tidak ditemukan', p_quotation_id;
    END IF;

    IF v_qt.status = 'Converted' THEN
        RAISE EXCEPTION 'ALREADY_CONVERTED: Penawaran % sudah pernah dikonversi menjadi Invoice', v_qt.qt_no;
    END IF;

    IF p_inv_no IS NULL OR TRIM(p_inv_no) = '' THEN
        RAISE EXCEPTION 'INVALID_PARAM: Nomor invoice (inv_no) wajib diisi';
    END IF;

    IF EXISTS (SELECT 1 FROM public.invoices WHERE inv_no = p_inv_no) THEN
        RAISE EXCEPTION 'DUPLICATE_INV_NO: Nomor invoice % sudah pernah digunakan', p_inv_no;
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'EMPTY_ITEMS: Invoice harus memiliki minimal 1 item';
    END IF;

    -- [3] Hitung Ulang Nominal & Split Barang vs Jasa
    -- ATURAN BISNIS MUTLAK: Konversi Penawaran TIDAK MENGUBAH STOK
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_qty := (v_item->>'qty')::NUMERIC;
        v_price := (v_item->>'price')::NUMERIC;

        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'INVALID_ITEM_VALUES: Kuantiti item invoice tidak valid';
        END IF;

        IF v_price IS NULL OR v_price < 0 THEN
            RAISE EXCEPTION 'INVALID_ITEM_VALUES: Harga item invoice tidak boleh negatif';
        END IF;

        v_disc_type := COALESCE(v_item->>'discountType', v_item->>'discount_type', 'none');
        v_disc_val := COALESCE((v_item->>'discountValue')::NUMERIC, (v_item->>'discount_value')::NUMERIC, 0.00);
        v_disc_amt := COALESCE((v_item->>'discountAmount')::NUMERIC, (v_item->>'discount_amount')::NUMERIC, 0.00);

        IF v_disc_type IN ('percent', 'percentage') AND v_disc_val > 0 THEN
            v_disc_amt := ROUND((v_qty * v_price * v_disc_val / 100.0), 2);
        ELSIF v_disc_type IN ('nominal', 'fixed', 'rp') AND v_disc_val > 0 AND v_disc_amt = 0 THEN
            v_disc_amt := v_disc_val;
        END IF;

        IF v_disc_amt < 0 OR v_disc_amt > (v_qty * v_price) THEN
            RAISE EXCEPTION 'INVALID_DISCOUNT: Nilai diskon pada item invoice tidak valid';
        END IF;

        v_item_subtotal := (v_qty * v_price) - v_disc_amt;

        v_gross_total := v_gross_total + (v_qty * v_price);
        v_discount_total := v_discount_total + v_disc_amt;
        v_net_total := v_net_total + v_item_subtotal;

        IF COALESCE(v_item->>'type', 'barang') = 'jasa' THEN
            v_jasa_net := v_jasa_net + v_item_subtotal;
        ELSE
            v_barang_net := v_barang_net + v_item_subtotal;
        END IF;
    END LOOP;

    -- Cocokkan dengan Total Penawaran Asli Jika Tersedia
    IF v_qt.total IS NOT NULL AND ABS(v_qt.total - v_net_total) > 0.05 THEN
        RAISE EXCEPTION 'TOTAL_MISMATCH: Nilai penawaran asli (%) tidak sesuai dengan rincian invoice server (%)',
            v_qt.total, v_net_total;
    END IF;

    IF v_net_total <= 0 THEN
        RAISE EXCEPTION 'INVALID_TOTAL: Total invoice harus lebih besar dari 0';
    END IF;

    -- [4] Validasi Pembayaran, DP & Sisa Piutang (Due Date Opsional)
    --     Metode pembayaran yang didukung:
    --       'Tunai'            = Bayar penuh langsung (Lunas)
    --       'TunaiBelumLunas'  = Cash tapi belum bayar (piutang penuh, tanpa jurnal kas, metode tersimpan tetap Tunai)
    --       'Kredit'           = Tempo/piutang dengan DP opsional
    IF p_payment_method IS NULL OR p_payment_method NOT IN ('Tunai', 'TunaiBelumLunas', 'Tunai Belum Lunas', 'Kredit') THEN
        RAISE EXCEPTION 'INVALID_PAYMENT_METHOD: Metode pembayaran "%" tidak didukung untuk konversi penawaran. Gunakan Tunai, TunaiBelumLunas, atau Kredit.', p_payment_method;
    END IF;

    IF p_payment_method = 'Tunai' THEN
        -- Tunai + Lunas: pembayaran penuh, tanpa piutang
        v_paid := v_net_total;
        v_remaining := 0.00;
        v_status := 'Lunas';
        v_stored_method := 'Tunai';
    ELSIF p_payment_method IN ('TunaiBelumLunas', 'Tunai Belum Lunas') THEN
        -- Tunai + Belum Lunas: tidak ada uang diterima, seluruhnya piutang, metode tetap Tunai
        v_paid := 0.00;
        v_remaining := v_net_total;
        v_status := 'Belum Bayar';
        v_stored_method := 'Tunai';
    ELSE
        -- Kredit / Tempo: DP sesuai input, sisa masuk piutang
        v_paid := LEAST(v_net_total, GREATEST(0.00, COALESCE(p_paid_amount, 0.00)));
        v_remaining := GREATEST(0.00, v_net_total - v_paid);
        IF v_remaining <= 0.001 THEN
            v_status := 'Lunas';
        ELSIF v_paid > 0.001 THEN
            v_status := 'Sebagian';
        ELSE
            v_status := 'Belum Bayar';
        END IF;
        v_stored_method := 'Kredit';
    END IF;

    -- [5] Resolve COAs for Invoices
    SELECT id INTO v_sales_coa_id FROM public.chart_of_accounts WHERE code = '4-1110' AND is_active = TRUE;
    SELECT id INTO v_service_coa_id FROM public.chart_of_accounts WHERE code = '4-1120' AND is_active = TRUE;
    IF v_service_coa_id IS NULL THEN v_service_coa_id := v_sales_coa_id; END IF;

    SELECT id INTO v_piutang_coa_id FROM public.chart_of_accounts WHERE code = '1-1110' AND is_active = TRUE;

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
            RAISE EXCEPTION 'COA_NOT_FOUND: Akun kas pembayaran untuk invoice tidak ditemukan';
        END IF;

        v_journal_lines := v_journal_lines || jsonb_build_array(
            jsonb_build_object(
                'chart_of_account_id', v_pay_coa_id,
                'debit', v_paid,
                'credit', 0,
                'description', 'Penerimaan Penjualan Invoice ' || p_inv_no || ' (' || COALESCE(p_customer_name, v_qt.customer_name, 'Pelanggan') || ')'
            )
        );
    END IF;

    IF v_remaining > 0 THEN
        IF v_piutang_coa_id IS NULL THEN
            RAISE EXCEPTION 'COA_NOT_FOUND: Bagan akun Piutang Usaha (1-1110) tidak ditemukan';
        END IF;

        v_journal_lines := v_journal_lines || jsonb_build_array(
            jsonb_build_object(
                'chart_of_account_id', v_piutang_coa_id,
                'debit', v_remaining,
                'credit', 0,
                'description', 'Piutang Penjualan Invoice ' || p_inv_no || ' (' || COALESCE(p_customer_name, v_qt.customer_name, 'Pelanggan') || ')'
            )
        );
    END IF;

    IF v_barang_net > 0 THEN
        v_journal_lines := v_journal_lines || jsonb_build_array(
            jsonb_build_object(
                'chart_of_account_id', v_sales_coa_id,
                'debit', 0,
                'credit', v_barang_net,
                'description', 'Penjualan Barang Invoice ' || p_inv_no
            )
        );
    END IF;

    IF v_jasa_net > 0 THEN
        v_journal_lines := v_journal_lines || jsonb_build_array(
            jsonb_build_object(
                'chart_of_account_id', v_service_coa_id,
                'debit', 0,
                'credit', v_jasa_net,
                'description', 'Pendapatan Jasa Invoice ' || p_inv_no
            )
        );
    END IF;

    -- [6] Insert Invoice Header
    INSERT INTO public.invoices (
        inv_no, customer_id, customer_name, customer_farm, due_date, invoice_date, status,
        subtotal, discount_total, total, paid_amount, remaining, project_id, quotation_id,
        created_by, payment_method
    ) VALUES (
        p_inv_no, v_qt.customer_id, COALESCE(p_customer_name, v_qt.customer_name, 'Pelanggan'),
        COALESCE(p_customer_farm, '-'), p_due_date, p_inv_date, v_status,
        v_gross_total, v_discount_total, v_net_total, v_paid, v_remaining, v_qt.project_id, p_quotation_id,
        v_caller_id, v_stored_method
    ) RETURNING id INTO v_inv_id;

    -- [7] Insert Invoice Items Lengkap dengan item_type, product_name, cost_price (Omit generated column 'subtotal')
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

    -- [8] Insert Receivables Jika Masih Ada Sisa
    IF v_remaining > 0 THEN
        INSERT INTO public.receivables (
            invoice_id, inv_no, customer_name, due_date, status, total, paid, remaining
        ) VALUES (
            v_inv_id, p_inv_no, COALESCE(p_customer_name, v_qt.customer_name, 'Pelanggan'),
            p_due_date, v_status, v_net_total, v_paid, v_remaining
        ) RETURNING id INTO v_rec_id;
    END IF;

    -- [9] Lock Quotation Status to 'Converted'
    UPDATE public.quotations
    SET status = 'Converted',
        updated_at = NOW()
    WHERE id = p_quotation_id;

    -- [10] Post Jurnal Akuntansi Secara Atomik
    IF jsonb_array_length(v_journal_lines) > 0 THEN
        SELECT journal_id, journal_no INTO v_journal_res
        FROM public.post_journal_entry(
            p_journal_date := p_inv_date,
            p_source_type := 'INVOICE',
            p_source_id := v_inv_id,
            p_source_code := p_inv_no,
            p_description := 'Faktur Penjualan ' || p_inv_no || ' (Konversi QT ' || v_qt.qt_no || ')',
            p_user_id := v_caller_id,
            p_lines := v_journal_lines
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'invoice_id', v_inv_id,
        'inv_no', p_inv_no,
        'receivable_id', v_rec_id,
        'journal_id', COALESCE(v_journal_res.journal_id, NULL),
        'journal_no', COALESCE(v_journal_res.journal_no, NULL),
        'total', v_net_total,
        'paid_amount', v_paid,
        'remaining', v_remaining,
        'status', v_status,
        'payment_method', v_stored_method
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.convert_quotation_to_invoice_atomic FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.convert_quotation_to_invoice_atomic TO authenticated;


-- ------------------------------------------------------------------------------
-- 6. ENHANCED ATOMIC VOID FOR POS WITH STRICT PAYMENT CHECK GUARD (V3)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.void_pos_transaction_atomic(
    p_transaction_id BIGINT,
    p_reason TEXT DEFAULT 'VOID Transaksi oleh Pengguna'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_caller_role VARCHAR;
    v_trx RECORD;
    v_linked_inv_ids BIGINT[];
    v_pay_count INT := 0;
    v_orig_journal_id BIGINT;
    v_reversal_id BIGINT := NULL;
    v_reversal_res RECORD;
    v_item JSONB;
    v_prod RECORD;
    v_prod_id BIGINT;
    v_item_qty NUMERIC(15,2);
    v_old_stock NUMERIC(15,2);
    v_new_stock NUMERIC(15,2);
BEGIN
    -- [1] Authentication & Role Authorization (Owner & Admin Only)
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHENTICATED: Sesi pengguna tidak terautentikasi';
    END IF;

    v_caller_role := public.get_current_user_role();
    IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin') THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Hanya Owner atau Admin yang berhak membatalkan (VOID) transaksi POS';
    END IF;

    IF p_transaction_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_PARAM: p_transaction_id wajib diisi';
    END IF;

    -- [2] Lock Target Transaction
    SELECT * INTO v_trx FROM public.transactions WHERE id = p_transaction_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSACTION_NOT_FOUND: Transaksi ID % tidak ditemukan', p_transaction_id;
    END IF;

    IF v_trx.status = 'VOID' THEN
        RAISE EXCEPTION 'ALREADY_VOIDED: Transaksi % sudah berstatus VOID', v_trx.trx_code;
    END IF;

    IF v_trx.transaction_type = 'Beli' THEN
        RAISE EXCEPTION 'INVALID_TYPE: Transaksi pembelian tidak dapat di-VOID melalui fungsi ini';
    END IF;

    -- [3] Relational Linked Invoices & Active Payment Check Guard
    SELECT ARRAY_AGG(id) INTO v_linked_inv_ids
    FROM public.invoices
    WHERE transaction_id = p_transaction_id
       OR id = v_trx.invoice_id
       OR inv_no = v_trx.trx_code
       OR inv_no = ('INV-' || v_trx.trx_code);

    IF v_linked_inv_ids IS NOT NULL AND array_length(v_linked_inv_ids, 1) > 0 THEN
        SELECT COUNT(*) INTO v_pay_count
        FROM public.payment_history
        WHERE status = 'VALID'
          AND (
              invoice_id = ANY(v_linked_inv_ids)
              OR inv_no IN (
                  SELECT inv_no FROM public.invoices WHERE id = ANY(v_linked_inv_ids)
              )
          );

        IF v_pay_count > 0 THEN
            RAISE EXCEPTION 'CANNOT_VOID_PAID_TRANSACTION: Transaksi % memiliki % pembayaran piutang aktif berstatus VALID pada invoice terkait. Batalkan atau VOID pembayaran piutang terlebih dahulu melalui menu Pembayaran Piutang sebelum membatalkan transaksi POS ini.',
                v_trx.trx_code, v_pay_count;
        END IF;
    END IF;

    -- [4] Lookup & Reverse Associated Journal Entry
    SELECT id INTO v_orig_journal_id
    FROM public.journal_entries
    WHERE source_type = 'TRANSACTION'
      AND (source_id = p_transaction_id OR source_code = v_trx.trx_code)
      AND is_reversal = FALSE
      AND status = 'POSTED'
    ORDER BY id DESC
    LIMIT 1;

    IF v_orig_journal_id IS NOT NULL THEN
        SELECT reversal_id INTO v_reversal_res
        FROM public.reverse_journal_entry(
            p_original_journal_id := v_orig_journal_id,
            p_user_id := v_caller_id,
            p_reversal_reason := COALESCE(p_reason, 'VOID Transaksi POS ' || v_trx.trx_code)
        );
        v_reversal_id := v_reversal_res.reversal_id;
    END IF;

    -- [5] Update Transactions Status Atomically
    UPDATE public.transactions
    SET status = 'VOID',
        voided_at = NOW(),
        voided_by = v_caller_id,
        updated_at = NOW()
    WHERE id = p_transaction_id;

    -- [6] Restore Stock Atomically & Log in stock_logs (Action Type 'VOID')
    IF v_trx.items IS NOT NULL AND jsonb_typeof(v_trx.items) = 'array' THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(v_trx.items) LOOP
            v_prod_id := COALESCE((v_item->>'productId')::BIGINT, (v_item->>'product_id')::BIGINT, (v_item->>'id')::BIGINT);
            v_item_qty := COALESCE((v_item->>'qty')::NUMERIC, 0.00);

            IF v_prod_id IS NOT NULL AND v_item_qty > 0 THEN
                SELECT * INTO v_prod FROM public.products WHERE id = v_prod_id FOR UPDATE;
                IF FOUND AND v_prod.type = 'barang' THEN
                    v_old_stock := v_prod.stock;
                    v_new_stock := v_old_stock + v_item_qty;

                    UPDATE public.products
                    SET stock = v_new_stock,
                        updated_at = NOW()
                    WHERE id = v_prod_id;

                    INSERT INTO public.stock_logs (
                        product_id, product_name, action_type, qty, stock_before, stock_after, reference_code, note, created_by
                    ) VALUES (
                        v_prod_id, v_prod.name, 'VOID', v_item_qty, v_old_stock, v_new_stock, v_trx.trx_code,
                        'Pengembalian stok void transaksi ' || v_trx.trx_code, v_caller_id
                    );
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- [7] Cancel Associated Invoice and Receivable Atomically
    IF v_linked_inv_ids IS NOT NULL AND array_length(v_linked_inv_ids, 1) > 0 THEN
        UPDATE public.invoices
        SET status = 'Dibatalkan',
            remaining = 0.00,
            updated_at = NOW()
        WHERE id = ANY(v_linked_inv_ids);

        UPDATE public.receivables
        SET status = 'Dibatalkan',
            remaining = 0.00,
            updated_at = NOW()
        WHERE invoice_id = ANY(v_linked_inv_ids);
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'transaction_id', p_transaction_id,
        'trx_code', v_trx.trx_code,
        'reversal_journal_id', v_reversal_id,
        'status', 'VOID'
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.void_pos_transaction_atomic FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_pos_transaction_atomic TO authenticated;

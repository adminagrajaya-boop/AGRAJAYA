-- ==============================================================================
-- AGRA JAYA POS — MIGRATION: COMPREHENSIVE ATOMIC BUSINESS TRANSACTIONS ENGINE
-- Target Database: PostgreSQL (Supabase)
-- Purpose: 100% server-side atomicity for POS, PO, Expense, Equity, & Quotation Conversion.
--          Eliminates client-side multi-request drift and dangerous compensation deletes.
-- ==============================================================================

BEGIN;

-- Ensure cost_price column exists on invoice_items for complete audit compatibility
ALTER TABLE public.invoice_items 
    ADD COLUMN IF NOT EXISTS cost_price NUMERIC(15,2) DEFAULT 0.00;

-- ------------------------------------------------------------------------------
-- 1. ATOMIC POS TRANSACTIONS ENGINE
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
    p_inv_no VARCHAR DEFAULT NULL
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
    v_inv_id BIGINT := NULL;
    v_item JSONB;
    v_prod RECORD;
    v_prod_id BIGINT;
    v_qty NUMERIC(15,2);
    v_old_stock NUMERIC(15,2);
    v_new_stock NUMERIC(15,2);
    v_rev_coa_id BIGINT;
    v_payment_coa_id BIGINT;
    v_piutang_coa_id BIGINT;
    v_dp_coa_id BIGINT;
    v_pay_acc RECORD;
    v_journal_lines JSONB := '[]'::JSONB;
    v_journal_res RECORD;
    v_paid NUMERIC(15,2);
    v_remaining NUMERIC(15,2);
    v_inv_no VARCHAR;
    v_inv_status VARCHAR;
BEGIN
    -- [1] Authentication & Role Guard
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHENTICATED: Sesi pengguna tidak terautentikasi';
    END IF;

    v_caller_role := public.get_current_user_role();
    IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin', 'kasir') THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Pengguna tidak memiliki hak untuk memproses transaksi POS';
    END IF;

    -- [2] Parameter Validation & Anti-Duplicate
    IF p_trx_code IS NULL OR TRIM(p_trx_code) = '' THEN
        RAISE EXCEPTION 'INVALID_PARAM: Kode transaksi (trx_code) wajib diisi';
    END IF;

    IF EXISTS (SELECT 1 FROM public.transactions WHERE trx_code = p_trx_code) THEN
        RAISE EXCEPTION 'DUPLICATE_TRX_CODE: Kode transaksi % sudah pernah diproses', p_trx_code;
    END IF;

    IF p_total IS NULL OR p_total < 0 THEN
        RAISE EXCEPTION 'INVALID_TOTAL: Total transaksi tidak valid (Rp %)', p_total;
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'EMPTY_ITEMS: Transaksi harus memiliki minimal 1 item belanja';
    END IF;

    -- [3] Resolve Accounting COAs
    SELECT id INTO v_rev_coa_id
    FROM public.chart_of_accounts
    WHERE code = '4-1110' AND is_active = TRUE;
    IF v_rev_coa_id IS NULL THEN
        RAISE EXCEPTION 'COA_NOT_FOUND: Bagan akun Pendapatan Penjualan Barang (4-1110) tidak ditemukan';
    END IF;

    IF p_payment_method IN ('Tunai', 'Transfer', 'QRIS') THEN
        IF p_payment_account_id IS NULL THEN
            RAISE EXCEPTION 'INVALID_PARAM: payment_account_id wajib diisi untuk metode %', p_payment_method;
        END IF;

        SELECT id, name, chart_of_account_id INTO v_pay_acc
        FROM public.payment_accounts
        WHERE id = p_payment_account_id AND is_active = TRUE;

        IF NOT FOUND OR v_pay_acc.chart_of_account_id IS NULL THEN
            RAISE EXCEPTION 'PAYMENT_ACCOUNT_INVALID: Akun pembayaran ID % tidak valid atau tidak memiliki relasi COA', p_payment_account_id;
        END IF;

        v_payment_coa_id := v_pay_acc.chart_of_account_id;

        -- Prepare Journal Lines
        v_journal_lines := jsonb_build_array(
            jsonb_build_object(
                'chart_of_account_id', v_payment_coa_id,
                'debit', p_total,
                'credit', 0,
                'description', 'Penerimaan kas/bank POS ' || p_trx_code || ' via ' || v_pay_acc.name
            ),
            jsonb_build_object(
                'chart_of_account_id', v_rev_coa_id,
                'debit', 0,
                'credit', p_total,
                'description', 'Penjualan barang POS ' || p_trx_code || ' (' || COALESCE(p_party_name, 'Pelanggan Umum') || ')'
            )
        );

    ELSIF p_payment_method = 'Kredit' THEN
        SELECT id INTO v_piutang_coa_id
        FROM public.chart_of_accounts
        WHERE code = '1-1110' AND is_active = TRUE;
        IF v_piutang_coa_id IS NULL THEN
            RAISE EXCEPTION 'COA_NOT_FOUND: Bagan akun Piutang Usaha (1-1110) tidak ditemukan';
        END IF;

        v_paid := LEAST(p_total, GREATEST(0.00, COALESCE(p_dp_amount, 0.00)));
        v_remaining := GREATEST(0.00, p_total - v_paid);

        IF v_paid > 0 THEN
            IF p_payment_account_id IS NOT NULL THEN
                SELECT chart_of_account_id INTO v_dp_coa_id
                FROM public.payment_accounts
                WHERE id = p_payment_account_id AND is_active = TRUE;
            ELSE
                SELECT chart_of_account_id INTO v_dp_coa_id
                FROM public.payment_accounts
                WHERE type = 'CASH' AND is_active = TRUE
                ORDER BY id ASC LIMIT 1;
            END IF;

            IF v_dp_coa_id IS NULL THEN
                RAISE EXCEPTION 'COA_NOT_FOUND: Akun kas penampung DP piutang tidak ditemukan';
            END IF;

            v_journal_lines := v_journal_lines || jsonb_build_array(
                jsonb_build_object(
                    'chart_of_account_id', v_dp_coa_id,
                    'debit', v_paid,
                    'credit', 0,
                    'description', 'Penerimaan DP tunai POS ' || p_trx_code || ' (' || COALESCE(p_party_name, 'Pelanggan Kredit') || ')'
                )
            );
        END IF;

        IF v_remaining > 0 THEN
            v_journal_lines := v_journal_lines || jsonb_build_array(
                jsonb_build_object(
                    'chart_of_account_id', v_piutang_coa_id,
                    'debit', v_remaining,
                    'credit', 0,
                    'description', 'Piutang penjualan POS ' || p_trx_code || ' (' || COALESCE(p_party_name, 'Pelanggan Kredit') || ')'
                )
            );
        END IF;

        v_journal_lines := v_journal_lines || jsonb_build_array(
            jsonb_build_object(
                'chart_of_account_id', v_rev_coa_id,
                'debit', 0,
                'credit', p_total,
                'description', 'Penjualan barang POS ' || p_trx_code || ' (' || COALESCE(p_party_name, 'Pelanggan Kredit') || ')'
            )
        );

    ELSE
        RAISE EXCEPTION 'INVALID_PAYMENT_METHOD: Metode pembayaran % tidak didukung', p_payment_method;
    END IF;

    -- [4] Row Locking & Stock Deduction for Products
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_prod_id := COALESCE((v_item->>'productId')::BIGINT, (v_item->>'id')::BIGINT);
        v_qty := COALESCE((v_item->>'qty')::NUMERIC, 0.00);

        IF v_prod_id IS NOT NULL AND v_qty > 0 THEN
            SELECT * INTO v_prod FROM public.products WHERE id = v_prod_id FOR UPDATE;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'PRODUCT_NOT_FOUND: Produk ID % tidak ditemukan', v_prod_id;
            END IF;

            IF v_prod.type = 'barang' THEN
                IF v_prod.stock < v_qty THEN
                    RAISE EXCEPTION 'INSUFFICIENT_STOCK: Stok produk "%" tidak mencukupi (Tersedia: %, Diminta: %)', v_prod.name, v_prod.stock, v_qty;
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
        END IF;
    END LOOP;

    -- [5] Insert Transactions Row
    INSERT INTO public.transactions (
        trx_code, transaction_type, party_name, transaction_date, status, total, profit,
        payment_method, payment_account_id, items, created_by
    ) VALUES (
        p_trx_code, 'Jual', COALESCE(p_party_name, 'Pelanggan Umum'), p_transaction_date, 'VALID',
        p_total, COALESCE(p_profit, 0.00), p_payment_method, p_payment_account_id, p_items, v_caller_id
    ) RETURNING id INTO v_trx_id;

    -- [7] Post Journal Entry Atomically
    IF p_total > 0 THEN
        SELECT journal_id, journal_no INTO v_journal_res
        FROM public.post_journal_entry(
            p_journal_date := p_transaction_date,
            p_source_type := 'TRANSACTION',
            p_source_id := v_trx_id,
            p_source_code := p_trx_code,
            p_description := 'Transaksi Penjualan POS ' || p_trx_code || ' - ' || COALESCE(p_party_name, 'Pelanggan Umum'),
            p_user_id := v_caller_id,
            p_lines := v_journal_lines
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'transaction_id', v_trx_id,
        'trx_code', p_trx_code,
        'invoice_id', v_inv_id,
        'inv_no', v_inv_no,
        'journal_id', v_journal_res.journal_id,
        'journal_no', v_journal_res.journal_no
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_pos_transaction_atomic FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_pos_transaction_atomic TO authenticated;


-- ------------------------------------------------------------------------------
-- 2. ATOMIC SUPPLIER PURCHASE (PO) ENGINE
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_purchase_atomic(
    p_po_no VARCHAR,
    p_supplier_name VARCHAR,
    p_purchase_date DATE,
    p_total NUMERIC,
    p_payment_method VARCHAR,
    p_payment_account_id BIGINT DEFAULT NULL,
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
    v_inv_coa_id BIGINT;
    v_payment_coa_id BIGINT;
    v_payable_coa_id BIGINT;
    v_pay_acc RECORD;
    v_item JSONB;
    v_prod RECORD;
    v_prod_id BIGINT;
    v_qty NUMERIC(15,2);
    v_cost_price NUMERIC(15,2);
    v_old_stock NUMERIC(15,2);
    v_new_stock NUMERIC(15,2);
    v_remaining NUMERIC(15,2);
    v_paid NUMERIC(15,2);
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

    IF p_total IS NULL OR p_total <= 0 THEN
        RAISE EXCEPTION 'INVALID_TOTAL: Total pembelian harus lebih besar dari 0';
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'EMPTY_ITEMS: Pembelian harus memiliki minimal 1 item';
    END IF;

    -- [3] Resolve Accounting COAs
    SELECT id INTO v_inv_coa_id
    FROM public.chart_of_accounts
    WHERE code = '1-1210' AND is_active = TRUE;
    IF v_inv_coa_id IS NULL THEN
        RAISE EXCEPTION 'COA_NOT_FOUND: Bagan akun Persediaan Barang Dagang (1-1210) tidak ditemukan';
    END IF;

    IF p_payment_method IN ('Tunai', 'Transfer') THEN
        IF p_payment_account_id IS NULL THEN
            RAISE EXCEPTION 'INVALID_PARAM: payment_account_id wajib diisi untuk metode %', p_payment_method;
        END IF;

        SELECT id, name, chart_of_account_id INTO v_pay_acc
        FROM public.payment_accounts
        WHERE id = p_payment_account_id AND is_active = TRUE;

        IF NOT FOUND OR v_pay_acc.chart_of_account_id IS NULL THEN
            RAISE EXCEPTION 'PAYMENT_ACCOUNT_INVALID: Akun kas/bank ID % tidak valid atau tidak memiliki COA', p_payment_account_id;
        END IF;

        v_payment_coa_id := v_pay_acc.chart_of_account_id;

        v_journal_lines := jsonb_build_array(
            jsonb_build_object(
                'chart_of_account_id', v_inv_coa_id,
                'debit', p_total,
                'credit', 0,
                'description', 'Pembelian persediaan barang PO ' || p_po_no || ' (' || p_supplier_name || ')'
            ),
            jsonb_build_object(
                'chart_of_account_id', v_payment_coa_id,
                'debit', 0,
                'credit', p_total,
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

        v_journal_lines := jsonb_build_array(
            jsonb_build_object(
                'chart_of_account_id', v_inv_coa_id,
                'debit', p_total,
                'credit', 0,
                'description', 'Pembelian persediaan barang PO ' || p_po_no || ' (' || p_supplier_name || ')'
            ),
            jsonb_build_object(
                'chart_of_account_id', v_payable_coa_id,
                'debit', 0,
                'credit', p_total,
                'description', 'Hutang pembelian tempo PO ' || p_po_no || ' (' || p_supplier_name || ')'
            )
        );
    ELSE
        RAISE EXCEPTION 'INVALID_PAYMENT_METHOD: Metode pembayaran % tidak didukung untuk PO', p_payment_method;
    END IF;

    -- [4] Row Locking & Stock Increment for Products
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_prod_id := (v_item->>'productId')::BIGINT;
        v_qty := (v_item->>'qty')::NUMERIC;
        v_cost_price := COALESCE((v_item->>'costPrice')::NUMERIC, 0.00);

        IF v_prod_id IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'INVALID_ITEM: Item ID % atau kuantiti % tidak valid', v_prod_id, v_qty;
        END IF;

        SELECT * INTO v_prod FROM public.products WHERE id = v_prod_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PRODUCT_NOT_FOUND: Produk ID % tidak ditemukan', v_prod_id;
        END IF;

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
            v_old_stock, v_new_stock, p_po_no, 'Pembelian PO ' || p_po_no, v_caller_id
        );
    END LOOP;

    -- [5] Insert Purchases Header
    v_remaining := CASE WHEN p_payment_method = 'Kredit' THEN p_total ELSE 0.00 END;
    v_paid := p_total - v_remaining;

    INSERT INTO public.purchases (
        po_no, supplier_id, supplier_name, purchase_date, total, paid_amount, remaining,
        payment_method, payment_account_id, created_by
    ) VALUES (
        p_po_no, NULL, p_supplier_name, p_purchase_date, p_total, v_paid, v_remaining,
        p_payment_method, p_payment_account_id, v_caller_id
    ) RETURNING id INTO v_purch_id;

    -- [6] Insert Purchase Items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_prod_id := (v_item->>'productId')::BIGINT;
        v_qty := (v_item->>'qty')::NUMERIC;
        v_cost_price := COALESCE((v_item->>'costPrice')::NUMERIC, 0.00);

        INSERT INTO public.purchase_items (
            purchase_id, product_id, cost_price, qty
        ) VALUES (
            v_purch_id, v_prod_id, v_cost_price, v_qty
        );
    END LOOP;

    -- [7] If Payment Method is Kredit, Insert into Payables (using DB default tempo)
    IF p_payment_method = 'Kredit' THEN
        INSERT INTO public.payables (
            purchase_id, po_no, supplier_name, status, total, paid, remaining
        ) VALUES (
            v_purch_id, p_po_no, p_supplier_name, 'Belum Lunas', p_total, 0.00, p_total
        );
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
        'journal_id', v_journal_res.journal_id,
        'journal_no', v_journal_res.journal_no
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
    v_pay_acc RECORD;
    v_exp_coa RECORD;
    v_journal_lines JSONB;
    v_journal_res RECORD;
BEGIN
    -- [1] Authentication & Role Guard (Owner / Admin Only)
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHENTICATED: Sesi pengguna tidak terautentikasi';
    END IF;

    v_caller_role := public.get_current_user_role();
    IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin') THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Hanya Owner dan Admin yang berhak mencatat beban operasional';
    END IF;

    -- [2] Parameter Validation & Anti-Duplicate
    IF p_expense_no IS NULL OR TRIM(p_expense_no) = '' THEN
        RAISE EXCEPTION 'INVALID_PARAM: Nomor beban (expense_no) wajib diisi';
    END IF;

    IF EXISTS (SELECT 1 FROM public.expenses WHERE expense_no = p_expense_no) THEN
        RAISE EXCEPTION 'DUPLICATE_EXPENSE_NO: Nomor beban % sudah pernah dicatat', p_expense_no;
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: Nominal beban harus lebih besar dari 0';
    END IF;

    IF p_payee IS NULL OR TRIM(p_payee) = '' THEN
        RAISE EXCEPTION 'INVALID_PARAM: Penerima pembayaran (payee) wajib diisi';
    END IF;

    IF p_note IS NULL OR TRIM(p_note) = '' THEN
        RAISE EXCEPTION 'INVALID_PARAM: Keterangan beban wajib diisi';
    END IF;

    -- [3] Resolve & Validate COAs
    SELECT id, code, name, category INTO v_exp_coa
    FROM public.chart_of_accounts
    WHERE id = p_chart_of_account_id AND is_active = TRUE;

    IF NOT FOUND OR v_exp_coa.category <> 'EXPENSE' THEN
        RAISE EXCEPTION 'INVALID_EXPENSE_COA: Akun COA ID % bukan akun beban aktif', p_chart_of_account_id;
    END IF;

    SELECT id, name, chart_of_account_id INTO v_pay_acc
    FROM public.payment_accounts
    WHERE id = p_payment_account_id AND is_active = TRUE;

    IF NOT FOUND OR v_pay_acc.chart_of_account_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_PAYMENT_ACCOUNT: Akun kas/bank ID % tidak valid', p_payment_account_id;
    END IF;

    -- [4] Insert Expenses Record
    INSERT INTO public.expenses (
        expense_no, expense_date, chart_of_account_id, payment_account_id,
        amount, payee, project_id, note, status, created_by
    ) VALUES (
        p_expense_no, p_expense_date, p_chart_of_account_id, p_payment_account_id,
        p_amount, p_payee, p_project_id, p_note, 'VALID', v_caller_id
    ) RETURNING id INTO v_exp_id;

    -- [5] Post Journal Entry Atomically
    v_journal_lines := jsonb_build_array(
        jsonb_build_object(
            'chart_of_account_id', p_chart_of_account_id,
            'debit', p_amount,
            'credit', 0,
            'description', 'Beban ' || p_payee || ': ' || p_note
        ),
        jsonb_build_object(
            'chart_of_account_id', v_pay_acc.chart_of_account_id,
            'debit', 0,
            'credit', p_amount,
            'description', 'Pembayaran ' || p_expense_no || ' via ' || v_pay_acc.name
        )
    );

    SELECT journal_id, journal_no INTO v_journal_res
    FROM public.post_journal_entry(
        p_journal_date := p_expense_date,
        p_source_type := 'EXPENSE',
        p_source_id := v_exp_id,
        p_source_code := p_expense_no,
        p_description := 'Pengeluaran Beban ' || p_expense_no || ' - ' || p_payee || ' (' || v_exp_coa.code || ' ' || v_exp_coa.name || ')',
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
    v_pay_acc RECORD;
    v_eq_coa RECORD;
    v_journal_lines JSONB;
    v_journal_res RECORD;
BEGIN
    -- [1] Authentication & Role Guard (Owner Only)
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHENTICATED: Sesi pengguna tidak terautentikasi';
    END IF;

    v_caller_role := public.get_current_user_role();
    IF v_caller_role IS NULL OR v_caller_role <> 'owner' THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Hanya Owner yang berhak mencatat transaksi Modal atau Prive';
    END IF;

    -- [2] Parameter Validation & Anti-Duplicate
    IF p_equity_no IS NULL OR TRIM(p_equity_no) = '' THEN
        RAISE EXCEPTION 'INVALID_PARAM: Nomor transaksi ekuitas (equity_no) wajib diisi';
    END IF;

    IF EXISTS (SELECT 1 FROM public.equity_transactions WHERE equity_no = p_equity_no) THEN
        RAISE EXCEPTION 'DUPLICATE_EQUITY_NO: Nomor transaksi % sudah pernah dicatat', p_equity_no;
    END IF;

    IF p_transaction_type NOT IN ('CAPITAL_IN', 'DRAWING_OUT') THEN
        RAISE EXCEPTION 'INVALID_TYPE: Tipe transaksi ekuitas harus CAPITAL_IN atau DRAWING_OUT';
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: Nominal harus lebih besar dari 0';
    END IF;

    IF p_note IS NULL OR TRIM(p_note) = '' THEN
        RAISE EXCEPTION 'INVALID_PARAM: Keterangan transaksi wajib diisi';
    END IF;

    -- [3] Resolve & Validate COAs
    SELECT id, code, name, category INTO v_eq_coa
    FROM public.chart_of_accounts
    WHERE id = p_chart_of_account_id AND is_active = TRUE;

    IF NOT FOUND OR v_eq_coa.category <> 'EQUITY' THEN
        RAISE EXCEPTION 'INVALID_EQUITY_COA: Akun COA ID % bukan akun ekuitas aktif', p_chart_of_account_id;
    END IF;

    SELECT id, name, chart_of_account_id INTO v_pay_acc
    FROM public.payment_accounts
    WHERE id = p_payment_account_id AND is_active = TRUE;

    IF NOT FOUND OR v_pay_acc.chart_of_account_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_PAYMENT_ACCOUNT: Akun kas/bank ID % tidak valid', p_payment_account_id;
    END IF;

    -- [4] Insert Equity Record
    INSERT INTO public.equity_transactions (
        equity_no, equity_date, transaction_type, chart_of_account_id,
        payment_account_id, amount, note, status, created_by
    ) VALUES (
        p_equity_no, p_equity_date, p_transaction_type, p_chart_of_account_id,
        p_payment_account_id, p_amount, p_note, 'VALID', v_caller_id
    ) RETURNING id INTO v_eq_id;

    -- [5] Post Journal Entry Atomically
    IF p_transaction_type = 'CAPITAL_IN' THEN
        v_journal_lines := jsonb_build_array(
            jsonb_build_object(
                'chart_of_account_id', v_pay_acc.chart_of_account_id,
                'debit', p_amount,
                'credit', 0,
                'description', 'Penerimaan modal kas/bank via ' || v_pay_acc.name
            ),
            jsonb_build_object(
                'chart_of_account_id', p_chart_of_account_id,
                'debit', 0,
                'credit', p_amount,
                'description', 'Setoran modal pemilik: ' || p_note
            )
        );
    ELSE
        v_journal_lines := jsonb_build_array(
            jsonb_build_object(
                'chart_of_account_id', p_chart_of_account_id,
                'debit', p_amount,
                'credit', 0,
                'description', 'Penarikan prive pemilik: ' || p_note
            ),
            jsonb_build_object(
                'chart_of_account_id', v_pay_acc.chart_of_account_id,
                'debit', 0,
                'credit', p_amount,
                'description', 'Pengeluaran kas/bank prive via ' || v_pay_acc.name
            )
        );
    END IF;

    SELECT journal_id, journal_no INTO v_journal_res
    FROM public.post_journal_entry(
        p_journal_date := p_equity_date,
        p_source_type := 'EQUITY',
        p_source_id := v_eq_id,
        p_source_code := p_equity_no,
        p_description := 'Transaksi Ekuitas ' || p_equity_no || ' - ' || (CASE WHEN p_transaction_type = 'CAPITAL_IN' THEN 'Setor Modal' ELSE 'Tarik Prive' END) || ' (' || v_eq_coa.code || ' ' || v_eq_coa.name || ')',
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
-- 5. ATOMIC QUOTATION TO INVOICE CONVERSION ENGINE
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.convert_quotation_to_invoice_atomic(
    p_quotation_id BIGINT,
    p_inv_no VARCHAR,
    p_inv_date DATE,
    p_due_date DATE DEFAULT NULL,
    p_customer_name VARCHAR DEFAULT NULL,
    p_customer_farm VARCHAR DEFAULT NULL,
    p_is_tunai_lunas BOOLEAN DEFAULT FALSE,
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
    v_item JSONB;
    v_qty NUMERIC(15,2);
    v_price NUMERIC(15,2);
    v_cost_price NUMERIC(15,2);
    v_disc_type VARCHAR(10);
    v_disc_val NUMERIC(15,2);
    v_disc_amt NUMERIC(15,2);
    v_item_subtotal NUMERIC(15,2);
    v_gross_total NUMERIC(15,2) := 0.00;
    v_net_total NUMERIC(15,2) := 0.00;
    v_barang_net NUMERIC(15,2) := 0.00;
    v_jasa_net NUMERIC(15,2) := 0.00;
    v_paid NUMERIC(15,2);
    v_remaining NUMERIC(15,2);
    v_status VARCHAR;
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

    -- [2] Lock & Validate Source Quotation
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

    -- [3] Calculate Item Totals & Split Goods/Service (Quotation conversion retains rule: DOES NOT touch stock)
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_qty := COALESCE((v_item->>'qty')::NUMERIC, 0.00);
        v_price := COALESCE((v_item->>'price')::NUMERIC, 0.00);
        v_disc_amt := COALESCE((v_item->>'discountAmount')::NUMERIC, (v_item->>'discount_amount')::NUMERIC, 0.00);
        v_item_subtotal := (v_qty * v_price) - v_disc_amt;

        IF v_qty <= 0 OR v_price < 0 THEN
            RAISE EXCEPTION 'INVALID_ITEM_VALUES: Kuantiti atau harga tidak valid pada item invoice';
        END IF;

        v_gross_total := v_gross_total + (v_qty * v_price);
        v_net_total := v_net_total + v_item_subtotal;

        IF (v_item->>'type') = 'jasa' THEN
            v_jasa_net := v_jasa_net + v_item_subtotal;
        ELSE
            v_barang_net := v_barang_net + v_item_subtotal;
        END IF;
    END LOOP;

    -- [4] Determine Payment Amounts and Status (Due date remains optional)
    IF p_is_tunai_lunas THEN
        v_paid := v_net_total;
        v_remaining := 0.00;
        v_status := 'Lunas';
    ELSE
        v_paid := LEAST(v_net_total, GREATEST(0.00, COALESCE(p_paid_amount, 0.00)));
        v_remaining := GREATEST(0.00, v_net_total - v_paid);
        v_status := CASE WHEN v_remaining <= 0 THEN 'Lunas' WHEN v_paid > 0 THEN 'Sebagian' ELSE 'Belum Bayar' END;
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
                'description', 'Piutang Usaha Invoice ' || p_inv_no || ' (' || COALESCE(p_customer_name, v_qt.customer_name, 'Pelanggan') || ')'
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

    -- [6] Insert Invoices Record
    INSERT INTO public.invoices (
        inv_no, customer_name, customer_farm, invoice_date, due_date,
        status, subtotal, discount_total, total, paid_amount, remaining, quotation_id, created_by
    ) VALUES (
        p_inv_no, COALESCE(p_customer_name, v_qt.customer_name, 'Pelanggan'),
        COALESCE(p_customer_farm, v_qt.project_name, '-'), p_inv_date, p_due_date,
        v_status, v_gross_total, (v_gross_total - v_net_total), v_net_total, v_paid, v_remaining, p_quotation_id, v_caller_id
    ) RETURNING id INTO v_inv_id;

    -- [7] Insert Invoice Items (Excluding generated stored column subtotal)
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_qty := (v_item->>'qty')::NUMERIC;
        v_price := (v_item->>'price')::NUMERIC;
        v_cost_price := COALESCE((v_item->>'costPrice')::NUMERIC, (v_item->>'cost_price')::NUMERIC, 0.00);
        v_disc_type := COALESCE(v_item->>'discountType', v_item->>'discount_type', 'none');
        v_disc_val := COALESCE((v_item->>'discountValue')::NUMERIC, (v_item->>'discount_value')::NUMERIC, 0.00);
        v_disc_amt := COALESCE((v_item->>'discountAmount')::NUMERIC, (v_item->>'discount_amount')::NUMERIC, 0.00);

        INSERT INTO public.invoice_items (
            invoice_id, product_id, category, unit, price, cost_price, qty,
            discount_type, discount_value, discount_amount
        ) VALUES (
            v_inv_id,
            (COALESCE(v_item->>'productId', v_item->>'product_id', v_item->>'id'))::BIGINT,
            COALESCE(v_item->>'category', 'General'),
            COALESCE(v_item->>'unit', 'Unit'),
            v_price, v_cost_price, v_qty,
            v_disc_type, v_disc_val, v_disc_amt
        );
    END LOOP;

    -- [8] Insert Receivables if Remaining > 0
    IF NOT p_is_tunai_lunas AND v_remaining > 0 THEN
        INSERT INTO public.receivables (
            invoice_id, inv_no, customer_name, due_date, status, total, paid, remaining
        ) VALUES (
            v_inv_id, p_inv_no, COALESCE(p_customer_name, v_qt.customer_name, 'Pelanggan'),
            p_due_date, v_status, v_net_total, v_paid, v_remaining
        );
    END IF;

    -- [9] Update Quotations Status to 'Converted'
    UPDATE public.quotations
    SET status = 'Converted',
        updated_at = NOW()
    WHERE id = p_quotation_id;

    -- [10] Post Journal Entry Atomically
    IF v_net_total > 0 AND jsonb_array_length(v_journal_lines) >= 2 THEN
        SELECT journal_id, journal_no INTO v_journal_res
        FROM public.post_journal_entry(
            p_journal_date := p_inv_date,
            p_source_type := 'INVOICE',
            p_source_id := v_inv_id,
            p_source_code := p_inv_no,
            p_description := 'Penjualan Invoice ' || p_inv_no || ' (' || COALESCE(p_customer_name, v_qt.customer_name, 'Pelanggan') || ')',
            p_user_id := v_caller_id,
            p_lines := v_journal_lines
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'invoice_id', v_inv_id,
        'inv_no', p_inv_no,
        'quotation_id', p_quotation_id,
        'journal_id', v_journal_res.journal_id,
        'journal_no', v_journal_res.journal_no
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.convert_quotation_to_invoice_atomic FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.convert_quotation_to_invoice_atomic TO authenticated;

COMMIT;

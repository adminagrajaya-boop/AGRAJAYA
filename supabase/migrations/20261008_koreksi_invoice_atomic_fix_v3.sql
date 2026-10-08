-- ==============================================================================
-- AGRA JAYA POS — MIGRATION: HARDENED ATOMIC RPC FOR INVOICE CORRECTION FIX V3
-- Target Database: PostgreSQL (Supabase)
-- Fixes: Relational fallback for project_id, customer_id, quotation_id
-- ==============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.correct_invoice_atomic(
    p_old_inv_id BIGINT,
    p_correction_reason TEXT,
    p_new_inv_data JSONB,
    p_new_inv_items JSONB,
    p_new_rec_data JSONB DEFAULT NULL,
    p_new_journal_data JSONB DEFAULT NULL,
    p_new_journal_lines JSONB DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER 
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_caller_role VARCHAR;
    v_old_inv RECORD;
    v_payment_count INT;
    v_old_jrn_count INT;
    v_old_journal_id BIGINT;
    v_old_payment_coa_id BIGINT;
    v_old_payment_coa_code VARCHAR;
    v_old_coa_count INT;
    v_new_inv_id BIGINT;
    v_new_inv_no VARCHAR;
    v_new_jrn_no VARCHAR;
    v_new_journal_id BIGINT;
    v_item JSONB;

    v_cust_id BIGINT;
    v_proj_id BIGINT;
    v_quot_id BIGINT;
    v_trx_id BIGINT;
    v_prod_id BIGINT;
    v_customer_farm_raw TEXT;
    v_customer_farm TEXT;

    v_due_date_raw TEXT;
    v_inv_date_raw TEXT;
    v_due_date DATE;
    v_inv_date DATE;

    v_item_price NUMERIC(15,2);
    v_item_qty NUMERIC(15,2);
    v_item_disc_val NUMERIC(15,2);
    v_item_disc_type VARCHAR(20);
    v_item_disc_amt NUMERIC(15,2);
    v_item_subtotal_calc NUMERIC(15,2);
    v_calc_items_sum NUMERIC(15,2) := 0.00;
    
    v_barang_sum NUMERIC(15,2) := 0.00;
    v_jasa_sum NUMERIC(15,2) := 0.00;
    v_barang_credit NUMERIC(15,2) := 0.00;
    v_jasa_credit NUMERIC(15,2) := 0.00;

    v_hdr_subtotal NUMERIC(15,2);
    v_hdr_discount NUMERIC(15,2);
    v_hdr_total_payload NUMERIC(15,2);
    v_calc_inv_total NUMERIC(15,2);
    
    v_derived_paid NUMERIC(15,2);
    v_derived_remaining NUMERIC(15,2);
    v_derived_status VARCHAR(50);
    v_resolved_pay_method VARCHAR(50);

    v_line_idx INT := 1;
    v_piutang_coa_id BIGINT;
    v_rev_barang_coa_id BIGINT;
    v_rev_jasa_coa_id BIGINT;
BEGIN
    -- [1] AUTHENTICATION & ROLE AUTHORIZATION
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED: Sesi pengguna tidak terautentikasi'; END IF;

    v_caller_role := public.get_current_user_role();
    IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin') THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Hanya Owner atau Admin yang berhak mengoreksi invoice';
    END IF;

    IF p_correction_reason IS NULL OR trim(p_correction_reason) = '' THEN
        RAISE EXCEPTION 'INVALID_PARAM: Alasan koreksi invoice wajib diisi';
    END IF;

    -- [2] LOCK AND VALIDATE OLD INVOICE
    SELECT * INTO v_old_inv FROM public.invoices WHERE id = p_old_inv_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'INVOICE_NOT_FOUND: Invoice lama dengan ID % tidak ditemukan', p_old_inv_id; END IF;
    IF v_old_inv.status IN ('Dibatalkan', 'Void') THEN RAISE EXCEPTION 'INVALID_INVOICE_STATUS: Invoice % sudah berstatus Dibatalkan/Void', v_old_inv.inv_no; END IF;
    IF v_old_inv.corrected_from IS NOT NULL THEN RAISE EXCEPTION 'CANNOT_CORRECT_A_CORRECTION: Invoice % adalah hasil koreksi', v_old_inv.inv_no; END IF;

    IF EXISTS (SELECT 1 FROM public.invoices WHERE corrected_from = p_old_inv_id) THEN
        RAISE EXCEPTION 'ALREADY_CORRECTED: Invoice % sudah pernah dikoreksi sebelumnya', v_old_inv.inv_no;
    END IF;

    -- [3] RESOLVE AUTHORITATIVE OLD PAYMENT METHOD
    v_resolved_pay_method := public.resolve_legacy_payment_method(p_old_inv_id, v_old_inv.inv_no);
    IF v_resolved_pay_method IS NULL THEN
        RAISE EXCEPTION 'CANNOT_DETERMINE_PAYMENT_METHOD: Metode pembayaran invoice lama % tidak dapat ditentukan secara deterministik', v_old_inv.inv_no;
    END IF;

    -- [4] PAYMENT HISTORY CHECK
    SELECT COUNT(*) INTO v_payment_count 
    FROM public.payment_history 
    WHERE (invoice_id = p_old_inv_id OR inv_no = v_old_inv.inv_no) AND status = 'VALID';

    IF v_payment_count > 0 THEN
        RAISE EXCEPTION 'PAYMENT_EXISTS: Invoice % memiliki histori pembayaran aktif dan tidak dapat dikoreksi otomatis', v_old_inv.inv_no;
    END IF;

    -- [5] INVOICE NUMBER FORMAT & UNIQUENESS
    v_new_inv_no := trim(p_new_inv_data->>'inv_no');
    IF v_new_inv_no !~ '^INV-[0-9]{4}-[0-9]+(-REV[0-9]*)?$' THEN
        RAISE EXCEPTION 'INVALID_INV_FORMAT: Format nomor invoice % tidak sesuai standar', v_new_inv_no;
    END IF;

    IF EXISTS (SELECT 1 FROM public.invoices WHERE inv_no = v_new_inv_no) THEN
        RAISE EXCEPTION 'DUPLICATE_INV_NO: Nomor invoice % sudah terdaftar', v_new_inv_no;
    END IF;

    -- [6] FK RELATIONS VALIDATION & FALLBACKS
    v_cust_id := (p_new_inv_data->>'customer_id')::BIGINT;
    IF v_cust_id IS NULL THEN v_cust_id := v_old_inv.customer_id; END IF;
    IF v_cust_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.customers WHERE id = v_cust_id) THEN
        RAISE EXCEPTION 'INVALID_CUSTOMER_ID: Customer ID % tidak ditemukan', v_cust_id;
    END IF;

    v_proj_id := (p_new_inv_data->>'project_id')::BIGINT;
    IF v_proj_id IS NULL THEN v_proj_id := v_old_inv.project_id; END IF;
    IF v_proj_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.projects WHERE id = v_proj_id) THEN
        RAISE EXCEPTION 'INVALID_PROJECT_ID: Project ID % tidak ditemukan', v_proj_id;
    END IF;

    v_quot_id := (p_new_inv_data->>'quotation_id')::BIGINT;
    IF v_quot_id IS NULL THEN v_quot_id := v_old_inv.quotation_id; END IF;
    IF v_quot_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.quotations WHERE id = v_quot_id) THEN
            RAISE EXCEPTION 'INVALID_QUOTATION_ID: Quotation ID % tidak ditemukan', v_quot_id;
        END IF;
        IF EXISTS (SELECT 1 FROM public.invoices WHERE quotation_id = v_quot_id AND id != p_old_inv_id AND status NOT IN ('Dibatalkan', 'Void')) THEN
            RAISE EXCEPTION 'QUOTATION_ACTIVE_INVOICE_EXISTS: Quotation ID % memiliki invoice aktif lain', v_quot_id;
        END IF;
    END IF;

    -- [7] FIELD FALLBACKS & PARSING
    v_customer_farm_raw := trim(p_new_inv_data->>'customer_farm');
    IF v_customer_farm_raw IS NULL OR v_customer_farm_raw = '' THEN
        v_customer_farm := v_old_inv.customer_farm;
    ELSE
        v_customer_farm := v_customer_farm_raw;
    END IF;

    v_due_date_raw := trim(p_new_inv_data->>'due_date');
    IF v_due_date_raw IS NULL OR v_due_date_raw = '' OR v_due_date_raw = 'null' THEN 
        IF v_old_inv.due_date IS NULL THEN
            v_due_date := NULL;
        ELSE
            BEGIN
                v_due_date := v_old_inv.due_date::TEXT::DATE;
            EXCEPTION WHEN OTHERS THEN
                v_due_date := NULL;
            END;
        END IF;
    ELSE 
        BEGIN
            v_due_date := v_due_date_raw::DATE;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'INVALID_DUE_DATE: Due date "%" pada payload tidak valid', v_due_date_raw;
        END;
    END IF;

    v_inv_date_raw := trim(p_new_inv_data->>'invoice_date');
    IF v_inv_date_raw IS NULL OR v_inv_date_raw = '' OR v_inv_date_raw = 'null' THEN 
        v_inv_date := CURRENT_DATE; 
    ELSE 
        BEGIN
            v_inv_date := v_inv_date_raw::DATE;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'INVALID_INVOICE_DATE: Invoice date "%" pada payload tidak valid', v_inv_date_raw;
        END;
    END IF;

    -- [8] SERVER-CALCULATED ITEM DISCOUNTS & UNKNOWN CATEGORY REJECTION
    IF p_new_inv_items IS NULL OR jsonb_array_length(p_new_inv_items) = 0 THEN
        RAISE EXCEPTION 'EMPTY_ITEMS: Minimal 1 item barang/jasa wajib ada';
    END IF;

    v_line_idx := 1;
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_new_inv_items) LOOP
        v_prod_id := (v_item->>'product_id')::BIGINT;
        IF v_prod_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.products WHERE id = v_prod_id) THEN
            RAISE EXCEPTION 'INVALID_PRODUCT_ID: Produk ID % pada baris ke-% tidak ditemukan', v_prod_id, v_line_idx;
        END IF;

        v_item_price := COALESCE((v_item->>'price')::NUMERIC, 0.00);
        v_item_qty := COALESCE((v_item->>'qty')::NUMERIC, 0.00);
        v_item_disc_type := trim(v_item->>'discount_type');
        v_item_disc_val := COALESCE((v_item->>'discount_value')::NUMERIC, 0.00);

        IF v_item_qty <= 0 THEN RAISE EXCEPTION 'INVALID_ITEM_QTY: Qty item ke-% harus > 0', v_line_idx; END IF;
        IF v_item_price < 0 THEN RAISE EXCEPTION 'INVALID_ITEM_PRICE: Harga item ke-% tidak boleh negatif', v_line_idx; END IF;
        IF v_item_disc_val < 0 THEN RAISE EXCEPTION 'INVALID_ITEM_DISCOUNT_VALUE: Diskon item ke-% tidak boleh negatif', v_line_idx; END IF;

        IF v_item_disc_type = 'percentage' THEN
            v_item_disc_amt := ROUND((v_item_qty * v_item_price) * (v_item_disc_val / 100.0), 2);
        ELSIF v_item_disc_type IN ('fixed', 'nominal') THEN
            v_item_disc_amt := v_item_disc_val;
        ELSE
            v_item_disc_amt := 0.00;
        END IF;

        IF v_item_disc_amt > (v_item_qty * v_item_price) THEN 
            RAISE EXCEPTION 'INVALID_ITEM_DISCOUNT: Diskon item ke-% melebihi kotor item', v_line_idx; 
        END IF;

        v_item_subtotal_calc := (v_item_qty * v_item_price) - v_item_disc_amt;

        IF UPPER(COALESCE(v_item->>'category', '')) LIKE '%JASA%' 
           OR UPPER(COALESCE(v_item->>'category', '')) LIKE '%SERVIS%' 
           OR UPPER(COALESCE(v_item->>'category', '')) LIKE '%SERVICE%' 
           OR UPPER(COALESCE(v_item->>'category', '')) LIKE '%INSTALASI%' 
           OR UPPER(COALESCE(v_item->>'category', '')) LIKE '%LAYANAN%' 
           OR LOWER(COALESCE(v_item->>'type', '')) = 'jasa' THEN
            v_jasa_sum := v_jasa_sum + v_item_subtotal_calc;
        ELSE
            v_barang_sum := v_barang_sum + v_item_subtotal_calc;
        END IF;

        v_calc_items_sum := v_calc_items_sum + v_item_subtotal_calc;
        v_line_idx := v_line_idx + 1;
    END LOOP;

    -- [9] RECALCULATE HEADER TOTAL & DERIVE PAYMENT STATE SERVER-SIDE
    v_hdr_subtotal := v_calc_items_sum;
    v_hdr_discount := COALESCE((p_new_inv_data->>'discount_total')::NUMERIC, 0.00);

    IF v_hdr_discount < 0 OR v_hdr_discount > v_hdr_subtotal THEN
        RAISE EXCEPTION 'INVALID_HEADER_DISCOUNT: Diskon total header tidak valid';
    END IF;

    v_calc_inv_total := v_hdr_subtotal - v_hdr_discount;

    v_hdr_total_payload := COALESCE((p_new_inv_data->>'total')::NUMERIC, 0.00);
    IF v_hdr_total_payload > 0 AND ABS(v_calc_inv_total - v_hdr_total_payload) > 0.01 THEN
        RAISE EXCEPTION 'INVOICE_TOTAL_MISMATCH: Total invoice client (Rp %) berbeda dengan total hitung server (Rp %)',
            v_hdr_total_payload, v_calc_inv_total;
    END IF;

    -- DERIVE PAYMENT STATE SERVER-SIDE FROM OLD INVOICE
    IF v_old_inv.paid_amount = v_old_inv.total AND v_old_inv.remaining = 0 AND v_old_inv.status IN ('Lunas', 'Paid') THEN
        v_derived_paid := v_calc_inv_total;
        v_derived_remaining := 0.00;
        v_derived_status := 'Lunas';
    ELSIF v_old_inv.paid_amount = 0 AND v_old_inv.remaining = v_old_inv.total AND v_resolved_pay_method IN ('Tunai', 'Transfer', 'QRIS') THEN
        v_derived_paid := 0.00;
        v_derived_remaining := v_calc_inv_total;
        v_derived_status := 'Belum Bayar';
    ELSIF v_old_inv.paid_amount = 0 AND v_old_inv.remaining = v_old_inv.total AND v_resolved_pay_method = 'Kredit' THEN
        v_derived_paid := 0.00;
        v_derived_remaining := v_calc_inv_total;
        v_derived_status := 'Belum Bayar';
    ELSIF v_old_inv.paid_amount > 0 AND v_old_inv.remaining > 0 THEN
        RAISE EXCEPTION 'PARTIAL_PAYMENT_RESCALE_NOT_SUPPORTED: Rescaling koreksi invoice bayar sebagian tidak didukung';
    ELSE
        RAISE EXCEPTION 'INVALID_OLD_PAYMENT_STATE: State pembayaran invoice lama % tidak valid', v_old_inv.inv_no;
    END IF;

    -- [10] REVERSE OLD JOURNAL ENTRY
    SELECT COUNT(*), MAX(id) INTO v_old_jrn_count, v_old_journal_id
    FROM public.journal_entries
    WHERE source_type = 'INVOICE' AND source_id = p_old_inv_id AND status = 'POSTED' AND is_reversal = false;

    IF v_old_jrn_count = 0 THEN
        SELECT COUNT(*), MAX(id) INTO v_old_jrn_count, v_old_journal_id
        FROM public.journal_entries
        WHERE source_type = 'INVOICE' AND source_id IS NULL AND source_code = v_old_inv.inv_no AND status = 'POSTED' AND is_reversal = false;
    END IF;

    IF v_old_jrn_count != 1 THEN
        RAISE EXCEPTION 'AMBIGUOUS_OLD_JOURNAL: Ditemukan % jurnal aktif untuk invoice lama', v_old_jrn_count;
    END IF;

    -- AUDIT OLD PAYMENT COA (WITHOUT COALESCE FALLBACK TO 1-1010)
    IF v_derived_paid > 0 THEN
        SELECT COUNT(*), MAX(jl.chart_of_account_id), MAX(coa.code) 
        INTO v_old_coa_count, v_old_payment_coa_id, v_old_payment_coa_code
        FROM public.journal_lines jl
        JOIN public.chart_of_accounts coa ON jl.chart_of_account_id = coa.id
        WHERE jl.journal_entry_id = v_old_journal_id 
          AND jl.debit > 0 AND coa.code IN ('1-1010', '1-1020', '1-1030', '1-1101');

        IF v_old_coa_count = 0 THEN
            RAISE EXCEPTION 'MISSING_OLD_PAYMENT_COA: Akun Kas/Bank pada jurnal lama tidak ditemukan';
        ELSIF v_old_coa_count > 1 THEN
            RAISE EXCEPTION 'AMBIGUOUS_OLD_PAYMENT_COA: Ditemukan % akun Kas/Bank pada jurnal lama', v_old_coa_count;
        END IF;

        IF v_resolved_pay_method = 'Tunai' AND v_old_payment_coa_code NOT IN ('1-1010', '1-1101') THEN
            RAISE EXCEPTION 'PAYMENT_METHOD_COA_MISMATCH: Payment method Tunai tidak cocok dengan COA jurnal %', v_old_payment_coa_code;
        ELSIF v_resolved_pay_method = 'Transfer' AND v_old_payment_coa_code != '1-1020' THEN
            RAISE EXCEPTION 'PAYMENT_METHOD_COA_MISMATCH: Payment method Transfer tidak cocok dengan COA jurnal %', v_old_payment_coa_code;
        ELSIF v_resolved_pay_method = 'QRIS' AND v_old_payment_coa_code != '1-1030' THEN
            RAISE EXCEPTION 'PAYMENT_METHOD_COA_MISMATCH: Payment method QRIS tidak cocok dengan COA jurnal %', v_old_payment_coa_code;
        END IF;
    END IF;

    PERFORM public.reverse_journal_entry(v_old_journal_id, v_caller_id, 'KOREKSI INVOICE ' || v_old_inv.inv_no);

    -- [11] VOID OLD INVOICE & RECEIVABLE
    UPDATE public.invoices SET status = 'Dibatalkan', voided_at = NOW(), voided_by = v_caller_id, remaining = 0 WHERE id = p_old_inv_id;
    UPDATE public.receivables SET status = 'Dibatalkan', remaining = 0 WHERE invoice_id = p_old_inv_id;

    -- [12] INSERT NEW INVOICE WITH DERIVED PAYMENT STATE
    INSERT INTO public.invoices (
        inv_no, customer_id, customer_name, customer_farm, due_date, invoice_date, status, 
        subtotal, discount_total, total, paid_amount, remaining, project_id, quotation_id, 
        transaction_id, created_by, corrected_from, payment_method
    ) VALUES (
        v_new_inv_no, v_cust_id, p_new_inv_data->>'customer_name', v_customer_farm,
        v_due_date, v_inv_date, v_derived_status, v_hdr_subtotal, v_hdr_discount, v_calc_inv_total,
        v_derived_paid, v_derived_remaining, v_proj_id, v_quot_id, v_trx_id, v_caller_id, p_old_inv_id, v_resolved_pay_method
    ) RETURNING id INTO v_new_inv_id;

    -- [13] INSERT NEW INVOICE ITEMS (USING SERVER CALCULATED VALUES)
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_new_inv_items) LOOP
        v_item_price := COALESCE((v_item->>'price')::NUMERIC, 0.00);
        v_item_qty := COALESCE((v_item->>'qty')::NUMERIC, 0.00);
        v_item_disc_type := trim(v_item->>'discount_type');
        v_item_disc_val := COALESCE((v_item->>'discount_value')::NUMERIC, 0.00);

        IF v_item_disc_type = 'percentage' THEN
            v_item_disc_amt := ROUND((v_item_qty * v_item_price) * (v_item_disc_val / 100.0), 2);
        ELSIF v_item_disc_type IN ('fixed', 'nominal') THEN
            v_item_disc_amt := v_item_disc_val;
        ELSE
            v_item_disc_amt := 0.00;
        END IF;

        v_item_subtotal_calc := (v_item_qty * v_item_price) - v_item_disc_amt;

        INSERT INTO public.invoice_items (
            invoice_id, product_id, category, unit, price, qty, 
            discount_type, discount_value, discount_amount
        ) VALUES (
            v_new_inv_id, (v_item->>'product_id')::BIGINT, v_item->>'category', v_item->>'unit',
            v_item_price, v_item_qty, v_item_disc_type, v_item_disc_val, v_item_disc_amt
        );
    END LOOP;

    -- [14] INSERT NEW RECEIVABLE
    IF v_derived_remaining > 0 THEN
        INSERT INTO public.receivables (
            invoice_id, inv_no, customer_name, due_date, status, total, paid, remaining
        ) VALUES (
            v_new_inv_id, v_new_inv_no, p_new_inv_data->>'customer_name', v_due_date, v_derived_status, v_calc_inv_total, v_derived_paid, v_derived_remaining
        );
    END IF;

    -- [15] SERVER-AUTHORITATIVE JOURNAL DERIVATION & MULTI-REVENUE SPLIT
    v_new_jrn_no := 'JRN-' || TO_CHAR(v_inv_date, 'YYYYMMDD') || '-' || LPAD(v_new_inv_id::TEXT, 6, '0');
    IF EXISTS (SELECT 1 FROM public.journal_entries WHERE journal_no = v_new_jrn_no) THEN 
        v_new_jrn_no := v_new_jrn_no || '-REV'; 
    END IF;

    SELECT id INTO v_piutang_coa_id FROM public.chart_of_accounts WHERE code = '1-1110' AND is_active = true;
    SELECT id INTO v_rev_barang_coa_id FROM public.chart_of_accounts WHERE code = '4-1110' AND is_active = true;
    SELECT id INTO v_rev_jasa_coa_id FROM public.chart_of_accounts WHERE code = '4-1120' AND is_active = true;

    IF v_piutang_coa_id IS NULL OR v_rev_barang_coa_id IS NULL OR v_rev_jasa_coa_id IS NULL THEN
        RAISE EXCEPTION 'MISSING_ESSENTIAL_COA: Akun akuntansi utama tidak ditemukan di database';
    END IF;

    IF v_barang_sum > 0 AND v_jasa_sum > 0 THEN
        v_barang_credit := ROUND(v_barang_sum - (v_barang_sum / v_hdr_subtotal * v_hdr_discount), 2);
        v_jasa_credit := ROUND(v_calc_inv_total - v_barang_credit, 2);
    ELSIF v_jasa_sum > 0 THEN
        v_jasa_credit := v_calc_inv_total;
    ELSE
        v_barang_credit := v_calc_inv_total;
    END IF;

    INSERT INTO public.journal_entries (
        journal_no, journal_date, description, source_type, source_id, source_code, status, created_by, is_reversal
    ) VALUES (
        v_new_jrn_no, v_inv_date, 'Jurnal Koreksi Penjualan Invoice ' || v_new_inv_no, 'INVOICE', v_new_inv_id, v_new_inv_no, 'POSTED', v_caller_id, false
    ) RETURNING id INTO v_new_journal_id;

    v_line_idx := 1;
    IF v_derived_paid > 0 THEN
        INSERT INTO public.journal_lines (journal_entry_id, chart_of_account_id, description, debit, credit, line_no)
        VALUES (v_new_journal_id, v_old_payment_coa_id, 'Penerimaan Penjualan Cash/DP ' || v_new_inv_no, v_derived_paid, 0.00, v_line_idx);
        v_line_idx := v_line_idx + 1;
    END IF;

    IF v_derived_remaining > 0 THEN
        INSERT INTO public.journal_lines (journal_entry_id, chart_of_account_id, description, debit, credit, line_no)
        VALUES (v_new_journal_id, v_piutang_coa_id, 'Piutang Usaha Invoice ' || v_new_inv_no, v_derived_remaining, 0.00, v_line_idx);
        v_line_idx := v_line_idx + 1;
    END IF;

    IF v_barang_credit > 0 THEN
        INSERT INTO public.journal_lines (journal_entry_id, chart_of_account_id, description, debit, credit, line_no)
        VALUES (v_new_journal_id, v_rev_barang_coa_id, 'Pendapatan Penjualan Barang ' || v_new_inv_no, 0.00, v_barang_credit, v_line_idx);
        v_line_idx := v_line_idx + 1;
    END IF;

    IF v_jasa_credit > 0 THEN
        INSERT INTO public.journal_lines (journal_entry_id, chart_of_account_id, description, debit, credit, line_no)
        VALUES (v_new_journal_id, v_rev_jasa_coa_id, 'Pendapatan Jasa & Servis ' || v_new_inv_no, 0.00, v_jasa_credit, v_line_idx);
        v_line_idx := v_line_idx + 1;
    END IF;

    -- [16] INSERT AUDIT LOG ATOMICALLY
    INSERT INTO public.invoice_correction_logs (
        old_invoice_id, new_invoice_id, user_id, correction_reason, 
        old_total, new_total, old_status, new_status, old_payment_method, new_payment_method
    ) VALUES (
        p_old_inv_id, v_new_inv_id, v_caller_id, p_correction_reason, 
        v_old_inv.total, v_calc_inv_total, v_old_inv.status, v_derived_status, v_resolved_pay_method, v_resolved_pay_method
    );

    RETURN jsonb_build_object('success', true, 'new_invoice_id', v_new_inv_id, 'new_invoice_no', v_new_inv_no, 'recalculated_total', v_calc_inv_total);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.correct_invoice_atomic FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.correct_invoice_atomic TO authenticated;

COMMIT;

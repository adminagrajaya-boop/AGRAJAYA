-- ==============================================================================
-- AGRA JAYA POS — MIGRATION: HARDENED ATOMIC PAYMENT & VOID ENGINE V1
-- Target Database: PostgreSQL (Supabase)
-- Mode: Production Hardened, Immutable Audit, Strict Authorization, Double-Entry Accounting
-- ==============================================================================

BEGIN;

-- 1. HARDENED ATOMIC RPC FOR PROCESSING PAYMENTS (PREVENT OVERPAYMENT & DOUBLE-SUBMIT)
CREATE OR REPLACE FUNCTION public.process_payment_atomic(
    p_invoice_id BIGINT,
    p_amount NUMERIC(15,2),
    p_payment_method VARCHAR(50),
    p_payment_account_id BIGINT,
    p_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_caller_role VARCHAR;
    v_inv RECORD;
    v_existing_valid_paid NUMERIC(15,2) := 0.00;
    v_new_paid NUMERIC(15,2);
    v_new_remaining NUMERIC(15,2);
    v_new_status VARCHAR(50);
    v_payment_id BIGINT;
    v_date_str DATE;
    v_pay_acc RECORD;
    v_pay_coa_id BIGINT;
    v_piutang_coa_id BIGINT;
    v_journal_id BIGINT;
    v_journal_lines JSONB;
BEGIN
    -- [1] AUTHENTICATION & ROLE AUTHORIZATION
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN 
        RAISE EXCEPTION 'UNAUTHENTICATED: Sesi pengguna tidak terautentikasi'; 
    END IF;

    v_caller_role := public.get_current_user_role();
    IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin', 'kasir') THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Peran pengguna tidak memiliki hak untuk memproses pembayaran';
    END IF;

    -- [2] VALIDATE PARAMETERS
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: Nominal pembayaran harus lebih besar dari 0';
    END IF;

    IF p_payment_account_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_PAYMENT_ACCOUNT: Akun pembayaran wajib dipilih';
    END IF;

    -- [3] LOCK AND VALIDATE TARGET INVOICE FOR UPDATE
    SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN 
        RAISE EXCEPTION 'INVOICE_NOT_FOUND: Invoice ID % tidak ditemukan', p_invoice_id; 
    END IF;

    IF v_inv.status IN ('Dibatalkan', 'Void') THEN
        RAISE EXCEPTION 'INVALID_INVOICE_STATUS: Pembayaran tidak dapat diproses karena invoice % berstatus Dibatalkan', v_inv.inv_no;
    END IF;

    -- [4] RECALCULATE EXISTING VALID PAYMENTS WITH STRICT ROW LOCKING
    SELECT COALESCE(SUM(amount), 0.00) INTO v_existing_valid_paid 
    FROM public.payment_history 
    WHERE (invoice_id = p_invoice_id OR inv_no = v_inv.inv_no) AND status = 'VALID';

    -- [5] OVERPAYMENT SAFETY RULE (STRICT MANDATORY BLOCK)
    IF (v_existing_valid_paid + p_amount) > (v_inv.total + 0.01) THEN
        RAISE EXCEPTION 'OVERPAYMENT_BLOCKED: Total pembayaran (Rp %) akan melebihi total tagihan invoice % (Rp %). Pembayaran ditolak.',
            (v_existing_valid_paid + p_amount), v_inv.inv_no, v_inv.total;
    END IF;

    -- [6] DERIVE NEW INVOICE / RECEIVABLE STATE SERVER-SIDE
    v_new_paid := v_existing_valid_paid + p_amount;
    v_new_remaining := GREATEST(0.00, v_inv.total - v_new_paid);
    
    IF v_new_remaining <= 0.01 THEN
        v_new_remaining := 0.00;
        v_new_status := 'Lunas';
    ELSE
        v_new_status := 'Sebagian';
    END IF;

    v_date_str := CURRENT_DATE;

    -- [7] INSERT VALID PAYMENT HISTORY RECORD ATOMICALLY
    INSERT INTO public.payment_history (
        invoice_id, inv_no, customer_name, payment_date, payment_method, 
        payment_account_id, amount, payment_type, status, created_by, note
    ) VALUES (
        p_invoice_id, v_inv.inv_no, v_inv.customer_name, v_date_str, COALESCE(p_payment_method, 'Tunai'),
        p_payment_account_id, p_amount, 'piutang', 'VALID', v_caller_id, p_note
    ) RETURNING id INTO v_payment_id;

    -- [8] UPDATE INVOICES TABLE
    UPDATE public.invoices 
    SET paid_amount = v_new_paid,
        remaining = v_new_remaining,
        status = v_new_status,
        updated_at = NOW()
    WHERE id = p_invoice_id;

    -- [9] UPDATE / INSERT RECEIVABLES TABLE
    IF EXISTS (SELECT 1 FROM public.receivables WHERE invoice_id = p_invoice_id OR inv_no = v_inv.inv_no) THEN
        UPDATE public.receivables 
        SET paid = v_new_paid,
            remaining = v_new_remaining,
            status = v_new_status,
            updated_at = NOW()
        WHERE invoice_id = p_invoice_id OR inv_no = v_inv.inv_no;
    ELSE
        INSERT INTO public.receivables (
            invoice_id, inv_no, customer_name, due_date, status, total, paid, remaining
        ) VALUES (
            p_invoice_id, v_inv.inv_no, v_inv.customer_name, v_inv.due_date, v_new_status, v_inv.total, v_new_paid, v_new_remaining
        );
    END IF;

    -- [10] RESOLVE COA ACCOUNTS FOR AUTOMATIC JOURNAL POSTING
    SELECT pa.id, pa.name, pa.chart_of_account_id INTO v_pay_acc
    FROM public.payment_accounts pa
    WHERE pa.id = p_payment_account_id AND pa.is_active = true;

    IF v_pay_acc.id IS NULL OR v_pay_acc.chart_of_account_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_PAYMENT_ACCOUNT_COA: Akun pembayaran % tidak terhubung ke Bagan Akun (COA)', p_payment_account_id;
    END IF;

    v_pay_coa_id := v_pay_acc.chart_of_account_id;

    SELECT id INTO v_piutang_coa_id 
    FROM public.chart_of_accounts 
    WHERE code = '1-1110' AND is_active = true;

    IF v_piutang_coa_id IS NULL THEN
        RAISE EXCEPTION 'MISSING_PIUTANG_COA: Akun Piutang Usaha (1-1110) tidak ditemukan di database';
    END IF;

    -- [11] POST AUTOMATIC DOUBLE-ENTRY JOURNAL ENTRY
    v_journal_lines := jsonb_build_array(
        jsonb_build_object(
            'chart_of_account_id', v_pay_coa_id,
            'debit', p_amount,
            'credit', 0.00,
            'description', 'Penerimaan pembayaran piutang ' || v_inv.inv_no || ' via ' || v_pay_acc.name
        ),
        jsonb_build_object(
            'chart_of_account_id', v_piutang_coa_id,
            'debit', 0.00,
            'credit', p_amount,
            'description', 'Pelunasan/cicilan piutang ' || v_inv.inv_no || ' (' || COALESCE(v_inv.customer_name, 'Pelanggan') || ')'
        )
    );

    SELECT journal_id INTO v_journal_id
    FROM public.post_journal_entry(
        p_journal_date := v_date_str,
        p_source_type := 'PAYMENT',
        p_source_id := v_payment_id,
        p_source_code := 'PAY-' || v_inv.inv_no,
        p_description := 'Jurnal Pembayaran Piutang ' || v_inv.inv_no || ' - ' || COALESCE(v_inv.customer_name, 'Pelanggan'),
        p_user_id := v_caller_id,
        p_lines := v_journal_lines
    );

    RETURN jsonb_build_object(
        'success', true,
        'payment_id', v_payment_id,
        'journal_id', v_journal_id,
        'new_paid', v_new_paid,
        'new_remaining', v_new_remaining,
        'status', v_new_status
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.process_payment_atomic FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_payment_atomic TO authenticated;

-- 2. HARDENED ATOMIC RPC FOR VOIDING PAYMENTS & REVERSAL JOURNALS
CREATE OR REPLACE FUNCTION public.void_payment_atomic(
    p_payment_id BIGINT,
    p_reason TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_caller_role VARCHAR;
    v_pay RECORD;
    v_inv RECORD;
    v_orig_jrn RECORD;
    v_new_paid NUMERIC(15,2) := 0.00;
    v_new_remaining NUMERIC(15,2);
    v_new_status VARCHAR(50);
BEGIN
    -- [1] AUTHENTICATION & ROLE AUTHORIZATION
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN 
        RAISE EXCEPTION 'UNAUTHENTICATED: Sesi pengguna tidak terautentikasi'; 
    END IF;

    v_caller_role := public.get_current_user_role();
    IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin') THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Hanya peran Owner atau Admin yang berhak membatalkan (VOID) pembayaran';
    END IF;

    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RAISE EXCEPTION 'INVALID_PARAM: Alasan pembatalan (VOID) pembayaran wajib diisi';
    END IF;

    -- [2] LOCK AND VALIDATE TARGET PAYMENT ROW
    SELECT * INTO v_pay FROM public.payment_history WHERE id = p_payment_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_NOT_FOUND: Pembayaran ID % tidak ditemukan', p_payment_id;
    END IF;

    IF v_pay.status = 'VOID' THEN
        RAISE EXCEPTION 'ALREADY_VOID: Pembayaran ini sudah berstatus VOID sebelumnya';
    END IF;

    -- [3] LOCK TARGET INVOICE
    SELECT * INTO v_inv FROM public.invoices WHERE id = v_pay.invoice_id OR inv_no = v_pay.inv_no FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_NOT_FOUND: Invoice terkait % tidak ditemukan', v_pay.inv_no;
    END IF;

    -- [4] UPDATE PAYMENT ROW TO VOID
    UPDATE public.payment_history 
    SET status = 'VOID',
        voided_at = NOW(),
        voided_by = v_caller_id,
        note = COALESCE(note || ' | ', '') || 'VOID REASON: ' || trim(p_reason)
    WHERE id = p_payment_id;

    -- [5] REVERSE ASSOCIATED JOURNAL ENTRY
    SELECT * INTO v_orig_jrn 
    FROM public.journal_entries 
    WHERE source_type = 'PAYMENT' AND source_id = p_payment_id AND status = 'POSTED' AND is_reversal = false;

    IF v_orig_jrn.id IS NOT NULL THEN
        PERFORM public.reverse_journal_entry(
            p_original_journal_id := v_orig_jrn.id,
            p_user_id := v_caller_id,
            p_reversal_reason := 'PEMBALIKAN VOID PEMBAYARAN: ' || trim(p_reason)
        );
    END IF;

    -- [6] RECALCULATE ALL REMAINING VALID PAYMENTS FOR THE INVOICE
    SELECT COALESCE(SUM(amount), 0.00) INTO v_new_paid 
    FROM public.payment_history 
    WHERE (invoice_id = v_inv.id OR inv_no = v_inv.inv_no) AND status = 'VALID';

    v_new_remaining := GREATEST(0.00, v_inv.total - v_new_paid);

    IF v_new_paid = 0 THEN
        v_new_status := 'Belum Bayar';
    ELSIF v_new_remaining <= 0.01 THEN
        v_new_remaining := 0.00;
        v_new_status := 'Lunas';
    ELSE
        v_new_status := 'Sebagian';
    END IF;

    -- [7] UPDATE INVOICE STATE
    UPDATE public.invoices 
    SET paid_amount = v_new_paid,
        remaining = v_new_remaining,
        status = v_new_status,
        updated_at = NOW()
    WHERE id = v_inv.id;

    -- [8] UPDATE RECEIVABLES STATE
    UPDATE public.receivables 
    SET paid = v_new_paid,
        remaining = v_new_remaining,
        status = v_new_status,
        updated_at = NOW()
    WHERE invoice_id = v_inv.id OR inv_no = v_inv.inv_no;

    RETURN jsonb_build_object(
        'success', true,
        'payment_id', p_payment_id,
        'recalculated_paid', v_new_paid,
        'recalculated_remaining', v_new_remaining,
        'new_status', v_new_status
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.void_payment_atomic FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_payment_atomic TO authenticated;

COMMIT;

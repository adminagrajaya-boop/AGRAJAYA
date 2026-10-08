-- Migration: 20261008_financial_security_hardening

BEGIN;

-- A. HAPUS broad authenticated write policies
DROP POLICY IF EXISTS p_invoices_insert_authenticated ON public.invoices;
DROP POLICY IF EXISTS p_invoices_update_authenticated ON public.invoices;
DROP POLICY IF EXISTS p_invoices_delete_authenticated ON public.invoices;

DROP POLICY IF EXISTS p_invoice_items_insert_authenticated ON public.invoice_items;
DROP POLICY IF EXISTS p_invoice_items_update_authenticated ON public.invoice_items;
DROP POLICY IF EXISTS p_invoice_items_delete_authenticated ON public.invoice_items;

DROP POLICY IF EXISTS p_receivables_insert_authenticated ON public.receivables;
DROP POLICY IF EXISTS p_receivables_update_authenticated ON public.receivables;
DROP POLICY IF EXISTS p_receivables_delete_authenticated ON public.receivables;

-- B. PAYMENT HISTORY
DROP POLICY IF EXISTS p_payment_history_insert_authenticated ON public.payment_history;

-- C. INTERNAL ACCOUNTING ENGINE
REVOKE EXECUTE ON FUNCTION public.post_journal_entry(date, varchar, bigint, varchar, text, uuid, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.reverse_journal_entry(bigint, uuid, text) FROM PUBLIC, anon, authenticated;

-- D. VOID PAYMENT HARDENING
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

    -- GUARD VOID INVOICE
    IF v_inv.status IN ('Dibatalkan', 'Void') THEN
        RAISE EXCEPTION 'VOID_INVOICE_BLOCKED: Pembayaran tidak dapat di-VOID karena invoice % sudah berstatus %', v_inv.inv_no, v_inv.status;
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

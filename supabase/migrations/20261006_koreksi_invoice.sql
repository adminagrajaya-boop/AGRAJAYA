-- Migration for Invoice Correction
-- Adds corrected_from relationship, correction logs, and atomic RPC for safe correction

-- 1. Add corrected_from to invoices
ALTER TABLE public.invoices
ADD COLUMN IF NOT EXISTS corrected_from BIGINT NULL REFERENCES public.invoices(id);

-- 2. Create Audit Log Table for Corrections
CREATE TABLE IF NOT EXISTS public.invoice_correction_logs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    old_invoice_id BIGINT NOT NULL REFERENCES public.invoices(id),
    new_invoice_id BIGINT NOT NULL REFERENCES public.invoices(id),
    user_id UUID NOT NULL, -- references auth.users
    correction_reason TEXT,
    old_total NUMERIC(15,2),
    new_total NUMERIC(15,2),
    old_status VARCHAR(50),
    new_status VARCHAR(50),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Apply RLS to audit log
ALTER TABLE public.invoice_correction_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow authenticated read" ON public.invoice_correction_logs FOR SELECT TO authenticated USING (true);
CREATE POLICY "Allow authenticated insert" ON public.invoice_correction_logs FOR INSERT TO authenticated WITH CHECK (true);

-- 3. Create Atomic RPC for Invoice Correction
CREATE OR REPLACE FUNCTION public.correct_invoice_atomic(
    p_old_inv_id BIGINT,
    p_user_id UUID,
    p_correction_reason TEXT,
    p_new_inv_data JSONB,
    p_new_inv_items JSONB,
    p_new_rec_data JSONB,
    p_new_journal_data JSONB,
    p_new_journal_lines JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_old_inv RECORD;
    v_payment_count INT;
    v_old_journal_id BIGINT;
    v_new_inv_id BIGINT;
    v_new_inv_no VARCHAR;
    v_new_journal_id BIGINT;
    v_item JSONB;
    v_line JSONB;
BEGIN
    -- Validations
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'User ID is required for correction';
    END IF;

    SELECT * INTO v_old_inv FROM public.invoices WHERE id = p_old_inv_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Old invoice not found';
    END IF;

    IF v_old_inv.status = 'Dibatalkan' OR v_old_inv.status = 'Void' THEN
        RAISE EXCEPTION 'Invoice is already voided or cancelled';
    END IF;

    -- Check for payments
    SELECT COUNT(*) INTO v_payment_count 
    FROM public.payment_history 
    WHERE inv_no = v_old_inv.inv_no AND status != 'VOID';

    IF v_payment_count > 0 THEN
        RAISE EXCEPTION 'Cannot correct invoice automatically because it already has payment history. Please void payments first.';
    END IF;

    -- Reverse Old Journal
    SELECT id INTO v_old_journal_id
    FROM public.journal_entries
    WHERE source_type = 'INVOICE' AND source_code = v_old_inv.inv_no AND status = 'POSTED' AND is_reversal = false;

    IF v_old_journal_id IS NOT NULL THEN
        -- We assume reverse_journal_entry exists from foundation
        PERFORM public.reverse_journal_entry(v_old_journal_id, p_user_id, 'KOREKSI INVOICE ' || v_old_inv.inv_no);
    END IF;

    -- Void Old Invoice
    UPDATE public.invoices
    SET status = 'Dibatalkan',
        voided_at = NOW(),
        voided_by = p_user_id,
        remaining = 0
    WHERE id = p_old_inv_id;

    -- Void Old Receivable
    UPDATE public.receivables
    SET status = 'Dibatalkan',
        remaining = 0
    WHERE inv_no = v_old_inv.inv_no;

    -- Revert Quotation status if applicable?
    -- The prompt says: "Quotation yang belum menjadi invoice: tetap bisa Edit... Koreksi dilakukan dari modul Invoice."
    -- We won't touch quotation status because the new invoice will still be linked to it.

    -- Insert New Invoice
    INSERT INTO public.invoices (
        inv_no, customer_id, customer_name, customer_farm, due_date, invoice_date, status, 
        subtotal, discount_total, total, paid_amount, remaining, project_id, quotation_id, 
        transaction_id, created_by, corrected_from
    ) VALUES (
        p_new_inv_data->>'inv_no',
        (p_new_inv_data->>'customer_id')::BIGINT,
        p_new_inv_data->>'customer_name',
        p_new_inv_data->>'customer_farm',
        (p_new_inv_data->>'due_date')::DATE,
        (p_new_inv_data->>'invoice_date')::DATE,
        p_new_inv_data->>'status',
        (p_new_inv_data->>'subtotal')::NUMERIC,
        (p_new_inv_data->>'discount_total')::NUMERIC,
        (p_new_inv_data->>'total')::NUMERIC,
        (p_new_inv_data->>'paid_amount')::NUMERIC,
        (p_new_inv_data->>'remaining')::NUMERIC,
        (p_new_inv_data->>'project_id')::BIGINT,
        (p_new_inv_data->>'quotation_id')::BIGINT,
        (p_new_inv_data->>'transaction_id')::BIGINT,
        p_user_id,
        p_old_inv_id
    ) RETURNING id, inv_no INTO v_new_inv_id, v_new_inv_no;

    -- Insert New Items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_new_inv_items)
    LOOP
        INSERT INTO public.invoice_items (
            invoice_id, product_id, category, unit, price, qty, 
            discount_type, discount_value, discount_amount, subtotal
        ) VALUES (
            v_new_inv_id,
            (v_item->>'product_id')::BIGINT,
            v_item->>'category',
            v_item->>'unit',
            (v_item->>'price')::NUMERIC,
            (v_item->>'qty')::NUMERIC,
            v_item->>'discount_type',
            (v_item->>'discount_value')::NUMERIC,
            (v_item->>'discount_amount')::NUMERIC,
            (v_item->>'subtotal')::NUMERIC
        );
    END LOOP;

    -- Insert New Receivable
    IF p_new_rec_data IS NOT NULL AND jsonb_typeof(p_new_rec_data) != 'null' THEN
        INSERT INTO public.receivables (
            inv_no, customer_id, customer_name, total_amount, paid_amount, remaining, 
            due_date, status
        ) VALUES (
            v_new_inv_no,
            (p_new_rec_data->>'customer_id')::BIGINT,
            p_new_rec_data->>'customer_name',
            (p_new_rec_data->>'total_amount')::NUMERIC,
            (p_new_rec_data->>'paid_amount')::NUMERIC,
            (p_new_rec_data->>'remaining')::NUMERIC,
            (p_new_rec_data->>'due_date')::DATE,
            p_new_rec_data->>'status'
        );
    END IF;

    -- Insert New Journal
    IF p_new_journal_data IS NOT NULL AND jsonb_typeof(p_new_journal_data) != 'null' THEN
        INSERT INTO public.journal_entries (
            journal_no, journal_date, description, source_type, source_code, status, 
            created_by, is_reversal
        ) VALUES (
            p_new_journal_data->>'journal_no',
            (p_new_journal_data->>'journal_date')::DATE,
            p_new_journal_data->>'description',
            p_new_journal_data->>'source_type',
            v_new_inv_no,
            p_new_journal_data->>'status',
            p_user_id,
            false
        ) RETURNING id INTO v_new_journal_id;

        FOR v_line IN SELECT * FROM jsonb_array_elements(p_new_journal_lines)
        LOOP
            INSERT INTO public.journal_lines (
                journal_entry_id, chart_of_account_id, description, debit, credit
            ) VALUES (
                v_new_journal_id,
                (v_line->>'chart_of_account_id')::BIGINT,
                v_line->>'description',
                (v_line->>'debit')::NUMERIC,
                (v_line->>'credit')::NUMERIC
            );
        END LOOP;
    END IF;

    -- Insert Audit Log
    INSERT INTO public.invoice_correction_logs (
        old_invoice_id, new_invoice_id, user_id, correction_reason, 
        old_total, new_total, old_status, new_status
    ) VALUES (
        p_old_inv_id, v_new_inv_id, p_user_id, p_correction_reason,
        v_old_inv.total, (p_new_inv_data->>'total')::NUMERIC, v_old_inv.status, p_new_inv_data->>'status'
    );

    RETURN jsonb_build_object('success', true, 'new_invoice_id', v_new_inv_id, 'new_invoice_no', v_new_inv_no);
END;
$$;

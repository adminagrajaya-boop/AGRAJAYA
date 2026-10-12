-- ==============================================================================
-- AGRA JAYA POS — MIGRATION: SECURE JOURNAL ENGINE WRAPPERS & ATOMIC PAYABLE PAYMENT
-- Target Database: PostgreSQL (Supabase)
-- Security: Role-checked DEFINER RPCs, strict balance validation, idempotent audit
-- ==============================================================================

BEGIN;

-- 1. SECURE AUTHORIZED WRAPPER FOR POSTING JOURNAL ENTRIES
CREATE OR REPLACE FUNCTION public.post_journal_entry_secure(
    p_journal_date DATE,
    p_source_type VARCHAR,
    p_source_id BIGINT,
    p_source_code VARCHAR,
    p_description TEXT,
    p_lines JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_caller_role VARCHAR;
    v_res RECORD;
    v_line JSONB;
    v_account_id BIGINT;
    v_debit NUMERIC(15,2);
    v_credit NUMERIC(15,2);
    v_total_debit NUMERIC(15,2) := 0.00;
    v_total_credit NUMERIC(15,2) := 0.00;
BEGIN
    -- [1] Authentication & Role Check
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHENTICATED: Sesi pengguna tidak terautentikasi';
    END IF;

    v_caller_role := public.get_current_user_role();
    IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin', 'kasir') THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Peran pengguna tidak memiliki hak akses untuk memposting jurnal';
    END IF;

    -- Strict check for sensitive source types
    IF p_source_type IN ('EXPENSE', 'EQUITY') AND v_caller_role NOT IN ('owner', 'admin') THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Hanya Owner atau Admin yang berhak memposting jurnal Beban atau Ekuitas';
    END IF;

    -- [2] Validate Source Type & Existence of Source Record (Anti-Ghost Journal)
    IF p_source_type IS NULL OR p_source_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_PARAM: p_source_type dan p_source_id wajib diisi';
    END IF;

    CASE p_source_type
        WHEN 'TRANSACTION' THEN
            IF NOT EXISTS (SELECT 1 FROM public.transactions WHERE id = p_source_id) THEN
                RAISE EXCEPTION 'SOURCE_NOT_FOUND: Transaksi ID % tidak ditemukan', p_source_id;
            END IF;
        WHEN 'INVOICE' THEN
            IF NOT EXISTS (SELECT 1 FROM public.invoices WHERE id = p_source_id) THEN
                RAISE EXCEPTION 'SOURCE_NOT_FOUND: Invoice ID % tidak ditemukan', p_source_id;
            END IF;
        WHEN 'PURCHASE' THEN
            IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE id = p_source_id) THEN
                RAISE EXCEPTION 'SOURCE_NOT_FOUND: Pembelian ID % tidak ditemukan', p_source_id;
            END IF;
        WHEN 'PAYMENT' THEN
            IF NOT EXISTS (SELECT 1 FROM public.payment_history WHERE id = p_source_id) THEN
                RAISE EXCEPTION 'SOURCE_NOT_FOUND: Pembayaran ID % tidak ditemukan', p_source_id;
            END IF;
        WHEN 'EXPENSE' THEN
            IF NOT EXISTS (SELECT 1 FROM public.expenses WHERE id = p_source_id) THEN
                RAISE EXCEPTION 'SOURCE_NOT_FOUND: Beban ID % tidak ditemukan', p_source_id;
            END IF;
        WHEN 'EQUITY' THEN
            IF NOT EXISTS (SELECT 1 FROM public.equity_transactions WHERE id = p_source_id) THEN
                RAISE EXCEPTION 'SOURCE_NOT_FOUND: Ekuitas ID % tidak ditemukan', p_source_id;
            END IF;
        ELSE
            RAISE EXCEPTION 'INVALID_SOURCE_TYPE: Source type % tidak didukung', p_source_type;
    END CASE;

    -- [3] Validate Lines Array & Accounting Balance
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) < 2 THEN
        RAISE EXCEPTION 'INVALID_LINES: Jurnal minimal harus memiliki 2 baris (Debit & Kredit)';
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        v_account_id := (v_line->>'chart_of_account_id')::BIGINT;
        v_debit := COALESCE((v_line->>'debit')::NUMERIC, 0.00);
        v_credit := COALESCE((v_line->>'credit')::NUMERIC, 0.00);

        IF v_account_id IS NULL THEN
            RAISE EXCEPTION 'INVALID_ACCOUNT: chart_of_account_id wajib diisi pada setiap baris jurnal';
        END IF;

        IF NOT EXISTS (SELECT 1 FROM public.chart_of_accounts WHERE id = v_account_id AND is_active = true) THEN
            RAISE EXCEPTION 'INACTIVE_ACCOUNT: Akun ID % tidak ditemukan atau tidak aktif', v_account_id;
        END IF;

        IF v_debit < 0 OR v_credit < 0 THEN
            RAISE EXCEPTION 'NEGATIVE_AMOUNT: Nominal jurnal tidak boleh negatif';
        END IF;

        v_total_debit := v_total_debit + v_debit;
        v_total_credit := v_total_credit + v_credit;
    END LOOP;

    IF v_total_debit <> v_total_credit THEN
        RAISE EXCEPTION 'UNBALANCED_JOURNAL: Total Debit (Rp %) tidak sama dengan Total Kredit (Rp %)', v_total_debit, v_total_credit;
    END IF;

    IF v_total_debit <= 0 THEN
        RAISE EXCEPTION 'ZERO_JOURNAL_AMOUNT: Total nominal jurnal harus lebih besar dari 0';
    END IF;

    -- [4] Call Internal post_journal_entry Function
    SELECT journal_id, journal_no INTO v_res
    FROM public.post_journal_entry(
        p_journal_date := p_journal_date,
        p_source_type := p_source_type,
        p_source_id := p_source_id,
        p_source_code := p_source_code,
        p_description := p_description,
        p_user_id := v_caller_id,
        p_lines := p_lines
    );

    RETURN jsonb_build_object(
        'success', true,
        'journal_id', v_res.journal_id,
        'journal_no', v_res.journal_no
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.post_journal_entry_secure FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_journal_entry_secure TO authenticated;


-- 2. SECURE AUTHORIZED WRAPPER FOR REVERSING JOURNAL ENTRIES
CREATE OR REPLACE FUNCTION public.reverse_journal_entry_secure(
    p_original_journal_id BIGINT,
    p_reversal_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_caller_role VARCHAR;
    v_res RECORD;
    v_orig public.journal_entries%ROWTYPE;
BEGIN
    -- [1] Authentication & Role Check
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHENTICATED: Sesi pengguna tidak terautentikasi';
    END IF;

    v_caller_role := public.get_current_user_role();
    IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin') THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Hanya Owner atau Admin yang berhak membalikkan (reversal) jurnal';
    END IF;

    IF p_reversal_reason IS NULL OR trim(p_reversal_reason) = '' THEN
        RAISE EXCEPTION 'INVALID_PARAM: Alasan pembalikan jurnal wajib diisi';
    END IF;

    -- [2] Verify Original Journal
    SELECT * INTO v_orig FROM public.journal_entries WHERE id = p_original_journal_id;
    IF v_orig.id IS NULL THEN
        RAISE EXCEPTION 'ORIGINAL_JOURNAL_NOT_FOUND: Jurnal ID % tidak ditemukan', p_original_journal_id;
    END IF;

    IF v_orig.status <> 'POSTED' THEN
        RAISE EXCEPTION 'INVALID_JOURNAL_STATUS: Jurnal berstatus % tidak dapat dibalik', v_orig.status;
    END IF;

    IF v_orig.is_reversal = TRUE THEN
        RAISE EXCEPTION 'CANNOT_REVERSE_REVERSAL: Jurnal pembalik tidak dapat dibalik ulang';
    END IF;

    -- [3] Call Internal reverse_journal_entry
    SELECT reversal_id, reversal_no INTO v_res
    FROM public.reverse_journal_entry(
        p_original_journal_id := p_original_journal_id,
        p_user_id := v_caller_id,
        p_reversal_reason := trim(p_reversal_reason)
    );

    RETURN jsonb_build_object(
        'success', true,
        'reversal_id', v_res.reversal_id,
        'reversal_no', v_res.reversal_no
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.reverse_journal_entry_secure FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reverse_journal_entry_secure TO authenticated;


-- 3. HARDENED ATOMIC RPC FOR PROCESSING PAYABLE (SUPPLIER) PAYMENTS
CREATE OR REPLACE FUNCTION public.process_payable_payment_atomic(
    p_purchase_id BIGINT,
    p_amount NUMERIC(15,2),
    p_payment_method VARCHAR(50),
    p_payment_account_id BIGINT,
    p_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_caller_role VARCHAR;
    v_purch RECORD;
    v_existing_valid_paid NUMERIC(15,2) := 0.00;
    v_new_paid NUMERIC(15,2);
    v_new_remaining NUMERIC(15,2);
    v_new_status VARCHAR(50);
    v_payment_id BIGINT;
    v_date_str DATE;
    v_pay_acc RECORD;
    v_pay_coa_id BIGINT;
    v_payable_coa_id BIGINT;
    v_journal_id BIGINT;
    v_journal_lines JSONB;
BEGIN
    -- [1] Authentication & Role Authorization
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN 
        RAISE EXCEPTION 'UNAUTHENTICATED: Sesi pengguna tidak terautentikasi'; 
    END IF;

    v_caller_role := public.get_current_user_role();
    IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin', 'kasir') THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Peran pengguna tidak memiliki hak untuk memproses pembayaran hutang';
    END IF;

    -- [2] Validate Parameters
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: Nominal pembayaran harus lebih besar dari 0';
    END IF;

    IF p_payment_account_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_PAYMENT_ACCOUNT: Akun pembayaran wajib dipilih';
    END IF;

    -- [3] Lock & Validate Target Purchase
    SELECT * INTO v_purch FROM public.purchases WHERE id = p_purchase_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PURCHASE_NOT_FOUND: Pembelian ID % tidak ditemukan', p_purchase_id;
    END IF;

    IF v_purch.status IN ('Dibatalkan', 'Void') THEN
        RAISE EXCEPTION 'INVALID_PURCHASE_STATUS: Pembayaran hutang tidak dapat diproses karena pembelian % berstatus Dibatalkan/Void', v_purch.po_no;
    END IF;

    -- [4] Calculate Existing Valid Payments With Row Locking
    SELECT COALESCE(SUM(amount), 0.00) INTO v_existing_valid_paid
    FROM public.payment_history
    WHERE (purchase_id = p_purchase_id OR po_no = v_purch.po_no) AND status = 'VALID' AND payment_type = 'hutang';

    -- [5] Overpayment Guard
    IF (v_existing_valid_paid + p_amount) > (v_purch.total + 0.01) THEN
        RAISE EXCEPTION 'OVERPAYMENT_BLOCKED: Total pembayaran (Rp %) akan melebihi total tagihan PO % (Rp %). Pembayaran ditolak.',
            (v_existing_valid_paid + p_amount), v_purch.po_no, v_purch.total;
    END IF;

    -- [6] Derive New State
    v_new_paid := v_existing_valid_paid + p_amount;
    v_new_remaining := GREATEST(0.00, v_purch.total - v_new_paid);

    IF v_new_remaining <= 0.01 THEN
        v_new_remaining := 0.00;
        v_new_status := 'Lunas';
    ELSE
        v_new_status := 'Sebagian';
    END IF;

    v_date_str := CURRENT_DATE;

    -- [7] Insert Real payment_history Record Atomically
    INSERT INTO public.payment_history (
        purchase_id, po_no, supplier_name, payment_date, payment_method,
        payment_account_id, amount, payment_type, status, created_by, note
    ) VALUES (
        v_purch.id, v_purch.po_no, v_purch.supplier_name, v_date_str, COALESCE(p_payment_method, 'Tunai'),
        p_payment_account_id, p_amount, 'hutang', 'VALID', v_caller_id, p_note
    ) RETURNING id INTO v_payment_id;

    -- [8] Update Purchases Table
    UPDATE public.purchases
    SET paid_amount = v_new_paid,
        remaining = v_new_remaining,
        updated_at = NOW()
    WHERE id = v_purch.id;

    -- [9] Update / Insert Payables Table
    IF EXISTS (SELECT 1 FROM public.payables WHERE purchase_id = v_purch.id OR po_no = v_purch.po_no) THEN
        UPDATE public.payables
        SET paid = v_new_paid,
            remaining = v_new_remaining,
            status = v_new_status,
            updated_at = NOW()
        WHERE purchase_id = v_purch.id OR po_no = v_purch.po_no;
    ELSE
        INSERT INTO public.payables (
            purchase_id, po_no, supplier_name, due_date, status, total, paid, remaining
        ) VALUES (
            v_purch.id, v_purch.po_no, v_purch.supplier_name, NULL, v_new_status, v_purch.total, v_new_paid, v_new_remaining
        );
    END IF;

    -- [10] Resolve COA
    SELECT pa.id, pa.name, pa.chart_of_account_id INTO v_pay_acc
    FROM public.payment_accounts pa
    WHERE pa.id = p_payment_account_id AND pa.is_active = true;

    IF v_pay_acc.id IS NULL OR v_pay_acc.chart_of_account_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_PAYMENT_ACCOUNT_COA: Akun pembayaran % tidak terhubung ke Bagan Akun (COA)', p_payment_account_id;
    END IF;

    v_pay_coa_id := v_pay_acc.chart_of_account_id;

    SELECT id INTO v_payable_coa_id
    FROM public.chart_of_accounts
    WHERE code = '2-1110' AND is_active = true;

    IF v_payable_coa_id IS NULL THEN
        RAISE EXCEPTION 'MISSING_PAYABLE_COA: Akun Hutang Usaha (2-1110) tidak ditemukan di database';
    END IF;

    -- [11] Post Automatic Double-Entry Journal Entry (Debit Hutang, Credit Kas/Bank)
    v_journal_lines := jsonb_build_array(
        jsonb_build_object(
            'chart_of_account_id', v_payable_coa_id,
            'debit', p_amount,
            'credit', 0.00,
            'description', 'Pelunasan/cicilan hutang PO ' || v_purch.po_no || ' (' || COALESCE(v_purch.supplier_name, 'Supplier') || ')'
        ),
        jsonb_build_object(
            'chart_of_account_id', v_pay_coa_id,
            'debit', 0.00,
            'credit', p_amount,
            'description', 'Pengeluaran kas/bank bayar hutang PO ' || v_purch.po_no || ' via ' || v_pay_acc.name
        )
    );

    SELECT journal_id INTO v_journal_id
    FROM public.post_journal_entry(
        p_journal_date := v_date_str,
        p_source_type := 'PAYMENT',
        p_source_id := v_payment_id,
        p_source_code := 'PAY-' || v_purch.po_no,
        p_description := 'Jurnal Pembayaran Hutang PO ' || v_purch.po_no || ' - ' || COALESCE(v_purch.supplier_name, 'Supplier'),
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

REVOKE EXECUTE ON FUNCTION public.process_payable_payment_atomic FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_payable_payment_atomic TO authenticated;

COMMIT;

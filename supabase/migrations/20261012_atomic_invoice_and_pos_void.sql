-- ==============================================================================
-- AGRA JAYA POS — MIGRATION: HARDENED ATOMIC INVOICE & POS TRANSACTION VOID ENGINE
-- Target Database: PostgreSQL (Supabase)
-- Purpose: Complete server-side atomicity for document cancellation & journal reversal.
--          Guarantees business documents and journals never separate on network drops.
-- ==============================================================================

BEGIN;

-- 1. ATOMIC RPC FOR VOIDING INVOICE & REVERSING ACCOUNTING JOURNAL
CREATE OR REPLACE FUNCTION public.void_invoice_atomic(
    p_invoice_id BIGINT,
    p_reason TEXT DEFAULT 'VOID Invoice oleh Pengguna'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_caller_role VARCHAR;
    v_inv RECORD;
    v_pay_count INT := 0;
    v_orig_journal_id BIGINT;
    v_reversal_id BIGINT := NULL;
    v_reversal_res RECORD;
BEGIN
    -- [1] Authentication & Role Authorization
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHENTICATED: Sesi pengguna tidak terautentikasi';
    END IF;

    v_caller_role := public.get_current_user_role();
    IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin') THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Hanya Owner atau Admin yang berhak membatalkan (VOID) invoice';
    END IF;

    IF p_invoice_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_PARAM: p_invoice_id wajib diisi';
    END IF;

    -- [2] Lock Target Invoice
    SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_NOT_FOUND: Invoice ID % tidak ditemukan', p_invoice_id;
    END IF;

    IF v_inv.status IN ('Dibatalkan', 'Void') THEN
        RAISE EXCEPTION 'ALREADY_VOIDED: Invoice % sudah berstatus Dibatalkan / Void', v_inv.inv_no;
    END IF;

    -- [3] Active Payment Check Guard
    SELECT COUNT(*) INTO v_pay_count
    FROM public.payment_history
    WHERE (invoice_id = p_invoice_id OR inv_no = v_inv.inv_no) AND status = 'VALID';

    IF v_pay_count > 0 THEN
        RAISE EXCEPTION 'CANNOT_VOID_PAID_INVOICE: Invoice % memiliki % pembayaran aktif. Batalkan pembayaran terlebih dahulu melalui Riwayat Bayar.', v_inv.inv_no, v_pay_count;
    END IF;

    -- [4] Lookup & Reverse Associated Journal Entry
    SELECT id INTO v_orig_journal_id
    FROM public.journal_entries
    WHERE source_type = 'INVOICE'
      AND (source_id = p_invoice_id OR source_code = v_inv.inv_no)
      AND is_reversal = FALSE
      AND status = 'POSTED'
    ORDER BY id DESC
    LIMIT 1;

    IF v_orig_journal_id IS NOT NULL THEN
        SELECT reversal_id INTO v_reversal_res
        FROM public.reverse_journal_entry(
            p_original_journal_id := v_orig_journal_id,
            p_user_id := v_caller_id,
            p_reversal_reason := COALESCE(p_reason, 'VOID Invoice ' || v_inv.inv_no)
        );
        v_reversal_id := v_reversal_res.reversal_id;
    END IF;

    -- [5] Update Invoices Table Atomically
    UPDATE public.invoices
    SET status = 'Dibatalkan',
        voided_at = NOW(),
        voided_by = v_caller_id,
        remaining = 0.00,
        updated_at = NOW()
    WHERE id = p_invoice_id;

    -- [6] Update Receivables Table Atomically
    UPDATE public.receivables
    SET status = 'Dibatalkan',
        remaining = 0.00,
        updated_at = NOW()
    WHERE invoice_id = p_invoice_id OR inv_no = v_inv.inv_no;

    -- [7] Revert Linked Quotation Status (If Exists)
    IF v_inv.quotation_id IS NOT NULL THEN
        UPDATE public.quotations
        SET status = 'Approved',
            updated_at = NOW()
        WHERE id = v_inv.quotation_id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'invoice_id', p_invoice_id,
        'inv_no', v_inv.inv_no,
        'reversal_journal_id', v_reversal_id,
        'status', 'Dibatalkan'
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.void_invoice_atomic FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_invoice_atomic TO authenticated;


-- 2. ATOMIC RPC FOR VOIDING POS TRANSACTION & REVERSING ACCOUNTING JOURNAL & RESTORING STOCK
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
    -- [1] Authentication & Role Authorization
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

    -- [3] Lookup & Reverse Associated Journal Entry
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

    -- [4] Update Transactions Status Atomically
    UPDATE public.transactions
    SET status = 'VOID',
        voided_at = NOW(),
        voided_by = v_caller_id,
        updated_at = NOW()
    WHERE id = p_transaction_id;

    -- [5] Restore Stock Atomically & Log in stock_logs
    IF v_trx.items IS NOT NULL AND jsonb_typeof(v_trx.items) = 'array' THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(v_trx.items) LOOP
            v_prod_id := COALESCE((v_item->>'productId')::BIGINT, (v_item->>'id')::BIGINT);
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

    -- [6] Cancel Associated Invoice or Receivable If Exists
    UPDATE public.invoices
    SET status = 'Dibatalkan',
        remaining = 0.00,
        updated_at = NOW()
    WHERE trx_code = v_trx.trx_code OR inv_no = v_trx.trx_code;

    UPDATE public.receivables
    SET status = 'Dibatalkan',
        remaining = 0.00,
        updated_at = NOW()
    WHERE inv_no = v_trx.trx_code;

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

COMMIT;

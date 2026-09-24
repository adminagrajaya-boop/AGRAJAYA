-- ==============================================================================
-- AGRA JAYA POS — FINANCIAL FOUNDATION MIGRATION #01 (HARDENED & AUDITED)
-- Target Database: PostgreSQL (Supabase)
-- Mode: Idempotent, Non-Destructive, Strict Double-Entry Accounting, Immutable Ledger
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. CHART OF ACCOUNTS (COA)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.chart_of_accounts (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code VARCHAR(20) NOT NULL UNIQUE,
    name VARCHAR(100) NOT NULL,
    category VARCHAR(20) NOT NULL CHECK (category IN ('ASSET', 'LIABILITY', 'EQUITY', 'REVENUE', 'COGS', 'EXPENSE')),
    parent_id BIGINT NULL REFERENCES public.chart_of_accounts(id),
    normal_balance VARCHAR(10) NOT NULL CHECK (normal_balance IN ('DEBIT', 'CREDIT')),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    description TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_coa_category ON public.chart_of_accounts(category);
CREATE INDEX IF NOT EXISTS idx_coa_parent ON public.chart_of_accounts(parent_id);

-- SEED MINIMUM CHART OF ACCOUNTS (24 AKUN STANDAR)
INSERT INTO public.chart_of_accounts (code, name, category, normal_balance, description)
VALUES
    ('1-1010', 'Kas Tunai Kasir', 'ASSET', 'DEBIT', 'Uang tunai kasir toko fisik'),
    ('1-1020', 'Bank Operasional', 'ASSET', 'DEBIT', 'Rekening bank operasional utama'),
    ('1-1030', 'Penampung QRIS', 'ASSET', 'DEBIT', 'Akun penampung penerimaan QRIS toko'),
    ('1-1110', 'Piutang Usaha', 'ASSET', 'DEBIT', 'Tagihan piutang tempo peternak'),
    ('1-1210', 'Persediaan Barang Dagang', 'ASSET', 'DEBIT', 'Nilai aset stok barang dagang toko'),

    ('2-1110', 'Hutang Usaha Supplier', 'LIABILITY', 'CREDIT', 'Kewajiban hutang pembelian PO tempo'),
    ('2-1120', 'Hutang Titipan Refund', 'LIABILITY', 'CREDIT', 'Kewajiban pengembalian dana void pelanggan'),

    ('3-1110', 'Modal Pemilik', 'EQUITY', 'CREDIT', 'Modal disetor pemilik usaha'),
    ('3-1120', 'Prive Pemilik', 'EQUITY', 'DEBIT', 'Penarikan dana pribadi pemilik (contra-equity)'),
    ('3-1130', 'Laba Periode Berjalan', 'EQUITY', 'CREDIT', 'Akumulasi laba bersih berjalan'),

    ('4-1110', 'Pendapatan Penjualan Barang', 'REVENUE', 'CREDIT', 'Penjualan peralatan dan hardware kandang'),
    ('4-1120', 'Pendapatan Jasa & Instalasi', 'REVENUE', 'CREDIT', 'Pendapatan jasa servis dan instalasi'),
    ('4-1990', 'Pendapatan Selisih Inventaris', 'REVENUE', 'CREDIT', 'Pendapatan penyesuaian selisih lebih stok'),

    ('5-1110', 'HPP Barang Dagang', 'COGS', 'DEBIT', 'Harga pokok penjualan barang kasir'),

    ('6-1010', 'Beban Operasional Umum', 'EXPENSE', 'DEBIT', 'Beban operasional harian toko'),
    ('6-1020', 'Beban Listrik', 'EXPENSE', 'DEBIT', 'Biaya listrik operasional toko'),
    ('6-1030', 'Beban Air', 'EXPENSE', 'DEBIT', 'Biaya air operasional toko'),
    ('6-1040', 'Beban Internet/Telekomunikasi', 'EXPENSE', 'DEBIT', 'Biaya internet dan komunikasi toko'),
    ('6-1050', 'Beban Transportasi/Logistik', 'EXPENSE', 'DEBIT', 'Beban BBM dan ekspedisi pengiriman'),
    ('6-1060', 'Beban Upah', 'EXPENSE', 'DEBIT', 'Upah teknisi harian dan staf'),
    ('6-1070', 'Beban Sewa', 'EXPENSE', 'DEBIT', 'Biaya sewa tempat operasional'),
    ('6-1080', 'Beban Perlengkapan', 'EXPENSE', 'DEBIT', 'Perlengkapan toko dan ATK'),
    ('6-1090', 'Beban Kerusakan/Susut', 'EXPENSE', 'DEBIT', 'Beban kerusakan atau susut persediaan'),
    ('6-1990', 'Beban Operasional Lainnya', 'EXPENSE', 'DEBIT', 'Beban operasional non-rutin lainnya')
ON CONFLICT (code) DO NOTHING;

-- ------------------------------------------------------------------------------
-- 2. PAYMENT ACCOUNTS (MAPPING METODE BAYAR KE KAS/BANK)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.payment_accounts (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    type VARCHAR(20) NOT NULL CHECK (type IN ('CASH', 'BANK', 'EWALLET', 'GATEWAY')),
    chart_of_account_id BIGINT NOT NULL REFERENCES public.chart_of_accounts(id),
    account_number VARCHAR(50) NULL,
    holder_name VARCHAR(100) NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_payment_acc_coa ON public.payment_accounts(chart_of_account_id);

-- SEED GENERIC PAYMENT ACCOUNTS
DO $$
DECLARE
    v_kas_id BIGINT;
    v_bank_id BIGINT;
    v_qris_id BIGINT;
BEGIN
    SELECT id INTO v_kas_id FROM public.chart_of_accounts WHERE code = '1-1010';
    SELECT id INTO v_bank_id FROM public.chart_of_accounts WHERE code = '1-1020';
    SELECT id INTO v_qris_id FROM public.chart_of_accounts WHERE code = '1-1030';

    IF v_kas_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.payment_accounts WHERE name = 'Kas Tunai Kasir') THEN
        INSERT INTO public.payment_accounts (name, type, chart_of_account_id) VALUES ('Kas Tunai Kasir', 'CASH', v_kas_id);
    END IF;

    IF v_bank_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.payment_accounts WHERE name = 'Bank Operasional') THEN
        INSERT INTO public.payment_accounts (name, type, chart_of_account_id) VALUES ('Bank Operasional', 'BANK', v_bank_id);
    END IF;

    IF v_qris_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.payment_accounts WHERE name = 'Penampung QRIS') THEN
        INSERT INTO public.payment_accounts (name, type, chart_of_account_id) VALUES ('Penampung QRIS', 'GATEWAY', v_qris_id);
    END IF;
END $$;

-- ------------------------------------------------------------------------------
-- 3. EXTEND EXISTING TABLES (SAFE, NULLABLE ALTERATIONS)
-- ------------------------------------------------------------------------------

-- transactions extension
ALTER TABLE public.transactions 
    ADD COLUMN IF NOT EXISTS payment_account_id BIGINT NULL REFERENCES public.payment_accounts(id),
    ADD COLUMN IF NOT EXISTS invoice_id BIGINT NULL REFERENCES public.invoices(id),
    ADD COLUMN IF NOT EXISTS voided_at TIMESTAMPTZ NULL,
    ADD COLUMN IF NOT EXISTS voided_by UUID NULL REFERENCES public.profiles(id);

-- invoices extension
ALTER TABLE public.invoices 
    ADD COLUMN IF NOT EXISTS transaction_id BIGINT NULL REFERENCES public.transactions(id),
    ADD COLUMN IF NOT EXISTS voided_at TIMESTAMPTZ NULL,
    ADD COLUMN IF NOT EXISTS voided_by UUID NULL REFERENCES public.profiles(id);

-- purchases extension
ALTER TABLE public.purchases 
    ADD COLUMN IF NOT EXISTS payment_account_id BIGINT NULL REFERENCES public.payment_accounts(id),
    ADD COLUMN IF NOT EXISTS voided_at TIMESTAMPTZ NULL,
    ADD COLUMN IF NOT EXISTS voided_by UUID NULL REFERENCES public.profiles(id);

-- payment_history extension
ALTER TABLE public.payment_history 
    ADD COLUMN IF NOT EXISTS payment_account_id BIGINT NULL REFERENCES public.payment_accounts(id),
    ADD COLUMN IF NOT EXISTS status VARCHAR(20) NOT NULL DEFAULT 'VALID',
    ADD COLUMN IF NOT EXISTS voided_at TIMESTAMPTZ NULL,
    ADD COLUMN IF NOT EXISTS voided_by UUID NULL REFERENCES public.profiles(id),
    ADD COLUMN IF NOT EXISTS note TEXT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'chk_payment_history_status'
    ) THEN
        ALTER TABLE public.payment_history ADD CONSTRAINT chk_payment_history_status CHECK (status IN ('VALID', 'VOID'));
    END IF;
END $$;

-- ------------------------------------------------------------------------------
-- 4. JOURNAL ENTRIES & JOURNAL LINES (DOUBLE-ENTRY ENGINE)
-- ------------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS public.journal_entry_seq START WITH 1 INCREMENT BY 1;

CREATE TABLE IF NOT EXISTS public.journal_entries (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    journal_no VARCHAR(30) NOT NULL UNIQUE,
    journal_date DATE NOT NULL,
    description TEXT NOT NULL,
    source_type VARCHAR(30) NOT NULL CHECK (source_type IN (
        'TRANSACTION', 'INVOICE', 'PURCHASE', 'PAYMENT', 'EXPENSE', 'EQUITY', 'STOCK_ADJUSTMENT', 'REVERSAL_VOID'
    )),
    source_id BIGINT NOT NULL,
    source_code VARCHAR(50) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'POSTED' CHECK (status IN ('DRAFT', 'POSTED', 'VOID')),
    is_reversal BOOLEAN NOT NULL DEFAULT FALSE,
    reversal_of_id BIGINT NULL REFERENCES public.journal_entries(id),
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    posted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_reversal_not_self CHECK (reversal_of_id IS NULL OR reversal_of_id <> id)
);

-- IDEMPOTENCY PARTIAL UNIQUE INDEXES
CREATE UNIQUE INDEX IF NOT EXISTS uq_journal_source_active 
ON public.journal_entries (source_type, source_id) 
WHERE (is_reversal = FALSE AND status = 'POSTED');

CREATE UNIQUE INDEX IF NOT EXISTS uq_journal_single_reversal 
ON public.journal_entries (reversal_of_id) 
WHERE (is_reversal = TRUE AND status = 'POSTED');

CREATE INDEX IF NOT EXISTS idx_jrn_date ON public.journal_entries(journal_date);

-- JOURNAL LINES
CREATE TABLE IF NOT EXISTS public.journal_lines (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    journal_entry_id BIGINT NOT NULL REFERENCES public.journal_entries(id) ON DELETE CASCADE,
    chart_of_account_id BIGINT NOT NULL REFERENCES public.chart_of_accounts(id),
    description VARCHAR(255) NULL,
    debit NUMERIC(15,2) NOT NULL DEFAULT 0.00 CHECK (debit >= 0),
    credit NUMERIC(15,2) NOT NULL DEFAULT 0.00 CHECK (credit >= 0),
    line_no INT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_line_not_both_zero CHECK (debit > 0 OR credit > 0),
    CONSTRAINT chk_line_one_sided CHECK ((debit > 0 AND credit = 0) OR (credit > 0 AND debit = 0))
);

CREATE INDEX IF NOT EXISTS idx_jrn_lines_entry ON public.journal_lines(journal_entry_id);
CREATE INDEX IF NOT EXISTS idx_jrn_lines_account ON public.journal_lines(chart_of_account_id);

-- IMMUTABILITY ENFORCEMENT TRIGGER (POSTED JOURNALS CANNOT BE MODIFIED OR DELETED)
CREATE OR REPLACE FUNCTION public.prevent_journal_modification()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'IMMUTABLE_RECORD: Jurnal dan baris rincian yang sudah berstatus POSTED tidak dapat diubah atau dihapus. Gunakan fungsi reverse_journal_entry() untuk pembatalan akuntansi yang sah.';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_immutable_journal_entries ON public.journal_entries;
CREATE TRIGGER trg_immutable_journal_entries
BEFORE UPDATE OR DELETE ON public.journal_entries
FOR EACH ROW EXECUTE FUNCTION public.prevent_journal_modification();

DROP TRIGGER IF EXISTS trg_immutable_journal_lines ON public.journal_lines;
CREATE TRIGGER trg_immutable_journal_lines
BEFORE UPDATE OR DELETE ON public.journal_lines
FOR EACH ROW EXECUTE FUNCTION public.prevent_journal_modification();

-- ------------------------------------------------------------------------------
-- 5. EXPENSES TABLE (PENCATATAN BEBAN OPERASIONAL)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.expenses (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    expense_no VARCHAR(30) NOT NULL UNIQUE,
    expense_date DATE NOT NULL,
    chart_of_account_id BIGINT NOT NULL REFERENCES public.chart_of_accounts(id),
    payment_account_id BIGINT NOT NULL REFERENCES public.payment_accounts(id),
    amount NUMERIC(15,2) NOT NULL CHECK (amount > 0),
    payee VARCHAR(150) NOT NULL,
    project_id BIGINT NULL REFERENCES public.projects(id),
    note TEXT NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'VALID' CHECK (status IN ('VALID', 'VOID')),
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    voided_at TIMESTAMPTZ NULL,
    voided_by UUID NULL REFERENCES public.profiles(id)
);

CREATE INDEX IF NOT EXISTS idx_expenses_date ON public.expenses(expense_date);
CREATE INDEX IF NOT EXISTS idx_expenses_coa ON public.expenses(chart_of_account_id);

-- COA CATEGORY VALIDATOR FOR EXPENSES
CREATE OR REPLACE FUNCTION public.validate_expense_coa()
RETURNS TRIGGER AS $$
DECLARE
    v_cat VARCHAR;
BEGIN
    SELECT category INTO v_cat FROM public.chart_of_accounts WHERE id = NEW.chart_of_account_id;
    IF v_cat <> 'EXPENSE' THEN
        RAISE EXCEPTION 'INVALID_COA_CATEGORY: Akun beban harus berasal dari kategori EXPENSE (Ditemukan: %)', v_cat;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_expense_coa ON public.expenses;
CREATE TRIGGER trg_validate_expense_coa
BEFORE INSERT OR UPDATE ON public.expenses
FOR EACH ROW EXECUTE FUNCTION public.validate_expense_coa();

-- ------------------------------------------------------------------------------
-- 6. EQUITY TRANSACTIONS (PENCATATAN MODAL & PRIVE)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.equity_transactions (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    equity_no VARCHAR(30) NOT NULL UNIQUE,
    equity_date DATE NOT NULL,
    transaction_type VARCHAR(20) NOT NULL CHECK (transaction_type IN ('CAPITAL_IN', 'DRAWING_OUT')),
    chart_of_account_id BIGINT NOT NULL REFERENCES public.chart_of_accounts(id),
    payment_account_id BIGINT NOT NULL REFERENCES public.payment_accounts(id),
    amount NUMERIC(15,2) NOT NULL CHECK (amount > 0),
    note TEXT NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'VALID' CHECK (status IN ('VALID', 'VOID')),
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    voided_at TIMESTAMPTZ NULL,
    voided_by UUID NULL REFERENCES public.profiles(id)
);

CREATE INDEX IF NOT EXISTS idx_equity_date ON public.equity_transactions(equity_date);

-- COA CATEGORY VALIDATOR FOR EQUITY
CREATE OR REPLACE FUNCTION public.validate_equity_coa()
RETURNS TRIGGER AS $$
DECLARE
    v_cat VARCHAR;
BEGIN
    SELECT category INTO v_cat FROM public.chart_of_accounts WHERE id = NEW.chart_of_account_id;
    IF v_cat <> 'EQUITY' THEN
        RAISE EXCEPTION 'INVALID_COA_CATEGORY: Akun ekuitas harus berasal dari kategori EQUITY (Ditemukan: %)', v_cat;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_equity_coa ON public.equity_transactions;
CREATE TRIGGER trg_validate_equity_coa
BEFORE INSERT OR UPDATE ON public.equity_transactions
FOR EACH ROW EXECUTE FUNCTION public.validate_equity_coa();

-- ------------------------------------------------------------------------------
-- 7. HELPER: ROLE SECURITY CHECK
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_current_user_role()
RETURNS VARCHAR 
SECURITY DEFINER
SET search_path = public
LANGUAGE sql STABLE AS $$
    SELECT role FROM public.profiles WHERE id = auth.uid() LIMIT 1;
$$;

-- ------------------------------------------------------------------------------
-- 8. JOURNAL POSTING RPC ENGINE (HARDENED, ATOMIC & IDEMPOTENT)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.post_journal_entry(
    p_journal_date DATE,
    p_source_type VARCHAR,
    p_source_id BIGINT,
    p_source_code VARCHAR,
    p_description TEXT,
    p_user_id UUID,
    p_lines JSONB -- Array: [{chart_of_account_id, debit, credit, description}]
)
RETURNS TABLE (
    journal_id BIGINT,
    journal_no VARCHAR
) 
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
    v_existing_id BIGINT;
    v_existing_no VARCHAR;
    v_new_id BIGINT;
    v_new_no VARCHAR;
    v_effective_user_id UUID;
    v_total_debit NUMERIC(15,2) := 0.00;
    v_total_credit NUMERIC(15,2) := 0.00;
    v_line JSONB;
    v_line_idx INT := 1;
    v_account_id BIGINT;
    v_debit NUMERIC(15,2);
    v_credit NUMERIC(15,2);
    v_is_active BOOLEAN;
    v_has_debit BOOLEAN := FALSE;
    v_has_credit BOOLEAN := FALSE;
BEGIN
    -- 1. Validasi Autentikasi & Otorisasi Role
    IF public.get_current_user_role() NOT IN ('owner', 'admin', 'kasir') THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Hanya role owner, admin, atau kasir yang berhak memposting jurnal';
    END IF;

    -- Cegah pemalsuan user_id pembuat jurnal (Anti-Spoofing)
    v_effective_user_id := COALESCE(auth.uid(), p_user_id);
    IF v_effective_user_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHENTICATED: User ID wajib terisi atau user harus terautentikasi';
    END IF;

    -- 2. Validasi Tipe Dokumen Sumber
    IF p_source_type NOT IN ('TRANSACTION', 'INVOICE', 'PURCHASE', 'PAYMENT', 'EXPENSE', 'EQUITY', 'STOCK_ADJUSTMENT') THEN
        RAISE EXCEPTION 'INVALID_SOURCE_TYPE: source_type % tidak didukung untuk jurnal reguler', p_source_type;
    END IF;

    -- 3. Validasi Keberadaan Record Sumber (Anti-Ghost Journal)
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
        WHEN 'STOCK_ADJUSTMENT' THEN
            IF NOT EXISTS (SELECT 1 FROM public.stock_logs WHERE id = p_source_id) THEN
                RAISE EXCEPTION 'SOURCE_NOT_FOUND: Stock log ID % tidak ditemukan', p_source_id;
            END IF;
    END CASE;

    -- 4. Idempotency Check (Kembalikan jurnal yang sudah ada jika pernah diposting)
    SELECT id, journal_entries.journal_no INTO v_existing_id, v_existing_no
    FROM public.journal_entries
    WHERE source_type = p_source_type AND source_id = p_source_id AND is_reversal = FALSE AND status = 'POSTED'
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
        RETURN QUERY SELECT v_existing_id, v_existing_no;
        RETURN;
    END IF;

    -- 5. Validasi Baris Input Jurnal
    IF jsonb_array_length(p_lines) < 2 THEN
        RAISE EXCEPTION 'INVALID_LINES_COUNT: Jurnal harus memiliki minimal 2 baris (1 Debit dan 1 Kredit)';
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        v_account_id := (v_line->>'chart_of_account_id')::bigint;
        v_debit := COALESCE((v_line->>'debit')::numeric, 0.00);
        v_credit := COALESCE((v_line->>'credit')::numeric, 0.00);

        IF v_account_id IS NULL THEN
            RAISE EXCEPTION 'MISSING_ACCOUNT_ID: Baris ke-% tidak memiliki chart_of_account_id', v_line_idx;
        END IF;

        SELECT is_active INTO v_is_active FROM public.chart_of_accounts WHERE id = v_account_id;
        IF v_is_active IS NULL OR v_is_active = FALSE THEN
            RAISE EXCEPTION 'ACCOUNT_INACTIVE_OR_NOT_FOUND: Akun ID % tidak aktif atau tidak ditemukan', v_account_id;
        END IF;

        IF (v_debit = 0 AND v_credit = 0) OR (v_debit > 0 AND v_credit > 0) THEN
            RAISE EXCEPTION 'INVALID_LINE_AMOUNT: Baris ke-% harus memiliki salah satu dari Debit atau Kredit > 0', v_line_idx;
        END IF;

        IF v_debit > 0 THEN v_has_debit := TRUE; END IF;
        IF v_credit > 0 THEN v_has_credit := TRUE; END IF;

        v_total_debit := v_total_debit + v_debit;
        v_total_credit := v_total_credit + v_credit;
        v_line_idx := v_line_idx + 1;
    END LOOP;

    -- 6. Verifikasi Keseimbangan Akuntansi Mutlak (Double-Entry Balance)
    IF NOT v_has_debit OR NOT v_has_credit THEN
        RAISE EXCEPTION 'MISSING_DEBIT_OR_CREDIT: Jurnal wajib memiliki minimal satu baris Debit dan satu baris Kredit';
    END IF;

    IF ABS(v_total_debit - v_total_credit) > 0.001 THEN
        RAISE EXCEPTION 'JOURNAL_UNBALANCED: Total Debit (Rp %) tidak sama dengan Total Kredit (Rp %)', v_total_debit, v_total_credit;
    END IF;

    -- 7. Generate Safe Sequential Journal Number
    v_new_no := 'JRN-' || to_char(p_journal_date, 'YYYYMMDD') || '-' || lpad(nextval('public.journal_entry_seq')::text, 6, '0');

    -- 8. Insert Header Jurnal Atomis
    INSERT INTO public.journal_entries (
        journal_no, journal_date, description, source_type, source_id, source_code, status, is_reversal, created_by
    ) VALUES (
        v_new_no, p_journal_date, p_description, p_source_type, p_source_id, p_source_code, 'POSTED', FALSE, v_effective_user_id
    ) RETURNING id INTO v_new_id;

    -- 9. Insert Detail Lines Atomis
    v_line_idx := 1;
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        INSERT INTO public.journal_lines (
            journal_entry_id, chart_of_account_id, description, debit, credit, line_no
        ) VALUES (
            v_new_id,
            (v_line->>'chart_of_account_id')::bigint,
            v_line->>'description',
            COALESCE((v_line->>'debit')::numeric, 0.00),
            COALESCE((v_line->>'credit')::numeric, 0.00),
            v_line_idx
        );
        v_line_idx := v_line_idx + 1;
    END LOOP;

    RETURN QUERY SELECT v_new_id, v_new_no;
END;
$$;

-- ------------------------------------------------------------------------------
-- 9. REVERSAL RPC ENGINE (IMMUTABLE VOID REVERSAL)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reverse_journal_entry(
    p_original_journal_id BIGINT,
    p_user_id UUID,
    p_reversal_reason TEXT
)
RETURNS TABLE (
    reversal_id BIGINT,
    reversal_no VARCHAR
) 
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
    v_orig public.journal_entries%ROWTYPE;
    v_existing_rev_id BIGINT;
    v_existing_rev_no VARCHAR;
    v_new_rev_id BIGINT;
    v_new_rev_no VARCHAR;
    v_effective_user_id UUID;
    v_line public.journal_lines%ROWTYPE;
BEGIN
    -- 1. Validasi Otorisasi (Hanya Owner & Admin yang Berhak Membalik Jurnal)
    IF public.get_current_user_role() NOT IN ('owner', 'admin') THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Hanya role owner atau admin yang berhak melakukan pembatalan (VOID) jurnal';
    END IF;

    v_effective_user_id := COALESCE(auth.uid(), p_user_id);
    IF v_effective_user_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHENTICATED: User ID wajib terisi atau user harus terautentikasi';
    END IF;

    -- 2. Verifikasi Jurnal Asli
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

    -- 3. Idempotency Check Reversal (Cegah Multiple Reversals)
    SELECT id, journal_no INTO v_existing_rev_id, v_existing_rev_no
    FROM public.journal_entries
    WHERE reversal_of_id = p_original_journal_id AND is_reversal = TRUE AND status = 'POSTED'
    LIMIT 1;

    IF v_existing_rev_id IS NOT NULL THEN
        RETURN QUERY SELECT v_existing_rev_id, v_existing_rev_no;
        RETURN;
    END IF;

    -- 4. Generate Sequential Reversal Number
    v_new_rev_no := 'REV-' || to_char(CURRENT_DATE, 'YYYYMMDD') || '-' || lpad(nextval('public.journal_entry_seq')::text, 6, '0');

    -- 5. Insert Reversal Header
    INSERT INTO public.journal_entries (
        journal_no, journal_date, description, source_type, source_id, source_code, status, is_reversal, reversal_of_id, created_by
    ) VALUES (
        v_new_rev_no,
        CURRENT_DATE,
        'PEMBALIK VOID: ' || COALESCE(p_reversal_reason, v_orig.description),
        'REVERSAL_VOID',
        v_orig.source_id,
        v_orig.source_code,
        'POSTED',
        TRUE,
        v_orig.id,
        v_effective_user_id
    ) RETURNING id INTO v_new_rev_id;

    -- 6. Copy Lines dengan Menukar Debit dan Kredit (Strict 1:1 Swap)
    FOR v_line IN SELECT * FROM public.journal_lines WHERE journal_entry_id = p_original_journal_id ORDER BY line_no ASC LOOP
        INSERT INTO public.journal_lines (
            journal_entry_id, chart_of_account_id, description, debit, credit, line_no
        ) VALUES (
            v_new_rev_id,
            v_line.chart_of_account_id,
            'Pembalik: ' || COALESCE(v_line.description, ''),
            v_line.credit, -- Swap: Kredit asal menjadi Debit pembalik
            v_line.debit,  -- Swap: Debit asal menjadi Kredit pembalik
            v_line.line_no
        );
    END LOOP;

    RETURN QUERY SELECT v_new_rev_id, v_new_rev_no;
END;
$$;

-- ------------------------------------------------------------------------------
-- 10. ROW LEVEL SECURITY (RLS) POLICIES
-- ------------------------------------------------------------------------------
ALTER TABLE public.chart_of_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.journal_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.journal_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.equity_transactions ENABLE ROW LEVEL SECURITY;

-- POLICIES: chart_of_accounts
DROP POLICY IF EXISTS p_coa_owner ON public.chart_of_accounts;
CREATE POLICY p_coa_owner ON public.chart_of_accounts FOR ALL TO authenticated
USING (public.get_current_user_role() = 'owner')
WITH CHECK (public.get_current_user_role() = 'owner');

DROP POLICY IF EXISTS p_coa_read_staff ON public.chart_of_accounts;
CREATE POLICY p_coa_read_staff ON public.chart_of_accounts FOR SELECT TO authenticated
USING (public.get_current_user_role() IN ('admin', 'kasir'));

-- POLICIES: payment_accounts
DROP POLICY IF EXISTS p_payacc_owner_admin ON public.payment_accounts;
CREATE POLICY p_payacc_owner_admin ON public.payment_accounts FOR ALL TO authenticated
USING (public.get_current_user_role() IN ('owner', 'admin'))
WITH CHECK (public.get_current_user_role() IN ('owner', 'admin'));

DROP POLICY IF EXISTS p_payacc_read_kasir ON public.payment_accounts;
CREATE POLICY p_payacc_read_kasir ON public.payment_accounts FOR SELECT TO authenticated
USING (public.get_current_user_role() = 'kasir');

-- POLICIES: journal_entries & journal_lines (STRICT IMMUTABILITY: SELECT ONLY UNTUK CLIENT)
-- Seluruh proses penulisan jurnal wajib melalui RPC post_journal_entry & reverse_journal_entry
DROP POLICY IF EXISTS p_journal_read_owner_admin ON public.journal_entries;
CREATE POLICY p_journal_read_owner_admin ON public.journal_entries FOR SELECT TO authenticated
USING (public.get_current_user_role() IN ('owner', 'admin'));

DROP POLICY IF EXISTS p_journal_lines_read_owner_admin ON public.journal_lines;
CREATE POLICY p_journal_lines_read_owner_admin ON public.journal_lines FOR SELECT TO authenticated
USING (public.get_current_user_role() IN ('owner', 'admin'));

-- POLICIES: expenses
DROP POLICY IF EXISTS p_expenses_owner_admin ON public.expenses;
CREATE POLICY p_expenses_owner_admin ON public.expenses FOR ALL TO authenticated
USING (public.get_current_user_role() IN ('owner', 'admin'))
WITH CHECK (public.get_current_user_role() IN ('owner', 'admin'));

-- POLICIES: equity_transactions (Khusus Owner)
DROP POLICY IF EXISTS p_equity_owner ON public.equity_transactions;
CREATE POLICY p_equity_owner ON public.equity_transactions FOR ALL TO authenticated
USING (public.get_current_user_role() = 'owner')
WITH CHECK (public.get_current_user_role() = 'owner');

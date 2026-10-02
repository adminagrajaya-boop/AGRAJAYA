-- Migration: Fix Invoice Subtotal Bug & Add Quotation/Invoice Discount Schema & Hardened RLS
-- Target Database: PostgreSQL (Supabase)
-- Date: 2026-10-02

BEGIN;

-- 1. Extend quotations table with subtotal & discount_total
ALTER TABLE public.quotations 
    ADD COLUMN IF NOT EXISTS subtotal NUMERIC(15,2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS discount_total NUMERIC(15,2) DEFAULT 0;

-- 2. Extend quotation_items table with discount fields
ALTER TABLE public.quotation_items 
    ADD COLUMN IF NOT EXISTS discount_type VARCHAR(10) DEFAULT 'none',
    ADD COLUMN IF NOT EXISTS discount_value NUMERIC(15,2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS discount_amount NUMERIC(15,2) DEFAULT 0;

-- 3. Extend invoices table with subtotal & discount_total
ALTER TABLE public.invoices 
    ADD COLUMN IF NOT EXISTS subtotal NUMERIC(15,2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS discount_total NUMERIC(15,2) DEFAULT 0;

-- 4. Extend invoice_items table with discount fields
ALTER TABLE public.invoice_items 
    ADD COLUMN IF NOT EXISTS discount_type VARCHAR(10) DEFAULT 'none',
    ADD COLUMN IF NOT EXISTS discount_value NUMERIC(15,2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS discount_amount NUMERIC(15,2) DEFAULT 0;

-- 5. Hardened RLS Policies for public.invoices
ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_invoices_select_authenticated ON public.invoices;
CREATE POLICY p_invoices_select_authenticated
ON public.invoices FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.is_active = true
    )
);

DROP POLICY IF EXISTS p_invoices_insert_authenticated ON public.invoices;
CREATE POLICY p_invoices_insert_authenticated
ON public.invoices FOR INSERT TO authenticated
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.is_active = true
    )
);

DROP POLICY IF EXISTS p_invoices_update_authenticated ON public.invoices;
CREATE POLICY p_invoices_update_authenticated
ON public.invoices FOR UPDATE TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.is_active = true
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.is_active = true
    )
);

DROP POLICY IF EXISTS p_invoices_delete_authenticated ON public.invoices;
CREATE POLICY p_invoices_delete_authenticated
ON public.invoices FOR DELETE TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.is_active = true
    )
);

-- 6. Hardened RLS Policies for public.invoice_items
ALTER TABLE public.invoice_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_invoice_items_select_authenticated ON public.invoice_items;
CREATE POLICY p_invoice_items_select_authenticated
ON public.invoice_items FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.is_active = true
    )
);

DROP POLICY IF EXISTS p_invoice_items_insert_authenticated ON public.invoice_items;
CREATE POLICY p_invoice_items_insert_authenticated
ON public.invoice_items FOR INSERT TO authenticated
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.is_active = true
    )
);

DROP POLICY IF EXISTS p_invoice_items_update_authenticated ON public.invoice_items;
CREATE POLICY p_invoice_items_update_authenticated
ON public.invoice_items FOR UPDATE TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.is_active = true
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.is_active = true
    )
);

DROP POLICY IF EXISTS p_invoice_items_delete_authenticated ON public.invoice_items;
CREATE POLICY p_invoice_items_delete_authenticated
ON public.invoice_items FOR DELETE TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.is_active = true
    )
);

-- 7. Hardened RLS Policies for public.receivables
ALTER TABLE public.receivables ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_receivables_select_authenticated ON public.receivables;
CREATE POLICY p_receivables_select_authenticated
ON public.receivables FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.is_active = true
    )
);

DROP POLICY IF EXISTS p_receivables_insert_authenticated ON public.receivables;
CREATE POLICY p_receivables_insert_authenticated
ON public.receivables FOR INSERT TO authenticated
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.is_active = true
    )
);

DROP POLICY IF EXISTS p_receivables_update_authenticated ON public.receivables;
CREATE POLICY p_receivables_update_authenticated
ON public.receivables FOR UPDATE TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.is_active = true
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.is_active = true
    )
);

DROP POLICY IF EXISTS p_receivables_delete_authenticated ON public.receivables;
CREATE POLICY p_receivables_delete_authenticated
ON public.receivables FOR DELETE TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.is_active = true
    )
);

COMMIT;

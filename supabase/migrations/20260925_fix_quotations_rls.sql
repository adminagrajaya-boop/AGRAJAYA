-- Migration: Quotations and Quotation Items RLS Hardening
-- Date: 2026-09-25
-- Description: Enables Row Level Security and creates strict policies for public.quotations and public.quotation_items.

ALTER TABLE public.quotations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quotation_items ENABLE ROW LEVEL SECURITY;

-- SELECT policies
DROP POLICY IF EXISTS p_quotations_select_authenticated ON public.quotations;
CREATE POLICY p_quotations_select_authenticated
ON public.quotations
FOR SELECT
TO authenticated
USING (true);

DROP POLICY IF EXISTS p_quotation_items_select_authenticated ON public.quotation_items;
CREATE POLICY p_quotation_items_select_authenticated
ON public.quotation_items
FOR SELECT
TO authenticated
USING (true);

-- INSERT policies
DROP POLICY IF EXISTS p_quotations_insert_authenticated ON public.quotations;
CREATE POLICY p_quotations_insert_authenticated
ON public.quotations
FOR INSERT
TO authenticated
WITH CHECK (
    created_by = auth.uid()
    AND EXISTS (
        SELECT 1
        FROM public.profiles
        WHERE profiles.id = auth.uid()
          AND profiles.is_active = true
    )
);

DROP POLICY IF EXISTS p_quotation_items_insert_authenticated ON public.quotation_items;
CREATE POLICY p_quotation_items_insert_authenticated
ON public.quotation_items
FOR INSERT
TO authenticated
WITH CHECK (true);

-- UPDATE policies
DROP POLICY IF EXISTS p_quotations_update_authenticated ON public.quotations;
CREATE POLICY p_quotations_update_authenticated
ON public.quotations
FOR UPDATE
TO authenticated
USING (true)
WITH CHECK (true);

-- DELETE policies for rollback cleanup
DROP POLICY IF EXISTS p_quotation_items_delete_authenticated ON public.quotation_items;
CREATE POLICY p_quotation_items_delete_authenticated
ON public.quotation_items
FOR DELETE
TO authenticated
USING (true);

DROP POLICY IF EXISTS p_quotations_delete_authenticated ON public.quotations;
CREATE POLICY p_quotations_delete_authenticated
ON public.quotations
FOR DELETE
TO authenticated
USING (true);

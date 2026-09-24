-- Migration: Fix Payment History Insert RLS Policy
-- Date: 2026-09-25
-- Description: Hardens INSERT policy for public.payment_history table to allow authenticated active users to insert payment history entries where created_by matches auth.uid().

ALTER TABLE public.payment_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_payment_history_insert_authenticated
ON public.payment_history;

CREATE POLICY p_payment_history_insert_authenticated
ON public.payment_history
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

-- Migration: Fix POS Transactions Insert RLS Policy
-- Date: 2026-09-25
-- Description: Hardens INSERT policy for public.transactions table to allow authenticated active users to create POS transactions where created_by matches auth.uid().

ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;

-- Drop legacy or misconfigured INSERT policy if exists
DROP POLICY IF EXISTS p_transactions_insert_authenticated ON public.transactions;
DROP POLICY IF EXISTS p_transactions_insert_owner_admin_kasir ON public.transactions;
DROP POLICY IF EXISTS p_transactions_insert ON public.transactions;

-- Create dedicated, strict INSERT policy for authenticated active users
CREATE POLICY p_transactions_insert_authenticated
ON public.transactions
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

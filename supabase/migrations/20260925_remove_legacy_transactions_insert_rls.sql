-- Migration: Remove Legacy Redundant Insert Policy on Transactions
-- Date: 2026-09-25
-- Description: Drops legacy transactions_insert_sales_roles policy to ensure p_transactions_insert_authenticated is the sole INSERT policy enforcing created_by = auth.uid().

DROP POLICY IF EXISTS transactions_insert_sales_roles
ON public.transactions;

-- Migration: Production Data Fresh Start Reset
-- Target Database: PostgreSQL (Supabase)
-- Date: 2026-09-30
-- Description: Safely clears all operational business data for fresh start,
-- preserving auth users, profiles identity, RLS, COA foundation, and payment accounts.

BEGIN;

-- 1. Operational Transactional & Master Data Reset (CASCADE safe against FKs)
TRUNCATE TABLE public.quotation_items CASCADE;
TRUNCATE TABLE public.quotations CASCADE;

TRUNCATE TABLE public.invoice_items CASCADE;
TRUNCATE TABLE public.invoices CASCADE;

TRUNCATE TABLE public.receivables CASCADE;

TRUNCATE TABLE public.purchase_items CASCADE;
TRUNCATE TABLE public.purchases CASCADE;

TRUNCATE TABLE public.payables CASCADE;

TRUNCATE TABLE public.payment_history CASCADE;

TRUNCATE TABLE public.stock_logs CASCADE;

TRUNCATE TABLE public.journal_lines CASCADE;
TRUNCATE TABLE public.journal_entries CASCADE;

TRUNCATE TABLE public.expenses CASCADE;
TRUNCATE TABLE public.equity_transactions CASCADE;

TRUNCATE TABLE public.transactions CASCADE;

TRUNCATE TABLE public.projects CASCADE;
TRUNCATE TABLE public.products CASCADE;
TRUNCATE TABLE public.customers CASCADE;
TRUNCATE TABLE public.suppliers CASCADE;

-- 2. Preserve Essential Profiles (Owner & Kasir)
-- Clean up any non-system test profiles while preserving Owner and Kasir
DELETE FROM public.profiles 
WHERE id NOT IN (
    '0041f669-01f0-4278-bad1-98244f0f362b'::uuid, -- Owner
    'eb2fd85f-8c7f-4ce7-98ca-960b701bd7de'::uuid  -- Kasir
);

COMMIT;

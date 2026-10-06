-- Migration: Make due_date nullable to support Cash/Belum Lunas and optional due dates
ALTER TABLE public.invoices ALTER COLUMN due_date DROP NOT NULL;

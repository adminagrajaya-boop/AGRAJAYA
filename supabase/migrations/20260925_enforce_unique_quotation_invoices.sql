-- Migration: Enforce database-level unique mapping for Quotation -> Invoice
-- Description: Guarantees at database level that 1 quotation can produce at most 1 invoice.
-- Preserves nullability of quotation_id so non-quotation invoices (e.g. direct/POS credit) remain supported.

CREATE UNIQUE INDEX IF NOT EXISTS idx_invoices_unique_quotation_id 
ON public.invoices (quotation_id) 
WHERE quotation_id IS NOT NULL;

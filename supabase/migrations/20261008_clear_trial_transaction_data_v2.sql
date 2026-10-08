-- Migration: 20261008_clear_trial_transaction_data_v2

BEGIN;

TRUNCATE TABLE
  public.invoice_correction_logs,
  public.payment_history,
  public.receivables,
  public.invoice_items,
  public.invoices,
  public.quotation_items,
  public.quotations,
  public.journal_lines,
  public.journal_entries,
  public.transactions,
  public.payables,
  public.purchases,
  public.expenses,
  public.equity_transactions,
  public.stock_logs
RESTART IDENTITY CASCADE;

COMMIT;

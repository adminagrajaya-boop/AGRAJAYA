const fs = require('fs');
const path = require('path');
const vm = require('vm');

console.log('================================================================');
console.log('AGRA JAYA POS — COMPREHENSIVE AUTOMATED REGRESSION TEST SUITE');
console.log('================================================================');

let passedTests = 0;
let failedTests = 0;

function assert(condition, testName, details = '') {
    if (condition) {
        console.log(`[PASS] ${testName}`);
        passedTests++;
    } else {
        console.error(`[FAIL] ${testName}: ${details}`);
        failedTests++;
    }
}

// 1. READ HTML AND MIGRATION SOURCES
const htmlPath = path.join(__dirname, '..', 'index.html');
const swPath = path.join(__dirname, '..', 'sw.js');
const migrationDir = path.join(__dirname, '..', 'supabase', 'migrations');
const newMigrationPath = path.join(migrationDir, '20261012_secure_journal_and_payable_engine.sql');

const htmlContent = fs.readFileSync(htmlPath, 'utf8');
const swContent = fs.readFileSync(swPath, 'utf8');
const newMigrationSql = fs.readFileSync(newMigrationPath, 'utf8');

// TEST 1: SYNTAX CHECK FOR INDEX.HTML EMBEDDED JAVASCRIPT
try {
    const scriptStart = htmlContent.indexOf('<script>', htmlContent.indexOf('ALPINE.JS APPLICATION LOGIC'));
    const scriptEnd = htmlContent.lastIndexOf('</script>');
    assert(scriptStart > 0 && scriptEnd > scriptStart, 'Script tags located correctly in index.html');

    const scriptCode = htmlContent.substring(scriptStart + 8, scriptEnd);
    new vm.Script(scriptCode, { filename: 'app.js' });
    assert(true, 'JavaScript in index.html parses and compiles without syntax error');
} catch (e) {
    assert(false, 'JavaScript in index.html parses and compiles without syntax error', e.message);
}

// TEST 2: VERSION BUMP CONSISTENCY IN SW.JS AND INDEX.HTML
const htmlVersionMatch = htmlContent.match(/CURRENT_APP_VERSION\s*=\s*'([^']+)'/);
const swVersionMatch = swContent.match(/CACHE_NAME\s*=\s*'agra-jaya-pos-shell-([^']+)'/);

assert(htmlVersionMatch && htmlVersionMatch[1] === 'v5.9', 'index.html is bumped to CURRENT_APP_VERSION v5.9');
assert(swVersionMatch && swVersionMatch[1] === 'v5.9', 'sw.js CACHE_NAME is bumped to v5.9');
assert(htmlVersionMatch && swVersionMatch && htmlVersionMatch[1] === swVersionMatch[1], 'Cache versions between HTML and SW are strictly synchronized');

// TEST 3: NO PLACEHOLDER JOURNAL OR MOCK PAYMENT HISTORY LEFTOVERS
assert(!htmlContent.includes('const journalData = null; const journalError = null;'), 'No placeholder journalData/journalError in index.html');
assert(!htmlContent.includes('const insertedHist = { id: Date.now() };'), 'No mock insertedHist = { id: Date.now() } in index.html');
assert(!htmlContent.includes('const revResult = null; const revErr = null;'), 'No mock revResult/revErr in index.html');
assert(!htmlContent.includes('const rpcErr = null;'), 'No mock rpcErr in index.html');

assert(htmlContent.includes("supabaseClient.rpc('post_journal_entry_secure',"), 'post_journal_entry_secure is called in index.html');
assert(htmlContent.includes("supabaseClient.rpc('void_invoice_atomic',") && htmlContent.includes("supabaseClient.rpc('void_pos_transaction_atomic',"), 'Atomic void RPCs are invoked for document and journal reversals');
assert(htmlContent.includes("supabaseClient.rpc('process_payable_payment_atomic',"), 'process_payable_payment_atomic is called in index.html');

// Check each flow specifically
const posJournalPattern = /p_source_type:\s*'TRANSACTION'/;
assert(posJournalPattern.test(htmlContent), 'POS checkout calls post_journal_entry_secure with source TRANSACTION');

const invoiceJournalPattern = /p_source_type:\s*'INVOICE'/;
assert(invoiceJournalPattern.test(htmlContent), 'Quotation->Invoice conversion calls post_journal_entry_secure with source INVOICE');

const purchaseJournalPattern = /p_source_type:\s*'PURCHASE'/;
assert(purchaseJournalPattern.test(htmlContent), 'Purchase/PO calls post_journal_entry_secure with source PURCHASE');

const expenseJournalPattern = /p_source_type:\s*'EXPENSE'/;
assert(expenseJournalPattern.test(htmlContent), 'Expense flow calls post_journal_entry_secure with source EXPENSE');

const equityJournalPattern = /p_source_type:\s*'EQUITY'/;
assert(equityJournalPattern.test(htmlContent), 'Equity flow calls post_journal_entry_secure with source EQUITY');

// TEST 5: STATE CLEANING ON 0 QUERY RESULTS (NO STALE DATA RETENTION)
const normalizedHtml = htmlContent.replace(/\r\n/g, '\n');
assert(normalizedHtml.includes('if (!Array.isArray(remoteQuotations) || remoteQuotations.length === 0) {\n                            this.penawaranList = [];'), 'Quotations list is explicitly emptied on 0 results');
assert(normalizedHtml.includes('if (!Array.isArray(remoteInvoices) || remoteInvoices.length === 0) {\n                            this.invoiceList = [];'), 'Invoices list is explicitly emptied on 0 results');
assert(normalizedHtml.includes('if (!Array.isArray(remoteReceivables) || remoteReceivables.length === 0) {\n                            this.piutangList = [];'), 'Receivables list is explicitly emptied on 0 results');
assert(normalizedHtml.includes('if (!Array.isArray(remotePurchases) || remotePurchases.length === 0) {\n                            this.pembelianList = [];'), 'Purchases list is explicitly emptied on 0 results');
assert(normalizedHtml.includes('if (!Array.isArray(remotePayables) || remotePayables.length === 0) {\n                            this.hutangList = [];'), 'Payables list is explicitly emptied on 0 results');
assert(normalizedHtml.includes('if (!Array.isArray(remoteTransactions) || remoteTransactions.length === 0) {\n                            this.transactionHistory = [];'), 'Transactions list is explicitly emptied on 0 results');
assert(normalizedHtml.includes('if (!Array.isArray(remotePayments) || remotePayments.length === 0) {\n                            this.paymentHistory = [];'), 'Payment history list is explicitly emptied on 0 results');

// TEST 6: FETCH ERRORS ARE NOT MASKED AS EMPTY SUCCESS
assert(htmlContent.includes('if (qtFetchErr) throw qtFetchErr;'), 'Quotation fetch error throws explicitly');
assert(htmlContent.includes('if (invFetchErr) throw invFetchErr;'), 'Invoice fetch error throws explicitly');
assert(htmlContent.includes('if (recFetchErr) throw recFetchErr;'), 'Receivable fetch error throws explicitly');
assert(htmlContent.includes('if (payFetchErr) throw payFetchErr;'), 'Payment history fetch error throws explicitly');
assert(htmlContent.includes('if (purchFetchErr) throw purchFetchErr;'), 'Purchases fetch error throws explicitly');
assert(htmlContent.includes('if (payableFetchErr) throw payableFetchErr;'), 'Payables fetch error throws explicitly');
assert(htmlContent.includes('if (trxFetchErr) throw trxFetchErr;'), 'Transactions fetch error throws explicitly');

// TEST 7: LOCALSTORAGE DOES NOT RESURRECT TRANSACTIONS BUT PRESERVES PRODUCTS & CONFIGS
assert(htmlContent.includes('agra_fresh_start_20261012'), 'Local storage uses agra_fresh_start_20261012 to clear stale transaction lists');
assert(!htmlContent.includes("localStorage.removeItem('agra_products')") || htmlContent.indexOf("localStorage.removeItem('agra_products')") < htmlContent.indexOf("agra_fresh_start_20261012"), 'Products in localStorage are preserved in fresh start check');

// TEST 8: DATABASE MIGRATION INTEGRITY & SECURITY HARDENING
assert(newMigrationSql.includes('CREATE OR REPLACE FUNCTION public.post_journal_entry_secure'), 'Migration includes post_journal_entry_secure');
assert(newMigrationSql.includes('CREATE OR REPLACE FUNCTION public.reverse_journal_entry_secure'), 'Migration includes reverse_journal_entry_secure');
assert(newMigrationSql.includes('CREATE OR REPLACE FUNCTION public.process_payable_payment_atomic'), 'Migration includes process_payable_payment_atomic');
assert(newMigrationSql.includes('REVOKE EXECUTE ON FUNCTION public.post_journal_entry_secure FROM PUBLIC, anon;'), 'post_journal_entry_secure revoked from anon');
assert(newMigrationSql.includes('GRANT EXECUTE ON FUNCTION public.post_journal_entry_secure TO authenticated;'), 'post_journal_entry_secure granted to authenticated');
assert(newMigrationSql.includes('REVOKE EXECUTE ON FUNCTION public.process_payable_payment_atomic FROM PUBLIC, anon;'), 'process_payable_payment_atomic revoked from anon');
assert(newMigrationSql.includes('GRANT EXECUTE ON FUNCTION public.process_payable_payment_atomic TO authenticated;'), 'process_payable_payment_atomic granted to authenticated');

// Check that internal functions are still NOT granted to authenticated
assert(!newMigrationSql.includes('GRANT EXECUTE ON FUNCTION public.post_journal_entry('), 'Internal post_journal_entry is NOT granted to authenticated or public');
assert(!newMigrationSql.includes('GRANT EXECUTE ON FUNCTION public.reverse_journal_entry('), 'Internal reverse_journal_entry is NOT granted to authenticated or public');

// TEST 9: ATOMIC PAYABLE PAYMENT OVERPAYMENT GUARD & IDEMPOTENCY
assert(newMigrationSql.includes('OVERPAYMENT_BLOCKED: Total pembayaran'), 'process_payable_payment_atomic has strict overpayment guard');
assert(newMigrationSql.includes("payment_type, status, created_by, note\n    ) VALUES (\n        v_purch.id, v_purch.po_no, v_purch.supplier_name, v_date_str, COALESCE(p_payment_method, 'Tunai'),\n        p_payment_account_id, p_amount, 'hutang', 'VALID'"), 'process_payable_payment_atomic inserts real payment_history record with status VALID');
assert(newMigrationSql.includes("code = '2-1110'"), 'process_payable_payment_atomic uses Hutang Usaha (2-1110)');

// TEST 9B: SCHEMA COMPATIBILITY FOR PURCHASES AND PAYABLES
assert(newMigrationSql.includes('v_purch.voided_at IS NOT NULL'), 'purchases void check uses voided_at instead of status');
assert(!newMigrationSql.includes('v_purch.status IN'), 'No invalid v_purch.status references remain');
assert(newMigrationSql.includes('INSERT INTO public.payables (\n            purchase_id, po_no, supplier_name, status, total, paid, remaining\n        )'), 'payables insert leaves due_date to database default behavior');
assert(newMigrationSql.includes("p_source_type IN ('PURCHASE', 'EXPENSE', 'EQUITY') AND v_caller_role NOT IN ('owner', 'admin')"), 'Role restriction for PURCHASE, EXPENSE, EQUITY enforced to owner and admin');

// TEST 10: ATOMIC INVOICE CORRECTION & PAYMENT PROTECTIONS PRESERVED
const correctInvMigration = fs.readFileSync(path.join(migrationDir, '20261008_koreksi_invoice_atomic_fix_v3.sql'), 'utf8');
assert(correctInvMigration.includes('CREATE OR REPLACE FUNCTION public.correct_invoice_atomic'), 'correct_invoice_atomic migration exists and is intact');
assert(htmlContent.includes("supabaseClient.rpc('correct_invoice_atomic'"), 'correct_invoice_atomic is called in index.html');
assert(htmlContent.includes("supabaseClient.rpc('process_payment_atomic'"), 'process_payment_atomic is called in index.html');
assert(htmlContent.includes("supabaseClient.rpc('void_payment_atomic'"), 'void_payment_atomic is called in index.html');

// TEST 11: ATOMIC VOID RPC INTEGRATION & FALLBACK REMOVAL
const atomicMigrationPath = path.join(migrationDir, '20261012_atomic_invoice_and_pos_void.sql');
assert(fs.existsSync(atomicMigrationPath), '20261012_atomic_invoice_and_pos_void.sql exists');
const atomicSql = fs.readFileSync(atomicMigrationPath, 'utf8');

assert(atomicSql.includes('CREATE OR REPLACE FUNCTION public.void_invoice_atomic'), 'Atomic invoice void function is defined in migration');
assert(atomicSql.includes('CREATE OR REPLACE FUNCTION public.void_pos_transaction_atomic'), 'Atomic POS void function is defined in migration');
assert(atomicSql.includes('REVOKE EXECUTE ON FUNCTION public.void_invoice_atomic FROM PUBLIC, anon;'), 'void_invoice_atomic is revoked from anon');
assert(atomicSql.includes('REVOKE EXECUTE ON FUNCTION public.void_pos_transaction_atomic FROM PUBLIC, anon;'), 'void_pos_transaction_atomic is revoked from anon');
assert(atomicSql.includes('GRANT EXECUTE ON FUNCTION public.void_invoice_atomic TO authenticated;'), 'void_invoice_atomic is granted to authenticated');
assert(atomicSql.includes('GRANT EXECUTE ON FUNCTION public.void_pos_transaction_atomic TO authenticated;'), 'void_pos_transaction_atomic is granted to authenticated');
assert(!atomicSql.includes("'VOID_IN'"), 'Stock logs action_type does NOT use VOID_IN');
assert(atomicSql.includes("'VOID'"), 'Stock logs action_type uses standard VOID');

assert(htmlContent.includes("supabaseClient.rpc('void_invoice_atomic'"), 'index.html invokes void_invoice_atomic');
assert(htmlContent.includes("supabaseClient.rpc('void_pos_transaction_atomic'"), 'index.html invokes void_pos_transaction_atomic');
assert(!htmlContent.includes('void_invoice_atomic fallback:'), 'index.html has no fallback catch block for void_invoice_atomic');
assert(!htmlContent.includes('void_pos_transaction_atomic fallback:'), 'index.html has no fallback catch block for void_pos_transaction_atomic');
assert(!htmlContent.includes('if (!atomicExecuted && supabaseClient && this.isAuthenticated)'), 'index.html has no non-atomic fallback in promptCancelInvoice');
assert(!htmlContent.includes('if (!atomicExecuted)'), 'index.html has no non-atomic fallback in promptVoidTransaction');

console.log('----------------------------------------------------------------');
console.log(`TOTAL TESTS: ${passedTests + failedTests}`);
console.log(`PASSED: ${passedTests}`);
console.log(`FAILED: ${failedTests}`);
console.log('----------------------------------------------------------------');

if (failedTests > 0) {
    process.exit(1);
} else {
    console.log('ALL REGRESSION TESTS PASSED! System is reliable and ready.');
    process.exit(0);
}

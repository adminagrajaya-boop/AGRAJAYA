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

// TEST 4: ALL TRANSACTIONS EXECUTE VIA ATOMIC SERVER-SIDE RPCS (NO SEPARATE CLIENT JOURNAL POSTING)
assert(!htmlContent.includes("supabaseClient.rpc('post_journal_entry_secure',"), 'post_journal_entry_secure is eliminated from frontend in favor of single-transaction RPCs');
assert(htmlContent.includes("supabaseClient.rpc('create_pos_transaction_atomic',"), 'POS checkout calls create_pos_transaction_atomic');
assert(htmlContent.includes("supabaseClient.rpc('convert_quotation_to_invoice_atomic',"), 'Quotation conversion calls convert_quotation_to_invoice_atomic');
assert(htmlContent.includes("supabaseClient.rpc('create_purchase_atomic',"), 'Purchase/PO calls create_purchase_atomic');
assert(htmlContent.includes("supabaseClient.rpc('create_expense_atomic',"), 'Expense flow calls create_expense_atomic');
assert(htmlContent.includes("supabaseClient.rpc('create_equity_transaction_atomic',"), 'Equity flow calls create_equity_transaction_atomic');
assert(htmlContent.includes("supabaseClient.rpc('void_invoice_atomic',") && htmlContent.includes("supabaseClient.rpc('void_pos_transaction_atomic',"), 'Atomic void RPCs are invoked for document and journal reversals');
assert(htmlContent.includes("supabaseClient.rpc('process_payable_payment_atomic',"), 'process_payable_payment_atomic is called in index.html');

// Check that new atomic migration exists and defines all 5 atomic engines
// Check that revised atomic migration v3 exists and defines all atomic engines
const v3MigrationPath = path.join(migrationDir, '20261012_atomic_business_transactions_engine_v3.sql');
assert(fs.existsSync(v3MigrationPath), 'Atomic business transactions engine migration v3 file exists');
const v3Sql = fs.readFileSync(v3MigrationPath, 'utf8');

// Verify anti-overload drops
assert(v3Sql.includes('DROP FUNCTION IF EXISTS public.create_purchase_atomic'), 'Migration v3 drops previous create_purchase_atomic signatures');
assert(v3Sql.includes('DROP FUNCTION IF EXISTS public.create_pos_transaction_atomic'), 'Migration v3 drops previous create_pos_transaction_atomic signatures');

assert(v3Sql.includes('CREATE OR REPLACE FUNCTION public.create_pos_transaction_atomic'), 'Migration v3 defines create_pos_transaction_atomic');
assert(v3Sql.includes('CREATE OR REPLACE FUNCTION public.create_purchase_atomic'), 'Migration v3 defines create_purchase_atomic');
assert(v3Sql.includes('CREATE OR REPLACE FUNCTION public.create_expense_atomic'), 'Migration v3 defines create_expense_atomic');
assert(v3Sql.includes('CREATE OR REPLACE FUNCTION public.create_equity_transaction_atomic'), 'Migration v3 defines create_equity_transaction_atomic');
assert(v3Sql.includes('CREATE OR REPLACE FUNCTION public.convert_quotation_to_invoice_atomic'), 'Migration v3 defines convert_quotation_to_invoice_atomic');
assert(v3Sql.includes('CREATE OR REPLACE FUNCTION public.void_pos_transaction_atomic'), 'Migration v3 defines enhanced void_pos_transaction_atomic');

// Verify strict POS persistence: transactions, invoices, invoice_items, receivables, stock_logs, journal
assert(v3Sql.includes('INSERT INTO public.transactions'), 'Migration v3 creates transactions record in POS');
assert(v3Sql.includes('INSERT INTO public.invoices'), 'Migration v3 creates invoices record in POS');
assert(v3Sql.includes('INSERT INTO public.invoice_items'), 'Migration v3 creates invoice_items record in POS');
assert(v3Sql.includes('INSERT INTO public.receivables'), 'Migration v3 creates receivables record in POS if credit has remaining balance');
assert(v3Sql.includes('INSERT INTO public.stock_logs'), 'Migration v3 logs stock changes with action_type SALE');
assert(v3Sql.includes("'transaction_id', v_trx_id"), 'Migration v3 returns transaction_id');
assert(v3Sql.includes("'invoice_id', v_inv_id"), 'Migration v3 returns invoice_id');
assert(v3Sql.includes("'receivable_id', v_rec_id"), 'Migration v3 returns receivable_id');

// Verify invoice_items schema enhancements and type persistence
assert(v3Sql.includes('ADD COLUMN IF NOT EXISTS item_type VARCHAR(20) DEFAULT'), 'Migration v3 adds item_type to invoice_items');
assert(v3Sql.includes('ADD COLUMN IF NOT EXISTS product_name VARCHAR(255) NULL'), 'Migration v3 adds product_name to invoice_items');
assert(v3Sql.includes('v_item_type') && v3Sql.includes('v_item_name'), 'POS and Quotation conversion persist item_type and product_name');

// Verify VOID POS Payment Guard
assert(v3Sql.includes('CANNOT_VOID_PAID_TRANSACTION: Transaksi % memiliki % pembayaran piutang aktif'), 'void_pos_transaction_atomic strictly blocks voiding transactions with valid payments');

// Verify Server-side Nominal Re-calculation & Validation
assert(v3Sql.includes('TOTAL_MISMATCH: Total transaksi dari client'), 'POS validates client total against server calculation');
assert(v3Sql.includes('TOTAL_MISMATCH: Total pembelian dari client'), 'Purchase validates client total against server calculation');
assert(v3Sql.includes('TOTAL_MISMATCH: Nilai penawaran asli'), 'Quotation conversion validates quotation total against server calculation');
assert(v3Sql.includes('INSUFFICIENT_STOCK: Stok produk'), 'POS rejects checkout if stock insufficient');

// Verify contract returns for PO and Quotation
assert(v3Sql.includes("'payable_id', v_payable_id"), 'create_purchase_atomic returns payable_id');
assert(v3Sql.includes("'receivable_id', v_rec_id") && v3Sql.includes("'invoice_id', v_inv_id"), 'convert_quotation_to_invoice_atomic returns invoice_id and receivable_id');

// Verify Security Grants
assert(v3Sql.includes('REVOKE EXECUTE ON FUNCTION public.create_pos_transaction_atomic FROM PUBLIC, anon;'), 'create_pos_transaction_atomic revoked from anon');
assert(v3Sql.includes('REVOKE EXECUTE ON FUNCTION public.create_purchase_atomic FROM PUBLIC, anon;'), 'create_purchase_atomic revoked from anon');
assert(v3Sql.includes('REVOKE EXECUTE ON FUNCTION public.create_expense_atomic FROM PUBLIC, anon;'), 'create_expense_atomic revoked from anon');
assert(v3Sql.includes('REVOKE EXECUTE ON FUNCTION public.create_equity_transaction_atomic FROM PUBLIC, anon;'), 'create_equity_transaction_atomic revoked from anon');
assert(v3Sql.includes('REVOKE EXECUTE ON FUNCTION public.convert_quotation_to_invoice_atomic FROM PUBLIC, anon;'), 'convert_quotation_to_invoice_atomic revoked from anon');
assert(v3Sql.includes('REVOKE EXECUTE ON FUNCTION public.void_pos_transaction_atomic FROM PUBLIC, anon;'), 'void_pos_transaction_atomic revoked from anon');

// TEST 4B: FRONTEND STRICT PERSISTENCE - NO FAKE DATE.NOW() DATABASE IDS
assert(!htmlContent.includes('const insertedTrxId = atomicTrx.transaction_id || Date.now()'), 'Frontend does not fallback insertedTrxId to Date.now()');
assert(!htmlContent.includes('id: atomicTrx.invoice_id || Date.now()'), 'Frontend does not fallback invoice_id to Date.now()');
assert(!htmlContent.includes('id: Date.now(),\n                            invNo: atomicTrx.inv_no'), 'Frontend does not use Date.now() for receivable id');
assert(!htmlContent.includes('id: insertedPurchaseId || Date.now()'), 'Frontend does not fallback purchase id to Date.now()');
assert(!htmlContent.includes('id: insertedInvId || Date.now()'), 'Frontend does not fallback quotation conversion invoice_id to Date.now()');
assert(htmlContent.includes('const itemType = item.item_type || item.type'), 'Frontend maps item_type from invoice_items');

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

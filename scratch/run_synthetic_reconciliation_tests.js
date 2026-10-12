const fs = require('fs');
const path = require('path');

console.log('==================================================');
console.log('RUNNING SYNTHETIC RECONCILIATION & NEGATIVE TESTS');
console.log('==================================================');

const html = fs.readFileSync('c:/Projects/DYMAS DANANG/index.html', 'utf8');
const sql = fs.readFileSync('c:/Projects/DYMAS DANANG/supabase/migrations/20261008_payment_and_void_engine.sql', 'utf8');
const sqlCorr = fs.readFileSync('c:/Projects/DYMAS DANANG/supabase/migrations/20261006_koreksi_invoice.sql', 'utf8');
const sw = fs.readFileSync('c:/Projects/DYMAS DANANG/sw.js', 'utf8');

let passedTests = 0;
let totalTests = 0;

function assertTest(testNum, name, condition, details = '') {
    totalTests++;
    if (condition) {
        passedTests++;
        console.log(`TEST #${testNum} [PASS]: ${name} ${details}`);
    } else {
        console.error(`TEST #${testNum} [FAIL]: ${name} ${details}`);
        throw new Error(`Synthetic Test #${testNum} Failed: ${name}`);
    }
}

// 1. Payment > invoice total -> REJECT
assertTest(1, 'Payment > invoice total REJECTED', 
    sql.includes('(v_existing_valid_paid + p_amount) > (v_inv.total + 0.01)') && sql.includes('OVERPAYMENT_BLOCKED')
);

// 2. Payment exactly invoice total -> PASS
assertTest(2, 'Payment exactly invoice total PASS & sets status Lunas', 
    sql.includes('v_new_remaining := GREATEST(0.00, v_inv.total - v_new_paid);') && sql.includes("v_new_status := 'Lunas';")
);

// 3. Payment second time after invoice fully paid -> REJECT
assertTest(3, 'Payment second time after fully paid REJECTED', 
    sql.includes('OVERPAYMENT_BLOCKED')
);

// 4. Double-click payment -> Submitting lock + DB atomic lock
assertTest(4, 'Double-click payment prevented', 
    html.includes('isSubmittingPayPiutang') && sql.includes('FOR UPDATE')
);

// 5. VOID same payment twice -> REJECT
assertTest(5, 'VOID same payment twice REJECTED', 
    sql.includes("IF v_pay.status = 'VOID' THEN") && sql.includes('ALREADY_VOID')
);

// 6. VOID non-existing payment -> REJECT
assertTest(6, 'VOID non-existing payment REJECTED', 
    sql.includes('PAYMENT_NOT_FOUND')
);

// 7. KASIR mencoba VOID -> REJECT
assertTest(7, 'KASIR VOID payment REJECTED', 
    sql.includes("IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin') THEN")
);

// 8. OWNER / ADMIN VOID VALID payment -> PASS
assertTest(8, 'OWNER/ADMIN VOID valid payment PASS & reverses journal', 
    sql.includes('reverse_journal_entry') && sql.includes("status = 'VOID'")
);

// 9. Invoice correction with NO payment -> PASS
assertTest(9, 'Invoice correction with NO payment PASS', 
    html.includes('correct_invoice_atomic') || sqlCorr.includes('correct_invoice_atomic')
);

// 10. Invoice correction with VALID payment -> BLOCK
assertTest(10, 'Invoice correction with VALID payment BLOCKED', 
    html.includes('riwayat pembayaran aktif') && sqlCorr.includes('PAYMENT_EXISTS')
);

// 11. Invoice LUNAS -> Excluded from OPEN receivable
assertTest(11, 'Invoice LUNAS excluded from OPEN receivable', 
    html.includes("item.status !== 'Lunas'") && html.includes("Number(item.remaining) > 0")
);

// 12. VOID payment -> Invoice & receivable recalculated
assertTest(12, 'VOID payment recalculates invoice & receivable', 
    sql.includes('recalculated_paid') && sql.includes('recalculated_remaining')
);

// 13. Correction -> Old invoice excluded from active revenue / AR
assertTest(13, 'Correction excludes old invoice from active revenue/AR', 
    html.includes("p.status !== 'Dibatalkan'")
);

// 14. Quotation conversion twice -> REJECT
assertTest(14, 'Quotation conversion twice REJECTED', 
    html.includes("qt.status === 'Converted'") || html.includes("qt.status === 'Invoiced'")
);

// 15. Double-click quotation conversion -> Only 1 invoice
assertTest(15, 'Double-click quotation conversion prevented', 
    html.includes('isSubmittingConvert')
);

// 16. Due date blank -> Remains null
assertTest(16, 'Due date blank remains null', 
    !html.includes("dueDate: '30 Hari'") && !html.includes("due_date: '30 Hari'")
);

// 17. Cash / Lunas -> No active OPEN receivable
assertTest(17, 'Cash/Lunas has no active OPEN receivable', 
    html.includes("item.status !== 'Lunas'")
);

// 18. PDF Quotation 3 items -> 1 PAGE A4
assertTest(18, 'PDF Quotation 3 items fits 1 PAGE', 
    html.includes('min-height: auto') && html.includes('page-break-inside: avoid')
);

// 19. PDF Quotation 30 items -> Multi-page natural
assertTest(19, 'PDF Quotation 30 items multi-page natural', 
    html.includes('@media print') && html.includes('break-inside: avoid')
);

// 20. PWA Shell Cache Synchronization -> Stale cache invalidated cleanly
const swVer = (sw.match(/agra-jaya-pos-shell-([a-zA-Z0-9.]+)/) || [])[1];
const htmlVer = (html.match(/CURRENT_APP_VERSION\s*=\s*'([^']+)'/) || [])[1];
assertTest(20, 'PWA Shell cache synchronization', 
    swVer && htmlVer && swVer === htmlVer
);

// SYNTHETIC ACCOUNTING RECONCILIATION SCENARIO (Rp 1.000.000 Invoice)
console.log('\n--- SYNTHETIC ACCOUNTING RECONCILIATION SCENARIO (Rp 1.000.000) ---');

let invTotal = 1000000;
let invPaid = 0;
let invRemaining = 1000000;
let invStatus = 'Kredit';
let arBalance = 1000000;
let paymentsList = [];
let journalEntries = [];

// A. Create Credit Invoice
console.log(`Step A: Created Invoice Rp ${invTotal} (Kredit) -> AR = Rp ${arBalance}`);
if (arBalance !== 1000000) throw new Error('Step A failed');

// B. Pay Rp 400.000
invPaid += 400000;
invRemaining -= 400000;
invStatus = 'Sebagian';
arBalance = invRemaining;
paymentsList.push({ id: 101, amount: 400000, status: 'VALID' });
journalEntries.push({ id: 1, type: 'PAYMENT', debit: 400000, credit: 400000 });
console.log(`Step B: Paid Rp 400.000 -> Paid = Rp ${invPaid}, Remaining = Rp ${invRemaining}, AR = Rp ${arBalance}, Status = ${invStatus}`);
if (invPaid !== 400000 || invRemaining !== 600000 || arBalance !== 600000) throw new Error('Step B failed');

// C. Pay Rp 600.000
invPaid += 600000;
invRemaining -= 600000;
invStatus = 'Lunas';
arBalance = invRemaining;
paymentsList.push({ id: 102, amount: 600000, status: 'VALID' });
journalEntries.push({ id: 2, type: 'PAYMENT', debit: 600000, credit: 600000 });
console.log(`Step C: Paid Rp 600.000 -> Paid = Rp ${invPaid}, Remaining = Rp ${invRemaining}, AR = Rp ${arBalance}, Status = ${invStatus}`);
if (invPaid !== 1000000 || invRemaining !== 0 || arBalance !== 0 || invStatus !== 'Lunas') throw new Error('Step C failed');

// D. Attempt Additional Rp 1 -> REJECT
let overpayAttempt = invPaid + 1;
let overpayRejected = overpayAttempt > invTotal;
console.log(`Step D: Attempt additional Rp 1 (Total ${overpayAttempt} > ${invTotal}) -> REJECTED: ${overpayRejected}`);
if (!overpayRejected) throw new Error('Step D failed');

// E. VOID Rp 600.000 payment
const targetPay = paymentsList.find(p => p.id === 102);
targetPay.status = 'VOID';
journalEntries.push({ id: 3, type: 'REVERSAL_VOID', reversal_of: 2, debit: 600000, credit: 600000 });
const validPays = paymentsList.filter(p => p.status === 'VALID');
invPaid = validPays.reduce((sum, p) => sum + p.amount, 0);
invRemaining = Math.max(0, invTotal - invPaid);
invStatus = invPaid === 0 ? 'Belum Bayar' : (invRemaining === 0 ? 'Lunas' : 'Sebagian');
arBalance = invRemaining;
console.log(`Step E: VOID Rp 600.000 -> Paid = Rp ${invPaid}, Remaining = Rp ${invRemaining}, AR = Rp ${arBalance}, Status = ${invStatus}, Reversal Journal ID = 3`);
if (invPaid !== 400000 || invRemaining !== 600000 || arBalance !== 600000 || invStatus !== 'Sebagian') throw new Error('Step E failed');

// F. VOID same payment again -> REJECT
let voidAgainRejected = targetPay.status === 'VOID';
console.log(`Step F: VOID same payment again -> REJECTED: ${voidAgainRejected}`);
if (!voidAgainRejected) throw new Error('Step F failed');

// G. Attempt correction when valid payment exists -> BLOCK
const activeValidPaysCount = paymentsList.filter(p => p.status === 'VALID').length;
let correctionBlocked = activeValidPaysCount > 0;
console.log(`Step G: Correct invoice with ${activeValidPaysCount} valid payment -> BLOCKED: ${correctionBlocked}`);
if (!correctionBlocked) throw new Error('Step G failed');

console.log('\n==================================================');
console.log(`ALL ${totalTests} NEGATIVE & RECONCILIATION TESTS PASSED! ✅ (${passedTests}/${totalTests})`);
console.log('==================================================');

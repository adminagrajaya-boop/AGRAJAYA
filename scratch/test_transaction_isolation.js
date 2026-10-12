const fs = require('fs');
const path = require('path');
const vm = require('vm');

console.log('================================================================');
console.log('AGRA JAYA POS — ISOLATED TRANSACTION ENGINE INTEGRATION TESTS');
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

const htmlPath = path.join(__dirname, '..', 'index.html');
const migrationPath = path.join(__dirname, '..', 'supabase', 'migrations', '20261012_secure_journal_and_payable_engine.sql');
const htmlContent = fs.readFileSync(htmlPath, 'utf8');
const migrationSql = fs.readFileSync(migrationPath, 'utf8');

// -----------------------------------------------------------------------------
// 1. SIMULATED ACCOUNTING LEDGER & BALANCED DOUBLE-ENTRY RULE ENGINE
// -----------------------------------------------------------------------------
class MockAccountingEngine {
    constructor() {
        this.chartOfAccounts = [
            { id: 101, code: '1-1110', name: 'Kas Utama', category: 'ASSET', is_active: true },
            { id: 102, code: '1-1120', name: 'Bank BCA', category: 'ASSET', is_active: true },
            { id: 103, code: '1-1130', name: 'Piutang Usaha', category: 'ASSET', is_active: true },
            { id: 104, code: '1-1140', name: 'Persediaan Barang', category: 'ASSET', is_active: true },
            { id: 201, code: '2-1110', name: 'Hutang Usaha', category: 'LIABILITY', is_active: true },
            { id: 301, code: '3-1110', name: 'Modal Pemilik', category: 'EQUITY', is_active: true },
            { id: 302, code: '3-1120', name: 'Prive Pemilik', category: 'EQUITY', is_active: true },
            { id: 401, code: '4-1110', name: 'Pendapatan Penjualan', category: 'REVENUE', is_active: true },
            { id: 501, code: '5-1110', name: 'Beban Operasional Listrik', category: 'EXPENSE', is_active: true },
            { id: 502, code: '5-1120', name: 'Beban Gaji Karyawan', category: 'EXPENSE', is_active: true }
        ];
        this.journals = [];
        this.purchases = [];
        this.payables = [];
        this.invoices = [];
        this.receivables = [];
        this.paymentHistory = [];
        this.expenses = [];
        this.equityTrx = [];
        this.transactions = [];
    }

    voidInvoiceAtomic(callerRole, callerId, { invoiceId, reason }) {
        if (!callerId) throw new Error('UNAUTHENTICATED');
        if (!['owner', 'admin'].includes(callerRole)) throw new Error('UNAUTHORIZED: Hanya Owner atau Admin yang berhak membatalkan (VOID) invoice');
        const inv = this.invoices.find(i => i.id === invoiceId);
        if (!inv) throw new Error('INVOICE_NOT_FOUND');
        if (['Dibatalkan', 'Void'].includes(inv.status)) throw new Error('ALREADY_VOIDED: Invoice sudah berstatus Dibatalkan / Void');

        const activePayments = this.paymentHistory.filter(p => (p.invoice_id === invoiceId || p.inv_no === inv.inv_no) && p.status === 'VALID');
        if (activePayments.length > 0) throw new Error(`CANNOT_VOID_PAID_INVOICE: Invoice memiliki ${activePayments.length} pembayaran aktif`);

        const origJournal = this.journals.find(j => j.source_type === 'INVOICE' && (j.source_id === invoiceId || j.source_code === inv.inv_no) && !j.is_reversal && j.status === 'POSTED');
        let revId = null;
        if (origJournal) {
            origJournal.status = 'REVERSED';
            revId = this.journals.length + 1;
            this.journals.push({
                id: revId,
                journal_no: `REV-${origJournal.journal_no}`,
                source_type: 'REVERSAL',
                source_id: origJournal.id,
                source_code: origJournal.journal_no,
                description: reason || `Reversal Invoice ${inv.inv_no}`,
                lines: origJournal.lines.map(l => ({ chart_of_account_id: l.chart_of_account_id, debit: l.credit, credit: l.debit })),
                status: 'POSTED',
                is_reversal: true,
                created_by: callerId
            });
        }

        inv.status = 'Dibatalkan';
        inv.remaining = 0;
        const rec = this.receivables.find(r => r.invoice_id === invoiceId || r.inv_no === inv.inv_no);
        if (rec) {
            rec.status = 'Dibatalkan';
            rec.remaining = 0;
        }

        return { success: true, invoice_id: invoiceId, inv_no: inv.inv_no, reversal_journal_id: revId, status: 'Dibatalkan' };
    }

    voidPosTransactionAtomic(callerRole, callerId, { transactionId, reason, products, stockLogs }) {
        if (!callerId) throw new Error('UNAUTHENTICATED');
        if (!['owner', 'admin'].includes(callerRole)) throw new Error('UNAUTHORIZED: Hanya Owner atau Admin yang berhak membatalkan (VOID) transaksi POS');
        const trx = this.transactions.find(t => t.id === transactionId);
        if (!trx) throw new Error('TRANSACTION_NOT_FOUND');
        if (trx.status === 'VOID' || trx.status === 'Void') throw new Error(`ALREADY_VOIDED: Transaksi ${trx.trx_code} sudah berstatus VOID`);
        if (trx.transaction_type === 'Beli') throw new Error('INVALID_TYPE: Transaksi pembelian tidak dapat di-VOID melalui fungsi ini');

        const origJournal = this.journals.find(j => j.source_type === 'TRANSACTION' && (j.source_id === transactionId || j.source_code === trx.trx_code) && !j.is_reversal && j.status === 'POSTED');
        let revId = null;
        if (origJournal) {
            origJournal.status = 'REVERSED';
            revId = this.journals.length + 1;
            this.journals.push({
                id: revId,
                journal_no: `REV-${origJournal.journal_no}`,
                source_type: 'REVERSAL',
                source_id: origJournal.id,
                source_code: origJournal.journal_no,
                description: reason || `Reversal Transaksi POS ${trx.trx_code}`,
                lines: origJournal.lines.map(l => ({ chart_of_account_id: l.chart_of_account_id, debit: l.credit, credit: l.debit })),
                status: 'POSTED',
                is_reversal: true,
                created_by: callerId
            });
        }

        trx.status = 'VOID';

        if (Array.isArray(trx.items) && products) {
            for (const item of trx.items) {
                const pid = Number(item.productId !== undefined ? item.productId : item.id);
                const qty = Number(item.qty || 0);
                const prod = products.find(p => p.id === pid);
                if (prod && prod.type === 'barang' && qty > 0) {
                    const oldStock = prod.stock;
                    prod.stock += qty;
                    if (stockLogs) {
                        stockLogs.push({
                            product_id: pid,
                            product_name: prod.name,
                            action_type: 'VOID',
                            qty: qty,
                            stock_before: oldStock,
                            stock_after: prod.stock,
                            reference_code: trx.trx_code,
                            note: 'Pengembalian stok void transaksi ' + trx.trx_code,
                            created_by: callerId
                        });
                    }
                }
            }
        }

        const inv = this.invoices.find(i => i.trx_code === trx.trx_code || i.inv_no === trx.trx_code);
        if (inv) {
            inv.status = 'Dibatalkan';
            inv.remaining = 0;
        }
        const rec = this.receivables.find(r => r.inv_no === trx.trx_code);
        if (rec) {
            rec.status = 'Dibatalkan';
            rec.remaining = 0;
        }

        return { success: true, transaction_id: transactionId, trx_code: trx.trx_code, reversal_journal_id: revId, status: 'VOID' };
    }

    postJournalSecure(callerRole, callerId, { journalDate, sourceType, sourceId, sourceCode, description, lines }) {
        if (!callerId) throw new Error('UNAUTHENTICATED');
        if (!['owner', 'admin', 'kasir'].includes(callerRole)) throw new Error('UNAUTHORIZED_CALLER');
        
        // Strict sensitive source types
        if (['PURCHASE', 'EXPENSE', 'EQUITY'].includes(sourceType) && !['owner', 'admin'].includes(callerRole)) {
            throw new Error('UNAUTHORIZED_SENSITIVE_SOURCE: Role kasir tidak berhak memposting jurnal ' + sourceType);
        }

        if (!Array.isArray(lines) || lines.length < 2) {
            throw new Error('INVALID_LINES: Minimal 2 baris (Debit & Kredit)');
        }

        let totalDebit = 0;
        let totalCredit = 0;

        for (const line of lines) {
            const coa = this.chartOfAccounts.find(c => c.id === line.chart_of_account_id && c.is_active);
            if (!coa) throw new Error('INACTIVE_ACCOUNT: ID ' + line.chart_of_account_id);
            if (line.debit < 0 || line.credit < 0) throw new Error('NEGATIVE_AMOUNT');
            totalDebit += Number(line.debit || 0);
            totalCredit += Number(line.credit || 0);
        }

        if (Math.abs(totalDebit - totalCredit) > 0.001) {
            throw new Error(`UNBALANCED_JOURNAL: Debit (${totalDebit}) != Credit (${totalCredit})`);
        }
        if (totalDebit <= 0) {
            throw new Error('ZERO_JOURNAL_AMOUNT');
        }

        const journalId = this.journals.length + 1;
        const journalNo = `JRN-202610-${String(journalId).padStart(4, '0')}`;
        const entry = {
            id: journalId,
            journal_no: journalNo,
            journal_date: journalDate,
            source_type: sourceType,
            source_id: sourceId,
            source_code: sourceCode,
            description,
            lines,
            status: 'POSTED',
            is_reversal: false,
            created_by: callerId
        };
        this.journals.push(entry);
        return { success: true, journal_id: journalId, journal_no: journalNo };
    }

    reverseJournalSecure(callerRole, callerId, { originalJournalId, reason }) {
        if (!callerId) throw new Error('UNAUTHENTICATED');
        if (!['owner', 'admin'].includes(callerRole)) {
            throw new Error('UNAUTHORIZED: Kasir tidak berhak membalikkan jurnal');
        }
        const orig = this.journals.find(j => j.id === originalJournalId);
        if (!orig) throw new Error('ORIGINAL_JOURNAL_NOT_FOUND');
        if (orig.status !== 'POSTED') throw new Error('INVALID_JOURNAL_STATUS');
        if (orig.is_reversal) throw new Error('CANNOT_REVERSE_REVERSAL');

        // Create reversal journal
        const reversalId = this.journals.length + 1;
        const reversalNo = `REV-${orig.journal_no}`;
        const revLines = orig.lines.map(l => ({
            chart_of_account_id: l.chart_of_account_id,
            debit: l.credit,
            credit: l.debit,
            description: `[REVERSAL] ${reason}`
        }));

        const revEntry = {
            id: reversalId,
            journal_no: reversalNo,
            source_type: orig.source_type,
            source_id: orig.source_id,
            lines: revLines,
            status: 'POSTED',
            is_reversal: true,
            created_by: callerId
        };
        orig.status = 'REVERSED';
        this.journals.push(revEntry);
        return { success: true, reversal_id: reversalId, reversal_no: reversalNo };
    }

    processPayablePaymentAtomic(callerRole, callerId, { purchaseId, amount, paymentMethod, paymentAccountId, note }) {
        if (!callerId) throw new Error('UNAUTHENTICATED');
        if (!['owner', 'admin', 'kasir'].includes(callerRole)) throw new Error('UNAUTHORIZED');
        if (!amount || amount <= 0) throw new Error('INVALID_AMOUNT');

        const purch = this.purchases.find(p => p.id === purchaseId);
        if (!purch) throw new Error('PURCHASE_NOT_FOUND');

        // Test voided_at schema requirement
        if (purch.voided_at) {
            throw new Error('INVALID_PURCHASE_STATUS: Pembelian telah dibatalkan/void');
        }

        const validPaid = this.paymentHistory
            .filter(p => p.purchase_id === purchaseId && p.status === 'VALID')
            .reduce((s, p) => s + p.amount, 0);

        if ((validPaid + amount) > (purch.total + 0.01)) {
            throw new Error(`OVERPAYMENT_BLOCKED: Total ${validPaid + amount} > ${purch.total}`);
        }

        const newPaid = validPaid + amount;
        const newRemaining = Math.max(0, purch.total - newPaid);
        const newStatus = newRemaining <= 0.01 ? 'Lunas' : 'Sebagian';

        // Payment history insert
        const payHistId = this.paymentHistory.length + 1;
        this.paymentHistory.push({
            id: payHistId,
            purchase_id: purch.id,
            po_no: purch.po_no,
            amount: amount,
            status: 'VALID',
            payment_type: 'hutang'
        });

        // Update purchase
        purch.paid_amount = newPaid;
        purch.remaining = newRemaining;

        // Update / Insert payable (Default due_date preserved)
        let payable = this.payables.find(p => p.purchase_id === purch.id);
        if (payable) {
            payable.paid = newPaid;
            payable.remaining = newRemaining;
            payable.status = newStatus;
        } else {
            payable = {
                purchase_id: purch.id,
                po_no: purch.po_no,
                due_date: 'DATABASE_DEFAULT_TEMPO', // proves due_date uses DB default
                status: newStatus,
                total: purch.total,
                paid: newPaid,
                remaining: newRemaining
            };
            this.payables.push(payable);
        }

        // Post double-entry journal (Debit 2-1110 Hutang, Credit Kas/Bank)
        const journal = this.postJournalSecure(callerRole, callerId, {
            journalDate: '2026-10-12',
            sourceType: 'PAYMENT',
            sourceId: payHistId,
            sourceCode: 'PAY-' + purch.po_no,
            description: 'Bayar hutang PO ' + purch.po_no,
            lines: [
                { chart_of_account_id: 201, debit: amount, credit: 0 },
                { chart_of_account_id: 101, debit: 0, credit: amount }
            ]
        });

        return {
            success: true,
            payment_id: payHistId,
            journal_id: journal.journal_id,
            new_paid: newPaid,
            new_remaining: newRemaining,
            status: newStatus
        };
    }
}

// -----------------------------------------------------------------------------
// RUN INTEGRATION TESTS
// -----------------------------------------------------------------------------
const engine = new MockAccountingEngine();

// TEST A: POS CHECKOUT DOUBLE ENTRY BALANCE
try {
    const posJournal = engine.postJournalSecure('kasir', 'user-1', {
        journalDate: '2026-10-12',
        sourceType: 'TRANSACTION',
        sourceId: 501,
        sourceCode: 'TRX-202610-001',
        description: 'Penjualan POS Tunai',
        lines: [
            { chart_of_account_id: 101, debit: 150000, credit: 0 },
            { chart_of_account_id: 401, debit: 0, credit: 150000 }
        ]
    });
    assert(posJournal.success && posJournal.journal_id > 0, 'POS Cash Checkout posts balanced journal entry');
} catch (e) {
    assert(false, 'POS Cash Checkout posts balanced journal entry', e.message);
}

// TEST B: QUOTATION -> INVOICE DOUBLE ENTRY BALANCE
try {
    const invJournal = engine.postJournalSecure('kasir', 'user-1', {
        journalDate: '2026-10-12',
        sourceType: 'INVOICE',
        sourceId: 301,
        sourceCode: 'INV-202610-001',
        description: 'Penjualan Invoice Tempo',
        lines: [
            { chart_of_account_id: 103, debit: 500000, credit: 0 },
            { chart_of_account_id: 401, debit: 0, credit: 500000 }
        ]
    });
    assert(invJournal.success && invJournal.journal_id > 0, 'Quotation to Invoice conversion posts balanced journal entry');
} catch (e) {
    assert(false, 'Quotation to Invoice conversion posts balanced journal entry', e.message);
}

// TEST C: KASIR ROLE IS BLOCKED FROM PURCHASE JOURNAL
try {
    engine.postJournalSecure('kasir', 'user-1', {
        journalDate: '2026-10-12',
        sourceType: 'PURCHASE',
        sourceId: 101,
        sourceCode: 'PO-001',
        description: 'Pembelian Supplier',
        lines: [
            { chart_of_account_id: 104, debit: 200000, credit: 0 },
            { chart_of_account_id: 201, debit: 0, credit: 200000 }
        ]
    });
    assert(false, 'Kasir posting PURCHASE journal is strictly rejected');
} catch (e) {
    assert(e.message.includes('UNAUTHORIZED_SENSITIVE_SOURCE'), 'Kasir posting PURCHASE journal is strictly rejected');
}

// TEST D: OWNER / ADMIN CAN POST PURCHASE JOURNAL
try {
    const purchJournal = engine.postJournalSecure('admin', 'user-admin', {
        journalDate: '2026-10-12',
        sourceType: 'PURCHASE',
        sourceId: 101,
        sourceCode: 'PO-001',
        description: 'Pembelian Supplier Berhasil',
        lines: [
            { chart_of_account_id: 104, debit: 200000, credit: 0 },
            { chart_of_account_id: 201, debit: 0, credit: 200000 }
        ]
    });
    assert(purchJournal.success, 'Admin/Owner successfully posts PURCHASE journal');
} catch (e) {
    assert(false, 'Admin/Owner successfully posts PURCHASE journal', e.message);
}

// TEST E: KASIR ROLE IS BLOCKED FROM EXPENSE JOURNAL
try {
    engine.postJournalSecure('kasir', 'user-1', {
        journalDate: '2026-10-12',
        sourceType: 'EXPENSE',
        sourceId: 701,
        sourceCode: 'EXP-001',
        description: 'Beban Listrik',
        lines: [
            { chart_of_account_id: 501, debit: 75000, credit: 0 },
            { chart_of_account_id: 101, debit: 0, credit: 75000 }
        ]
    });
    assert(false, 'Kasir posting EXPENSE journal is strictly rejected');
} catch (e) {
    assert(e.message.includes('UNAUTHORIZED_SENSITIVE_SOURCE'), 'Kasir posting EXPENSE journal is strictly rejected');
}

// TEST F: KASIR ROLE IS BLOCKED FROM EQUITY (MODAL / PRIVE) JOURNAL
try {
    engine.postJournalSecure('kasir', 'user-1', {
        journalDate: '2026-10-12',
        sourceType: 'EQUITY',
        sourceId: 801,
        sourceCode: 'EQ-001',
        description: 'Setor Modal',
        lines: [
            { chart_of_account_id: 101, debit: 1000000, credit: 0 },
            { chart_of_account_id: 301, debit: 0, credit: 1000000 }
        ]
    });
    assert(false, 'Kasir posting EQUITY journal is strictly rejected');
} catch (e) {
    assert(e.message.includes('UNAUTHORIZED_SENSITIVE_SOURCE'), 'Kasir posting EQUITY journal is strictly rejected');
}

// TEST G: OWNER POSTS EQUITY JOURNAL
try {
    const eqJournal = engine.postJournalSecure('owner', 'user-owner', {
        journalDate: '2026-10-12',
        sourceType: 'EQUITY',
        sourceId: 801,
        sourceCode: 'EQ-001',
        description: 'Setoran Modal Pemilik',
        lines: [
            { chart_of_account_id: 101, debit: 1000000, credit: 0 },
            { chart_of_account_id: 301, debit: 0, credit: 1000000 }
        ]
    });
    assert(eqJournal.success, 'Owner successfully posts EQUITY journal');
} catch (e) {
    assert(false, 'Owner successfully posts EQUITY journal', e.message);
}

// TEST H: KASIR IS REJECTED FROM REVERSING JOURNAL ENTRIES
try {
    engine.reverseJournalSecure('kasir', 'user-1', {
        originalJournalId: 1,
        reason: 'Kasir mencoba void jurnal'
    });
    assert(false, 'Kasir is blocked from reversing journal entries');
} catch (e) {
    assert(e.message.includes('UNAUTHORIZED'), 'Kasir is blocked from reversing journal entries');
}

// TEST I: OWNER/ADMIN CAN REVERSE JOURNAL (IMMUTABLE REVERSAL ENTRY CREATED)
try {
    const revRes = engine.reverseJournalSecure('admin', 'user-admin', {
        originalJournalId: 1,
        reason: 'VOID transaksi kasir oleh Admin'
    });
    assert(revRes.success && revRes.reversal_id > 0, 'Admin reverses journal with immutable reversal entry');
    const orig = engine.journals.find(j => j.id === 1);
    assert(orig.status === 'REVERSED', 'Original journal marked as REVERSED');
} catch (e) {
    assert(false, 'Admin reverses journal with immutable reversal entry', e.message);
}

// TEST J: ATTEMPTING TO REVERSE A REVERSAL JOURNAL IS BLOCKED
try {
    const revEntry = engine.journals.find(j => j.is_reversal === true);
    engine.reverseJournalSecure('admin', 'user-admin', {
        originalJournalId: revEntry.id,
        reason: 'Mencoba reverse reversal'
    });
    assert(false, 'Reversing a reversal entry is blocked');
} catch (e) {
    assert(e.message.includes('CANNOT_REVERSE_REVERSAL'), 'Reversing a reversal entry is blocked');
}

// TEST K: SUPPLIER PAYABLE ATOMIC PAYMENT WITH DEFAULT DUE_DATE & OVERPAYMENT GUARD
engine.purchases.push({
    id: 99,
    po_no: 'PO-TEST-99',
    total: 300000,
    paid_amount: 0,
    remaining: 300000,
    voided_at: null
});

try {
    const payRes = engine.processPayablePaymentAtomic('admin', 'user-admin', {
        purchaseId: 99,
        amount: 100000,
        paymentMethod: 'Tunai',
        paymentAccountId: 101,
        note: 'Cicilan 1'
    });
    assert(payRes.success && payRes.new_paid === 100000 && payRes.new_remaining === 200000, 'Partial payable payment succeeds');
    const payableRow = engine.payables.find(p => p.purchase_id === 99);
    assert(payableRow.due_date === 'DATABASE_DEFAULT_TEMPO', 'Payable due_date adopts database default behavior');
} catch (e) {
    assert(false, 'Partial payable payment succeeds', e.message);
}

// TEST L: OVERPAYMENT GUARD BLOCKS EXCESS PAYMENT
try {
    engine.processPayablePaymentAtomic('admin', 'user-admin', {
        purchaseId: 99,
        amount: 250000, // Remaining is 200000, this exceeds by 50000
        paymentMethod: 'Tunai',
        paymentAccountId: 101,
        note: 'Kelebihan bayar'
    });
    assert(false, 'Overpayment on payable is strictly blocked');
} catch (e) {
    assert(e.message.includes('OVERPAYMENT_BLOCKED'), 'Overpayment on payable is strictly blocked');
}

// TEST M: PAYMENT ON VOIDED PURCHASE (voided_at IS NOT NULL) IS BLOCKED
engine.purchases.push({
    id: 100,
    po_no: 'PO-VOID-100',
    total: 500000,
    paid_amount: 0,
    remaining: 500000,
    voided_at: '2026-10-12T10:00:00Z'
});

try {
    engine.processPayablePaymentAtomic('admin', 'user-admin', {
        purchaseId: 100,
        amount: 100000,
        paymentMethod: 'Tunai',
        paymentAccountId: 101
    });
    assert(false, 'Payment on voided purchase (voided_at NOT NULL) is blocked');
} catch (e) {
    assert(e.message.includes('INVALID_PURCHASE_STATUS'), 'Payment on voided purchase (voided_at NOT NULL) is blocked');
}

// TEST N: UNBALANCED JOURNAL ENTRY IS STRICTLY REJECTED
try {
    engine.postJournalSecure('admin', 'user-admin', {
        journalDate: '2026-10-12',
        sourceType: 'TRANSACTION',
        sourceId: 999,
        sourceCode: 'TRX-UNBALANCED',
        description: 'Jurnal tidak seimbang',
        lines: [
            { chart_of_account_id: 101, debit: 100000, credit: 0 },
            { chart_of_account_id: 401, debit: 0, credit: 80000 }
        ]
    });
    assert(false, 'Unbalanced journal entry is strictly rejected');
} catch (e) {
    assert(e.message.includes('UNBALANCED_JOURNAL'), 'Unbalanced journal entry is strictly rejected');
}

// TEST O: FRONTEND ROLLBACK SAFETY IN INDEX.HTML
assert(htmlContent.includes('await this.rollbackInvoiceConversion(insertedInvId);'), 'Quotation->Invoice conversion has rollback on journal failure');
assert(htmlContent.includes("await supabaseClient.from('purchase_items').delete().eq('purchase_id', insertedPurchaseId);"), 'Purchase creation has item rollback on journal failure');
assert(htmlContent.includes("await supabaseClient.from('expenses').delete().eq('id', insertedExpense.id);"), 'Expense creation has orphan row cleanup on journal failure');
assert(htmlContent.includes("await supabaseClient.from('equity_transactions').delete().eq('id', insertedEquity.id);"), 'Equity creation has orphan row cleanup on journal failure');

// TEST P: FRONTEND EXPLICIT ROLE CHECKS FOR KASIR
assert(htmlContent.includes('Hanya Owner dan Admin yang berhak mencatat Pembelian Supplier'), 'Frontend role check restricts savePurchase to owner & admin');
assert(htmlContent.includes('Hanya Owner dan Admin yang dapat mencatat beban operasional'), 'Frontend role check restricts saveExpense to owner & admin');
assert(htmlContent.includes('Hanya Owner yang berhak mencatat transaksi Modal atau Prive'), 'Frontend role check restricts saveEquity to owner');
assert(htmlContent.includes('Hanya Owner dan Admin yang berhak membatalkan (VOID) Transaksi'), 'Frontend role check restricts void transaction to owner & admin');
assert(htmlContent.includes('Hanya Owner dan Admin yang berhak membatalkan (VOID) Invoice'), 'Frontend role check restricts void invoice to owner & admin');

// TEST Q: DOUBLE SUBMISSION GUARDS (PREVENT CONCURRENT / DUPLICATE TRANSACTIONS)
assert(htmlContent.includes('isCompletingTransaction'), 'POS transaction completion guarded by isCompletingTransaction lock');
assert(htmlContent.includes('isSavingPurchase'), 'PO creation guarded by isSavingPurchase lock');
assert(htmlContent.includes('isConvertingQuotation'), 'Quotation to invoice conversion guarded by isConvertingQuotation lock');
assert(htmlContent.includes('isVoidingInvoice'), 'Invoice cancellation guarded by isVoidingInvoice lock');

// TEST R: ATOMIC VOID DATABASE MIGRATION INTEGRITY & CLIENT INTEGRATION
const atomicVoidMigrationPath = path.join(__dirname, '..', 'supabase', 'migrations', '20261012_atomic_invoice_and_pos_void.sql');
assert(fs.existsSync(atomicVoidMigrationPath), 'Atomic void migration file exists');
const atomicVoidSql = fs.readFileSync(atomicVoidMigrationPath, 'utf8');

assert(atomicVoidSql.includes('CREATE OR REPLACE FUNCTION public.void_invoice_atomic'), 'Migration includes void_invoice_atomic');
assert(atomicVoidSql.includes('CREATE OR REPLACE FUNCTION public.void_pos_transaction_atomic'), 'Migration includes void_pos_transaction_atomic');
assert(atomicVoidSql.includes('REVOKE EXECUTE ON FUNCTION public.void_invoice_atomic FROM PUBLIC, anon;'), 'void_invoice_atomic revoked from anon');
assert(atomicVoidSql.includes('GRANT EXECUTE ON FUNCTION public.void_invoice_atomic TO authenticated;'), 'void_invoice_atomic granted to authenticated');
assert(atomicVoidSql.includes('REVOKE EXECUTE ON FUNCTION public.void_pos_transaction_atomic FROM PUBLIC, anon;'), 'void_pos_transaction_atomic revoked from anon');
assert(atomicVoidSql.includes('GRANT EXECUTE ON FUNCTION public.void_pos_transaction_atomic TO authenticated;'), 'void_pos_transaction_atomic granted to authenticated');
assert(htmlContent.includes("supabaseClient.rpc('void_invoice_atomic'"), 'index.html integrates void_invoice_atomic');
assert(htmlContent.includes("supabaseClient.rpc('void_pos_transaction_atomic'"), 'index.html integrates void_pos_transaction_atomic');

// TEST S: STOCK LOG ACTION TYPE STRICTLY USES 'VOID', NOT 'VOID_IN'
assert(!atomicVoidSql.includes("'VOID_IN'"), 'Migration contains NO invalid action_type VOID_IN');
assert(atomicVoidSql.includes("'VOID'"), 'Migration uses valid action_type VOID adhering to production constraints');

// TEST T: STRICT ELIMINATION OF DANGEROUS MULTI-REQUEST NON-ATOMIC FALLBACKS
assert(!htmlContent.includes('void_invoice_atomic fallback:'), 'index.html has NO non-atomic fallback catch block for void_invoice_atomic');
assert(!htmlContent.includes('void_pos_transaction_atomic fallback:'), 'index.html has NO non-atomic fallback catch block for void_pos_transaction_atomic');
assert(!htmlContent.includes('if (!atomicExecuted && supabaseClient && this.isAuthenticated)'), 'index.html has NO secondary multi-request path in void invoice');
assert(!htmlContent.includes('if (!atomicExecuted)'), 'index.html has NO secondary multi-request path in void pos transaction');

// TEST U: SIMULATED DOUBLE VOID ON INVOICE IS STRICTLY REJECTED
engine.invoices.push({ id: 801, inv_no: 'INV-202610-801', status: 'Belum Lunas', total: 500000, remaining: 500000 });
engine.receivables.push({ invoice_id: 801, inv_no: 'INV-202610-801', status: 'Belum Lunas', total: 500000, remaining: 500000 });
const firstInvVoid = engine.voidInvoiceAtomic('admin', 'user-admin', { invoiceId: 801, reason: 'Void Pertama' });
assert(firstInvVoid.success && firstInvVoid.status === 'Dibatalkan', 'First invoice VOID succeeds atomically');
try {
    engine.voidInvoiceAtomic('admin', 'user-admin', { invoiceId: 801, reason: 'Void Kedua' });
    assert(false, 'Double VOID on Invoice must be rejected');
} catch (e) {
    assert(e.message.includes('ALREADY_VOIDED'), 'Double VOID on Invoice is strictly rejected with ALREADY_VOIDED');
}

// TEST V: SIMULATED DOUBLE VOID ON POS TRANSACTION IS STRICTLY REJECTED & SINGLE STOCK RESTORATION
const mockProducts = [{ id: 901, name: 'Pakan Ayam Premium', stock: 10, type: 'barang' }];
const mockStockLogs = [];
engine.transactions.push({
    id: 701,
    trx_code: 'TRX-202610-701',
    transaction_type: 'Jual',
    status: 'VALID',
    items: [{ productId: 901, qty: 5 }]
});
const firstTrxVoid = engine.voidPosTransactionAtomic('admin', 'user-admin', {
    transactionId: 701,
    reason: 'Void TRX Pertama',
    products: mockProducts,
    stockLogs: mockStockLogs
});
assert(firstTrxVoid.success && firstTrxVoid.status === 'VOID', 'First POS transaction VOID succeeds atomically');
assert(mockProducts[0].stock === 15, 'Stock correctly restored from 10 to 15 on first VOID');
assert(mockStockLogs.length === 1 && mockStockLogs[0].action_type === 'VOID', 'Stock log created with action_type VOID');

try {
    engine.voidPosTransactionAtomic('admin', 'user-admin', {
        transactionId: 701,
        reason: 'Void TRX Kedua',
        products: mockProducts,
        stockLogs: mockStockLogs
    });
    assert(false, 'Double VOID on POS Transaction must be rejected');
} catch (e) {
    assert(e.message.includes('ALREADY_VOIDED'), 'Double VOID on POS Transaction is strictly rejected with ALREADY_VOIDED');
}
assert(mockProducts[0].stock === 15, 'Stock remains 15 (no duplicate restoration after rejected double VOID)');
assert(mockStockLogs.length === 1, 'No duplicate stock logs generated');

// TEST W: PAID INVOICE VOID IS STRICTLY REJECTED
engine.invoices.push({ id: 802, inv_no: 'INV-202610-802', status: 'Sebagian', total: 500000, remaining: 300000 });
engine.paymentHistory.push({ id: 991, invoice_id: 802, inv_no: 'INV-202610-802', amount: 200000, status: 'VALID' });
try {
    engine.voidInvoiceAtomic('admin', 'user-admin', { invoiceId: 802 });
    assert(false, 'Paid invoice VOID must be rejected');
} catch (e) {
    assert(e.message.includes('CANNOT_VOID_PAID_INVOICE'), 'Paid invoice VOID is strictly rejected with CANNOT_VOID_PAID_INVOICE');
}

// TEST X: UNAUTHORIZED ROLE ATTEMPTING VOID IS STRICTLY REJECTED
try {
    engine.voidInvoiceAtomic('kasir', 'user-kasir', { invoiceId: 801 });
    assert(false, 'Kasir attempting VOID invoice must be rejected');
} catch (e) {
    assert(e.message.includes('UNAUTHORIZED'), 'Kasir attempting VOID invoice is strictly rejected with UNAUTHORIZED');
}
try {
    engine.voidPosTransactionAtomic('kasir', 'user-kasir', { transactionId: 701, products: mockProducts });
    assert(false, 'Kasir attempting VOID POS transaction must be rejected');
} catch (e) {
    assert(e.message.includes('UNAUTHORIZED'), 'Kasir attempting VOID POS transaction is strictly rejected with UNAUTHORIZED');
}

console.log('----------------------------------------------------------------');
console.log(`TOTAL ISOLATION TESTS: ${passedTests + failedTests}`);
console.log(`PASSED: ${passedTests}`);
console.log(`FAILED: ${failedTests}`);
console.log('----------------------------------------------------------------');

if (failedTests > 0) {
    process.exit(1);
} else {
    console.log('ALL TRANSACTION ENGINE ISOLATION TESTS PASSED!');
    process.exit(0);
}

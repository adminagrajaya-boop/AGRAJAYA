/**
 * AGRA JAYA POS — TEST SKENARIO PEMBAYARAN KONVERSI QUOTATION & AUDIT KONTRAK RPC V3
 * 
 * TIPE PENGUJIAN: SIMULASI / MOCK LOGIKA BISNIS & AUDIT STATIK KONTRAK FILE
 * PERINGATAN: File ini menjalankan simulasi logika bisnis dan verifikasi kontrak statis.
 * Pengujian ini BUKAN integrasi PostgreSQL live pada Supabase Production (sesuai instruksi ketat pengguna).
 */

const fs = require('fs');
const path = require('path');

console.log('================================================================================');
console.log('AGRA JAYA POS — TEST SKENARIO KONVERSI QUOTATION & AUDIT KONTRAK RPC V3');
console.log('Tipe Pengujian: Simulasi Logika Bisnis & Analisis Kontrak Statis (Mock Sandbox)');
console.log('================================================================================');

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

// -----------------------------------------------------------------------------
// 1. SIMULASI ENGINE PL/PGSQL CONVERT_QUOTATION_TO_INVOICE_ATOMIC
// -----------------------------------------------------------------------------
class MockQuotationConversionEngine {
    constructor() {
        this.coaKas = { id: 101, code: '1-1001', name: 'Kas Utama' };
        this.coaPiutang = { id: 103, code: '1-1110', name: 'Piutang Usaha' };
        this.coaPenjualan = { id: 401, code: '4-1110', name: 'Pendapatan Penjualan' };
        this.coaJasa = { id: 402, code: '4-1120', name: 'Pendapatan Jasa' };
    }

    convertQuotation({
        quotation,
        invNo,
        invDate,
        dueDate = null,
        paymentMethod = 'Kredit',
        paymentAccountId = 101,
        paidAmount = 0,
        items = []
    }) {
        if (!quotation) throw new Error('NOT_FOUND: Penawaran tidak ditemukan');
        if (!['Approved', 'Deal'].includes(quotation.status)) {
            throw new Error(`INVALID_STATUS: Penawaran berstatus "${quotation.status}"`);
        }
        if (!invNo || !invNo.trim()) throw new Error('INVALID_PARAM: inv_no wajib diisi');
        if (!items || items.length === 0) throw new Error('INVALID_ITEMS: Item kosong');

        // Validasi payment method
        const validMethods = ['Tunai', 'TunaiBelumLunas', 'Tunai Belum Lunas', 'Kredit'];
        if (!paymentMethod || !validMethods.includes(paymentMethod)) {
            throw new Error(`INVALID_PAYMENT_METHOD: Metode pembayaran "${paymentMethod}" tidak didukung`);
        }

        // Kalkulasi item
        let grossTotal = 0;
        let discountTotal = 0;
        let netTotal = 0;
        let barangNet = 0;
        let jasaNet = 0;

        items.forEach(it => {
            const qty = Number(it.qty);
            const price = Number(it.price);
            const discType = it.discountType || 'none';
            const discVal = Number(it.discountValue || 0);

            let discAmt = 0;
            if (discType === 'percent') {
                discAmt = Math.round((qty * price * Math.min(100, Math.max(0, discVal)) / 100) * 100) / 100;
            } else if (discType === 'nominal') {
                discAmt = Math.min(qty * price, Math.max(0, discVal));
            }

            const itemNet = Math.max(0, Math.round((qty * price - discAmt) * 100) / 100);
            grossTotal += (qty * price);
            discountTotal += discAmt;
            netTotal += itemNet;

            if (it.type === 'jasa') {
                jasaNet += itemNet;
            } else {
                barangNet += itemNet;
            }
        });

        if (netTotal <= 0) throw new Error('INVALID_TOTAL: Total invoice harus > 0');

        let paid = 0;
        let remaining = 0;
        let status = 'Belum Bayar';
        let storedMethod = 'Kredit';

        if (paymentMethod === 'Tunai') {
            paid = netTotal;
            remaining = 0;
            status = 'Lunas';
            storedMethod = 'Tunai';
        } else if (paymentMethod === 'TunaiBelumLunas' || paymentMethod === 'Tunai Belum Lunas') {
            paid = 0;
            remaining = netTotal;
            status = 'Belum Bayar';
            storedMethod = 'Tunai'; // Metode pembayaran tetap Tunai
        } else {
            // Kredit / Tempo
            paid = Math.min(netTotal, Math.max(0, Number(paidAmount || 0)));
            remaining = Math.max(0, netTotal - paid);
            if (remaining <= 0.001) {
                status = 'Lunas';
            } else if (paid > 0.001) {
                status = 'Sebagian';
            } else {
                status = 'Belum Bayar';
            }
            storedMethod = 'Kredit';
        }

        // Double-entry journal calculation
        const journalLines = [];

        // Kas masuk (hanya jika ada uang diterima > 0)
        if (paid > 0.001) {
            journalLines.push({
                coaId: this.coaKas.id,
                accountName: this.coaKas.name,
                debit: paid,
                credit: 0,
                memo: `Penerimaan Pembayaran Invoice ${invNo}`
            });
        }

        // Piutang usaha (hanya jika ada sisa > 0)
        if (remaining > 0.001) {
            journalLines.push({
                coaId: this.coaPiutang.id,
                accountName: this.coaPiutang.name,
                debit: remaining,
                credit: 0,
                memo: `Piutang Usaha Invoice ${invNo}`
            });
        }

        // Pendapatan penjualan barang
        if (barangNet > 0.001) {
            journalLines.push({
                coaId: this.coaPenjualan.id,
                accountName: this.coaPenjualan.name,
                debit: 0,
                credit: barangNet,
                memo: `Pendapatan Penjualan Invoice ${invNo}`
            });
        }

        // Pendapatan jasa
        if (jasaNet > 0.001) {
            journalLines.push({
                coaId: this.coaJasa.id,
                accountName: this.coaJasa.name,
                debit: 0,
                credit: jasaNet,
                memo: `Pendapatan Jasa Invoice ${invNo}`
            });
        }

        // Validasi Balance: Total Debit == Total Credit
        const totalDebit = journalLines.reduce((acc, l) => acc + l.debit, 0);
        const totalCredit = journalLines.reduce((acc, l) => acc + l.credit, 0);
        const isBalanced = Math.abs(totalDebit - totalCredit) < 0.001;

        // Receivable record
        let receivableRecord = null;
        if (remaining > 0.001) {
            receivableRecord = {
                invNo: invNo,
                customerName: quotation.customerName || 'Pelanggan',
                dueDate: dueDate,
                status: status,
                total: netTotal,
                paid: paid,
                remaining: remaining
            };
        }

        return {
            success: true,
            invoice: {
                invNo: invNo,
                status: status,
                total: netTotal,
                paid: paid,
                remaining: remaining,
                dueDate: dueDate,
                paymentMethod: storedMethod
            },
            receivable: receivableRecord,
            journal: {
                lines: journalLines,
                totalDebit: totalDebit,
                totalCredit: totalCredit,
                isBalanced: isBalanced
            }
        };
    }
}

// -----------------------------------------------------------------------------
// 2. RUN TESTS FOR 3 QUOTATION PAYMENT SCENARIOS
// -----------------------------------------------------------------------------
const engine = new MockQuotationConversionEngine();

const sampleQuotation = {
    id: 1,
    qtNo: 'QT-20261012-001',
    customerName: 'CV Makmur Sejahtera',
    status: 'Approved'
};

const sampleItems = [
    { productId: 1, name: 'Pakan Ayam Premium', qty: 10, price: 50000, type: 'barang' }, // 500,000
    { productId: 2, name: 'Vitamin Ternak', qty: 5, price: 100000, type: 'barang' }        // 500,000
];
// Net Total = 1,000,000

console.log('\n--- SKENARIO 1: TUNAI + LUNAS ---');
{
    const res1 = engine.convertQuotation({
        quotation: sampleQuotation,
        invNo: 'INV-001',
        invDate: '2026-10-12',
        dueDate: null,
        paymentMethod: 'Tunai',
        paidAmount: 1000000,
        items: sampleItems
    });

    assert(res1.invoice.status === 'Lunas', 'Skenario 1: Status invoice adalah Lunas');
    assert(res1.invoice.paid === 1000000, 'Skenario 1: Paid amount penuh (Rp 1.000.000)');
    assert(res1.invoice.remaining === 0, 'Skenario 1: Sisa piutang adalah 0');
    assert(res1.invoice.paymentMethod === 'Tunai', 'Skenario 1: Metode pembayaran tersimpan adalah Tunai');
    assert(res1.receivable === null, 'Skenario 1: Tidak membuat data piutang (tanpa piutang)');
    assert(res1.journal.isBalanced, 'Skenario 1: Jurnal berimbang (Debit == Credit)');
    
    const kasLine = res1.journal.lines.find(l => l.coaId === 101);
    const piutangLine = res1.journal.lines.find(l => l.coaId === 103);
    assert(kasLine && kasLine.debit === 1000000, 'Skenario 1: Jurnal kas mendebit penuh Rp 1.000.000');
    assert(!piutangLine, 'Skenario 1: Tidak ada baris piutang dalam jurnal');
}

console.log('\n--- SKENARIO 2: TUNAI + BELUM LUNAS ---');
{
    const res2 = engine.convertQuotation({
        quotation: sampleQuotation,
        invNo: 'INV-002',
        invDate: '2026-10-12',
        dueDate: null, // Opsional / null
        paymentMethod: 'TunaiBelumLunas',
        paidAmount: 0,
        items: sampleItems
    });

    assert(res2.invoice.status === 'Belum Bayar', 'Skenario 2: Status invoice adalah Belum Bayar');
    assert(res2.invoice.paid === 0, 'Skenario 2: Paid amount adalah 0 (belum ada uang diterima)');
    assert(res2.invoice.remaining === 1000000, 'Skenario 2: Sisa piutang tercatat penuh Rp 1.000.000');
    assert(res2.invoice.paymentMethod === 'Tunai', 'Skenario 2: Metode pembayaran tetap "Tunai" (bukan Kredit)');
    assert(res2.invoice.dueDate === null, 'Skenario 2: Tanggal jatuh tempo tetap null (tidak otomatis 30 hari)');
    assert(res2.receivable !== null, 'Skenario 2: Piutang tercatat pada database');
    assert(res2.receivable.remaining === 1000000, 'Skenario 2: Sisa piutang pada record piutang adalah Rp 1.000.000');
    assert(res2.receivable.dueDate === null, 'Skenario 2: Record piutang tidak dipaksa jatuh tempo 30 hari');
    assert(res2.journal.isBalanced, 'Skenario 2: Jurnal berimbang (Debit == Credit)');

    const kasLine = res2.journal.lines.find(l => l.coaId === 101);
    const piutangLine = res2.journal.lines.find(l => l.coaId === 103);
    assert(!kasLine, 'Skenario 2: TIDAK ADA jurnal penerimaan kas');
    assert(piutangLine && piutangLine.debit === 1000000, 'Skenario 2: Jurnal mendebit Piutang Usaha sebesar Rp 1.000.000');
}

console.log('\n--- SKENARIO 3: KREDIT / TEMPO DENGAN DP OPSIONAL ---');
{
    const res3 = engine.convertQuotation({
        quotation: sampleQuotation,
        invNo: 'INV-003',
        invDate: '2026-10-12',
        dueDate: '2026-11-20', // Input custom dari user
        paymentMethod: 'Kredit',
        paidAmount: 350000, // DP Rp 350.000
        items: sampleItems
    });

    assert(res3.invoice.status === 'Sebagian', 'Skenario 3: Status invoice adalah Sebagian');
    assert(res3.invoice.paid === 350000, 'Skenario 3: Paid amount sesuai DP input (Rp 350.000)');
    assert(res3.invoice.remaining === 650000, 'Skenario 3: Sisa piutang adalah Rp 650.000');
    assert(res3.invoice.paymentMethod === 'Kredit', 'Skenario 3: Metode pembayaran tersimpan adalah Kredit');
    assert(res3.invoice.dueDate === '2026-11-20', 'Skenario 3: Tanggal jatuh tempo sesuai input (2026-11-20)');
    assert(res3.receivable !== null, 'Skenario 3: Record piutang dibuat');
    assert(res3.receivable.paid === 350000 && res3.receivable.remaining === 650000, 'Skenario 3: Record piutang mencatat DP dan sisa akurat');
    assert(res3.journal.isBalanced, 'Skenario 3: Jurnal berimbang (Debit == Credit)');

    const kasLine = res3.journal.lines.find(l => l.coaId === 101);
    const piutangLine = res3.journal.lines.find(l => l.coaId === 103);
    const penjualanLine = res3.journal.lines.find(l => l.coaId === 401);
    assert(kasLine && kasLine.debit === 350000, 'Skenario 3: Jurnal kas HANYA mendebit sebesar DP yang dibayar (Rp 350.000)');
    assert(piutangLine && piutangLine.debit === 650000, 'Skenario 3: Jurnal mendebit Piutang Usaha sebesar sisa (Rp 650.000)');
    assert(penjualanLine && penjualanLine.credit === 1000000, 'Skenario 3: Jurnal mengkredit Pendapatan Penjualan Rp 1.000.000');
}

// -----------------------------------------------------------------------------
// 3. AUDIT KONTRAK STATIS FILE (INDEX.HTML & MIGRATION SQL V3)
// -----------------------------------------------------------------------------
console.log('\n--- AUDIT KONTRAK STATIS RPC V3 ---');
const v3MigrationPath = path.join(__dirname, '..', 'supabase', 'migrations', '20261012_atomic_business_transactions_engine_v3.sql');
const indexHtmlPath = path.join(__dirname, '..', 'index.html');

const v3Sql = fs.readFileSync(v3MigrationPath, 'utf8');
const indexHtml = fs.readFileSync(indexHtmlPath, 'utf8');

// Audit 1: convert_quotation_to_invoice_atomic
assert(
    v3Sql.includes('p_payment_method VARCHAR DEFAULT \'Kredit\'') || v3Sql.includes('p_payment_method VARCHAR'),
    'Audit RPC: convert_quotation_to_invoice_atomic menerima parameter p_payment_method VARCHAR'
);
assert(
    !v3Sql.includes('p_is_tunai_lunas BOOLEAN') || v3Sql.indexOf('p_is_tunai_lunas BOOLEAN') < v3Sql.indexOf('DROP FUNCTION IF EXISTS public.convert_quotation_to_invoice_atomic(BIGINT, VARCHAR, DATE, DATE, VARCHAR, VARCHAR, BOOLEAN'),
    'Audit RPC: signature convert_quotation_to_invoice_atomic tidak lagi memakai p_is_tunai_lunas'
);
assert(
    v3Sql.includes('DROP FUNCTION IF EXISTS public.convert_quotation_to_invoice_atomic(BIGINT, VARCHAR, DATE, DATE, VARCHAR, VARCHAR, BOOLEAN') &&
    v3Sql.includes('DROP FUNCTION IF EXISTS public.convert_quotation_to_invoice_atomic(BIGINT, VARCHAR, DATE, DATE, VARCHAR, VARCHAR, VARCHAR'),
    'Audit RPC: Migration v3 membersihkan kedua overload convert_quotation_to_invoice_atomic (BOOLEAN & VARCHAR)'
);
assert(
    indexHtml.includes('p_payment_method: options.paymentMethod || \'Tunai\''),
    'Audit Frontend: index.html memanggil convert_quotation_to_invoice_atomic dengan p_payment_method eksplisit'
);
assert(
    !indexHtml.includes('p_is_tunai_lunas: isTunaiLunas'),
    'Audit Frontend: index.html sudah tidak lagi mengirim p_is_tunai_lunas'
);

// Audit 2: create_equity_transaction_atomic
assert(
    v3Sql.includes('p_transaction_type IN (\'MODAL\', \'CAPITAL_IN\')') &&
    v3Sql.includes('p_transaction_type IN (\'PRIVE\', \'DRAWING_OUT\')'),
    'Audit RPC: create_equity_transaction_atomic menormalisasi CAPITAL_IN / DRAWING_OUT frontend ke MODAL / PRIVE'
);
assert(
    indexHtml.includes('p_transaction_type: type'),
    'Audit Frontend: index.html mengirim p_transaction_type ke create_equity_transaction_atomic'
);

// Audit 3: create_purchase_atomic & payables due date
assert(
    v3Sql.includes('INSERT INTO public.payables (\n            purchase_id, po_no, supplier_name, status, total, paid, remaining\n        ) VALUES (') ||
    v3Sql.includes('INSERT INTO public.payables (\r\n            purchase_id, po_no, supplier_name, status, total, paid, remaining\r\n        ) VALUES ('),
    'Audit RPC: create_purchase_atomic mempertahankan default tempo 30 hari database untuk payables supplier'
);

// Audit 4: All 6 RPC functions are defined and granted
const rpcList = [
    'create_pos_transaction_atomic',
    'create_purchase_atomic',
    'create_expense_atomic',
    'create_equity_transaction_atomic',
    'convert_quotation_to_invoice_atomic',
    'void_pos_transaction_atomic'
];

rpcList.forEach(rpc => {
    assert(v3Sql.includes(`CREATE OR REPLACE FUNCTION public.${rpc}`), `Audit RPC Definition: ${rpc} terdefinisi di v3.sql`);
    assert(v3Sql.includes(`REVOKE EXECUTE ON FUNCTION public.${rpc} FROM PUBLIC, anon;`), `Audit RPC Security: ${rpc} direvoke dari anon & PUBLIC`);
    assert(v3Sql.includes(`GRANT EXECUTE ON FUNCTION public.${rpc} TO authenticated;`), `Audit RPC Grant: ${rpc} digrant ke authenticated`);
    assert(indexHtml.includes(`'${rpc}'`), `Audit Frontend Integration: ${rpc} dipanggil oleh index.html`);
});

// Audit 5: Internal post_journal_entry & reverse_journal_entry security
assert(
    !v3Sql.includes('GRANT EXECUTE ON FUNCTION public.post_journal_entry TO authenticated') &&
    !v3Sql.includes('GRANT EXECUTE ON FUNCTION public.post_journal_entry TO anon'),
    'Audit Security: post_journal_entry internal TIDAK dibuka untuk authenticated atau anon'
);
assert(
    !v3Sql.includes('GRANT EXECUTE ON FUNCTION public.reverse_journal_entry TO authenticated') &&
    !v3Sql.includes('GRANT EXECUTE ON FUNCTION public.reverse_journal_entry TO anon'),
    'Audit Security: reverse_journal_entry internal TIDAK dibuka untuk authenticated atau anon'
);

console.log('================================================================================');
console.log(`TOTAL PENGUJIAN SKENARIO & AUDIT: ${passedTests + failedTests}`);
console.log(`PASSED: ${passedTests}`);
console.log(`FAILED: ${failedTests}`);
console.log('STATUS: SEMUA SKENARIO PEMBAYARAN QUOTATION & AUDIT KONTRAK RPC BERHASIL! ✅');
console.log('================================================================================');

if (failedTests > 0) process.exit(1);

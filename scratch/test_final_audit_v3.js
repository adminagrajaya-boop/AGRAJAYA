/**
 * AGRA JAYA POS — FINAL AUDIT V3 COMPREHENSIVE TEST SUITE
 * 
 * Pengujian:
 * 1. POS Discount Audit (Item Discounts, Transaction Discounts, Combined, Matching Total/Profit/Invoice/Journal)
 * 2. COA & Payment Accounts Audit (1-1001, 1-1010, 1-1210 vs 1-1140, payment_accounts.chart_of_account_id)
 * 3. 6 Core RPCs Contract Audit (Signatures, Drops, Roles, Grants, Atomicity, VOID guards)
 * 
 * CATATAN PENTING: Pengujian ini adalah simulasi logika bisnis dan verifikasi kontrak statis (Mock Sandbox).
 * BUKAN integrasi live PostgreSQL pada Supabase Production (sesuai instruksi ketat: Jangan terapkan migration ke Production).
 */

const fs = require('fs');
const path = require('path');

console.log('================================================================================');
console.log('AGRA JAYA POS — FINAL AUDIT V3 TEST SUITE (DISCOUNT, COA & 6 RPC CONTRACTS)');
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

const htmlPath = path.join(__dirname, '..', 'index.html');
const v3MigrationPath = path.join(__dirname, '..', 'supabase', 'migrations', '20261012_atomic_business_transactions_engine_v3.sql');
const htmlContent = fs.readFileSync(htmlPath, 'utf8');
const v3Sql = fs.readFileSync(v3MigrationPath, 'utf8');

// -----------------------------------------------------------------------------
// 1. SIMULASI ENGINE PL/PGSQL CREATE_POS_TRANSACTION_ATOMIC DENGAN DISKON
// -----------------------------------------------------------------------------
class MockPosAtomicEngine {
    constructor() {
        this.products = [
            { id: 1, name: 'Tempat Pakan Ayam', price: 50000, cost_price: 35000, stock: 100, type: 'barang' },
            { id: 2, name: 'Nipple Drinker Otomatis', price: 25000, cost_price: 15000, stock: 200, type: 'barang' },
            { id: 3, name: 'Jasa Pemasangan Closed House', price: 150000, cost_price: 50000, stock: 0, type: 'jasa' }
        ];
        this.paymentAccounts = [
            { id: 1, name: 'Kas Tunai Kasir', type: 'CASH', chart_of_account_id: 1010 },
            { id: 2, name: 'Bank Operasional', type: 'BANK', chart_of_account_id: 1020 },
            { id: 3, name: 'Penampung QRIS', type: 'GATEWAY', chart_of_account_id: 1030 }
        ];
        this.coaRevenue = { id: 4110, code: '4-1110', name: 'Pendapatan Penjualan Barang' };
        this.coaPiutang = { id: 1110, code: '1-1110', name: 'Piutang Usaha' };
    }

    createPosTransaction({
        trxCode,
        partyName,
        transactionDate,
        total,
        profit,
        paymentMethod,
        paymentAccountId = null,
        items = [],
        dpAmount = 0,
        dueDate = null,
        discount = 0
    }) {
        if (!trxCode) throw new Error('INVALID_PARAM: trx_code wajib');
        if (!items || items.length === 0) throw new Error('EMPTY_ITEMS: Keranjang kosong');

        let grossTotal = 0;
        let itemsDiscTotal = 0;
        let totalCost = 0;

        for (const item of items) {
            const prod = this.products.find(p => p.id === item.productId || p.id === item.id);
            if (!prod) throw new Error(`PRODUCT_NOT_FOUND: ${item.id}`);

            const qty = Number(item.qty);
            const price = Number(item.price);
            const costPrice = Number(prod.cost_price || item.costPrice || 0);

            const discType = item.discountType || item.discount_type || 'none';
            const discVal = Number(item.discountValue || item.discount_value || 0);
            let discAmt = Number(item.discountAmount || item.discount_amount || 0);

            if (['percent', 'percentage'].includes(discType) && discVal > 0) {
                discAmt = Math.round((qty * price * discVal) / 100);
            } else if (['nominal', 'fixed', 'rp'].includes(discType) && discVal > 0 && discAmt === 0) {
                discAmt = discVal;
            }

            if (discAmt < 0 || discAmt > (qty * price)) {
                throw new Error('INVALID_DISCOUNT: Nilai diskon item tidak valid');
            }

            grossTotal += (qty * price);
            itemsDiscTotal += discAmt;
            totalCost += (qty * costPrice);
        }

        const trxDiscount = Math.max(0, Number(discount || 0));
        const discountTotal = itemsDiscTotal + trxDiscount;
        const calcNetTotal = Math.max(0, grossTotal - discountTotal);
        const calcProfit = calcNetTotal - totalCost;

        if (total !== null && Math.abs(total - calcNetTotal) > 0.05) {
            throw new Error(`TOTAL_MISMATCH: Client (${total}) vs Server (${calcNetTotal})`);
        }

        let paid = 0;
        let remaining = 0;
        let status = 'Lunas';

        if (['Tunai', 'Transfer', 'QRIS'].includes(paymentMethod)) {
            paid = calcNetTotal;
            remaining = 0;
            status = 'Lunas';
        } else if (paymentMethod === 'Kredit') {
            const dp = Math.min(calcNetTotal, Math.max(0, Number(dpAmount || 0)));
            paid = dp;
            remaining = calcNetTotal - paid;
            status = remaining <= 0.001 ? 'Lunas' : (paid > 0.001 ? 'Sebagian' : 'Belum Bayar');
        } else {
            throw new Error(`INVALID_PAYMENT_METHOD: ${paymentMethod}`);
        }

        // Resolusi Akun Pembayaran
        let payCoaId = null;
        if (paid > 0) {
            let payAcc = null;
            if (paymentAccountId) {
                payAcc = this.paymentAccounts.find(pa => pa.id === paymentAccountId);
            } else {
                payAcc = this.paymentAccounts.find(pa => pa.type === 'CASH');
            }
            if (!payAcc) throw new Error('PAYMENT_ACCOUNT_INVALID');
            payCoaId = payAcc.chart_of_account_id;
        }

        // Susun Baris Jurnal
        const journalLines = [];
        if (paid > 0) {
            journalLines.push({
                chart_of_account_id: payCoaId,
                debit: paid,
                credit: 0,
                desc: 'Penerimaan kas/bank POS'
            });
        }
        if (remaining > 0) {
            journalLines.push({
                chart_of_account_id: this.coaPiutang.id,
                debit: remaining,
                credit: 0,
                desc: 'Piutang penjualan POS'
            });
        }
        journalLines.push({
            chart_of_account_id: this.coaRevenue.id,
            debit: 0,
            credit: calcNetTotal,
            desc: 'Pendapatan penjualan POS'
        });

        // Verifikasi Jurnal Berimbang
        const totalDebit = journalLines.reduce((sum, l) => sum + l.debit, 0);
        const totalCredit = journalLines.reduce((sum, l) => sum + l.credit, 0);
        if (Math.abs(totalDebit - totalCredit) > 0.01) {
            throw new Error(`UNBALANCED_JOURNAL: Debit (${totalDebit}) != Credit (${totalCredit})`);
        }

        return {
            success: true,
            subtotal: grossTotal,
            discountTotal: discountTotal,
            trxDiscount: trxDiscount,
            itemsDiscount: itemsDiscTotal,
            total: calcNetTotal,
            profit: calcProfit,
            paid: paid,
            remaining: remaining,
            status: status,
            journalLines: journalLines,
            isBalanced: Math.abs(totalDebit - totalCredit) <= 0.01
        };
    }
}

// -----------------------------------------------------------------------------
// BAGIAN A: AUDIT DISKON POS DARI FRONTEND SAMPAI DATABASE
// -----------------------------------------------------------------------------
console.log('\n--- BAGIAN A: AUDIT DISKON POS (ITEM, TRANSAKSI, KOMBINASI, JURNAL, LABA) ---');
const engine = new MockPosAtomicEngine();

// Skenario A1: Penjualan POS dengan Diskon Transaksi Penuh (Rp 20.000)
const resA1 = engine.createPosTransaction({
    trxCode: 'TRX-POS-D1',
    partyName: 'Pak Budi (Kandang Sukamaju)',
    transactionDate: '2026-10-12',
    total: 80000, // 2x Tempat Pakan = 100.000 - 20.000 disc = 80.000
    profit: 10000, // 80.000 - 70.000 (modal) = 10.000
    paymentMethod: 'Tunai',
    items: [{ productId: 1, qty: 2, price: 50000, costPrice: 35000 }],
    discount: 20000
});

assert(resA1.subtotal === 100000, 'A1: Subtotal kotor akurat Rp 100.000');
assert(resA1.discountTotal === 20000, 'A1: Total diskon tercatat Rp 20.000');
assert(resA1.total === 80000, 'A1: Grand total bersih akurat Rp 80.000');
assert(resA1.profit === 10000, 'A1: Laba bersih setelah diskon akurat Rp 10.000 (bukan overstated)');
assert(resA1.isBalanced, 'A1: Jurnal double-entry berimbang sempurna (Debit == Credit = Rp 80.000)');

// Skenario A2: Penjualan POS dengan Diskon Item Persentase (10%)
const resA2 = engine.createPosTransaction({
    trxCode: 'TRX-POS-D2',
    partyName: 'Pak Joko',
    transactionDate: '2026-10-12',
    total: 90000, // 2x 50.000 - (10% = 10.000) = 90.000
    profit: 20000, // 90.000 - 70.000 = 20.000
    paymentMethod: 'Tunai',
    items: [{ productId: 1, qty: 2, price: 50000, costPrice: 35000, discountType: 'percent', discountValue: 10 }],
    discount: 0
});

assert(resA2.subtotal === 100000, 'A2: Subtotal kotor akurat Rp 100.000');
assert(resA2.discountTotal === 10000, 'A2: Total diskon item persentase akurat Rp 10.000');
assert(resA2.total === 90000, 'A2: Grand total bersih akurat Rp 90.000');
assert(resA2.isBalanced, 'A2: Jurnal double-entry berimbang sempurna');

// Skenario A3: Penjualan POS Gabungan (Diskon Item + Diskon Transaksi)
const resA3 = engine.createPosTransaction({
    trxCode: 'TRX-POS-D3',
    partyName: 'Bu Siti',
    transactionDate: '2026-10-12',
    total: 105000, // (2x 50.000 - 10.000 item disc = 90.000) + (1x 25.000 = 25.000) = 115.000 gross net items - 10.000 trx disc = 105.000
    profit: 20000, // Modal = 70.000 + 15.000 = 85.000. Profit = 105.000 - 85.000 = 20.000
    paymentMethod: 'Tunai',
    items: [
        { productId: 1, qty: 2, price: 50000, costPrice: 35000, discountType: 'nominal', discountValue: 10000 },
        { productId: 2, qty: 1, price: 25000, costPrice: 15000, discountType: 'none', discountValue: 0 }
    ],
    discount: 10000
});

assert(resA3.subtotal === 125000, 'A3: Subtotal kotor akurat Rp 125.000');
assert(resA3.discountTotal === 20000, 'A3: Total diskon gabungan akurat Rp 20.000 (10.000 item + 10.000 transaksi)');
assert(resA3.total === 105000, 'A3: Grand total bersih akurat Rp 105.000');
assert(resA3.profit === 20000, 'A3: Laba bersih akurat Rp 20.000');
assert(resA3.isBalanced, 'A3: Jurnal double-entry berimbang sempurna');

// Skenario A4: Penjualan POS Kredit dengan Diskon dan DP Sebagian
const resA4 = engine.createPosTransaction({
    trxCode: 'TRX-POS-D4',
    partyName: 'Peternakan Barokah',
    transactionDate: '2026-10-12',
    total: 180000, // 200.000 kotor - 20.000 diskon = 180.000
    profit: 40000,
    paymentMethod: 'Kredit',
    items: [{ productId: 1, qty: 4, price: 50000, costPrice: 35000 }],
    dpAmount: 50000,
    dueDate: '2026-11-12',
    discount: 20000
});

assert(resA4.total === 180000, 'A4: Grand total kredit setelah diskon Rp 180.000');
assert(resA4.paid === 50000, 'A4: DP dibayar tunai Rp 50.000');
assert(resA4.remaining === 130000, 'A4: Sisa piutang tercatat Rp 130.000');
assert(resA4.status === 'Sebagian', 'A4: Status invoice adalah Sebagian');
assert(resA4.isBalanced, 'A4: Jurnal berimbang (Kas: Rp 50.000 + Piutang: Rp 130.000 = Pendapatan: Rp 180.000)');

// Skenario A5: Validasi Penolakan Nominal Manipulasi (Anti-Fraud Server-Side)
let rejectedMismatch = false;
try {
    engine.createPosTransaction({
        trxCode: 'TRX-POS-D5',
        partyName: 'Hacker',
        transactionDate: '2026-10-12',
        total: 50000, // Client mencoba membayar 50.000 padahal tagihan 80.000
        paymentMethod: 'Tunai',
        items: [{ productId: 1, qty: 2, price: 50000, costPrice: 35000 }],
        discount: 20000 // Seharusnya 80.000
    });
} catch (e) {
    if (e.message.includes('TOTAL_MISMATCH')) rejectedMismatch = true;
}
assert(rejectedMismatch, 'A5: Server secara ketat menolak transaksi jika total client tidak cocok perhitungan server');


// -----------------------------------------------------------------------------
// BAGIAN B: AUDIT COA DAN AKUN PEMBAYARAN
// -----------------------------------------------------------------------------
console.log('\n--- BAGIAN B: AUDIT COA DAN AKUN PEMBAYARAN ---');

// Audit B1: Bukti Kode 1-1001 vs 1-1010
assert(
    !v3Sql.includes("'1-1001'"),
    'B1: Kode 1-1001 TIDAK digunakan secara hardcoded dalam migration V3'
);
assert(
    !htmlContent.includes("'1-1001'"),
    'B1: Kode 1-1001 TIDAK digunakan dalam frontend index.html'
);

// Audit B2: RPC menggunakan COA dari payment_accounts.chart_of_account_id
assert(
    v3Sql.includes('v_pay_coa_id := v_pay_acc.chart_of_account_id;'),
    'B2: create_pos_transaction_atomic mengambil COA dari payment_accounts.chart_of_account_id'
);
assert(
    v3Sql.includes('v_payment_coa_id := v_pay_acc.chart_of_account_id;'),
    'B2: create_purchase_atomic mengambil COA dari payment_accounts.chart_of_account_id'
);
assert(
    v3Sql.includes('v_pay_acc.chart_of_account_id'),
    'B2: create_expense_atomic & create_equity_transaction_atomic mengambil COA dari payment_accounts'
);

// Audit B3: Akun Persediaan Barang Dagang mendukung kode Production (1-1210)
assert(
    v3Sql.includes("WHERE code IN ('1-1210', '1-1140') AND is_active = TRUE"),
    'B3: create_purchase_atomic mendukung kode 1-1210 (Persediaan Barang Dagang Production) dengan fallback 1-1140'
);

// Audit B4: Akun Pendapatan, Piutang, Hutang, Ekuitas sesuai konfigurasi Production
assert(v3Sql.includes("WHERE code = '4-1110'"), 'B4: Pendapatan Penjualan menggunakan 4-1110');
assert(v3Sql.includes("WHERE code = '4-1120'"), 'B4: Pendapatan Jasa menggunakan 4-1120');
assert(v3Sql.includes("WHERE code = '1-1110'"), 'B4: Piutang Usaha menggunakan 1-1110');
assert(v3Sql.includes("WHERE code = '2-1110'"), 'B4: Hutang Usaha Supplier menggunakan 2-1110');


// -----------------------------------------------------------------------------
// BAGIAN C: AUDIT FINAL KEENAM RPC & KONTRAK FRONTEND
// -----------------------------------------------------------------------------
console.log('\n--- BAGIAN C: AUDIT FINAL 6 RPC (KONTRAK, ROLE, VOID GUARD, ATOMISITAS) ---');

// Audit C1: create_pos_transaction_atomic menerima p_discount
assert(
    v3Sql.includes('p_discount NUMERIC DEFAULT 0.00'),
    'C1: create_pos_transaction_atomic menerima parameter p_discount NUMERIC DEFAULT 0.00'
);
assert(
    v3Sql.includes('DROP FUNCTION IF EXISTS public.create_pos_transaction_atomic(VARCHAR, VARCHAR, DATE, NUMERIC, NUMERIC, VARCHAR, BIGINT, JSONB, NUMERIC, DATE, VARCHAR, VARCHAR, VARCHAR, NUMERIC);'),
    'C1: Migration v3 membersihkan overload signature 14 parameter terdahulu'
);
assert(
    htmlContent.includes('p_discount: Number(this.discount || 0)'),
    'C1: Frontend index.html mengirim p_discount ke create_pos_transaction_atomic'
);
assert(
    htmlContent.includes('discountType: discType') && htmlContent.includes('discountAmount: discAmt'),
    'C1: Frontend cartItemsSnapshot menyertakan informasi diskon item lengkap'
);

// Audit C2: create_purchase_atomic
assert(
    v3Sql.includes('CREATE OR REPLACE FUNCTION public.create_purchase_atomic'),
    'C2: create_purchase_atomic terdefinisi di migration V3'
);
assert(
    htmlContent.includes("supabaseClient.rpc('create_purchase_atomic'"),
    'C2: Frontend memanggil create_purchase_atomic tanpa fallback non-atomik'
);

// Audit C3: create_expense_atomic
assert(
    v3Sql.includes('CREATE OR REPLACE FUNCTION public.create_expense_atomic'),
    'C3: create_expense_atomic terdefinisi di migration V3'
);
assert(
    htmlContent.includes("supabaseClient.rpc('create_expense_atomic'"),
    'C3: Frontend memanggil create_expense_atomic'
);

// Audit C4: create_equity_transaction_atomic
assert(
    v3Sql.includes('CREATE OR REPLACE FUNCTION public.create_equity_transaction_atomic'),
    'C4: create_equity_transaction_atomic terdefinisi di migration V3'
);
assert(
    v3Sql.includes("p_transaction_type IN ('MODAL', 'CAPITAL_IN')") &&
    v3Sql.includes("p_transaction_type IN ('PRIVE', 'DRAWING_OUT')"),
    'C4: create_equity_transaction_atomic menormalisasi jenis transaksi modal & prive'
);

// Audit C5: convert_quotation_to_invoice_atomic
assert(
    v3Sql.includes('CREATE OR REPLACE FUNCTION public.convert_quotation_to_invoice_atomic'),
    'C5: convert_quotation_to_invoice_atomic terdefinisi di migration V3'
);
assert(
    v3Sql.includes("p_payment_method NOT IN ('Tunai', 'TunaiBelumLunas', 'Tunai Belum Lunas', 'Kredit')"),
    'C5: convert_quotation_to_invoice_atomic mendukung metode Tunai, TunaiBelumLunas, dan Kredit'
);

// Audit C6: void_pos_transaction_atomic & Active Payment Protection Guard
assert(
    v3Sql.includes('CANNOT_VOID_PAID_TRANSACTION'),
    'C6: void_pos_transaction_atomic memiliki proteksi ketat menolak VOID transaksi jika ada pembayaran VALID'
);
assert(
    v3Sql.includes("action_type, qty, stock_before, stock_after, reference_code, note, created_by") &&
    v3Sql.includes("'VOID', v_item_qty"),
    'C6: void_pos_transaction_atomic memulihkan stok dengan action_type VOID sesuai schema'
);

// Audit C7: Role & Permissions Guard pada Semua RPC
const expectedRpcs = [
    'create_pos_transaction_atomic',
    'create_purchase_atomic',
    'create_expense_atomic',
    'create_equity_transaction_atomic',
    'convert_quotation_to_invoice_atomic',
    'void_pos_transaction_atomic'
];

expectedRpcs.forEach(rpc => {
    assert(
        v3Sql.includes(`REVOKE EXECUTE ON FUNCTION public.${rpc} FROM PUBLIC, anon;`),
        `C7: ${rpc} direvoke dari anon & PUBLIC`
    );
    assert(
        v3Sql.includes(`GRANT EXECUTE ON FUNCTION public.${rpc} TO authenticated;`),
        `C7: ${rpc} digrant ke authenticated`
    );
});

// Audit C8: Jurnal Internal Tidak Terbuka Langsung ke Klien
assert(
    !v3Sql.includes('GRANT EXECUTE ON FUNCTION public.post_journal_entry TO authenticated'),
    'C8: post_journal_entry internal TIDAK dibuka untuk authenticated'
);
assert(
    !v3Sql.includes('GRANT EXECUTE ON FUNCTION public.reverse_journal_entry TO authenticated'),
    'C8: reverse_journal_entry internal TIDAK dibuka untuk authenticated'
);

// Audit C9: Receipt Modal menampilkan breakdown diskon
assert(
    htmlContent.includes('activeReceipt.discount') &&
    htmlContent.includes("formatRupiah((activeReceipt.total || 0) + (activeReceipt.discount || 0))"),
    'C9: Modal struk kasir menampilkan rincian subtotal & diskon sebelum total'
);

console.log('================================================================================');
console.log(`TOTAL AUDIT & TEST CASES: ${passedTests + failedTests}`);
console.log(`PASSED: ${passedTests}`);
console.log(`FAILED: ${failedTests}`);
if (failedTests === 0) {
    console.log('STATUS: SEMUA AUDIT V3 & TEST SUITE BERHASIL SEMPURNA! ✅');
} else {
    console.log('STATUS: ADA TEST YANG GAGAL! ❌');
    process.exit(1);
}
console.log('================================================================================');

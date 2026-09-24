# DOKUMENTASI MIGRASI FONDASI KEUANGAN SUPABASE
## AGRA JAYA POS — PHASE #01

File migrasi utama: `supabase/migrations/20260924_financial_foundation.sql`

### 1. Ringkasan Objek Database yang Dibuat:
* **Tabel Baru (6 Tabel):**
  1. `chart_of_accounts`: Master bagan akun (COA) dengan 24 akun standar minimum (Kas, Bank, QRIS, Piutang, Persediaan, Hutang, Modal, Prive, Pendapatan, HPP, Beban).
  2. `payment_accounts`: Pemetaan metode pembayaran kasir/bank ke akun COA.
  3. `journal_entries`: Header voucher jurnal akuntansi double-entry dengan partial unique index untuk idempotency.
  4. `journal_lines`: Rincian baris debit dan kredit dengan constraint strict balancing.
  5. `expenses`: Tabel pencatatan beban operasional non-inventaris toko.
  6. `equity_transactions`: Tabel pencatatan setoran modal dan prive pemilik.

* **Extension Non-Destruktif pada Tabel Eksisting:**
  * `transactions`: penambahan `payment_account_id`, `invoice_id`, `voided_at`, `voided_by`.
  * `invoices`: penambahan `transaction_id`, `voided_at`, `voided_by`.
  * `purchases`: penambahan `payment_account_id`, `voided_at`, `voided_by`.
  * `payment_history`: penambahan `payment_account_id`, `status` (VALID/VOID), `voided_at`, `voided_by`, `note`.

* **Stored Procedures & Engine (RPC):**
  1. `post_journal_entry()`: Generator jurnal atomis dengan validasi double-entry mutlak `SUM(Debit) = SUM(Credit)`, verifikasi akun aktif, dan pencegahan duplikasi posting (idempotent).
  2. `reverse_journal_entry()`: Generator pembalik jurnal VOID otomatis tanpa mengubah atau menghapus jurnal asli (*Strict Immutability*).

* **Keamanan Row Level Security (RLS):**
  * Seluruh tabel baru dilindungi RLS.
  * Role `owner` memiliki akses penuh.
  * Role `admin` memiliki akses operasional dan pelaporan.
  * Role `kasir` hanya memiliki hak akses baca akun kas/bank dan tulis pembayaran.
  * Akses `anon` (publik) ditolak 100%.

### 2. Cara Eksekusi pada Supabase Project:
Buka **Supabase Dashboard** -> Project `fjudjicfgvpilvtpsfde` -> **SQL Editor** -> Salin seluruh isi file `supabase/migrations/20260924_financial_foundation.sql` -> Klik **Run**.
Semua perintah bersifat *idempotent* (`IF NOT EXISTS`, `ON CONFLICT DO NOTHING`) sehingga aman dijalankan berulang tanpa merusak data yang sudah ada.

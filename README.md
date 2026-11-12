# Warehouse Sistem 4 Keledai

Sistem gudang untuk usaha multi-brand (contoh: **Zerodeo** dan **Depot Kimia**), tersambung ke database **Supabase**.
Semua HP dan laptop tim melihat data yang sama.

**Alur harian**

```
Barang masuk (supplier, surat jalan, foto bukti)  ──►  stok bertambah per tanggal ED
Barang keluar harian (Shopee/TikTok/Tokopedia/B2B…)  ──►  stok berkurang otomatis, ED terdekat dulu
Stock opname mingguan (hitung fisik)  ──►  owner setujui  ──►  stok sistem = stok fisik
Export Excel data masuk/keluar/kartu stok  ──►  pembukuan (Accurate, dll.)
```

| Peran | Bisa apa | Lihat HPP? |
|---|---|---|
| **Owner** | Semua, termasuk menyetujui stock opname & barang keluar non-penjualan, kelola produk & pengguna | Ya |
| **Staf gudang** | Barang masuk, barang keluar, stock opname, cek stok, cetak label | Tidak |
| **Sales / Marketplace** | Lihat stok & riwayat barang keluar, harga jual | Tidak |
| **Finance** | Verifikasi barang masuk, nilai stok, kartu stok, export Excel | Ya |

## Aturan yang dijaga database

- Stok **tidak bisa diedit langsung** dan **tidak bisa minus**. Stok hanya berubah lewat barang masuk, barang keluar, atau stock opname.
- **Riwayat stok permanen**: setiap perubahan tercatat (siapa, kapan, dokumen apa) dan tidak bisa dihapus.
- **ED wajib** untuk produk personal care. Barang keluar otomatis mengambil **ED terdekat dulu**.
  Barang kedaluwarsa tidak bisa terjual, hanya bisa dikeluarkan sebagai "Rusak / kedaluwarsa".
- Barang keluar **sampel / rusak / internal** yang diinput staf baru mengurangi stok **setelah disetujui owner**.
- **Stock opname**: staf menghitung tanpa melihat angka sistem, selisih wajib diberi alasan, owner menyetujui.
- HPP & nilai Rupiah **tidak terkirim** ke HP staf dan sales (disaring di database, bukan hanya disembunyikan di layar).

## Menyambungkan ke Supabase (sekali saja)

1. **Buat project** di [supabase.com](https://supabase.com) → *New project* → region **Southeast Asia (Singapore)**. Simpan password database.
2. **Pasang database**: menu **SQL Editor** → *New query* → salin **seluruh isi** `supabase/setup.sql` → tempel → **Run**.
   Harus muncul *Success. No rows returned*. Lakukan ini **sebelum** ada yang mendaftar akun.
3. **Pengaturan login**: menu **Authentication**
   - *URL Configuration* → **Site URL** = `https://akarlabs.github.io/warehouse4-keledai/`
   - *Sign In / Providers* → *Email*: matikan **Confirm email** supaya tim bisa langsung masuk setelah daftar
     (kalau dibiarkan menyala, tiap orang harus klik link konfirmasi di email dulu).
4. **Ambil kunci**: *Project Settings* → **API Keys**. Salin **Project URL** dan kunci **anon / publishable**
   (yang boleh dipakai di browser). **Jangan** pakai kunci `service_role` / `secret`.
5. **Isi `config.js`** di GitHub: buka file `config.js` → ikon pensil (Edit) → isi kedua nilai → *Commit changes*.
   ```js
   window.APP_CONFIG = {
     supabaseUrl: "https://xxxxxxxx.supabase.co",
     supabaseAnonKey: "eyJhbGciOi…  atau  sb_publishable_…"
   };
   ```
   Kunci anon/publishable memang aman ditaruh di sini; data dilindungi aturan akses di database.
6. Buka aplikasi → **Pasang pertama kali (khusus Owner)** → daftar dengan email Owner. **Akun pertama otomatis menjadi Owner.**
7. Owner membuka menu **Pengguna** → *Buat akun tim*: isi ID (mis. `gudang1`), nama, peran, password awal → *Buat akun*.
   Tim masuk di halaman depan cukup dengan **ID + password**; dashboard terbuka sesuai perannya.
   (Butuh *Confirm email* dimatikan di langkah 3.)

## Mulai memakai

1. **Produk**: Beranda / menu *Produk* → *Unduh template Excel* → isi (kode SKU, nama, kode brand, wajib ED, HPP, harga jual) → *Unggah file Excel* → cek → *Simpan*. Panduan membuat kode SKU ada di aplikasi dan di sheet *Petunjuk*. Staf gudang juga bisa mengunggah; barangnya menunggu ACC.
2. **Stok awal**: *Template stok awal* → isi SKU, ED, jumlah hasil hitung fisik hari ini → *Unggah stok awal*.
3. **Setiap hari**: staf input *Barang masuk* & *Barang keluar* dengan mengetik sebagian kode SKU / nama barang lalu memilih dari daftar.
   Barang keluar juga bisa dari **PDF resi** marketplace, dan **SKU bundling** langsung memotong stok isinya.
4. **Setiap minggu**: *Stock opname* → hitung semua barang → kirim → owner setujui.
5. **Pembukuan**: *Export Excel* → pilih data & periode. File berisi lembar *Data* dan *Ringkasan* (jumlah baris & total kontrol).

## Tracker resi & bundling

- **Tracker resi**: setiap PDF resi yang diunggah Sales (menu *Tracker resi*) atau Gudang (menu *Barang keluar*) tercatat sebagai satu pesanan.
  Status: *Perlu diproses* → *Sedang disiapkan gudang* → *Sudah keluar*. Satu no. pesanan hanya bisa tercatat dan keluar sekali;
  divisi yang mengunggah belakangan diberi tahu siapa yang sudah menginput dan sampai mana prosesnya.
- **Antrean gudang**: pesanan dari Sales muncul di *Barang keluar → Pesanan menunggu diproses*; gudang cukup klik *Siapkan*, cek daftar ambil, simpan.
- **SKU bundling**: dibuat Sales/Owner satu per satu atau lewat *template Excel bundling* (1 baris = 1 barang isi paket).

## Struktur folder

```
index.html                   Aplikasi (satu file, tanpa build) — dibuka lewat GitHub Pages
config.js                    Alamat & kunci Supabase (isi di langkah 5)
supabase/setup.sql           Database produksi — jalankan sekali di SQL Editor
supabase/tests/              Uji otomatis database (run_tests.sh)
supabase/migrations/         Versi lengkap multi gudang & rak (untuk nanti, belum dipakai)
prototipe/                   Demo tanpa database & prototipe versi lengkap
```

## Pengujian

- `supabase/tests/run_tests.sh`: 76 pemeriksaan database (stok tidak minus, FEFO, persetujuan, stock opname,
  HPP tidak bocor ke staf/sales, riwayat tidak bisa diubah, dll.). Butuh PostgreSQL 15+ lokal.
- Aplikasi juga sudah diuji ujung-ke-ujung di Chromium terhadap PostgREST (komponen yang sama dengan Supabase):
  daftar & aktivasi akun, impor Excel, barang masuk dengan foto, scan QR dari foto, barang keluar FEFO,
  persetujuan, stock opname, export Excel (jumlah & total cocok dengan database), hak akses per peran.

## Catatan

- Foto bukti terima diperkecil otomatis (±50–100 KB) dan disimpan di database. Paket gratis Supabase (500 MB) cukup untuk ribuan foto.
- Paket gratis Supabase akan **dijeda kalau tidak dipakai 7 hari**. Untuk pemakaian harian tidak masalah; untuk jaminan selalu aktif, gunakan paket Pro.
- Cadangan data: Supabase → *Database* → *Backups*, atau rutin *Export Excel* kartu stok.

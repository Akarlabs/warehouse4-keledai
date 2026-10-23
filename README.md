# Warehouse Sistem 4 Keledai

Aplikasi gudang sederhana untuk usaha multi-brand (contoh: **Zerodeo** dan **Depot Kimia**).
Satu aplikasi, empat dashboard yang saling terhubung:

| Peran | Yang dikerjakan | Lihat HPP? |
|---|---|---|
| **Owner** | Pantau semua, setujui cek mingguan & keluar manual, tambah produk | Ya |
| **Staf Gudang** | Kemas & kirim pesanan (scan SKU), terima barang, keluar manual, cek mingguan, cetak label | Tidak |
| **Sales / Marketplace** | Impor pesanan Shopee/Tokopedia/TikTok, buat pesanan B2B & jual langsung, lihat stok tersedia | Tidak (hanya harga jual) |
| **Finance** | Faktur & piutang B2B, verifikasi barang masuk, laporan & export untuk pembukuan | Ya |

> **Status:** `index.html` adalah **demo yang bisa dipakai mencoba alur** (data contoh, tersimpan di browser).
> Database produksi (Supabase) sudah disiapkan dan diuji di folder `supabase/`. Lihat [Rencana ke produksi](#rencana-ke-produksi).

## Tampilan

Mengikuti design system **Winwin Berkah Amanah (WBA)**: logo Winwin asli (ikon di header, putih di tema gelap),
warna `brand-green` / `royal-blue` / `azure`, huruf Montserrat (judul & angka) dan Figtree (isi).
Layar loading memakai jenis *Denyut* dari WBA Design System dan hanya tampil saat pertama kali dibuka (belum ada data di perangkat).

## Alur yang tersambung

```
Sales impor / buat pesanan ──► Staf kemas (scan SKU, ambil ED terdekat) ──► Dikirim
                                                                           │
                                       B2B ──► Finance buat faktur ──► Catat pembayaran
Staf terima barang (supplier, surat jalan, foto bukti) ──► Finance verifikasi
Staf hitung stok mingguan ──► Owner setujui selisih
Staf ajukan keluar manual (sampel/rusak) ──► Owner setujui ──► stok berkurang
```

## Fitur utama

- **Pantau ED (kedaluwarsa)** untuk produk personal care. ED wajib diisi saat barang masuk; produk kimia tanpa ED cukup jumlahnya.
- **FEFO otomatis**: saat mengemas, sistem memberi tahu ED mana yang diambil dulu. Barang kedaluwarsa tidak bisa terjual, hanya bisa dikeluarkan sebagai "Rusak / kedaluwarsa".
- **Scan pakai kode SKU**, tidak wajib barcode pabrik:
  - Cetak **label QR berisi SKU** dari menu *Produk & label*, tempel di kardus/kemasan.
  - Tombol **Scan** → *Buka kamera* (scan langsung) atau *Foto barcode / QR*.
  - Tanpa label pun bisa: ketik sebagian SKU atau nama produk, ada saran otomatis.
  - Barcode pabrik (EAN) tetap terbaca kalau diisi di data produk.
- **Barang masuk** lengkap: pilih/tambah supplier, no. & tanggal surat jalan, foto bukti terima, nama penerima.
- **Anti dobel impor marketplace**: file yang sama diimpor dua kali tidak menggandakan pesanan. SKU paket/bundling dipetakan sekali ke produk satuan.
- **Cek mingguan**: staf menghitung fisik tanpa melihat angka sistem, selisih wajib diberi alasan, owner menyetujui.
- **Riwayat stok permanen**: setiap perubahan stok tercatat (siapa, kapan, dokumen apa).
- **Export** penjualan, stok & nilai, pembelian per supplier, piutang, riwayat — dengan total kontrol untuk dicocokkan.

## Cara mencoba

**Paling mudah – GitHub Pages (gratis, kamera HP berfungsi):**
1. Di repo ini buka **Settings → Pages**.
2. *Source*: **Deploy from a branch**, *Branch*: `main`, folder `/ (root)`, lalu **Save**.
3. Tunggu ±1 menit, buka alamat yang muncul (mis. `https://namaakun.github.io/warehouse-4-keledai/`) dari HP.
4. Pilih peran di bagian atas (**Masuk sebagai**) untuk berpindah dashboard.

> GitHub Pages untuk repo **private** butuh paket GitHub berbayar. Alternatif gratis: buat repo public,
> atau upload `index.html` ke Netlify/Vercel/Cloudflare Pages (drag & drop).

**Di komputer:** unduh `index.html` lalu buka di Chrome. Kamera langsung butuh alamat `https://`, jadi
di file lokal gunakan *Foto barcode / QR* atau ketik SKU.

Data contoh tersimpan di browser masing-masing. Tombol **Reset data contoh** mengembalikannya ke awal.

## Struktur folder

```
index.html                         Aplikasi demo (satu file, tanpa build)
prototipe/
  versi-lengkap-multigudang.html   Prototipe versi besar: multi gudang, rak, transfer antar kota
supabase/
  migrations/001_schema.sql        Tabel: produk, batch/ED, gudang, dokumen, pesanan, faktur
  migrations/002_functions.sql     Logika stok (FEFO, scan, opname, approval, impor marketplace)
  migrations/003_views.sql         Laporan & export untuk finance
  migrations/004_security.sql      Hak akses per peran (RLS)
  tests/                           105 skenario uji otomatis
```

## Rencana ke produksi

Database di `supabase/` sudah memenuhi aturan penting dan lolos 105 uji otomatis:
stok tidak bisa minus, riwayat stok tidak bisa diedit/dihapus, impor pesanan tidak bisa dobel,
selisih wajib disetujui orang lain, dan HPP tidak terbaca oleh peran yang tidak berhak.

Langkah berikutnya:
1. Buat project di [supabase.com](https://supabase.com) (gratis untuk mulai).
2. Jalankan isi `supabase/migrations/001` s/d `004` berurutan di **SQL Editor**.
3. Sambungkan tampilan aplikasi ke database (login per orang, data dibagi antar HP/laptop).
4. Uji paralel 1–2 bulan bersama pencatatan lama sebelum dipakai penuh.

Database sudah mendukung multi gudang & rak; untuk tahap UMKM cukup pakai satu gudang dan satu lokasi.

### Menjalankan uji database

Butuh PostgreSQL 15+ lokal:

```bash
DB=keledai_test ./supabase/tests/run_tests.sh
```

## Data contoh

Produk Zerodeo dan Depot Kimia diambil dari file master produk (nama, isi, SKU & HPP Depot Kimia).
SKU/barcode/harga jual Zerodeo, nomor batch, ED, stok, pelanggan, dan pesanan adalah **contoh** dan perlu diganti data asli.

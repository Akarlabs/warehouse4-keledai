# Warehouse Sistem 4 Keledai

Sistem gudang multi-brand untuk **4 Keledai** (brand: **Zerodeo** — personal care/deodoran; **Depot Kimia** — bahan kimia). Mengelola stok, barang masuk/keluar, bundling marketplace, tracker resi, stock opname, dan CRM sebaran area pengiriman. Semua UI & percakapan dalam Bahasa Indonesia.

## Arsitektur

- **Frontend**: `index.html` — satu file SPA, vanilla JS, **tanpa build/framework**. Pola: global state `G`, views `V.*`, actions `A.*`, `renderView()`. CDN: supabase-js 2.117.2, xlsx 0.18.5, pdfjs-dist 3.11.174.
- **CRM**: `crm.html` — halaman terpisah (sebaran provinsi/kota pengiriman), baca view `v_crm`, login memakai sesi Supabase yang sama (same-origin).
- **Backend**: Supabase (Postgres). Project ref `rvrypwvwtgqzgailgnbg`. Konfigurasi di `config.js` → `window.APP_CONFIG` (`supabaseUrl` + anon/publishable key).
- **Hosting**: GitHub Pages, repo `akarlabs/warehouse4-keledai`. Rilis dengan push dari GitHub Desktop.
- **Skema SQL lengkap**: `supabase/setup.sql` (sumber kebenaran untuk tabel, fungsi RPC, view, grant, RLS).

## Prinsip keamanan database — WAJIB dijaga

- Semua **tulis** lewat fungsi `security definer` (RPC). App hanya **baca** view `v_*`.
- RLS aktif di semua tabel; `revoke all from anon, authenticated` lalu grant selektif.
- **Jangan pernah** pakai `service_role`/secret key di app — hanya anon/publishable key.
- HPP (`cost`) hanya untuk owner/ops/finance via `can_see_cost()`; view menull-kan cost untuk peran lain. Jaga ini saat menambah view/fitur.
- `moves` = ledger **permanen** (trigger immutable), tidak bisa dihapus. Koreksi = gerakan baru, bukan edit/hapus.
- Stok **tidak bisa minus**. Keluar barang FEFO via `_plan_out`.

## Peran pengguna

`_require(...)` memperlakukan **ops seperti owner**. Peran: `owner`, `ops` (Head Operasional), `staf` (gudang), `sales` (marketing), `finance`. Login: user ketik **ID**, app memetakan ke email internal `<id>@4keledai.id` (bukan email asli, tidak ada yang dikirim).

## Model data inti

- `products` (sku, name, brand_code, cost, price, min_stock, track_ed, active, approved)
- `lots` (sku, ed, qty) — stok per tanggal ED; `moves` — ledger (kind: masuk/keluar/so)
- `bundles` + `bundle_items` — paket; `create_outbound` memecah bundle ke komponen saat keluar
- `orders` — tracker resi (+ `province`, `city` untuk CRM); `outbounds`/`outbound_lines`; `inbounds`/`inbound_lines`; `opnames`/`opname_lines`
- Views: `v_stock`, `v_lots`, `v_moves`, `v_orders`, `v_crm`, `v_bundles`, `v_outbounds`, dll.

## Konvensi kode SKU

Format `BRAND-JENIS-VARIAN-UKURAN` (mis. `ZDO-RO-CGW-40`, `CHEM-H2SO4-1KG`). Bundling: `ZDO-BDL-<isi>-<ukuran>` — `CGW2` = 2 pcs, `CGW3` = 3 pcs, `CGWMXF` = campur. **Isi paket wajib kode bahan yang punya stok, bukan kode bundling lain.** Depot Kimia memakai kode SKU bawaannya; jangan diubah tanpa diminta.

## Uji & rilis

- Uji DB: `supabase/tests/run_tests.sh` (psql + `supabase/tests/shim.sql` memalsukan skema auth).
- Uji e2e: harness Playwright (PostgREST + server auth palsu) — ada di folder scratchpad saat dikembangkan; jalankan sebelum rilis perubahan besar.
- Alur rilis: **edit → uji → migrasi Supabase → commit → push (GitHub Desktop) → hard-refresh (Ctrl+Shift+R)**.
- Perubahan database diterapkan via migrasi Supabase; perubahan `index.html`/`crm.html` via GitHub.
- Supabase: **Authentication → Sign In/Providers → Email → Confirm email = OFF** (login pakai ID).

## Catatan & hal yang belum selesai

- CRM: area pengiriman dibaca dari teks resi secara **best-effort**; terisi hanya dari resi yang diinput **sejak fitur aktif** (tidak surut). Kolom area bisa dikoreksi manual di rincian resi.
- HPP sebagian produk baru masih kosong → laporan margin belum akurat sampai diisi.
- Belum ada koneksi real-time ke Shopee/TikTok; resi masuk lewat **unggah PDF**.
- Tombol barang keluar dari resi meminta **konfirmasi** sebelum memotong stok.
- Tombol "CRM Area" di menu hanya untuk owner, ops, sales.

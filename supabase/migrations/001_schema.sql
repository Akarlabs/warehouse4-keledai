-- =====================================================================
-- Warehouse Sistem 4 Keledai — 001 Skema tabel
-- Prinsip:
--   * Stok HANYA berubah lewat buku besar stok (stock_moves), tidak bisa
--     diedit/dihapus. Saldo (stock_balances) dihitung otomatis & tidak
--     boleh minus.
--   * Setiap barang selalu punya batch. Produk tanpa batch memakai
--     batch bawaan bernama '-'.
--   * Dokumen (masuk, keluar, transfer, opname, penyesuaian) hanya bisa
--     diubah selama status draft. Posting/approval lewat fungsi RPC.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Pengaturan perusahaan (1 baris)
-- ---------------------------------------------------------------------
create table public.settings (
  id                   int primary key default 1 check (id = 1),
  company_name         text not null default 'Perusahaan Saya',
  company_address      text,
  company_phone        text,
  company_npwp         text,
  timezone             text not null default 'Asia/Jakarta',
  default_tax_percent  numeric(5,2) not null default 0 check (default_tax_percent >= 0),
  expiry_warning_days  int not null default 90 check (expiry_warning_days >= 0),
  invoice_footer       text,
  updated_at           timestamptz not null default now()
);
insert into public.settings default values;

-- ---------------------------------------------------------------------
-- Master data
-- ---------------------------------------------------------------------
create table public.brands (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique check (code ~ '^[A-Z0-9_-]{1,20}$'),
  name          text not null check (length(trim(name)) > 0),
  legal_entity  text,
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);

create table public.warehouses (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (code ~ '^[A-Z0-9_-]{1,20}$'),
  name        text not null check (length(trim(name)) > 0),
  city        text,
  address     text,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table public.locations (
  id            uuid primary key default gen_random_uuid(),
  warehouse_id  uuid not null references public.warehouses(id),
  code          text not null check (code ~ '^[A-Z0-9_.-]{1,30}$'),
  name          text,
  kind          text not null default 'rak'
                check (kind in ('penerimaan','rak','pengiriman','karantina')),
  barcode       text not null unique,
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  unique (warehouse_id, code)
);
create index on public.locations (warehouse_id);

create table public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  email         text,
  full_name     text,
  role          text not null default 'gudang'
                check (role in ('owner','admin','gudang','finance','sales')),
  warehouse_id  uuid references public.warehouses(id),
  active        boolean not null default false,
  created_at    timestamptz not null default now()
);

create table public.products (
  id             uuid primary key default gen_random_uuid(),
  brand_id       uuid not null references public.brands(id),
  sku            text not null unique check (length(trim(sku)) > 0),
  barcode        text unique,
  name           text not null check (length(trim(name)) > 0),
  category       text,
  uom            text not null default 'pcs',
  track_batch    boolean not null default true,
  min_stock      numeric(14,3) not null default 0 check (min_stock >= 0),
  default_cost   numeric(16,2) not null default 0 check (default_cost >= 0),
  default_price  numeric(16,2) not null default 0 check (default_price >= 0),
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index on public.products (brand_id);
create index on public.products (lower(sku));

create table public.batches (
  id           uuid primary key default gen_random_uuid(),
  product_id   uuid not null references public.products(id),
  batch_no     text not null check (length(trim(batch_no)) > 0),
  expiry_date  date,
  unit_cost    numeric(16,2) not null default 0 check (unit_cost >= 0),
  created_at   timestamptz not null default now(),
  unique (product_id, batch_no)
);

create table public.customers (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique check (code ~ '^[A-Z0-9_-]{1,20}$'),
  name                text not null check (length(trim(name)) > 0),
  contact_name        text,
  phone               text,
  email               text,
  npwp                text,
  address             text,
  city                text,
  payment_terms_days  int not null default 0 check (payment_terms_days >= 0),
  credit_limit        numeric(16,2) not null default 0 check (credit_limit >= 0),
  active              boolean not null default true,
  created_at          timestamptz not null default now()
);

create table public.stores (
  id              uuid primary key default gen_random_uuid(),
  channel         text not null
                  check (channel in ('shopee','tiktok','tokopedia','lazada','blibli','website','lainnya')),
  name            text not null check (length(trim(name)) > 0),
  brand_id        uuid references public.brands(id),
  warehouse_id    uuid not null references public.warehouses(id),
  import_mapping  jsonb,
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  unique (channel, name)
);

-- SKU marketplace -> produk. Satu SKU marketplace boleh dipetakan ke
-- beberapa produk (paket/bundling) dengan multiplier masing-masing.
create table public.sku_mappings (
  id            uuid primary key default gen_random_uuid(),
  store_id      uuid references public.stores(id) on delete cascade, -- null = berlaku semua toko
  external_sku  text not null check (length(trim(external_sku)) > 0),
  product_id    uuid not null references public.products(id),
  multiplier    numeric(14,3) not null default 1 check (multiplier > 0),
  created_at    timestamptz not null default now(),
  unique nulls not distinct (store_id, external_sku, product_id)
);
create index on public.sku_mappings (lower(external_sku));

-- ---------------------------------------------------------------------
-- Penomoran dokumen
-- ---------------------------------------------------------------------
create table public.doc_counters (
  prefix   text not null,
  period   text not null,
  last_no  int  not null default 0,
  primary key (prefix, period)
);

-- ---------------------------------------------------------------------
-- Buku besar stok & saldo
-- ---------------------------------------------------------------------
create table public.stock_moves (
  id            bigint generated always as identity primary key,
  moved_at      timestamptz not null default now(),
  product_id    uuid not null references public.products(id),
  batch_id      uuid not null references public.batches(id),
  location_id   uuid not null references public.locations(id),
  warehouse_id  uuid not null references public.warehouses(id),
  qty           numeric(14,3) not null check (qty <> 0),
  unit_cost     numeric(16,2) not null default 0,
  move_type     text not null check (move_type in
                ('masuk','keluar','transfer_keluar','transfer_masuk',
                 'penyesuaian','opname','pindah_lokasi')),
  doc_type      text not null,
  doc_id        uuid not null,
  doc_no        text not null,
  note          text,
  created_by    uuid
);
create index on public.stock_moves (product_id, moved_at);
create index on public.stock_moves (warehouse_id, moved_at);
create index on public.stock_moves (doc_type, doc_id);
create index on public.stock_moves (moved_at);

create table public.stock_balances (
  batch_id      uuid not null references public.batches(id),
  location_id   uuid not null references public.locations(id),
  product_id    uuid not null references public.products(id),
  warehouse_id  uuid not null references public.warehouses(id),
  qty           numeric(14,3) not null default 0 check (qty >= 0),
  updated_at    timestamptz not null default now(),
  primary key (batch_id, location_id)
);
create index on public.stock_balances (product_id, warehouse_id);
create index on public.stock_balances (warehouse_id);

-- ---------------------------------------------------------------------
-- Barang masuk
-- ---------------------------------------------------------------------
create table public.inbounds (
  id            uuid primary key default gen_random_uuid(),
  doc_no        text not null unique default '',
  warehouse_id  uuid not null references public.warehouses(id),
  source        text not null default 'supplier' check (source in
                ('supplier','retur_marketplace','retur_b2b','produksi','saldo_awal','lainnya')),
  partner_name  text,
  reference_no  text,
  mode          text not null default 'scan' check (mode in ('scan','manual')),
  status        text not null default 'draft' check (status in ('draft','posted','cancelled')),
  note          text,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  posted_by     uuid,
  posted_at     timestamptz
);
create index on public.inbounds (warehouse_id, status);

create table public.inbound_lines (
  id           uuid primary key default gen_random_uuid(),
  inbound_id   uuid not null references public.inbounds(id) on delete cascade,
  product_id   uuid not null references public.products(id),
  batch_no     text not null default '-',
  expiry_date  date,
  location_id  uuid not null references public.locations(id),
  qty          numeric(14,3) not null check (qty > 0),
  unit_cost    numeric(16,2) not null default 0 check (unit_cost >= 0),
  scanned      boolean not null default false,
  created_at   timestamptz not null default now()
);
create index on public.inbound_lines (inbound_id);

-- ---------------------------------------------------------------------
-- Penjualan B2B (dibuat sebelum outbounds karena direferensikan)
-- ---------------------------------------------------------------------
create table public.sales_orders (
  id               uuid primary key default gen_random_uuid(),
  doc_no           text not null unique default '',
  customer_id      uuid not null references public.customers(id),
  warehouse_id     uuid not null references public.warehouses(id),
  order_date       date not null default current_date,
  customer_po      text,
  tax_percent      numeric(5,2) not null default 0 check (tax_percent >= 0),
  discount_amount  numeric(16,2) not null default 0 check (discount_amount >= 0),
  status           text not null default 'draft'
                   check (status in ('draft','confirmed','diproses','dikirim','batal')),
  note             text,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  confirmed_by     uuid,
  confirmed_at     timestamptz
);
create index on public.sales_orders (customer_id);
create index on public.sales_orders (status);

create table public.sales_order_lines (
  id                uuid primary key default gen_random_uuid(),
  sales_order_id    uuid not null references public.sales_orders(id) on delete cascade,
  product_id        uuid not null references public.products(id),
  qty               numeric(14,3) not null check (qty > 0),
  unit_price        numeric(16,2) not null check (unit_price >= 0),
  discount_percent  numeric(5,2) not null default 0 check (discount_percent between 0 and 100),
  line_total        numeric(18,2) generated always as
                    (round(qty * unit_price * (1 - discount_percent / 100), 2)) stored,
  created_at        timestamptz not null default now()
);
create index on public.sales_order_lines (sales_order_id);

-- ---------------------------------------------------------------------
-- Barang keluar
-- ---------------------------------------------------------------------
create table public.outbounds (
  id              uuid primary key default gen_random_uuid(),
  doc_no          text not null unique default '',
  warehouse_id    uuid not null references public.warehouses(id),
  purpose         text not null default 'lainnya' check (purpose in
                  ('marketplace','b2b','sampel','rusak_musnah','internal','lainnya')),
  sales_order_id  uuid references public.sales_orders(id),
  partner_name    text,
  reference_no    text,
  mode            text not null default 'scan' check (mode in ('scan','manual')),
  status          text not null default 'draft' check (status in ('draft','posted','cancelled')),
  note            text,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  posted_by       uuid,
  posted_at       timestamptz
);
create index on public.outbounds (warehouse_id, status);
create index on public.outbounds (sales_order_id);

-- Permintaan per produk
create table public.outbound_items (
  id           uuid primary key default gen_random_uuid(),
  outbound_id  uuid not null references public.outbounds(id) on delete cascade,
  product_id   uuid not null references public.products(id),
  qty          numeric(14,3) not null check (qty > 0),
  unique (outbound_id, product_id)
);

-- Alokasi pengambilan per batch & lokasi
create table public.outbound_picks (
  id           uuid primary key default gen_random_uuid(),
  outbound_id  uuid not null references public.outbounds(id) on delete cascade,
  product_id   uuid not null references public.products(id),
  batch_id     uuid not null references public.batches(id),
  location_id  uuid not null references public.locations(id),
  qty          numeric(14,3) not null check (qty > 0),
  picked_qty   numeric(14,3) not null default 0 check (picked_qty >= 0),
  check (picked_qty <= qty)
);
create index on public.outbound_picks (outbound_id);
create index on public.outbound_picks (batch_id, location_id);

-- ---------------------------------------------------------------------
-- Transfer antar gudang
-- ---------------------------------------------------------------------
create table public.transfers (
  id                 uuid primary key default gen_random_uuid(),
  doc_no             text not null unique default '',
  from_warehouse_id  uuid not null references public.warehouses(id),
  to_warehouse_id    uuid not null references public.warehouses(id),
  mode               text not null default 'scan' check (mode in ('scan','manual')),
  status             text not null default 'draft'
                     check (status in ('draft','dikirim','diterima','cancelled')),
  note               text,
  receive_note       text,
  created_by         uuid,
  created_at         timestamptz not null default now(),
  sent_by            uuid,
  sent_at            timestamptz,
  received_by        uuid,
  received_at        timestamptz,
  check (from_warehouse_id <> to_warehouse_id)
);
create index on public.transfers (status);

create table public.transfer_items (
  id           uuid primary key default gen_random_uuid(),
  transfer_id  uuid not null references public.transfers(id) on delete cascade,
  product_id   uuid not null references public.products(id),
  qty          numeric(14,3) not null check (qty > 0),
  unique (transfer_id, product_id)
);

create table public.transfer_lines (
  id                uuid primary key default gen_random_uuid(),
  transfer_id       uuid not null references public.transfers(id) on delete cascade,
  product_id        uuid not null references public.products(id),
  batch_id          uuid not null references public.batches(id),
  from_location_id  uuid not null references public.locations(id),
  qty               numeric(14,3) not null check (qty > 0),
  picked_qty        numeric(14,3) not null default 0 check (picked_qty >= 0),
  received_qty      numeric(14,3) not null default 0 check (received_qty >= 0),
  check (picked_qty <= qty),
  check (received_qty <= qty)
);
create index on public.transfer_lines (transfer_id);
create index on public.transfer_lines (batch_id, from_location_id);

-- Penerimaan di gudang tujuan (satu baris kirim bisa ditaruh di beberapa rak)
create table public.transfer_receipts (
  id                uuid primary key default gen_random_uuid(),
  transfer_line_id  uuid not null references public.transfer_lines(id) on delete cascade,
  transfer_id       uuid not null references public.transfers(id) on delete cascade,
  location_id       uuid not null references public.locations(id),
  qty               numeric(14,3) not null check (qty > 0),
  received_by       uuid,
  received_at       timestamptz not null default now()
);
create index on public.transfer_receipts (transfer_id);

-- ---------------------------------------------------------------------
-- Pindah lokasi (rak ke rak dalam satu gudang)
-- ---------------------------------------------------------------------
create table public.relocations (
  id                uuid primary key default gen_random_uuid(),
  doc_no            text not null unique default '',
  warehouse_id      uuid not null references public.warehouses(id),
  product_id        uuid not null references public.products(id),
  batch_id          uuid not null references public.batches(id),
  from_location_id  uuid not null references public.locations(id),
  to_location_id    uuid not null references public.locations(id),
  qty               numeric(14,3) not null check (qty > 0),
  note              text,
  created_by        uuid,
  created_at        timestamptz not null default now(),
  check (from_location_id <> to_location_id)
);

-- ---------------------------------------------------------------------
-- Stock opname (cycle count)
-- ---------------------------------------------------------------------
create table public.stock_counts (
  id            uuid primary key default gen_random_uuid(),
  doc_no        text not null unique default '',
  warehouse_id  uuid not null references public.warehouses(id),
  title         text,
  location_ids  uuid[],          -- null = seluruh gudang
  status        text not null default 'counting'
                check (status in ('counting','submitted','approved','cancelled')),
  note          text,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  submitted_by  uuid,
  submitted_at  timestamptz,
  approved_by   uuid,
  approved_at   timestamptz
);

create table public.stock_count_lines (
  id           uuid primary key default gen_random_uuid(),
  count_id     uuid not null references public.stock_counts(id) on delete cascade,
  location_id  uuid not null references public.locations(id),
  product_id   uuid not null references public.products(id),
  batch_id     uuid not null references public.batches(id),
  counted_qty  numeric(14,3) not null default 0 check (counted_qty >= 0),
  system_qty   numeric(14,3),
  diff_qty     numeric(14,3) generated always as (counted_qty - coalesce(system_qty, 0)) stored,
  reason       text,
  counted_by   uuid,
  counted_at   timestamptz,
  auto_added   boolean not null default false,
  unique (count_id, location_id, batch_id)
);
create index on public.stock_count_lines (count_id);

-- ---------------------------------------------------------------------
-- Penyesuaian stok (wajib alasan + persetujuan)
-- ---------------------------------------------------------------------
create table public.adjustments (
  id            uuid primary key default gen_random_uuid(),
  doc_no        text not null unique default '',
  warehouse_id  uuid not null references public.warehouses(id),
  reason        text not null check (reason in
                ('rusak','hilang','expired','salah_input','ditemukan','sampel','lainnya')),
  note          text,
  status        text not null default 'draft'
                check (status in ('draft','pending','approved','rejected','cancelled')),
  created_by    uuid,
  created_at    timestamptz not null default now(),
  submitted_at  timestamptz,
  decided_by    uuid,
  decided_at    timestamptz,
  decision_note text
);

create table public.adjustment_lines (
  id             uuid primary key default gen_random_uuid(),
  adjustment_id  uuid not null references public.adjustments(id) on delete cascade,
  product_id     uuid not null references public.products(id),
  batch_no       text not null default '-',
  expiry_date    date,
  location_id    uuid not null references public.locations(id),
  qty_change     numeric(14,3) not null check (qty_change <> 0)
);
create index on public.adjustment_lines (adjustment_id);

-- ---------------------------------------------------------------------
-- Faktur & pembayaran B2B
-- ---------------------------------------------------------------------
create table public.invoices (
  id               uuid primary key default gen_random_uuid(),
  invoice_no       text not null unique default '',
  sales_order_id   uuid not null references public.sales_orders(id),
  customer_id      uuid not null references public.customers(id),
  invoice_date     date not null default current_date,
  due_date         date not null,
  subtotal         numeric(18,2) not null,
  discount_amount  numeric(18,2) not null default 0,
  tax_percent      numeric(5,2) not null default 0,
  tax_amount       numeric(18,2) not null default 0,
  total            numeric(18,2) not null,
  paid_amount      numeric(18,2) not null default 0 check (paid_amount >= 0),
  status           text not null default 'belum_lunas'
                   check (status in ('belum_lunas','sebagian','lunas','void')),
  note             text,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  check (paid_amount <= total)
);
create index on public.invoices (customer_id, status);
-- Satu SO hanya boleh punya satu faktur aktif (faktur void boleh dibuat ulang)
create unique index invoices_one_active_per_so on public.invoices (sales_order_id) where status <> 'void';

create table public.invoice_lines (
  id                uuid primary key default gen_random_uuid(),
  invoice_id        uuid not null references public.invoices(id) on delete cascade,
  product_id        uuid not null references public.products(id),
  description       text not null,
  qty               numeric(14,3) not null,
  unit_price        numeric(16,2) not null,
  discount_percent  numeric(5,2) not null default 0,
  line_total        numeric(18,2) not null
);
create index on public.invoice_lines (invoice_id);

create table public.payments (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null references public.invoices(id),
  paid_at     date not null default current_date,
  amount      numeric(18,2) not null check (amount > 0),
  method      text not null default 'transfer' check (method in ('transfer','tunai','giro','lainnya')),
  reference   text,
  note        text,
  created_by  uuid,
  created_at  timestamptz not null default now()
);
create index on public.payments (invoice_id);

-- ---------------------------------------------------------------------
-- Marketplace
-- ---------------------------------------------------------------------
create table public.marketplace_imports (
  id                uuid primary key default gen_random_uuid(),
  store_id          uuid not null references public.stores(id),
  file_name         text,
  total_rows        int not null default 0,
  orders_new        int not null default 0,
  orders_duplicate  int not null default 0,
  orders_cancelled  int not null default 0,
  lines_new         int not null default 0,
  lines_unmapped    int not null default 0,
  created_by        uuid,
  created_at        timestamptz not null default now()
);

create table public.marketplace_orders (
  id                 uuid primary key default gen_random_uuid(),
  store_id           uuid not null references public.stores(id),
  external_order_id  text not null check (length(trim(external_order_id)) > 0),
  order_date         timestamptz,
  external_status    text,
  buyer_name         text,
  status             text not null default 'baru'
                     check (status in ('baru','diproses','dikirim','batal')),
  total_amount       numeric(18,2) not null default 0,
  import_id          uuid references public.marketplace_imports(id),
  outbound_id        uuid references public.outbounds(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (store_id, external_order_id)
);
create index on public.marketplace_orders (status);
create index on public.marketplace_orders (outbound_id);
create index on public.marketplace_orders (order_date);

create table public.marketplace_order_lines (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references public.marketplace_orders(id) on delete cascade,
  external_sku  text,
  product_name  text,
  qty           numeric(14,3) not null check (qty > 0),
  unit_price    numeric(16,2) not null default 0,
  line_amount   numeric(18,2) not null default 0
);
create index on public.marketplace_order_lines (order_id);
create index on public.marketplace_order_lines (lower(external_sku));

-- Skenario uji Warehouse Sistem 4 Keledai
-- Dijalankan sebagai superuser lokal; berpindah ke peran "authenticated"
-- + id pengguna untuk meniru akses lewat aplikasi.
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Alat bantu uji
-- ---------------------------------------------------------------------
create schema test;
create function test.expect_error(p_sql text, p_pattern text) returns text
language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm ~* p_pattern then
      return 'OK  error sesuai: ' || left(sqlerrm, 110);
    end if;
    raise exception 'Error tidak sesuai. Diharapkan /%/, didapat: %', p_pattern, sqlerrm;
  end;
  raise exception 'Seharusnya error /%/ tapi berhasil: %', p_pattern, p_sql;
end $$;
create function test.eq(p_actual anyelement, p_expected anyelement, p_label text) returns text
language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'GAGAL %: hasil % , seharusnya %', p_label, p_actual, p_expected;
  end if;
  return 'OK  ' || p_label || ' = ' || coalesce(p_actual::text, 'null');
end $$;
create function test.login(p_email text) returns text
language plpgsql security definer as $$
declare v uuid;
begin
  select id into v from auth.users where email = p_email;
  perform set_config('request.jwt.claim.sub', v::text, false);
  return 'login ' || p_email;
end $$;
grant usage on schema test to authenticated, anon;
grant execute on all functions in schema test to authenticated, anon;

-- ---------------------------------------------------------------------
-- 1. Akun pengguna
-- ---------------------------------------------------------------------
insert into auth.users (email, raw_user_meta_data) values ('owner@4keledai.id', '{"full_name":"Pak Owner"}');
insert into auth.users (email) values ('admin@4keledai.id'), ('gudang@4keledai.id'), ('finance@4keledai.id'),
                                      ('sales@4keledai.id'), ('baru@4keledai.id');
select test.eq((select role || '/' || active from public.profiles p join auth.users u on u.id = p.id where u.email = 'owner@4keledai.id'),
               'owner/true', 'akun pertama otomatis owner aktif');
select test.eq((select active from public.profiles p join auth.users u on u.id = p.id where u.email = 'admin@4keledai.id'),
               false, 'akun berikutnya nonaktif dulu');

set role authenticated;
select test.login('baru@4keledai.id');
select test.eq((select count(*) from public.products), 0::bigint, 'akun nonaktif tidak melihat data');
select test.eq((public.dashboard_stats())->>'inbound_draft', '0', 'akun nonaktif: dashboard kosong');
reset role;
set role anon;
select test.expect_error($$select * from public.products$$, 'permission denied');
reset role;

set role authenticated;
select test.login('owner@4keledai.id');
-- gudang dulu, supaya bisa ditugaskan
insert into public.warehouses (code, name, city) values ('gdg-sby', 'Gudang Surabaya', 'Surabaya'), ('GDG-BDG', 'Gudang Bandung', 'Bandung');
select id as wh_sby from public.warehouses where code = 'GDG-SBY' \gset
select id as wh_bdg from public.warehouses where code = 'GDG-BDG' \gset
select test.eq((select count(*) from public.locations where code = 'TERIMA'), 2::bigint, 'lokasi TERIMA otomatis per gudang');

select public.update_user((select id from public.profiles where email = 'admin@4keledai.id'), 'admin', true, null, 'Bu Admin');
select public.update_user((select id from public.profiles where email = 'gudang@4keledai.id'), 'gudang', true, :'wh_sby', 'Mas Gudang');
select public.update_user((select id from public.profiles where email = 'finance@4keledai.id'), 'finance', true, null, 'Mbak Finance');
select public.update_user((select id from public.profiles where email = 'sales@4keledai.id'), 'sales', true, null, 'Mas Sales');
select test.expect_error(format($$select public.update_user(%L, 'gudang', true, null, null)$$,
       (select id from public.profiles where email = 'owner@4keledai.id')), 'Minimal harus ada satu owner');

-- ---------------------------------------------------------------------
-- 2. Master data
-- ---------------------------------------------------------------------
insert into public.brands (code, name, legal_entity) values ('brm', 'Bromen Skincare', 'PT Bromen'), ('ZDO', 'Zerodeo', 'PT Zerodeo');
insert into public.locations (warehouse_id, code, name, kind) values
  (:'wh_sby', 'a-01', 'Rak A1', 'rak'), (:'wh_sby', 'A-02', 'Rak A2', 'rak'),
  (:'wh_sby', 'KAR', 'Karantina', 'karantina'), (:'wh_bdg', 'R-01', 'Rak R1', 'rak');
select id as loc_a1 from public.locations where code = 'A-01' \gset
select id as loc_a2 from public.locations where code = 'A-02' \gset
select id as loc_kar from public.locations where code = 'KAR' \gset
select id as loc_r1 from public.locations where code = 'R-01' \gset
select id as loc_terima_sby from public.locations where code = 'TERIMA' and warehouse_id = :'wh_sby' \gset
select test.eq((select barcode from public.locations where id = :'loc_a1'), 'L-GDG-SBY-A-01', 'barcode lokasi otomatis');

select public.upsert_products($$[
  {"brand_code":"BRM","sku":"BRM-SERUM","barcode":"899001","name":"Bromen Serum 30ml","uom":"pcs","track_batch":true,"default_cost":20000,"default_price":150000},
  {"brand_code":"ZDO","sku":"ZDO-ROLL","barcode":"899002","name":"Zerodeo Roll On","track_batch":true,"default_cost":10000},
  {"brand_code":"BRM","sku":"KAOS-MERCH","barcode":"899003","name":"Kaos Merchandise","track_batch":false,"default_cost":30000}
]$$::jsonb);
select test.expect_error($$select public.upsert_products('[{"brand_code":"XXX","sku":"A","name":"A"}]')$$, 'Kode brand tidak dikenal');
select test.expect_error($$select public.upsert_products('[{"brand_code":"BRM","sku":"dup1","name":"A"},{"brand_code":"BRM","sku":"DUP1","name":"B"}]')$$, 'SKU ganda');
select id as p_serum from public.products where sku = 'BRM-SERUM' \gset
select id as p_zdo from public.products where sku = 'ZDO-ROLL' \gset
select id as p_kaos from public.products where sku = 'KAOS-MERCH' \gset

-- ---------------------------------------------------------------------
-- 3. Barang masuk (petugas gudang Surabaya)
-- ---------------------------------------------------------------------
select test.login('gudang@4keledai.id');
select test.expect_error(format($$insert into public.inbounds (warehouse_id) values (%L)$$, :'wh_bdg'), 'row-level security');
select test.expect_error($$insert into public.products (brand_id, sku, name) select id, 'X', 'X' from public.brands limit 1$$, 'row-level security');

insert into public.inbounds (warehouse_id, source, partner_name, reference_no) values (:'wh_sby', 'supplier', 'PT Supplier', 'PO-001');
select id as in1 from public.inbounds order by created_at desc limit 1 \gset
select test.eq((select doc_no ~ '^IN-\d{4}-0001$' from public.inbounds where id = :'in1'), true, 'nomor dokumen otomatis');

select public.inbound_add_line(:'in1', '899001', 10, :'loc_a1', 'b001', '2027-06-30', 20000);
select public.inbound_add_line(:'in1', '899001', 5, :'loc_a1', 'B001', '2027-06-30', 20000);
select test.eq((select qty from public.inbound_lines where inbound_id = :'in1' and batch_no = 'B001'), 15.000, 'scan berulang menambah qty baris yang sama (batch huruf besar)');
select public.inbound_add_line(:'in1', 'brm-serum', 10, :'loc_a2', 'B002', '2027-01-31', 22000);
select public.inbound_add_line(:'in1', '899003', 20, :'loc_a1');
select test.expect_error(format($$select public.inbound_add_line(%L, '899002', 5, %L, 'Z1', null)$$, :'in1', :'loc_a1'), 'expired wajib');
select test.expect_error(format($$select public.inbound_add_line(%L, '899002', 5, %L, null, '2027-01-01')$$, :'in1', :'loc_a1'), 'batch wajib');
select test.expect_error(format($$select public.inbound_add_line(%L, '12345', 1, %L)$$, :'in1', :'loc_a1'), 'tidak dikenal');
select test.expect_error(format($$select public.inbound_add_line(%L, '899003', 1, %L)$$, :'in1', :'loc_r1'), 'Lokasi tidak valid');
select test.expect_error(format($$update public.inbounds set status = 'posted' where id = %L$$, :'in1'), 'permission denied');

select public.post_inbound(:'in1');
select test.eq((select qty from public.stock_balances sb join public.batches b on b.id = sb.batch_id where b.batch_no = 'B001' and sb.location_id = :'loc_a1'), 15.000, 'stok serum B001 di A-01');
select test.eq((select qty from public.stock_balances where product_id = :'p_kaos'), 20.000, 'stok kaos (tanpa batch)');
select test.eq((select batch_no from public.batches where product_id = :'p_kaos'), '-', 'produk tanpa batch memakai batch "-"');
select test.expect_error(format($$select public.post_inbound(%L)$$, :'in1'), 'sudah posted');
select test.expect_error(format($$select public.inbound_add_line(%L, '899001', 1, %L, 'B001', '2027-06-30')$$, :'in1', :'loc_a1'), 'sudah posted');
delete from public.inbound_lines where inbound_id = :'in1';
select test.eq((select count(*) from public.inbound_lines where inbound_id = :'in1'), 3::bigint, 'baris dokumen posted tidak terhapus');
select test.expect_error($$insert into public.stock_moves (product_id, batch_id, location_id, warehouse_id, qty, move_type, doc_type, doc_id, doc_no) values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 1, 'masuk', 'x', gen_random_uuid(), 'x')$$, 'permission denied');
select test.expect_error($$update public.stock_balances set qty = 999$$, 'permission denied');
select test.expect_error(format($$select public._move(%L, (select id from public.batches limit 1), %L, 100, 0, 'masuk', 'x', gen_random_uuid(), 'x')$$, :'p_serum', :'loc_a1'), 'permission denied');
select test.expect_error($$select public.inbound_add_line(gen_random_uuid(), '899001', 1, gen_random_uuid())$$, 'tidak ditemukan');

-- batch sama dengan expired berbeda ditolak
insert into public.inbounds (warehouse_id, source) values (:'wh_sby', 'supplier');
select id as in_x from public.inbounds order by created_at desc limit 1 \gset
select test.expect_error(format($$select public.inbound_add_line(%L, '899001', 1, %L, 'B001', '2027-12-31')$$, :'in_x', :'loc_a1'), 'berbeda dengan input');
select public.cancel_document('inbound', :'in_x');

-- ---------------------------------------------------------------------
-- 4. Barang keluar dengan FEFO + scan
-- ---------------------------------------------------------------------
insert into public.outbounds (warehouse_id, purpose, partner_name) values (:'wh_sby', 'sampel', 'Tim Marketing');
select id as out1 from public.outbounds order by created_at desc limit 1 \gset
select test.expect_error(format($$insert into public.outbounds (warehouse_id, purpose) values (%L, 'marketplace')$$, :'wh_sby'), 'row-level security');
select public.outbound_set_item(:'out1', '899001', 12);
select public.allocate_outbound(:'out1');
select test.eq((select string_agg(b.batch_no || ':' || public._q(op.qty), ',' order by b.expiry_date)
                  from public.outbound_picks op join public.batches b on b.id = op.batch_id where op.outbound_id = :'out1'),
               'B002:10,B001:2', 'FEFO: batch expired terdekat diambil dulu');
select test.expect_error(format($$select public.post_outbound(%L)$$, :'out1'), 'belum di-scan');
select test.expect_error(format($$select public.pick_scan('outbound', %L, '899002')$$, :'out1'), 'SALAH BARANG');
select test.expect_error(format($$select public.pick_scan('outbound', %L, '899001', 1, %L)$$, :'out1', :'loc_terima_sby'), 'SALAH RAK');
select public.pick_scan('outbound', :'out1', '899001', 12);
select test.expect_error(format($$select public.pick_scan('outbound', %L, '899001', 1)$$, :'out1'), 'KELEBIHAN');
select public.post_outbound(:'out1');
select test.eq((select qty from public.stock_balances sb join public.batches b on b.id = sb.batch_id where b.batch_no = 'B001' and sb.location_id = :'loc_a1'), 13.000, 'stok B001 setelah keluar');
select test.eq((select qty from public.stock_balances sb join public.batches b on b.id = sb.batch_id where b.batch_no = 'B002'), 0.000, 'stok B002 habis');
select test.eq((select sum(qty) from public.stock_moves where doc_id = :'out1'), -12.000, 'buku besar mencatat 12 keluar');

-- Reservasi: draft lain tidak bisa memakai stok yang sudah dialokasikan
insert into public.outbounds (warehouse_id, purpose, mode) values (:'wh_sby', 'internal', 'manual');
select id as out2 from public.outbounds order by created_at desc limit 1 \gset
select public.outbound_set_item(:'out2', '899001', 13);
select public.allocate_outbound(:'out2');
insert into public.transfers (from_warehouse_id, to_warehouse_id, mode) values (:'wh_sby', :'wh_bdg', 'manual');
select id as trf1 from public.transfers order by created_at desc limit 1 \gset
select public.transfer_set_item(:'trf1', '899001', 5);
select test.expect_error(format($$select public.allocate_transfer(%L)$$, :'trf1'), 'Stok tidak cukup untuk dikirim: BRM-SERUM kurang 5');
select test.eq((select available_qty from public.v_stock_summary where product_id = :'p_serum' and warehouse_id = :'wh_sby'), 0.000, 'stok tersedia memperhitungkan alokasi draft');
select public.cancel_document('outbound', :'out2');
select test.eq((select available_qty from public.v_stock_summary where product_id = :'p_serum' and warehouse_id = :'wh_sby'), 13.000, 'batal draft melepas alokasi');

-- ---------------------------------------------------------------------
-- 5. Transfer antar gudang dengan selisih penerimaan
-- ---------------------------------------------------------------------
select public.transfer_set_item(:'trf1', '899003', 10);
select public.allocate_transfer(:'trf1');
select public.send_transfer(:'trf1');
select test.eq((select qty from public.stock_balances where product_id = :'p_kaos' and location_id = :'loc_a1'), 10.000, 'kaos berkurang di gudang asal saat dikirim');
-- petugas Surabaya tidak boleh menerima di Bandung
select test.expect_error(format($$select public.receive_scan(%L, '899001', 3, %L)$$, :'trf1', :'loc_r1'), 'hanya boleh mengurus gudang');
select test.login('admin@4keledai.id');
select public.receive_scan(:'trf1', '899001', 3, :'loc_r1');
select public.receive_scan(:'trf1', '899003', 10, :'loc_r1');
select test.expect_error(format($$select public.receive_scan(%L, '899003', 1, %L)$$, :'trf1', :'loc_r1'), 'KELEBIHAN');
select test.expect_error(format($$select public.complete_transfer(%L)$$, :'trf1'), 'Isi keterangan selisih');
select public.complete_transfer(:'trf1', null, '2 pcs serum pecah di ekspedisi');
select test.eq((select sum(qty) from public.stock_balances where warehouse_id = :'wh_bdg' and product_id = :'p_serum'), 3.000, 'serum diterima di Bandung');
select test.eq((select qty_selisih from public.v_discrepancies where sumber = 'transfer'), -2.000, 'selisih transfer tercatat di laporan selisih');

-- ---------------------------------------------------------------------
-- 6. Stock opname dengan approval
-- ---------------------------------------------------------------------
select test.login('gudang@4keledai.id');
insert into public.stock_counts (warehouse_id, title, location_ids) values (:'wh_sby', 'Cycle count rak A-01', array[:'loc_a1']::uuid[]);
select id as cnt1 from public.stock_counts order by created_at desc limit 1 \gset
select public.count_add(:'cnt1', :'loc_a1', '899001', 4, 'B001');
select public.count_add(:'cnt1', :'loc_a1', '899001', 3, 'B001');
select test.expect_error(format($$select public.count_add(%L, %L, '899001', 1, 'B001')$$, :'cnt1', :'loc_a2'), 'tidak termasuk cakupan');
select test.eq((select (public.submit_count(:'cnt1'))->>'lines_with_diff'), '2', 'opname: 2 baris selisih (serum kurang 1, kaos tidak dihitung)');
select test.eq((select diff_qty from public.stock_count_lines where count_id = :'cnt1' and product_id = :'p_serum'), -1.000, 'selisih serum -1');
select test.eq((select diff_qty from public.stock_count_lines where count_id = :'cnt1' and product_id = :'p_kaos'), -10.000, 'kaos tercatat tapi tidak ditemukan = -10');
select test.expect_error(format($$select public.approve_count(%L)$$, :'cnt1'), 'Akses ditolak');
select test.login('owner@4keledai.id');
select test.expect_error(format($$select public.approve_count(%L)$$, :'cnt1'), 'tanpa alasan');
select public.set_count_reasons(:'cnt1', (select jsonb_agg(jsonb_build_object('line_id', id, 'reason', 'hilang')) from public.stock_count_lines where count_id = :'cnt1'));
select public.approve_count(:'cnt1');
select test.eq((select qty from public.stock_balances sb join public.batches b on b.id = sb.batch_id where b.batch_no = 'B001' and sb.location_id = :'loc_a1'), 7.000, 'stok serum mengikuti hasil opname');
select test.eq((select qty from public.stock_balances where product_id = :'p_kaos' and location_id = :'loc_a1'), 0.000, 'stok kaos mengikuti hasil opname');

-- ---------------------------------------------------------------------
-- 7. Penyesuaian: usul gudang, setuju admin, admin tidak boleh setujui sendiri
-- ---------------------------------------------------------------------
select test.login('gudang@4keledai.id');
insert into public.adjustments (warehouse_id, reason) values (:'wh_sby', 'ditemukan');
select id as adj1 from public.adjustments order by created_at desc limit 1 \gset
select public.adjustment_add_line(:'adj1', '899003', :'loc_a1', 3);
select test.expect_error(format($$select public.submit_adjustment(%L)$$, :'adj1'), 'keterangan');
update public.adjustments set note = 'Ditemukan di bawah rak saat bersih-bersih' where id = :'adj1';
select public.submit_adjustment(:'adj1');
select test.expect_error(format($$select public.decide_adjustment(%L, true)$$, :'adj1'), 'Akses ditolak');
select test.login('admin@4keledai.id');
select public.decide_adjustment(:'adj1', true);
select test.eq((select qty from public.stock_balances where product_id = :'p_kaos' and location_id = :'loc_a1'), 3.000, 'penyesuaian disetujui menambah stok');
insert into public.adjustments (warehouse_id, reason, note) values (:'wh_sby', 'rusak', 'tes');
select id as adj2 from public.adjustments order by created_at desc limit 1 \gset
select public.adjustment_add_line(:'adj2', '899003', :'loc_a1', -1);
select public.submit_adjustment(:'adj2');
select test.expect_error(format($$select public.decide_adjustment(%L, true)$$, :'adj2'), 'orang lain');
select test.expect_error(format($$select public.decide_adjustment(%L, false)$$, :'adj2'), 'alasan penolakan');
select public.decide_adjustment(:'adj2', false, 'tidak ada bukti foto');

-- ---------------------------------------------------------------------
-- 8. Pindah rak
-- ---------------------------------------------------------------------
select test.login('gudang@4keledai.id');
select public.relocate_stock(:'loc_a1', :'loc_a2', '899003', (select id from public.batches where product_id = :'p_kaos'), 3);
select test.eq((select qty from public.stock_balances where product_id = :'p_kaos' and location_id = :'loc_a2'), 3.000, 'kaos pindah ke A-02');
select test.expect_error(format($$select public.relocate_stock(%L, %L, '899003', %L, 1)$$, :'loc_a1', :'loc_a2',
       (select id from public.batches where product_id = :'p_kaos')), 'Stok bebas');
select test.expect_error(format($$select public.relocate_stock(%L, %L, '899003', %L, 1)$$, :'loc_a2', :'loc_r1',
       (select id from public.batches where product_id = :'p_kaos')), 'satu gudang');

-- ---------------------------------------------------------------------
-- 9. B2B: SO -> limit kredit -> keluar -> faktur -> pembayaran
-- ---------------------------------------------------------------------
select test.login('sales@4keledai.id');
insert into public.customers (code, name, payment_terms_days, credit_limit) values ('tk-maju', 'Toko Maju', 30, 1000000);
select id as cust1 from public.customers where code = 'TK-MAJU' \gset
insert into public.sales_orders (customer_id, warehouse_id, tax_percent) values (:'cust1', :'wh_sby', 11);
select id as so1 from public.sales_orders order by created_at desc limit 1 \gset
insert into public.sales_order_lines (sales_order_id, product_id, qty, unit_price) values (:'so1', :'p_serum', 4, 150000);
select test.eq((select total from public.so_totals(:'so1')), 666000.00, 'total SO dengan PPN 11%');
select public.confirm_sales_order(:'so1');
update public.sales_order_lines set qty = 100 where sales_order_id = :'so1';
select test.eq((select qty from public.sales_order_lines where sales_order_id = :'so1'), 4.000, 'baris SO terkunci setelah confirm');
insert into public.sales_orders (customer_id, warehouse_id, tax_percent) values (:'cust1', :'wh_sby', 11);
select id as so2 from public.sales_orders order by created_at desc limit 1 \gset
insert into public.sales_order_lines (sales_order_id, product_id, qty, unit_price) values (:'so2', :'p_serum', 4, 150000);
select test.expect_error(format($$select public.confirm_sales_order(%L)$$, :'so2'), 'limit kredit.*Rp 666.000');
select public.cancel_document('sales_order', :'so2');
select public.create_outbound_from_so(:'so1') as out_so1 \gset
select test.eq((select status from public.sales_orders where id = :'so1'), 'diproses', 'SO diproses setelah dokumen keluar dibuat');
select test.login('gudang@4keledai.id');
select public.pick_scan('outbound', :'out_so1', '899001', 4);
select public.post_outbound(:'out_so1');
select test.eq((select status from public.sales_orders where id = :'so1'), 'dikirim', 'SO dikirim setelah barang keluar');
select test.login('finance@4keledai.id');
select public.create_invoice(:'so1', '2026-10-01') as inv1 \gset
select test.eq((select total::text || ' jatuh tempo ' || due_date from public.invoices where id = :'inv1'), '666000.00 jatuh tempo 2026-10-31', 'faktur & jatuh tempo 30 hari');
select test.expect_error(format($$select public.create_invoice(%L)$$, :'so1'), 'sudah punya faktur');
select public.add_payment(:'inv1', 500000);
select test.eq((select status from public.invoices where id = :'inv1'), 'sebagian', 'bayar sebagian');
select test.expect_error(format($$select public.add_payment(%L, 200000)$$, :'inv1'), 'melebihi sisa tagihan \(sisa Rp 166.000\)');
select public.add_payment(:'inv1', 166000);
select test.eq((select status from public.invoices where id = :'inv1'), 'lunas', 'faktur lunas');
select test.expect_error(format($$select public.post_inbound(%L)$$, :'in1'), 'Akses ditolak');

-- ---------------------------------------------------------------------
-- 10. Marketplace: impor, anti-dobel, bundling, SKU belum dipetakan
-- ---------------------------------------------------------------------
select test.login('admin@4keledai.id');
insert into public.stores (channel, name, brand_id, warehouse_id)
  values ('shopee', 'Bromen Official', (select id from public.brands where code = 'BRM'), :'wh_sby');
select id as store1 from public.stores where name = 'Bromen Official' \gset
insert into public.sku_mappings (store_id, external_sku, product_id, multiplier) values (:'store1', 'BUNDLE-2', :'p_serum', 2);
select test.login('sales@4keledai.id');
\set mprows '[{"order_id":"SHP001","order_date":"2026-10-20 10:00:00","status":"Perlu Dikirim","buyer":"ani","sku":"BRM-SERUM","product_name":"Serum","qty":1,"price":150000},{"order_id":"SHP001","order_date":"2026-10-20 10:00:00","status":"Perlu Dikirim","buyer":"ani","sku":"bundle-2","product_name":"Paket 2 Serum","qty":1,"price":280000},{"order_id":"SHP002","order_date":"2026-10-20 11:00:00","status":"Perlu Dikirim","buyer":"budi","sku":"SKU-ANEH","product_name":"Produk X","qty":1,"price":50000},{"order_id":"SHP003","order_date":"2026-10-20 12:00:00","status":"Batal","buyer":"cici","sku":"BRM-SERUM","product_name":"Serum","qty":2,"price":150000}]'
select test.eq((public.import_marketplace_orders(:'store1', 'shopee1.xlsx', :'mprows'::jsonb) - 'import_id'),
  '{"rows": 4, "lines_new": 4, "orders_new": 3, "lines_unmapped": 1, "orders_cancelled": 1, "orders_duplicate": 0}'::jsonb,
  'impor pertama: 3 pesanan baru, 1 batal, 1 SKU belum dipetakan');
select test.eq((select (public.import_marketplace_orders(:'store1', 'shopee1.xlsx', :'mprows'::jsonb))->>'orders_duplicate'), '3', 'impor ulang file yang sama tidak dobel');
select test.eq((select count(*) from public.marketplace_orders), 3::bigint, 'jumlah pesanan tetap 3');
select test.eq((select count(*) from public.marketplace_order_lines), 4::bigint, 'jumlah baris tetap 4');
select test.eq((select order_date at time zone 'Asia/Jakarta' from public.marketplace_orders where external_order_id = 'SHP001'), '2026-10-20 10:00:00'::timestamp, 'jam pesanan tersimpan sesuai WIB');
select test.expect_error($$select public.import_marketplace_orders((select id from public.stores limit 1), 'x', '[{"order_id":"","qty":1}]')$$, 'tanpa nomor pesanan');
select test.expect_error($$select public.import_marketplace_orders((select id from public.stores limit 1), 'x', '[{"order_id":"A","qty":0}]')$$, 'Jumlah barang kosong');

select test.login('gudang@4keledai.id');
select test.expect_error(format($$select public.create_outbound_from_marketplace(array[%L]::uuid[])$$,
       (select id from public.marketplace_orders where external_order_id = 'SHP002')), 'belum dipetakan ke produk: SKU-ANEH');
select public.create_outbound_from_marketplace(array[(select id from public.marketplace_orders where external_order_id = 'SHP001')]) as out_mp \gset
select test.eq((select qty from public.outbound_items where outbound_id = :'out_mp'), 3.000, 'bundling 2 + satuan 1 = 3 serum');
select public.pick_scan('outbound', :'out_mp', '899001', 3);
select public.post_outbound(:'out_mp');
select test.eq((select status from public.marketplace_orders where external_order_id = 'SHP001'), 'dikirim', 'pesanan marketplace jadi dikirim');
select test.eq((select coalesce(sum(qty), 0) from public.stock_balances where product_id = :'p_serum' and warehouse_id = :'wh_sby'), 0.000, 'serum Surabaya habis');
-- status batal dari impor ulang untuk pesanan yang belum diproses
\set mprows2 '[{"order_id":"SHP002","status":"Dibatalkan Pembeli","sku":"SKU-ANEH","qty":1}]'
select test.login('sales@4keledai.id');
select test.eq((select (public.import_marketplace_orders(:'store1', 'shopee2.xlsx', :'mprows2'::jsonb))->>'orders_cancelled'), '1', 'impor ulang membatalkan pesanan yang dibatalkan pembeli');

-- ---------------------------------------------------------------------
-- 11. Batch kedaluwarsa & karantina tidak dialokasikan
-- ---------------------------------------------------------------------
select test.login('gudang@4keledai.id');
insert into public.inbounds (warehouse_id, source, mode) values (:'wh_sby', 'retur_marketplace', 'manual');
select id as in2 from public.inbounds order by created_at desc limit 1 \gset
select public.inbound_add_line(:'in2', '899002', 5, :'loc_a1', 'OLD', '2020-01-01', 0, false);
select public.inbound_add_line(:'in2', '899002', 5, :'loc_kar', 'KRT', '2029-01-01', 0, false);
select public.inbound_add_line(:'in2', '899002', 5, :'loc_a2', 'NEW', '2028-01-01', 0, false);
select public.post_inbound(:'in2');
select test.eq((select unit_cost from public.batches where batch_no = 'NEW'), 10000.00, 'biaya batch memakai harga pokok default bila 0');
insert into public.outbounds (warehouse_id, purpose, mode) values (:'wh_sby', 'lainnya', 'manual');
select id as out3 from public.outbounds order by created_at desc limit 1 \gset
select public.outbound_set_item(:'out3', '899002', 6);
select test.expect_error(format($$select public.allocate_outbound(%L)$$, :'out3'), 'ZDO-ROLL kurang 1');
select public.outbound_set_item(:'out3', '899002', 5, false);
select public.allocate_outbound(:'out3');
select test.eq((select b.batch_no from public.outbound_picks op join public.batches b on b.id = op.batch_id where op.outbound_id = :'out3'), 'NEW', 'batch expired & karantina dilewati');
-- alokasi manual diubah ke batch expired untuk penjualan -> ditolak saat posting
select public.post_outbound(:'out3');
insert into public.outbounds (warehouse_id, purpose, mode) values (:'wh_sby', 'b2b', 'manual');
select id as out4 from public.outbounds order by created_at desc limit 1 \gset
select public.outbound_set_item(:'out4', '899002', 1);
insert into public.outbound_picks (outbound_id, product_id, batch_id, location_id, qty)
  values (:'out4', :'p_zdo', (select id from public.batches where batch_no = 'OLD'), :'loc_a1', 1);
select test.expect_error(format($$select public.post_outbound(%L)$$, :'out4'), 'kedaluwarsa');

-- ---------------------------------------------------------------------
-- 11b. Saldo awal dari file (go-live)
-- ---------------------------------------------------------------------
select test.login('owner@4keledai.id');
select test.expect_error(format($$select public.create_opening_stock(%L, '[{"sku":"BRM-SERUM","batch_no":"S1","expiry_date":"2027-01-01","location_code":"ZZ","qty":5}]')$$, :'wh_bdg'), 'Kode lokasi tidak ada');
select test.expect_error(format($$select public.create_opening_stock(%L, '[{"sku":"BRM-SERUM","batch_no":"S1","location_code":"R-01","qty":5}]')$$, :'wh_bdg'), 'expired wajib');
select public.create_opening_stock(:'wh_bdg', '[{"sku":"BRM-SERUM","batch_no":"s1","expiry_date":"2027-01-01","location_code":"r-01","qty":5,"unit_cost":21000},{"sku":"KAOS-MERCH","location_code":"R-01","qty":7}]') as in_open \gset
select test.eq((select source || '/' || status from public.inbounds where id = :'in_open'), 'saldo_awal/draft', 'saldo awal jadi draft barang masuk untuk diperiksa');
select public.post_inbound(:'in_open');
select test.eq((select sum(qty) from public.stock_balances where warehouse_id = :'wh_bdg' and product_id = :'p_serum'), 8.000, 'saldo awal serum Bandung masuk (3 + 5)');

-- ---------------------------------------------------------------------
-- 12. Integritas buku besar & laporan
-- ---------------------------------------------------------------------
reset role;
select test.eq((
  select count(*) from (
    select batch_id, location_id, sum(qty) q from public.stock_moves group by 1, 2
  ) m full join public.stock_balances b using (batch_id, location_id)
  where coalesce(m.q, 0) <> coalesce(b.qty, 0)), 0::bigint, 'INTEGRITAS: saldo = jumlah buku besar untuk setiap batch & lokasi');
select test.expect_error($$delete from public.stock_moves$$, 'tidak boleh diubah');
select test.expect_error($$update public.stock_moves set qty = 1$$, 'tidak boleh diubah');
set role authenticated;
select test.login('finance@4keledai.id');
select test.eq((select count(*) from public.v_sales where kanal = 'b2b'), 1::bigint, 'v_sales: 1 baris B2B');
select test.eq((select count(*) from public.v_sales where kanal = 'shopee'), 2::bigint, 'v_sales: 2 baris Shopee (pesanan batal tidak ikut)');
select test.eq((select sum(nilai) from public.v_sales where kanal = 'shopee'), 430000.00, 'v_sales: nilai Shopee');
select test.eq((select count(*) from public.v_discrepancies), 4::bigint, 'v_discrepancies: 2 opname + 1 penyesuaian + 1 transfer');
select test.eq((select count(*) > 0 from public.v_stock_moves), true, 'v_stock_moves bisa dibaca finance');
select test.eq((select (public.dashboard_stats())->>'expired'), '1', 'dashboard: 1 batch kedaluwarsa');
select test.expect_error($$select public.upsert_products('[]')$$, 'Akses ditolak');
reset role;

\echo
\echo '==================== SEMUA UJI LULUS ===================='

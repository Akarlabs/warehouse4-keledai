-- Skenario uji database produksi (supabase/setup.sql)
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = warning;

create schema test;
create function test.err(p_sql text, p_pat text) returns text language plpgsql as $$
begin
  begin execute p_sql;
  exception when others then
    if sqlerrm ~* p_pat then return 'OK  error sesuai: ' || left(sqlerrm, 120); end if;
    raise exception 'Error tidak sesuai. Diharapkan /%/, didapat: %', p_pat, sqlerrm;
  end;
  raise exception 'Seharusnya error /%/ tapi berhasil: %', p_pat, p_sql;
end $$;
create function test.eq(a anyelement, b anyelement, label text) returns text language plpgsql as $$
begin
  if a is distinct from b then raise exception 'GAGAL %: hasil %, seharusnya %', label, a, b; end if;
  return 'OK  ' || label || ' = ' || coalesce(a::text, 'null');
end $$;
create function test.login(p_email text) returns text language plpgsql security definer as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where email = p_email), 'role', 'authenticated')::text, false);
  return 'login ' || p_email;
end $$;
create function test.uid(p_email text) returns uuid language sql security definer as $$ select id from auth.users where email = p_email $$;
grant usage on schema test to authenticated, anon;
grant execute on all functions in schema test to authenticated, anon;

-- ---------- Akun ----------
insert into auth.users (email, raw_user_meta_data) values ('owner@k4.id', '{"full_name":"Pak Owner"}');
insert into auth.users (email, raw_user_meta_data) values ('staf@k4.id', '{"full_name":"Mas Staf"}'), ('sales@k4.id','{}'), ('fin@k4.id','{}'), ('baru@k4.id','{}');
select test.eq((select role||'/'||active from public.profiles where email='owner@k4.id'), 'owner/true', 'akun pertama = owner aktif');
select test.eq((select active from public.profiles where email='staf@k4.id'), false, 'akun berikutnya menunggu aktivasi');

set role anon;
select test.err($$select * from public.v_products$$, 'permission denied');
reset role;
set role authenticated;
select test.login('baru@k4.id');
select test.eq((select count(*) from public.v_brands), 0::bigint, 'akun belum aktif tidak melihat data');
select test.err($$select public.create_inbound('{}')$$, 'belum aktif');
select test.eq((public.my_profile())->>'active', 'false', 'my_profile tetap bisa dibaca akun belum aktif');
select test.err($$select * from public.products$$, 'permission denied');
select test.err($$select * from public.lots$$, 'permission denied');

select test.login('owner@k4.id');
select public.update_user(test.uid('staf@k4.id'), 'staf', true, 'Mas Staf');
select public.update_user(test.uid('sales@k4.id'), 'sales', true, 'Mbak Sales');
select public.update_user(test.uid('fin@k4.id'), 'finance', true, 'Bu Finance');
select test.err(format($$select public.update_user(%L,'staf',true)$$, test.uid('owner@k4.id')), 'satu owner');

-- ---------- Produk ----------
select test.eq((public.import_products('[
 {"sku":"zdo-ro-mxf-40","name":"Zerodeo Roll On Max Fresh 40ml","brand_code":"ZDO","track_ed":true,"min_stock":36,"cost":9500,"price":29000},
 {"sku":"ZDO-BM-CHM-75","name":"Zerodeo Body Mist Chic Motion 75ml","brand_code":"ZDO","track_ed":true,"min_stock":24,"cost":12500,"price":35000,"barcode":"8992001000079"},
 {"sku":"WT-TCCA90-1KG","name":"Kaporit TCCA 90% 1 kg","brand_code":"DKM","track_ed":false,"min_stock":20,"cost":26273,"price":52000}
]'))->>'baru', '3', 'impor 3 produk (SKU dibuat huruf besar)');
select test.err($$select public.import_products('[{"sku":"A B","name":"x","brand_code":"ZDO"}]')$$, 'Baris 2 .*SKU tidak valid');
select test.err($$select public.save_product('{"sku":"X-1","name":"x","brand_code":"ZDO","barcode":"8992001000079"}')$$, 'Barcode .* sudah dipakai');
select test.login('staf@k4.id');
select test.eq((select cost::text from public.v_products where sku='ZDO-RO-MXF-40'), null, 'staf tidak melihat HPP');
select test.eq((select price::text from public.v_products where sku='ZDO-RO-MXF-40'), null, 'staf tidak melihat harga jual');
select test.err($$select public.save_product('{"sku":"X-2","name":"x","brand_code":"ZDO"}')$$, 'Akses ditolak');
select test.login('sales@k4.id');
select test.eq((select cost::text from public.v_products where sku='ZDO-RO-MXF-40'), null, 'sales tidak melihat HPP');
select test.eq((select price from public.v_products where sku='ZDO-RO-MXF-40'), 29000.00, 'sales melihat harga jual');

-- ---------- Barang masuk ----------
select test.login('staf@k4.id');
select public.save_supplier('PT Mitra Kemasan Nusantara') as sup1 \gset
select test.eq(public.save_supplier('pt mitra kemasan nusantara'), :'sup1'::uuid, 'supplier sama tidak dobel');
select test.err($$select public.create_inbound('{"lines":[{"sku":"ZDO-RO-MXF-40","qty":5,"ed":"2029-01-01"}]}')$$, 'Pilih supplier');
select test.err(format($$select public.create_inbound('{"supplier_id":"%s","lines":[{"sku":"ZDO-RO-MXF-40","qty":5,"ed":"2029-01-01"}]}')$$, :'sup1'), 'surat jalan');
select test.err(format($$select public.create_inbound('{"supplier_id":"%s","sj_no":"SJ1","lines":[{"sku":"ZDO-RO-MXF-40","qty":5}]}')$$, :'sup1'), 'ED wajib');
select test.err(format($$select public.create_inbound('{"supplier_id":"%s","sj_no":"SJ1","lines":[{"sku":"ZDO-RO-MXF-40","qty":5,"ed":"2020-01-01"}]}')$$, :'sup1'), 'sudah lewat');
select test.err(format($$select public.create_inbound('{"supplier_id":"%s","sj_no":"SJ1","lines":[{"sku":"TIDAK-ADA","qty":5}]}')$$, :'sup1'), 'tidak dikenal');
select test.err($$select public.create_inbound('{"source":"saldo_awal","lines":[{"sku":"WT-TCCA90-1KG","qty":5}]}')$$, 'Akses ditolak');
select public.create_inbound(json_build_object('supplier_id', :'sup1', 'sj_no', 'SJ/MKN/001', 'sj_date', '2026-10-22', 'photo', 'data:image/jpeg;base64,AAAA',
  'lines', json_build_array(
    json_build_object('sku','ZDO-RO-MXF-40','qty',36,'ed','2026-12-20','batch_no','zr2405'),
    json_build_object('sku','ZDO-RO-MXF-40','qty',120,'ed','2029-09-30'),
    json_build_object('sku','WT-TCCA90-1KG','qty',110,'ed','2030-01-01')))::jsonb) as in1 \gset
select test.eq(:'in1' ~ '^IN-\d{4}-0001$', true, 'nomor dokumen otomatis');
select test.eq((select qty from public.v_stock where sku='ZDO-RO-MXF-40'), 156.000, 'stok roll on bertambah');
select test.eq((select count(*) from public.v_lots where sku='WT-TCCA90-1KG' and ed = '2030-01-01'), 1::bigint, 'produk non-personal care: ED opsional ikut tersimpan');
select test.eq((select has_photo from public.v_inbounds where doc_no=:'in1'), true, 'foto bukti tersimpan');
select test.eq(public.inbound_photo((select id from public.v_inbounds where doc_no=:'in1')), 'data:image/jpeg;base64,AAAA', 'foto bisa dibuka');
select test.eq((select value::text from public.v_inbounds where doc_no=:'in1'), null, 'staf tidak melihat nilai barang masuk');
select test.login('owner@k4.id');
select public.create_inbound('{"source":"saldo_awal","lines":[{"sku":"ZDO-BM-CHM-75","qty":8,"ed":"2026-09-30"},{"sku":"ZDO-BM-CHM-75","qty":40,"ed":"2029-10-31"}]}') as in2 \gset
select test.eq((select qty from public.v_stock where sku='ZDO-BM-CHM-75'), 48.000, 'saldo awal (boleh ED lewat)');
select test.eq((select value from public.v_inbounds where doc_no=:'in1'), 4372030.00, 'owner melihat nilai barang masuk');
select test.login('fin@k4.id');
select public.verify_inbound((select id from public.v_inbounds where doc_no=:'in1'));
select test.eq((select verified_name from public.v_inbounds where doc_no=:'in1'), 'Bu Finance', 'finance verifikasi barang masuk');
select test.err(format($$select public.verify_inbound(%L)$$, (select id from public.v_inbounds where doc_no=:'in1')), 'sudah diverifikasi');
select test.err($$select public.create_inbound('{}')$$, 'Akses ditolak');

-- ---------- Barang keluar ----------
select test.login('staf@k4.id');
select public.create_outbound('{"purpose":"shopee","ref":"2610230ZA1","customer":"nadia.k","lines":[{"sku":"ZDO-RO-MXF-40","qty":40}]}') as out1 \gset
select test.eq((:'out1'::jsonb)->>'status', 'posted', 'penjualan langsung mengurangi stok');
select test.eq((select string_agg(ed::text||':'||trim_scale(qty)::text, ',' order by ed) from public.v_outbound_lines where doc_no=(:'out1'::jsonb)->>'doc_no'), '2026-12-20:36,2029-09-30:4', 'FEFO: ED terdekat keluar dulu');
select test.eq((select qty from public.v_stock where sku='ZDO-RO-MXF-40'), 116.000, 'sisa roll on');
select test.err($$select public.create_outbound('{"purpose":"tokopedia","lines":[{"sku":"ZDO-BM-CHM-75","qty":45}]}')$$, 'kurang 5 \(stok kedaluwarsa tidak boleh dijual');
select test.err($$select public.create_outbound('{"purpose":"tokopedia","lines":[{"sku":"WT-TCCA90-1KG","qty":1},{"sku":"WT-TCCA90-1KG","qty":500}]}')$$, 'tidak cukup');
select test.eq((select qty from public.v_stock where sku='WT-TCCA90-1KG'), 110.000, 'transaksi gagal tidak mengubah stok');
select test.err($$select public.create_outbound('{"purpose":"rusak","lines":[{"sku":"ZDO-BM-CHM-75","qty":8}]}')$$, 'Keterangan wajib');
select public.create_outbound('{"purpose":"rusak","note":"Kedaluwarsa Sep 2026, dibuang","lines":[{"sku":"ZDO-BM-CHM-75","qty":8}]}') as out2 \gset
select test.eq((:'out2'::jsonb)->>'status', 'pending', 'barang rusak oleh staf menunggu owner');
select test.eq((select qty from public.v_stock where sku='ZDO-BM-CHM-75'), 48.000, 'stok belum berkurang sebelum disetujui');
select test.err(format($$select public.decide_outbound(%L, true)$$, (select id from public.v_outbounds where doc_no=(:'out2'::jsonb)->>'doc_no')), 'Akses ditolak');
select test.login('owner@k4.id');
select test.err(format($$select public.decide_outbound(%L, false)$$, (select id from public.v_outbounds where doc_no=(:'out2'::jsonb)->>'doc_no')), 'alasan penolakan');
select public.decide_outbound((select id from public.v_outbounds where doc_no=(:'out2'::jsonb)->>'doc_no'), true);
select test.eq((select expired_qty from public.v_stock where sku='ZDO-BM-CHM-75'), 0.000, 'disetujui: yang kedaluwarsa dibuang dulu');
select test.eq((select qty from public.v_stock where sku='ZDO-BM-CHM-75'), 40.000, 'sisa body mist');
select test.err(format($$select public.decide_outbound(%L, true)$$, (select id from public.v_outbounds where doc_no=(:'out2'::jsonb)->>'doc_no')), 'tidak menunggu');
select test.eq((public.create_outbound('{"purpose":"sampel","note":"endorse","lines":[{"sku":"ZDO-BM-CHM-75","qty":2}]}'))->>'status', 'posted', 'owner: sampel langsung keluar');
select test.login('sales@k4.id');
select test.err($$select public.create_outbound('{"purpose":"shopee","lines":[{"sku":"ZDO-BM-CHM-75","qty":1}]}')$$, 'Akses ditolak');
select test.eq((select count(*) > 0 from public.v_outbound_lines), true, 'sales bisa membaca riwayat keluar');
select test.eq((select hpp::text from public.v_outbound_lines limit 1), null, 'sales tidak melihat HPP keluar');

-- ---------- Stock opname mingguan ----------
select test.login('staf@k4.id');
select public.so_start() as so1 \gset
select test.err($$select public.so_start()$$, 'belum selesai');
select test.eq((select system_qty::text from public.v_opname_lines where opname_id=:'so1' and sku='ZDO-RO-MXF-40'), null, 'hitung buta: angka sistem disembunyikan');
select public.so_save(:'so1', '[{"sku":"ZDO-RO-MXF-40","counted":113},{"sku":"ZDO-BM-CHM-75","counted":38}]');
select test.err(format($$select public.so_submit(%L)$$, :'so1'), '1 produk belum dihitung');
select public.so_save(:'so1', '[{"sku":"WT-TCCA90-1KG","counted":112}]');
select test.eq((public.so_submit(:'so1'))->>'selisih', '2', 'SO: 2 produk selisih');
select test.eq((select diff from public.v_opname_lines where opname_id=:'so1' and sku='ZDO-RO-MXF-40'), -3.000, 'selisih roll on -3');
select test.err(format($$select public.so_approve(%L)$$, :'so1'), 'Akses ditolak');
select public.so_set_reasons(:'so1', '[{"sku":"ZDO-RO-MXF-40","reason":"Hilang"}]');
select test.login('owner@k4.id');
select test.err(format($$select public.so_approve(%L)$$, :'so1'), '1 selisih tanpa alasan');
select public.so_reopen(:'so1');
select test.eq((select status from public.v_opnames where id=:'so1'), 'counting', 'owner minta hitung ulang');
select test.login('staf@k4.id');
select public.so_submit(:'so1');
select public.so_set_reasons(:'so1', '[{"sku":"ZDO-RO-MXF-40","reason":"Hilang"},{"sku":"WT-TCCA90-1KG","reason":"Lupa dicatat masuk"}]');
select test.login('owner@k4.id');
select public.so_approve(:'so1');
select test.eq((select qty from public.v_stock where sku='ZDO-RO-MXF-40'), 113.000, 'SO disetujui: stok = fisik');
select test.eq((select qty from public.v_stock where sku='WT-TCCA90-1KG'), 112.000, 'SO kelebihan ditambahkan');
select test.eq((select diff_value from public.v_opnames where id=:'so1'), 24046.00, 'nilai selisih SO (owner)');
select test.eq(((public.dashboard())->>'so_done_this_week')::boolean, true, 'dashboard: SO minggu ini selesai');

-- ---------- Foto kemasan ----------
select test.login('staf@k4.id');
select test.err($$select public.set_product_photo('ZDO-RO-MXF-40', 'data:image/jpeg;base64,AAAA')$$, 'Akses ditolak');
select test.login('owner@k4.id');
select public.set_product_photo('ZDO-RO-MXF-40', 'data:image/jpeg;base64,AAAA');
select test.err($$select public.set_product_photo('ZDO-RO-MXF-40', 'bukan gambar')$$, 'check');
select test.err($$select public.set_product_photo('TIDAK-ADA', 'data:image/jpeg;base64,AAAA')$$, 'tidak dikenal');
select test.login('staf@k4.id');
select test.eq((select count(*) from public.v_product_photos), 1::bigint, 'staf bisa melihat foto kemasan');

-- ---------- SKU bundling ----------
select test.err($$select public.save_bundle('{"sku":"ZDO-BDL-2RO","name":"Paket 2 Roll On","items":[{"sku":"ZDO-RO-MXF-40","qty":2}]}')$$, 'Akses ditolak');
select test.login('owner@k4.id');
select public.save_bundle('{"sku":"zdo-bdl-2ro","name":"Paket 2 Roll On + Kaporit","items":[{"sku":"ZDO-RO-MXF-40","qty":2},{"sku":"WT-TCCA90-1KG","qty":1}]}');
select test.err($$select public.save_bundle('{"sku":"ZDO-RO-MXF-40","name":"x","items":[{"sku":"WT-TCCA90-1KG","qty":1}]}')$$, 'dipakai produk');
select test.err($$select public.save_product('{"sku":"ZDO-BDL-2RO","name":"x","brand_code":"ZDO"}')$$, 'dipakai SKU bundling');
select test.err($$select public.save_bundle('{"sku":"ZDO-BDL-X","name":"x","items":[]}')$$, 'minimal 1');
select test.eq((select jsonb_array_length(items) from public.v_bundles where sku='ZDO-BDL-2RO'), 2, 'bundling tersimpan dengan 2 isi');
select test.login('staf@k4.id');
select public.create_outbound('{"purpose":"shopee","ref":"BDL-1","lines":[{"sku":"ZDO-BDL-2RO","qty":3},{"sku":"ZDO-RO-MXF-40","qty":1}]}') as out3 \gset
select test.eq((select qty from public.v_stock where sku='ZDO-RO-MXF-40'), 106.000, 'bundling: roll on berkurang 3×2 + 1 = 7');
select test.eq((select qty from public.v_stock where sku='WT-TCCA90-1KG'), 109.000, 'bundling: kaporit berkurang 3×1');
select test.eq((select jsonb_array_length(lines) from public.v_outbounds where doc_no=(:'out3'::jsonb)->>'doc_no'), 2, 'baris digabung per SKU');
select test.eq((select bundles->0->>'sku' from public.v_outbounds where doc_no=(:'out3'::jsonb)->>'doc_no'), 'ZDO-BDL-2RO', 'dokumen mencatat SKU bundling');
select test.err($$select public.create_outbound('{"purpose":"shopee","lines":[{"sku":"ZDO-BDL-2RO","qty":100}]}')$$, 'tidak cukup');
select test.eq((select qty from public.v_stock where sku='WT-TCCA90-1KG'), 109.000, 'bundling gagal tidak mengubah stok');
select test.login('owner@k4.id');
select public.save_bundle('{"sku":"ZDO-BDL-2RO","name":"Paket 2 Roll On + Kaporit","active":false,"items":[{"sku":"ZDO-RO-MXF-40","qty":2}]}');
select test.login('staf@k4.id');
select test.err($$select public.create_outbound('{"purpose":"shopee","lines":[{"sku":"ZDO-BDL-2RO","qty":1}]}')$$, 'tidak dikenal');
select test.eq(((public.dashboard())->>'so_done_this_week')::boolean, true, 'dashboard tetap jalan');

-- ---------- ID & password tim ----------
select test.login('owner@k4.id');
select public.save_credential(test.uid('staf@k4.id'), 'Staf', 'awal12345');
select test.eq((select x->>'init_password' from public.list_users() x where x->>'email'='staf@k4.id'), 'awal12345', 'owner melihat password awal staf');
select test.eq((select x->>'login_id' from public.list_users() x where x->>'email'='staf@k4.id'), 'staf', 'ID login tersimpan');
select test.err(format($$select public.reset_password(%L, 'pendek')$$, test.uid('staf@k4.id')), 'minimal 8');
select test.err(format($$select public.reset_password(%L, 'baru12345')$$, test.uid('owner@k4.id')), 'Akun saya');
select public.reset_password(test.uid('staf@k4.id'), 'reset12345');
reset role;
select test.eq((select encrypted_password = crypt('reset12345', encrypted_password) from auth.users where email='staf@k4.id'), true, 'reset password mengubah password login');
set role authenticated;
select test.login('staf@k4.id');
select test.err($$select public.list_users()$$, 'Akses ditolak');
select test.err(format($$select public.save_credential(%L, 'x', 'y')$$, test.uid('staf@k4.id')), 'Akses ditolak');
select test.err(format($$select public.reset_password(%L, 'hack12345')$$, test.uid('owner@k4.id')), 'Akses ditolak');
select test.err($$select * from public.user_credentials$$, 'permission denied');
select public.mark_password_changed();
select test.login('owner@k4.id');
select test.eq((select (x->>'changed_by_user')||'/'||coalesce(x->>'init_password','-') from public.list_users() x where x->>'email'='staf@k4.id'), 'true/-', 'password yang diganti sendiri tidak disimpan');

-- ---------- Ganti ID ----------
select test.login('staf@k4.id');
select test.err(format($$select public.change_login_id(%L, 'curang')$$, test.uid('fin@k4.id')), 'Akses ditolak');
select test.err(format($$select public.change_login_id(%L, 'a b')$$, test.uid('staf@k4.id')), 'tanpa spasi');
select test.err(format($$select public.change_login_id(%L, 'fin@k4.id')$$, test.uid('staf@k4.id')), 'sudah dipakai');
select test.eq(public.change_login_id(test.uid('staf@k4.id'), 'Gudang1'), 'gudang1', 'staf ganti ID sendiri');
reset role;
select test.eq((select email from auth.users where id = test.uid('gudang1@4keledai.id')), 'gudang1@4keledai.id', 'email login ikut berubah');
set role authenticated;
select test.login('owner@k4.id');
select test.eq((select x->>'login_id' from public.list_users() x where x->>'email'='gudang1@4keledai.id'), 'gudang1', 'owner melihat ID baru');
select test.err(format($$select public.change_login_id(%L, 'bos')$$, test.uid('owner@k4.id')), 'harus berupa email');
select test.eq(public.change_login_id(test.uid('gudang1@4keledai.id'), 'staf@k4.id'), 'staf@k4.id', 'owner mengganti ID staf');

-- ---------- Head Operasional ----------
select test.login('owner@k4.id');
select public.update_user(test.uid('baru@k4.id'), 'ops', true, 'Yanuar');
select test.login('baru@k4.id');
select test.eq(public.can_see_cost(), true, 'head operasional melihat HPP');
select test.eq((select price from public.v_products where sku='ZDO-RO-MXF-40') > 0, true, 'head operasional melihat harga jual');
select public.save_product('{"sku":"ZDO-RO-NEW-40","name":"Roll On Baru","brand_code":"ZDO","cost":9000,"price":25000}');
select test.eq((select cost from public.v_products where sku='ZDO-RO-NEW-40'), 9000.00, 'head operasional tambah produk + HPP');
select test.err($$select public.list_users()$$, 'hanya untuk owner');
select test.err(format($$select public.reset_password(%L, 'abcd12345')$$, test.uid('staf@k4.id')), 'hanya untuk owner');
select public.create_outbound('{"purpose":"sampel","note":"endorse","lines":[{"sku":"WT-TCCA90-1KG","qty":1}]}') as out4 \gset
select test.eq((:'out4'::jsonb)->>'status', 'posted', 'head operasional: barang keluar sampel tanpa menunggu');

-- ---------- Produk ajuan staf gudang ----------
select test.login('staf@k4.id');
select test.err($$select public.save_product('{"sku":"X-1","name":"x","brand_code":"ZDO"}')$$, 'Akses ditolak');
select public.propose_product('{"sku":"dkm-soda-1kg","name":"Soda Api 1 kg","brand_code":"DKM","track_ed":false}');
select test.eq((select approved::text||'/'||proposed_name from public.v_products where sku='DKM-SODA-1KG'), 'false/Mas Staf', 'produk ajuan menunggu ACC');
select public.propose_product('{"sku":"DKM-COBA","name":"Coba","brand_code":"DKM","track_ed":false,"cost":5000}');
reset role; select test.eq((select cost from public.products where sku='DKM-COBA'), 0.00, 'HPP dari staf diabaikan'); set role authenticated;
select test.eq((select cost from public.v_products where sku='DKM-SODA-1KG'), null, 'staf tidak melihat HPP produk ajuan');
select public.create_inbound('{"source":"lainnya","lines":[{"sku":"DKM-SODA-1KG","qty":12}]}');
select test.err($$select public.approve_product('DKM-SODA-1KG', '{}')$$, 'Akses ditolak');
select test.login('fin@k4.id');
select test.err($$select public.reject_product('DKM-SODA-1KG')$$, 'sudah pernah masuk stok');
select test.eq(public.approve_product('DKM-SODA-1KG', '{"new_sku":"DKM-NAOH-1KG","cost":15000,"price":30000}'), 'DKM-NAOH-1KG', 'finance ACC + betulkan kode');
select test.eq((select qty from public.v_stock where sku='DKM-NAOH-1KG'), 12.000, 'stok ikut pindah ke kode baru');
select test.eq((select count(*) from public.v_moves where sku='DKM-NAOH-1KG'), 1::bigint, 'riwayat ikut kode baru');
select test.eq((select approved from public.v_products where sku='DKM-NAOH-1KG'), true, 'produk sudah ACC');
select test.login('staf@k4.id');
select public.propose_product('{"sku":"DKM-SALAH","name":"Salah ketik","brand_code":"DKM","track_ed":false}');
select test.login('baru@k4.id');
select public.reject_product('DKM-SALAH');
select public.reject_product('DKM-COBA');
select public.propose_product('{"sku":"DKM-HCL-1L","name":"HCl 1 L","brand_code":"DKM","track_ed":false,"cost":12000,"price":25000}');
select test.eq((select cost::text||'/'||approved from public.v_products where sku='DKM-HCL-1L'), '12000.00/true', 'head operasional: barang baru + HPP langsung aktif');
select test.eq((select count(*) from public.v_products where sku='DKM-SALAH'), 0::bigint, 'head operasional menolak ajuan yang belum dipakai');
reset role;
select test.err($$update public.moves set qty = 2 where sku='DKM-NAOH-1KG'$$, 'tidak boleh diubah');
set role authenticated;

-- ---------- Integritas ----------
reset role;
select test.eq((select count(*) from (select sku, ed, sum(qty) q from public.moves group by 1,2) m
   full join public.lots l on l.sku = m.sku and l.ed is not distinct from m.ed
   where coalesce(m.q,0) <> coalesce(l.qty,0)), 0::bigint, 'INTEGRITAS: stok = jumlah riwayat');
select test.err($$update public.moves set qty = 1$$, 'tidak boleh diubah');
select test.err($$delete from public.moves$$, 'tidak boleh diubah');
select test.err($$update public.lots set qty = -1$$, 'violates check');
set role authenticated;
select test.login('staf@k4.id');
select test.err($$update public.lots set qty = 999$$, 'permission denied');
select test.err($$insert into public.moves (sku, qty, kind, doc_no) values ('WT-TCCA90-1KG', 5, 'masuk', 'x')$$, 'permission denied');
select test.err($$select public._move('WT-TCCA90-1KG', null, 100, 'masuk', 'x', 'x')$$, 'permission denied');
select test.eq((select count(*) from public.v_moves where cost is not null), 0::bigint, 'staf: kartu stok tanpa HPP');
select test.eq(((public.dashboard())->>'stock_value'), null, 'staf: dashboard tanpa nilai');
select test.login('fin@k4.id');
select test.eq(((public.dashboard())->>'stock_value')::numeric > 0, true, 'finance: dashboard dengan nilai');
select test.err($$select public.create_outbound('{"purpose":"shopee","lines":[{"sku":"WT-TCCA90-1KG","qty":1}]}')$$, 'Akses ditolak');
reset role;
\echo '==================== SEMUA UJI LULUS ===================='

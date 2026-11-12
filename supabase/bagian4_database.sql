-- ---------------------------------------------------------------------
-- VIEW (dibaca aplikasi). Hanya pengguna aktif yang melihat isi.
-- HPP & nilai = null untuk staf dan sales.
-- ---------------------------------------------------------------------
create view public.v_settings with (security_barrier) as
  select company_name, timezone, warn_months, public._today() as today from public.settings where public.is_active();

create view public.v_brands with (security_barrier) as
  select code, name from public.brands where public.is_active();

create view public.v_suppliers with (security_barrier) as
  select id, name, phone, note, active from public.suppliers where public.is_active();

create view public.v_products with (security_barrier) as
  select p.sku, p.barcode, p.name, p.brand_code, b.name as brand_name, p.track_ed, p.min_stock,
         case when public.can_see_cost() then p.cost end as cost,
         case when public.my_role() in ('owner','finance','sales') then p.price end as price,
         p.active
    from public.products p join public.brands b on b.code = p.brand_code
   where public.is_active();

create view public.v_product_photos with (security_barrier) as
  select sku, photo from public.product_photos where public.is_active();

create view public.v_bundles with (security_barrier) as
  select b.sku, b.name, b.active,
         coalesce((select jsonb_agg(jsonb_build_object('sku', i.sku, 'name', p.name, 'qty', i.qty) order by p.name)
                     from public.bundle_items i join public.products p on p.sku = i.sku where i.bundle_sku = b.sku), '[]'::jsonb) as items
    from public.bundles b
   where public.is_active();

create view public.v_lots with (security_barrier) as
  select l.sku, p.name, p.brand_code, l.ed, l.qty,
         (l.ed - public._today()) as days_left,
         case when l.ed is null then 'tanpa_ed'
              when l.ed < public._today() then 'kedaluwarsa'
              when l.ed <= (public._today() + make_interval(months => s.warn_months))::date then 'dekat'
              else 'aman' end as ed_status,
         case when public.can_see_cost() then p.cost end as cost,
         case when public.can_see_cost() then round(l.qty * p.cost, 2) end as value
    from public.lots l join public.products p on p.sku = l.sku cross join public.settings s
   where l.qty > 0 and public.is_active();

create view public.v_stock with (security_barrier) as
  select p.sku, p.name, p.brand_code, b.name as brand_name, p.track_ed, p.min_stock, p.active,
         coalesce(sum(l.qty), 0) as qty,
         coalesce(sum(l.qty) filter (where l.ed is null or l.ed >= public._today()), 0) as sellable,
         coalesce(sum(l.qty) filter (where l.ed < public._today()), 0) as expired_qty,
         min(l.ed) filter (where l.qty > 0) as nearest_ed,
         coalesce(sum(l.qty), 0) < p.min_stock as below_min,
         case when public.can_see_cost() then round(coalesce(sum(l.qty), 0) * p.cost, 2) end as value,
         case when public.my_role() in ('owner','finance','sales') then p.price end as price
    from public.products p join public.brands b on b.code = p.brand_code
    left join public.lots l on l.sku = p.sku and l.qty > 0
   where public.is_active()
   group by p.sku, b.name;

create view public.v_moves with (security_barrier) as
  select m.id, m.at, (m.at at time zone s.timezone) as waktu, (m.at at time zone s.timezone)::date as tanggal,
         m.kind, m.doc_no, m.sku, p.name, p.brand_code, m.ed, m.qty, m.note, m.by_name,
         case when public.can_see_cost() then p.cost end as cost,
         case when public.can_see_cost() then round(m.qty * p.cost, 2) end as value
    from public.moves m join public.products p on p.sku = m.sku cross join public.settings s
   where public.is_active();

create view public.v_inbounds with (security_barrier) as
  select i.id, i.doc_no, i.doc_date, i.source, i.supplier_id, sp.name as supplier_name, i.sj_no, i.sj_date, i.no_sj_note,
         i.has_photo, i.note, i.received_name, i.created_at, i.verified_name, i.verified_at,
         (select count(*) from public.inbound_lines x where x.inbound_id = i.id) as line_count,
         (select sum(qty) from public.inbound_lines x where x.inbound_id = i.id) as total_qty,
         case when public.can_see_cost() then (select round(sum(x.qty * p.cost), 2) from public.inbound_lines x join public.products p on p.sku = x.sku where x.inbound_id = i.id) end as value,
         (select string_agg(public._q(x.qty) || ' × ' || p.name, chr(10) order by p.name) from public.inbound_lines x join public.products p on p.sku = x.sku where x.inbound_id = i.id) as items
    from public.inbounds i left join public.suppliers sp on sp.id = i.supplier_id
   where public.is_active();

create view public.v_inbound_lines with (security_barrier) as
  select i.doc_no, i.doc_date as tanggal, i.source as sumber, sp.name as supplier, i.sj_no as no_surat_jalan, i.sj_date as tgl_surat_jalan,
         x.sku, p.name as produk, p.brand_code as brand, x.ed, x.batch_no as batch, x.qty,
         case when public.can_see_cost() then p.cost end as hpp,
         case when public.can_see_cost() then round(x.qty * p.cost, 2) end as nilai,
         i.received_name as diterima_oleh, i.verified_name as diverifikasi_oleh, i.has_photo as ada_foto
    from public.inbound_lines x join public.inbounds i on i.id = x.inbound_id
    join public.products p on p.sku = x.sku left join public.suppliers sp on sp.id = i.supplier_id
   where public.is_active();

create view public.v_outbounds with (security_barrier) as
  select o.id, o.doc_no, o.doc_date, o.purpose, o.ref, o.customer, o.note, o.status, o.created_name, o.created_at, o.bundles,
         o.decided_name, o.decided_at, o.decided_note,
         (select sum(qty) from public.outbound_lines x where x.outbound_id = o.id) as total_qty,
         (select string_agg(public._q(x.qty) || ' × ' || p.name, chr(10) order by p.name) from public.outbound_lines x join public.products p on p.sku = x.sku where x.outbound_id = o.id) as items,
         (select jsonb_agg(jsonb_build_object('sku', x.sku, 'name', p.name, 'qty', x.qty, 'allocation', x.allocation) order by p.name)
            from public.outbound_lines x join public.products p on p.sku = x.sku where x.outbound_id = o.id) as lines
    from public.outbounds o
   where public.is_active();

-- Satu baris per ED yang benar-benar keluar (untuk export)
create view public.v_outbound_lines with (security_barrier) as
  select o.doc_no, o.doc_date as tanggal, o.purpose as tujuan, o.ref as no_pesanan, o.customer as pembeli, o.status,
         x.sku, p.name as produk, p.brand_code as brand,
         nullif(a->>'ed','')::date as ed,
         coalesce((a->>'qty')::numeric, x.qty) as qty,
         case when public.can_see_cost() then p.cost end as hpp,
         case when public.can_see_cost() then round(coalesce((a->>'qty')::numeric, x.qty) * p.cost, 2) end as nilai_hpp,
         case when public.my_role() in ('owner','finance','sales') then p.price end as harga_jual,
         o.created_name as diinput_oleh, o.decided_name as disetujui_oleh, o.note as keterangan
    from public.outbound_lines x join public.outbounds o on o.id = x.outbound_id
    join public.products p on p.sku = x.sku
    left join lateral jsonb_array_elements(coalesce(x.allocation, '[]'::jsonb)) a on true
   where public.is_active();

create view public.v_opnames with (security_barrier) as
  select o.id, o.doc_no, o.period, o.status, o.note, o.created_name, o.created_at, o.submitted_name, o.submitted_at,
         o.approved_name, o.approved_at,
         (select count(*) from public.opname_lines l where l.opname_id = o.id) as line_count,
         (select count(*) from public.opname_lines l where l.opname_id = o.id and l.counted is not null) as counted_count,
         (select count(*) from public.opname_lines l where l.opname_id = o.id and l.diff <> 0) as diff_count,
         case when public.can_see_cost() then (select round(sum(l.diff * p.cost), 2) from public.opname_lines l join public.products p on p.sku = l.sku where l.opname_id = o.id and l.diff <> 0) end as diff_value
    from public.opnames o
   where public.is_active();

-- Saat masih dihitung, angka sistem disembunyikan (hitung buta)
create view public.v_opname_lines with (security_barrier) as
  select o.doc_no, o.period, o.status as so_status, l.opname_id, l.sku, p.name, p.brand_code, l.counted,
         case when o.status = 'counting' then null else l.system_qty end as system_qty,
         case when o.status = 'counting' then null else l.diff end as diff,
         l.reason, l.counted_name,
         case when public.can_see_cost() and o.status <> 'counting' then round(l.diff * p.cost, 2) end as diff_value
    from public.opname_lines l join public.opnames o on o.id = l.opname_id join public.products p on p.sku = l.sku
   where public.is_active();

create or replace function public.dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_today date := public._today(); v_cost boolean := public.can_see_cost(); v_warn int;
begin
  if not public.is_active() then return null; end if;
  select warn_months into v_warn from public.settings where id = 1;
  return jsonb_build_object(
    'today', v_today,
    'total_qty', (select coalesce(sum(qty),0) from public.lots),
    'stock_value', case when v_cost then (select coalesce(sum(l.qty*p.cost),0) from public.lots l join public.products p on p.sku = l.sku) end,
    'expired_qty', (select coalesce(sum(qty),0) from public.lots where ed < v_today),
    'near_qty', (select coalesce(sum(qty),0) from public.lots where ed >= v_today and ed <= (v_today + make_interval(months => v_warn))::date),
    'risk_value', case when v_cost then (select coalesce(sum(l.qty*p.cost),0) from public.lots l join public.products p on p.sku = l.sku where l.ed <= (v_today + make_interval(months => v_warn))::date) end,
    'below_min', (select count(*) from (select p.sku from public.products p left join public.lots l on l.sku = p.sku where p.active and p.min_stock > 0 group by p.sku, p.min_stock having coalesce(sum(l.qty),0) < p.min_stock) z),
    'in_today', (select coalesce(sum(x.qty),0) from public.inbound_lines x join public.inbounds i on i.id = x.inbound_id where i.doc_date = v_today),
    'out_today', (select coalesce(sum(x.qty),0) from public.outbound_lines x join public.outbounds o on o.id = x.outbound_id where o.doc_date = v_today and o.status = 'posted'),
    'out_month', (select coalesce(sum(x.qty),0) from public.outbound_lines x join public.outbounds o on o.id = x.outbound_id where date_trunc('month', o.doc_date) = date_trunc('month', v_today) and o.status = 'posted'),
    'pending_out', (select count(*) from public.outbounds where status = 'pending'),
    'unverified_in', (select count(*) from public.inbounds where verified_at is null),
    'so_week', to_char(v_today, 'IYYY-"W"IW'),
    'so_open', (select jsonb_build_object('id', id, 'doc_no', doc_no, 'status', status) from public.opnames where status in ('counting','submitted') limit 1),
    'so_done_this_week', exists (select 1 from public.opnames where status = 'approved' and period = to_char(v_today, 'IYYY-"W"IW')),
    'pending_users', case when public.my_role() = 'owner' then (select count(*) from public.profiles where not active) end
  );
end $$;

-- FOTO KEMASAN & SKU BUNDLING
create or replace function public.set_product_photo(p_sku text, p_photo text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require('owner');
  if not exists (select 1 from public.products where sku = upper(trim(p_sku))) then raise exception 'SKU % tidak dikenal', p_sku; end if;
  if p_photo is null or p_photo = '' then delete from public.product_photos where sku = upper(trim(p_sku)); return; end if;
  if length(p_photo) >= 400000 then raise exception 'Foto terlalu besar'; end if;
  insert into public.product_photos (sku, photo) values (upper(trim(p_sku)), p_photo)
  on conflict (sku) do update set photo = excluded.photo, updated_at = now();
end $$;

-- p: {sku, name, active, items:[{sku, qty}]}
create or replace function public.save_bundle(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare v_sku text := upper(trim(p->>'sku')); r jsonb; v_item text; v_n int := 0;
begin
  perform public._require('owner');
  if v_sku is null or v_sku !~ '^[A-Z0-9._-]{2,40}$' then raise exception 'Kode SKU bundling tidak valid: 2–40 huruf/angka/titik/minus, tanpa spasi'; end if;
  if exists (select 1 from public.products where sku = v_sku) then raise exception 'Kode % sudah dipakai produk biasa', v_sku; end if;
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'Nama bundling wajib diisi'; end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'Isi bundling minimal 1 produk'; end if;
  insert into public.bundles (sku, name, active) values (v_sku, trim(p->>'name'), coalesce((p->>'active')::boolean, true))
  on conflict (sku) do update set name = excluded.name, active = excluded.active, updated_at = now();
  delete from public.bundle_items where bundle_sku = v_sku;
  for r in select * from jsonb_array_elements(p->'items') loop
    v_item := upper(trim(r->>'sku'));
    if not exists (select 1 from public.products where sku = v_item) then raise exception 'SKU % tidak dikenal', r->>'sku'; end if;
    if coalesce((r->>'qty')::numeric, 0) <= 0 then raise exception 'Jumlah % harus lebih dari 0', v_item; end if;
    insert into public.bundle_items (bundle_sku, sku, qty) values (v_sku, v_item, (r->>'qty')::numeric)
    on conflict (bundle_sku, sku) do update set qty = public.bundle_items.qty + excluded.qty;
    v_n := v_n + 1;
  end loop;
  return v_sku;
end $$;

-- ---------------------------------------------------------------------
-- HAK AKSES
-- ---------------------------------------------------------------------
do $$ declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

grant usage on schema public to authenticated;
grant select on public.v_settings, public.v_brands, public.v_suppliers, public.v_products, public.v_lots, public.v_stock,
                public.v_moves, public.v_inbounds, public.v_inbound_lines, public.v_outbounds, public.v_outbound_lines,
                public.v_opnames, public.v_opname_lines, public.v_product_photos, public.v_bundles
   to authenticated;

grant execute on function
  public.my_role(), public.is_active(), public.can_see_cost(), public._me_name(), public._today(), public._q(numeric),
  public.my_profile(), public.save_product(jsonb), public.import_products(jsonb), public.save_brand(text, text),
  public.save_supplier(text, text, text), public.create_inbound(jsonb), public.verify_inbound(uuid), public.inbound_photo(uuid),
  public.create_outbound(jsonb), public.decide_outbound(uuid, boolean, text),
  public.so_start(text), public.so_save(uuid, jsonb), public.so_submit(uuid), public.so_set_reasons(uuid, jsonb),
  public.so_reopen(uuid), public.so_cancel(uuid), public.so_approve(uuid),
  public.list_users(), public.update_user(uuid, text, boolean, text), public.update_my_name(text),
  public.save_settings(text, int), public.dashboard(), public.set_product_photo(text, text), public.save_bundle(jsonb)
to authenticated;

-- Brand awal (bisa diubah di aplikasi)
insert into public.brands values ('ZDO', 'Zerodeo'), ('DKM', 'Depot Kimia') on conflict do nothing;

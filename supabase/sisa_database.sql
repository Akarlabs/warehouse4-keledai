-- Sisa database Warehouse Sistem 4 Keledai (foto kemasan, bundling, hak akses)
-- Tempel SELURUH isi file ini di Supabase > SQL Editor > New query > Run

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


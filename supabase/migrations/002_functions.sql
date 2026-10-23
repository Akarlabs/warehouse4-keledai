-- =====================================================================
-- Warehouse Sistem 4 Keledai — 002 Fungsi, trigger & RPC
-- Semua perubahan stok terjadi di sini (security definer), bukan dari
-- aplikasi langsung. Pesan error ditulis dalam Bahasa Indonesia karena
-- langsung ditampilkan ke pengguna.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Helper peran & akses
-- ---------------------------------------------------------------------
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and active
$$;

create or replace function public.my_warehouse() returns uuid
language sql stable security definer set search_path = public as $$
  select warehouse_id from public.profiles where id = auth.uid() and active
$$;

create or replace function public.has_role(variadic p_roles text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role from public.profiles where id = auth.uid() and active) = any(p_roles), false)
$$;

-- Petugas gudang yang ditugaskan ke satu gudang hanya boleh mengurus gudang itu.
create or replace function public.can_use_warehouse(p_wh uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select case
             when p.role = 'gudang' and p.warehouse_id is not null then p.warehouse_id = p_wh
             else true
           end
    from public.profiles p where p.id = auth.uid() and p.active
  ), false)
$$;

create or replace function public._require_role(variadic p_roles text[]) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_role(variadic p_roles) then
    raise exception 'Akses ditolak: fitur ini hanya untuk peran %', array_to_string(p_roles, ', ')
      using errcode = '42501';
  end if;
end $$;

create or replace function public._require_warehouse(p_wh uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_use_warehouse(p_wh) then
    raise exception 'Akses ditolak: Anda hanya boleh mengurus gudang yang ditugaskan ke Anda'
      using errcode = '42501';
  end if;
end $$;

create or replace function public._q(p numeric) returns text
language sql immutable as $$ select trim_scale(coalesce(p, 0))::text $$;

-- Format Rupiah: Rp 1.250.000
create or replace function public._rp(p numeric) returns text
language sql immutable as $$
  select 'Rp ' || replace(to_char(round(coalesce(p, 0)), 'FM999,999,999,999,990'), ',', '.')
$$;

-- ---------------------------------------------------------------------
-- Penomoran dokumen: PREFIX-YYMM-0001
-- ---------------------------------------------------------------------
create or replace function public._next_doc_no(p_prefix text) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_tz text;
  v_period text;
  v_no int;
begin
  select timezone into v_tz from public.settings where id = 1;
  v_period := to_char(now() at time zone coalesce(v_tz, 'Asia/Jakarta'), 'YYMM');
  insert into public.doc_counters (prefix, period, last_no) values (p_prefix, v_period, 1)
  on conflict (prefix, period) do update set last_no = public.doc_counters.last_no + 1
  returning last_no into v_no;
  return p_prefix || '-' || v_period || '-' || lpad(v_no::text, 4, '0');
end $$;

create or replace function public._tg_doc_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.doc_no := public._next_doc_no(tg_argv[0]);
  new.created_by := coalesce(auth.uid(), new.created_by);
  return new;
end $$;

create trigger trg_inbounds_doc     before insert on public.inbounds     for each row execute function public._tg_doc_defaults('IN');
create trigger trg_outbounds_doc    before insert on public.outbounds    for each row execute function public._tg_doc_defaults('OUT');
create trigger trg_transfers_doc    before insert on public.transfers    for each row execute function public._tg_doc_defaults('TRF');
create trigger trg_relocations_doc  before insert on public.relocations  for each row execute function public._tg_doc_defaults('PND');
create trigger trg_counts_doc       before insert on public.stock_counts for each row execute function public._tg_doc_defaults('OPN');
create trigger trg_adjustments_doc  before insert on public.adjustments  for each row execute function public._tg_doc_defaults('ADJ');
create trigger trg_so_doc           before insert on public.sales_orders for each row execute function public._tg_doc_defaults('SO');

-- ---------------------------------------------------------------------
-- Normalisasi master data
-- ---------------------------------------------------------------------
create or replace function public._tg_upper_code() returns trigger
language plpgsql as $$
begin
  new.code := upper(trim(new.code));
  return new;
end $$;

create trigger trg_brands_code     before insert or update on public.brands     for each row execute function public._tg_upper_code();
create trigger trg_warehouses_code before insert or update on public.warehouses for each row execute function public._tg_upper_code();
create trigger trg_customers_code  before insert or update on public.customers  for each row execute function public._tg_upper_code();

create or replace function public._tg_location_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_wh text;
begin
  new.code := upper(trim(new.code));
  if tg_op = 'UPDATE' and new.warehouse_id <> old.warehouse_id then
    raise exception 'Lokasi tidak bisa dipindah ke gudang lain. Buat lokasi baru.';
  end if;
  if new.barcode is null or trim(new.barcode) = '' then
    select code into v_wh from public.warehouses where id = new.warehouse_id;
    new.barcode := 'L-' || v_wh || '-' || new.code;
  else
    new.barcode := trim(new.barcode);
  end if;
  return new;
end $$;
create trigger trg_locations_defaults before insert or update on public.locations
  for each row execute function public._tg_location_defaults();

-- Setiap gudang baru otomatis punya lokasi penerimaan "TERIMA"
create or replace function public._tg_warehouse_default_location() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.locations (warehouse_id, code, name, kind)
  values (new.id, 'TERIMA', 'Area penerimaan', 'penerimaan');
  return null;
end $$;
create trigger trg_warehouse_default_location after insert on public.warehouses
  for each row execute function public._tg_warehouse_default_location();

create or replace function public._tg_product_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.sku := trim(new.sku);
  new.barcode := nullif(trim(coalesce(new.barcode, '')), '');
  new.name := trim(new.name);
  new.updated_at := now();
  if tg_op = 'UPDATE' and new.track_batch <> old.track_batch
     and exists (select 1 from public.stock_balances where product_id = new.id and qty > 0) then
    raise exception 'Pengaturan batch produk % tidak bisa diubah selama masih ada stok', new.sku;
  end if;
  return new;
end $$;
create trigger trg_products_defaults before insert or update on public.products
  for each row execute function public._tg_product_defaults();

-- Profil otomatis saat akun dibuat. Akun pertama = owner aktif.
-- Akun berikutnya nonaktif sampai diaktifkan owner/admin.
create or replace function public._tg_handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_first boolean;
begin
  select not exists (select 1 from public.profiles) into v_first;
  insert into public.profiles (id, email, full_name, role, active)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    case when v_first then 'owner' else 'gudang' end,
    v_first
  )
  on conflict (id) do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public._tg_handle_new_user();

-- ---------------------------------------------------------------------
-- Pencarian kode hasil scan (produk atau lokasi)
-- ---------------------------------------------------------------------
create or replace function public._resolve_product(p_code text) returns public.products
language plpgsql stable security definer set search_path = public as $$
declare
  v public.products;
  v_code text := trim(coalesce(p_code, ''));
begin
  if v_code = '' then
    raise exception 'Kode produk kosong';
  end if;
  select * into v from public.products where barcode = v_code limit 1;
  if not found then
    select * into v from public.products where lower(sku) = lower(v_code) limit 1;
  end if;
  if not found then
    raise exception 'Barcode/SKU "%" tidak dikenal. Daftarkan dulu di menu Produk.', v_code;
  end if;
  if not v.active then
    raise exception 'Produk % (%) sedang nonaktif', v.name, v.sku;
  end if;
  return v;
end $$;

create or replace function public.lookup_code(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_code text := trim(coalesce(p_code, ''));
  p public.products;
  l public.locations;
  v_brand text;
begin
  if public.my_role() is null then
    raise exception 'Akses ditolak' using errcode = '42501';
  end if;
  if v_code = '' then return null; end if;

  select * into p from public.products where barcode = v_code limit 1;
  if not found then
    select * into p from public.products where lower(sku) = lower(v_code) limit 1;
  end if;
  if found then
    select name into v_brand from public.brands where id = p.brand_id;
    return jsonb_build_object(
      'type', 'product', 'id', p.id, 'sku', p.sku, 'barcode', p.barcode, 'name', p.name,
      'brand', v_brand, 'uom', p.uom, 'track_batch', p.track_batch, 'active', p.active,
      'default_cost', p.default_cost, 'default_price', p.default_price);
  end if;

  select * into l from public.locations where barcode = v_code limit 1;
  if found then
    return jsonb_build_object(
      'type', 'location', 'id', l.id, 'code', l.code, 'name', l.name, 'kind', l.kind,
      'warehouse_id', l.warehouse_id, 'active', l.active);
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------
-- Batch
-- ---------------------------------------------------------------------
-- Validasi input batch tanpa membuat data. Mengembalikan nomor batch yang
-- sudah dinormalisasi (huruf besar, tanpa spasi tepi).
create or replace function public._check_batch_input(
  p_product_id uuid, p_batch_no text, p_expiry date
) returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_p public.products;
  v_no text;
  v_exp date;
begin
  select * into v_p from public.products where id = p_product_id;
  if not found then raise exception 'Produk tidak ditemukan'; end if;
  if not v_p.track_batch then
    return '-';
  end if;
  v_no := upper(trim(coalesce(p_batch_no, '')));
  if v_no = '' or v_no = '-' then
    raise exception 'Nomor batch wajib diisi untuk % (%)', v_p.name, v_p.sku;
  end if;
  select expiry_date into v_exp from public.batches where product_id = p_product_id and batch_no = v_no;
  if found then
    if p_expiry is not null and v_exp is not null and v_exp <> p_expiry then
      raise exception 'Batch % untuk % sudah tercatat dengan expired %, berbeda dengan input %',
        v_no, v_p.sku, to_char(v_exp, 'DD-MM-YYYY'), to_char(p_expiry, 'DD-MM-YYYY');
    end if;
  elsif p_expiry is null then
    raise exception 'Tanggal expired wajib diisi untuk batch baru % (%)', v_no, v_p.sku;
  end if;
  return v_no;
end $$;

create or replace function public._get_or_create_batch(
  p_product_id uuid, p_batch_no text, p_expiry date, p_cost numeric default 0
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_no text;
  v_id uuid;
  v_exp date;
  v_default_cost numeric;
begin
  v_no := public._check_batch_input(p_product_id, p_batch_no, p_expiry);
  select id, expiry_date into v_id, v_exp from public.batches
   where product_id = p_product_id and batch_no = v_no;
  if found then
    if v_exp is null and p_expiry is not null and v_no <> '-' then
      update public.batches set expiry_date = p_expiry where id = v_id;
    end if;
    return v_id;
  end if;
  select default_cost into v_default_cost from public.products where id = p_product_id;
  insert into public.batches (product_id, batch_no, expiry_date, unit_cost)
  values (p_product_id, v_no, case when v_no = '-' then null else p_expiry end,
          coalesce(nullif(p_cost, 0), v_default_cost, 0))
  on conflict (product_id, batch_no) do update set batch_no = excluded.batch_no
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Buku besar stok
-- ---------------------------------------------------------------------
create or replace function public._tg_stock_move_apply() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_cur numeric;
  v_sku text;
  v_batch text;
  v_loc text;
begin
  if not exists (select 1 from public.batches where id = new.batch_id and product_id = new.product_id) then
    raise exception 'Batch tidak cocok dengan produk';
  end if;
  select warehouse_id into new.warehouse_id from public.locations where id = new.location_id;
  if new.warehouse_id is null then
    raise exception 'Lokasi tidak ditemukan';
  end if;
  new.created_by := coalesce(auth.uid(), new.created_by);

  if new.qty > 0 then
    insert into public.stock_balances (batch_id, location_id, product_id, warehouse_id, qty, updated_at)
    values (new.batch_id, new.location_id, new.product_id, new.warehouse_id, new.qty, now())
    on conflict (batch_id, location_id)
      do update set qty = public.stock_balances.qty + excluded.qty, updated_at = now();
  else
    select qty into v_cur from public.stock_balances
     where batch_id = new.batch_id and location_id = new.location_id
     for update;
    if coalesce(v_cur, 0) + new.qty < 0 then
      select p.sku, b.batch_no, l.code into v_sku, v_batch, v_loc
        from public.products p, public.batches b, public.locations l
       where p.id = new.product_id and b.id = new.batch_id and l.id = new.location_id;
      raise exception 'Stok tidak cukup: % batch % di lokasi % (tersedia %, dibutuhkan %)',
        v_sku, v_batch, v_loc, public._q(coalesce(v_cur, 0)), public._q(-new.qty)
        using errcode = 'P0001';
    end if;
    update public.stock_balances set qty = qty + new.qty, updated_at = now()
     where batch_id = new.batch_id and location_id = new.location_id;
  end if;
  return new;
end $$;
create trigger trg_stock_move_apply before insert on public.stock_moves
  for each row execute function public._tg_stock_move_apply();

create or replace function public._tg_stock_move_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'Riwayat stok tidak boleh diubah atau dihapus. Gunakan dokumen penyesuaian.';
end $$;
create trigger trg_stock_move_no_update before update or delete on public.stock_moves
  for each row execute function public._tg_stock_move_immutable();
create trigger trg_stock_move_no_truncate before truncate on public.stock_moves
  for each statement execute function public._tg_stock_move_immutable();

create or replace function public._move(
  p_product uuid, p_batch uuid, p_location uuid, p_qty numeric, p_cost numeric,
  p_type text, p_doc_type text, p_doc_id uuid, p_doc_no text, p_note text default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_qty = 0 then return; end if;
  insert into public.stock_moves
    (product_id, batch_id, location_id, warehouse_id, qty, unit_cost, move_type, doc_type, doc_id, doc_no, note)
  values
    (p_product, p_batch, p_location, (select warehouse_id from public.locations where id = p_location),
     p_qty, coalesce(p_cost, 0), p_type, p_doc_type, p_doc_id, p_doc_no, p_note);
end $$;

-- Stok yang sudah dialokasikan ke dokumen draft lain (outbound & transfer)
create or replace function public._reserved_qty(p_batch uuid, p_location uuid, p_exclude_doc uuid default null)
returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(x.qty), 0) from (
    select op.qty from public.outbound_picks op
      join public.outbounds o on o.id = op.outbound_id
     where o.status = 'draft' and op.batch_id = p_batch and op.location_id = p_location
       and o.id is distinct from p_exclude_doc
    union all
    select tl.qty from public.transfer_lines tl
      join public.transfers t on t.id = tl.transfer_id
     where t.status = 'draft' and tl.batch_id = p_batch and tl.from_location_id = p_location
       and t.id is distinct from p_exclude_doc
  ) x
$$;

-- Kandidat pengambilan FEFO: expired terdekat dulu, lalu batch terlama.
-- Batch kedaluwarsa & lokasi karantina tidak ikut.
create or replace function public._fefo_candidates(p_wh uuid, p_product uuid, p_exclude_doc uuid default null)
returns table (batch_id uuid, location_id uuid, available numeric)
language sql stable security definer set search_path = public as $$
  select sb.batch_id, sb.location_id,
         sb.qty - public._reserved_qty(sb.batch_id, sb.location_id, p_exclude_doc) as available
    from public.stock_balances sb
    join public.batches b on b.id = sb.batch_id
    join public.locations l on l.id = sb.location_id
   where sb.warehouse_id = p_wh
     and sb.product_id = p_product
     and sb.qty > 0
     and l.active
     and l.kind <> 'karantina'
     and (b.expiry_date is null or b.expiry_date >= current_date)
   order by b.expiry_date nulls last, b.created_at, b.batch_no,
            case l.kind when 'pengiriman' then 0 when 'rak' then 1 else 2 end, l.code
$$;

-- ---------------------------------------------------------------------
-- BARANG MASUK
-- ---------------------------------------------------------------------
create or replace function public.inbound_add_line(
  p_inbound_id uuid, p_code text, p_qty numeric, p_location_id uuid,
  p_batch_no text default null, p_expiry date default null,
  p_unit_cost numeric default 0, p_scanned boolean default true
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.inbounds;
  v_p public.products;
  v_batch text;
  v_line uuid;
  v_qty numeric;
begin
  perform public._require_role('owner', 'admin', 'gudang');
  select * into v_doc from public.inbounds where id = p_inbound_id for update;
  if not found then raise exception 'Dokumen tidak ditemukan'; end if;
  perform public._require_warehouse(v_doc.warehouse_id);
  if v_doc.status <> 'draft' then
    raise exception 'Dokumen % sudah %, tidak bisa ditambah', v_doc.doc_no, v_doc.status;
  end if;
  if coalesce(p_qty, 0) <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  if not exists (select 1 from public.locations where id = p_location_id
                  and warehouse_id = v_doc.warehouse_id and active) then
    raise exception 'Lokasi tidak valid untuk gudang dokumen ini';
  end if;

  v_p := public._resolve_product(p_code);
  v_batch := public._check_batch_input(v_p.id, p_batch_no, p_expiry);

  select id into v_line from public.inbound_lines
   where inbound_id = p_inbound_id and product_id = v_p.id and batch_no = v_batch
     and location_id = p_location_id and unit_cost = coalesce(p_unit_cost, 0)
     and expiry_date is not distinct from (case when v_batch = '-' then null else p_expiry end)
   limit 1;

  if found then
    update public.inbound_lines set qty = qty + p_qty where id = v_line returning qty into v_qty;
  else
    insert into public.inbound_lines
      (inbound_id, product_id, batch_no, expiry_date, location_id, qty, unit_cost, scanned)
    values
      (p_inbound_id, v_p.id, v_batch, case when v_batch = '-' then null else p_expiry end,
       p_location_id, p_qty, coalesce(p_unit_cost, 0), p_scanned)
    returning id, qty into v_line, v_qty;
  end if;

  return jsonb_build_object('line_id', v_line, 'sku', v_p.sku, 'name', v_p.name,
                            'batch_no', v_batch, 'qty', v_qty);
end $$;

create or replace function public.post_inbound(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.inbounds;
  r record;
  v_batch uuid;
  v_cur_qty numeric;
  v_cur_cost numeric;
  v_cost numeric;
  v_bad text;
begin
  perform public._require_role('owner', 'admin', 'gudang');
  select * into v_doc from public.inbounds where id = p_id for update;
  if not found then raise exception 'Dokumen tidak ditemukan'; end if;
  perform public._require_warehouse(v_doc.warehouse_id);
  if v_doc.status <> 'draft' then
    raise exception 'Dokumen % sudah %', v_doc.doc_no, v_doc.status;
  end if;
  if not exists (select 1 from public.inbound_lines where inbound_id = p_id) then
    raise exception 'Dokumen % belum berisi barang', v_doc.doc_no;
  end if;

  select string_agg(distinct l.code, ', ') into v_bad
    from public.inbound_lines il join public.locations l on l.id = il.location_id
   where il.inbound_id = p_id and (l.warehouse_id <> v_doc.warehouse_id or not l.active);
  if v_bad is not null then
    raise exception 'Lokasi bukan milik gudang ini atau nonaktif: %', v_bad;
  end if;

  select string_agg(distinct p.sku, ', ') into v_bad
    from public.inbound_lines il join public.products p on p.id = il.product_id
   where il.inbound_id = p_id and not p.active;
  if v_bad is not null then
    raise exception 'Produk nonaktif: %', v_bad;
  end if;

  for r in
    select il.* from public.inbound_lines il where il.inbound_id = p_id order by il.created_at, il.id
  loop
    v_batch := public._get_or_create_batch(r.product_id, r.batch_no, r.expiry_date, r.unit_cost);
    select unit_cost into v_cur_cost from public.batches where id = v_batch for update;
    select coalesce(sum(qty), 0) into v_cur_qty from public.stock_balances where batch_id = v_batch;
    v_cost := case when r.unit_cost > 0 then r.unit_cost else v_cur_cost end;
    -- Harga pokok rata-rata tertimbang per batch
    update public.batches
       set unit_cost = round((v_cur_qty * v_cur_cost + r.qty * v_cost) / (v_cur_qty + r.qty), 2)
     where id = v_batch;
    perform public._move(r.product_id, v_batch, r.location_id, r.qty, v_cost,
                         'masuk', 'inbound', p_id, v_doc.doc_no, v_doc.source);
  end loop;

  update public.inbounds set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- BARANG KELUAR
-- ---------------------------------------------------------------------
create or replace function public._allocate_outbound(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.outbounds;
  it record;
  c record;
  v_rem numeric;
  v_take numeric;
  v_short text[] := '{}';
begin
  select * into v_doc from public.outbounds where id = p_id for update;
  if v_doc.status <> 'draft' then
    raise exception 'Dokumen % sudah %', v_doc.doc_no, v_doc.status;
  end if;
  if exists (select 1 from public.outbound_picks where outbound_id = p_id and picked_qty > 0) then
    raise exception 'Sudah ada barang yang di-scan. Tekan "Reset scan" dulu sebelum alokasi ulang.';
  end if;
  perform pg_advisory_xact_lock(hashtext('alloc:' || v_doc.warehouse_id::text));

  delete from public.outbound_picks where outbound_id = p_id;

  for it in
    select oi.product_id, oi.qty, p.sku
      from public.outbound_items oi join public.products p on p.id = oi.product_id
     where oi.outbound_id = p_id order by p.sku
  loop
    v_rem := it.qty;
    for c in select * from public._fefo_candidates(v_doc.warehouse_id, it.product_id, p_id) loop
      exit when v_rem <= 0;
      v_take := least(c.available, v_rem);
      if v_take > 0 then
        insert into public.outbound_picks (outbound_id, product_id, batch_id, location_id, qty)
        values (p_id, it.product_id, c.batch_id, c.location_id, v_take);
        v_rem := v_rem - v_take;
      end if;
    end loop;
    if v_rem > 0 then
      v_short := v_short || format('%s kurang %s', it.sku, public._q(v_rem));
    end if;
  end loop;

  if array_length(v_short, 1) > 0 then
    raise exception 'Stok siap kirim tidak cukup: %', array_to_string(v_short, '; ');
  end if;
end $$;

create or replace function public.allocate_outbound(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_wh uuid;
begin
  perform public._require_role('owner', 'admin', 'gudang');
  select warehouse_id into v_wh from public.outbounds where id = p_id;
  if not found then raise exception 'Dokumen tidak ditemukan'; end if;
  perform public._require_warehouse(v_wh);
  if not exists (select 1 from public.outbound_items where outbound_id = p_id) then
    raise exception 'Isi daftar barang yang akan dikeluarkan dulu';
  end if;
  perform public._allocate_outbound(p_id);
end $$;

-- Tambah/ubah permintaan barang keluar (per produk)
create or replace function public.outbound_set_item(p_outbound_id uuid, p_code text, p_qty numeric, p_add boolean default true)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.outbounds;
  v_p public.products;
  v_qty numeric;
begin
  perform public._require_role('owner', 'admin', 'gudang');
  select * into v_doc from public.outbounds where id = p_outbound_id for update;
  if not found then raise exception 'Dokumen tidak ditemukan'; end if;
  perform public._require_warehouse(v_doc.warehouse_id);
  if v_doc.status <> 'draft' then raise exception 'Dokumen % sudah %', v_doc.doc_no, v_doc.status; end if;
  if v_doc.sales_order_id is not null or v_doc.purpose = 'marketplace' then
    raise exception 'Daftar barang dokumen ini mengikuti pesanan. Ubah pesanannya, bukan dokumen keluar.';
  end if;
  if exists (select 1 from public.outbound_picks where outbound_id = p_outbound_id and picked_qty > 0) then
    raise exception 'Sudah ada barang yang di-scan. Reset scan dulu untuk mengubah daftar.';
  end if;
  v_p := public._resolve_product(p_code);

  if p_add then
    if coalesce(p_qty, 0) <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
    insert into public.outbound_items (outbound_id, product_id, qty) values (p_outbound_id, v_p.id, p_qty)
    on conflict (outbound_id, product_id) do update set qty = public.outbound_items.qty + excluded.qty
    returning qty into v_qty;
  elsif coalesce(p_qty, 0) <= 0 then
    delete from public.outbound_items where outbound_id = p_outbound_id and product_id = v_p.id;
    v_qty := 0;
  else
    insert into public.outbound_items (outbound_id, product_id, qty) values (p_outbound_id, v_p.id, p_qty)
    on conflict (outbound_id, product_id) do update set qty = excluded.qty
    returning qty into v_qty;
  end if;
  -- alokasi lama tidak berlaku lagi
  delete from public.outbound_picks where outbound_id = p_outbound_id;
  return jsonb_build_object('sku', v_p.sku, 'name', v_p.name, 'qty', v_qty);
end $$;

-- Scan ambil barang untuk dokumen keluar atau transfer
create or replace function public.pick_scan(
  p_doc_type text, p_doc_id uuid, p_code text, p_qty numeric default 1, p_location_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_p public.products;
  v_wh uuid;
  v_status text;
  v_left numeric := p_qty;
  v_take numeric;
  r record;
  v_remaining numeric;
begin
  perform public._require_role('owner', 'admin', 'gudang');
  if coalesce(p_qty, 0) <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  v_p := public._resolve_product(p_code);

  if p_doc_type = 'outbound' then
    select warehouse_id, status into v_wh, v_status from public.outbounds where id = p_doc_id for update;
  elsif p_doc_type = 'transfer' then
    select from_warehouse_id, status into v_wh, v_status from public.transfers where id = p_doc_id for update;
  else
    raise exception 'Jenis dokumen tidak dikenal';
  end if;
  if v_wh is null then raise exception 'Dokumen tidak ditemukan'; end if;
  perform public._require_warehouse(v_wh);
  if v_status <> 'draft' then raise exception 'Dokumen sudah %, tidak bisa di-scan', v_status; end if;

  if p_doc_type = 'outbound' then
    for r in
      select op.id, op.qty, op.picked_qty from public.outbound_picks op
        join public.batches b on b.id = op.batch_id
        join public.locations l on l.id = op.location_id
       where op.outbound_id = p_doc_id and op.product_id = v_p.id and op.picked_qty < op.qty
         and (p_location_id is null or op.location_id = p_location_id)
       order by b.expiry_date nulls last, l.code
       for update of op
    loop
      exit when v_left <= 0;
      v_take := least(v_left, r.qty - r.picked_qty);
      update public.outbound_picks set picked_qty = picked_qty + v_take where id = r.id;
      v_left := v_left - v_take;
    end loop;
    select coalesce(sum(qty - picked_qty), 0) into v_remaining
      from public.outbound_picks where outbound_id = p_doc_id and product_id = v_p.id;
    if not exists (select 1 from public.outbound_picks where outbound_id = p_doc_id and product_id = v_p.id) then
      raise exception 'SALAH BARANG: % (%) tidak ada di daftar ambil dokumen ini', v_p.name, v_p.sku;
    end if;
  else
    for r in
      select tl.id, tl.qty, tl.picked_qty from public.transfer_lines tl
        join public.batches b on b.id = tl.batch_id
        join public.locations l on l.id = tl.from_location_id
       where tl.transfer_id = p_doc_id and tl.product_id = v_p.id and tl.picked_qty < tl.qty
         and (p_location_id is null or tl.from_location_id = p_location_id)
       order by b.expiry_date nulls last, l.code
       for update of tl
    loop
      exit when v_left <= 0;
      v_take := least(v_left, r.qty - r.picked_qty);
      update public.transfer_lines set picked_qty = picked_qty + v_take where id = r.id;
      v_left := v_left - v_take;
    end loop;
    if not exists (select 1 from public.transfer_lines where transfer_id = p_doc_id and product_id = v_p.id) then
      raise exception 'SALAH BARANG: % (%) tidak ada di daftar kirim transfer ini', v_p.name, v_p.sku;
    end if;
    select coalesce(sum(qty - picked_qty), 0) into v_remaining
      from public.transfer_lines where transfer_id = p_doc_id and product_id = v_p.id;
  end if;

  if v_left > 0 then
    if p_location_id is not null and v_left = p_qty and v_remaining > 0 then
      raise exception 'SALAH RAK: % tidak dijadwalkan diambil dari lokasi ini. Cek lokasi di daftar ambil.', v_p.sku;
    end if;
    raise exception 'KELEBIHAN: % sudah lengkap. Kelebihan % %, kembalikan ke rak.',
      v_p.sku, public._q(v_left), v_p.uom;
  end if;

  return jsonb_build_object('sku', v_p.sku, 'name', v_p.name, 'remaining', v_remaining);
end $$;

create or replace function public.pick_reset(p_doc_type text, p_doc_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_wh uuid; v_status text;
begin
  perform public._require_role('owner', 'admin', 'gudang');
  if p_doc_type = 'outbound' then
    select warehouse_id, status into v_wh, v_status from public.outbounds where id = p_doc_id;
  else
    select from_warehouse_id, status into v_wh, v_status from public.transfers where id = p_doc_id;
  end if;
  if v_wh is null then raise exception 'Dokumen tidak ditemukan'; end if;
  perform public._require_warehouse(v_wh);
  if v_status <> 'draft' then raise exception 'Dokumen sudah %', v_status; end if;
  if p_doc_type = 'outbound' then
    update public.outbound_picks set picked_qty = 0 where outbound_id = p_doc_id;
  else
    update public.transfer_lines set picked_qty = 0 where transfer_id = p_doc_id;
  end if;
end $$;

create or replace function public.post_outbound(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.outbounds;
  v_bad text;
  r record;
begin
  perform public._require_role('owner', 'admin', 'gudang');
  select * into v_doc from public.outbounds where id = p_id for update;
  if not found then raise exception 'Dokumen tidak ditemukan'; end if;
  perform public._require_warehouse(v_doc.warehouse_id);
  if v_doc.status <> 'draft' then raise exception 'Dokumen % sudah %', v_doc.doc_no, v_doc.status; end if;
  if not exists (select 1 from public.outbound_items where outbound_id = p_id) then
    raise exception 'Dokumen % belum berisi barang', v_doc.doc_no;
  end if;

  -- Alokasi harus sama persis dengan permintaan
  with i as (select product_id, sum(qty) q from public.outbound_items where outbound_id = p_id group by 1),
       k as (select product_id, sum(qty) q from public.outbound_picks where outbound_id = p_id group by 1)
  select string_agg(format('%s (diminta %s, dialokasikan %s)', p.sku, public._q(coalesce(i.q, 0)), public._q(coalesce(k.q, 0))), '; ')
    into v_bad
    from i full join k using (product_id) join public.products p on p.id = product_id
   where coalesce(i.q, 0) <> coalesce(k.q, 0);
  if v_bad is not null then
    raise exception 'Alokasi belum sesuai permintaan: %. Tekan "Alokasi FEFO" dulu.', v_bad;
  end if;

  -- Konsistensi alokasi manual
  if exists (select 1 from public.outbound_picks op join public.batches b on b.id = op.batch_id
              where op.outbound_id = p_id and b.product_id <> op.product_id) then
    raise exception 'Ada batch yang tidak cocok dengan produknya';
  end if;
  if exists (select 1 from public.outbound_picks op join public.locations l on l.id = op.location_id
              where op.outbound_id = p_id and l.warehouse_id <> v_doc.warehouse_id) then
    raise exception 'Ada lokasi ambil yang bukan milik gudang ini';
  end if;
  if v_doc.purpose in ('marketplace', 'b2b') then
    select string_agg(distinct format('%s batch %s', p.sku, b.batch_no), ', ') into v_bad
      from public.outbound_picks op join public.batches b on b.id = op.batch_id
      join public.products p on p.id = op.product_id
     where op.outbound_id = p_id and b.expiry_date < current_date;
    if v_bad is not null then
      raise exception 'Batch sudah kedaluwarsa tidak boleh dikirim ke pelanggan: %', v_bad;
    end if;
  end if;

  if v_doc.mode = 'scan' then
    select string_agg(format('%s kurang %s', p.sku, public._q(s.q)), '; ') into v_bad
      from (select product_id, sum(qty - picked_qty) q from public.outbound_picks
             where outbound_id = p_id group by 1 having sum(qty - picked_qty) > 0) s
      join public.products p on p.id = s.product_id;
    if v_bad is not null then
      raise exception 'Masih ada barang yang belum di-scan: %', v_bad;
    end if;
  end if;

  for r in
    select op.*, b.unit_cost from public.outbound_picks op join public.batches b on b.id = op.batch_id
     where op.outbound_id = p_id order by op.id
  loop
    perform public._move(r.product_id, r.batch_id, r.location_id, -r.qty, r.unit_cost,
                         'keluar', 'outbound', p_id, v_doc.doc_no, v_doc.purpose);
  end loop;

  update public.outbound_picks set picked_qty = qty where outbound_id = p_id;
  update public.outbounds set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = p_id;

  if v_doc.sales_order_id is not null then
    update public.sales_orders set status = 'dikirim' where id = v_doc.sales_order_id;
  end if;
  update public.marketplace_orders set status = 'dikirim', updated_at = now()
   where outbound_id = p_id and status = 'diproses';
end $$;

-- ---------------------------------------------------------------------
-- TRANSFER ANTAR GUDANG
-- ---------------------------------------------------------------------
create or replace function public.transfer_set_item(p_transfer_id uuid, p_code text, p_qty numeric, p_add boolean default true)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.transfers;
  v_p public.products;
  v_qty numeric;
begin
  perform public._require_role('owner', 'admin', 'gudang');
  select * into v_doc from public.transfers where id = p_transfer_id for update;
  if not found then raise exception 'Dokumen tidak ditemukan'; end if;
  perform public._require_warehouse(v_doc.from_warehouse_id);
  if v_doc.status <> 'draft' then raise exception 'Transfer % sudah %', v_doc.doc_no, v_doc.status; end if;
  if exists (select 1 from public.transfer_lines where transfer_id = p_transfer_id and picked_qty > 0) then
    raise exception 'Sudah ada barang yang di-scan. Reset scan dulu untuk mengubah daftar.';
  end if;
  v_p := public._resolve_product(p_code);
  if p_add then
    if coalesce(p_qty, 0) <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
    insert into public.transfer_items (transfer_id, product_id, qty) values (p_transfer_id, v_p.id, p_qty)
    on conflict (transfer_id, product_id) do update set qty = public.transfer_items.qty + excluded.qty
    returning qty into v_qty;
  elsif coalesce(p_qty, 0) <= 0 then
    delete from public.transfer_items where transfer_id = p_transfer_id and product_id = v_p.id;
    v_qty := 0;
  else
    insert into public.transfer_items (transfer_id, product_id, qty) values (p_transfer_id, v_p.id, p_qty)
    on conflict (transfer_id, product_id) do update set qty = excluded.qty
    returning qty into v_qty;
  end if;
  delete from public.transfer_lines where transfer_id = p_transfer_id;
  return jsonb_build_object('sku', v_p.sku, 'name', v_p.name, 'qty', v_qty);
end $$;

create or replace function public.allocate_transfer(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.transfers;
  it record;
  c record;
  v_rem numeric;
  v_take numeric;
  v_short text[] := '{}';
begin
  perform public._require_role('owner', 'admin', 'gudang');
  select * into v_doc from public.transfers where id = p_id for update;
  if not found then raise exception 'Dokumen tidak ditemukan'; end if;
  perform public._require_warehouse(v_doc.from_warehouse_id);
  if v_doc.status <> 'draft' then raise exception 'Transfer % sudah %', v_doc.doc_no, v_doc.status; end if;
  if not exists (select 1 from public.transfer_items where transfer_id = p_id) then
    raise exception 'Isi daftar barang yang akan dikirim dulu';
  end if;
  if exists (select 1 from public.transfer_lines where transfer_id = p_id and picked_qty > 0) then
    raise exception 'Sudah ada barang yang di-scan. Tekan "Reset scan" dulu sebelum alokasi ulang.';
  end if;
  perform pg_advisory_xact_lock(hashtext('alloc:' || v_doc.from_warehouse_id::text));
  delete from public.transfer_lines where transfer_id = p_id;

  for it in
    select ti.product_id, ti.qty, p.sku from public.transfer_items ti
      join public.products p on p.id = ti.product_id
     where ti.transfer_id = p_id order by p.sku
  loop
    v_rem := it.qty;
    for c in select * from public._fefo_candidates(v_doc.from_warehouse_id, it.product_id, p_id) loop
      exit when v_rem <= 0;
      v_take := least(c.available, v_rem);
      if v_take > 0 then
        insert into public.transfer_lines (transfer_id, product_id, batch_id, from_location_id, qty)
        values (p_id, it.product_id, c.batch_id, c.location_id, v_take);
        v_rem := v_rem - v_take;
      end if;
    end loop;
    if v_rem > 0 then
      v_short := v_short || format('%s kurang %s', it.sku, public._q(v_rem));
    end if;
  end loop;
  if array_length(v_short, 1) > 0 then
    raise exception 'Stok tidak cukup untuk dikirim: %', array_to_string(v_short, '; ');
  end if;
end $$;

create or replace function public.send_transfer(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.transfers;
  v_bad text;
  r record;
begin
  perform public._require_role('owner', 'admin', 'gudang');
  select * into v_doc from public.transfers where id = p_id for update;
  if not found then raise exception 'Dokumen tidak ditemukan'; end if;
  perform public._require_warehouse(v_doc.from_warehouse_id);
  if v_doc.status <> 'draft' then raise exception 'Transfer % sudah %', v_doc.doc_no, v_doc.status; end if;

  with i as (select product_id, sum(qty) q from public.transfer_items where transfer_id = p_id group by 1),
       k as (select product_id, sum(qty) q from public.transfer_lines where transfer_id = p_id group by 1)
  select string_agg(format('%s (diminta %s, dialokasikan %s)', p.sku, public._q(coalesce(i.q, 0)), public._q(coalesce(k.q, 0))), '; ')
    into v_bad
    from i full join k using (product_id) join public.products p on p.id = product_id
   where coalesce(i.q, 0) <> coalesce(k.q, 0);
  if v_bad is not null then
    raise exception 'Alokasi belum sesuai permintaan: %. Tekan "Alokasi FEFO" dulu.', v_bad;
  end if;
  if not exists (select 1 from public.transfer_lines where transfer_id = p_id) then
    raise exception 'Transfer % belum berisi barang', v_doc.doc_no;
  end if;

  if v_doc.mode = 'scan' then
    select string_agg(format('%s kurang %s', p.sku, public._q(s.q)), '; ') into v_bad
      from (select product_id, sum(qty - picked_qty) q from public.transfer_lines
             where transfer_id = p_id group by 1 having sum(qty - picked_qty) > 0) s
      join public.products p on p.id = s.product_id;
    if v_bad is not null then
      raise exception 'Masih ada barang yang belum di-scan: %', v_bad;
    end if;
  end if;

  for r in
    select tl.*, b.unit_cost from public.transfer_lines tl join public.batches b on b.id = tl.batch_id
     where tl.transfer_id = p_id order by tl.id
  loop
    perform public._move(r.product_id, r.batch_id, r.from_location_id, -r.qty, r.unit_cost,
                         'transfer_keluar', 'transfer', p_id, v_doc.doc_no, null);
  end loop;
  update public.transfer_lines set picked_qty = qty where transfer_id = p_id;
  update public.transfers set status = 'dikirim', sent_by = auth.uid(), sent_at = now() where id = p_id;
end $$;

create or replace function public.receive_scan(
  p_transfer_id uuid, p_code text, p_qty numeric, p_location_id uuid
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.transfers;
  v_p public.products;
  v_left numeric := p_qty;
  v_take numeric;
  r record;
  v_remaining numeric;
begin
  perform public._require_role('owner', 'admin', 'gudang');
  select * into v_doc from public.transfers where id = p_transfer_id for update;
  if not found then raise exception 'Dokumen tidak ditemukan'; end if;
  perform public._require_warehouse(v_doc.to_warehouse_id);
  if v_doc.status <> 'dikirim' then raise exception 'Transfer % berstatus %, bukan sedang dikirim', v_doc.doc_no, v_doc.status; end if;
  if coalesce(p_qty, 0) <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  if not exists (select 1 from public.locations where id = p_location_id
                  and warehouse_id = v_doc.to_warehouse_id and active) then
    raise exception 'Lokasi simpan bukan milik gudang tujuan';
  end if;
  v_p := public._resolve_product(p_code);
  if not exists (select 1 from public.transfer_lines where transfer_id = p_transfer_id and product_id = v_p.id) then
    raise exception 'SALAH BARANG: % (%) tidak ada di kiriman ini', v_p.name, v_p.sku;
  end if;

  for r in
    select tl.id, tl.qty, tl.received_qty from public.transfer_lines tl
      join public.batches b on b.id = tl.batch_id
     where tl.transfer_id = p_transfer_id and tl.product_id = v_p.id and tl.received_qty < tl.qty
     order by b.expiry_date nulls last, tl.id
     for update of tl
  loop
    exit when v_left <= 0;
    v_take := least(v_left, r.qty - r.received_qty);
    update public.transfer_lines set received_qty = received_qty + v_take where id = r.id;
    insert into public.transfer_receipts (transfer_line_id, transfer_id, location_id, qty, received_by)
    values (r.id, p_transfer_id, p_location_id, v_take, auth.uid());
    v_left := v_left - v_take;
  end loop;
  if v_left > 0 then
    raise exception 'KELEBIHAN: % yang dikirim sudah diterima semua. Kelebihan %.', v_p.sku, public._q(v_left);
  end if;
  select coalesce(sum(qty - received_qty), 0) into v_remaining
    from public.transfer_lines where transfer_id = p_transfer_id and product_id = v_p.id;
  return jsonb_build_object('sku', v_p.sku, 'name', v_p.name, 'remaining', v_remaining);
end $$;

-- Selesaikan penerimaan. p_all_to_location: terima sisa semua ke lokasi ini
-- (mode manual). Kekurangan wajib dijelaskan di p_note.
create or replace function public.complete_transfer(
  p_id uuid, p_all_to_location uuid default null, p_note text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.transfers;
  v_short text;
  r record;
begin
  perform public._require_role('owner', 'admin', 'gudang');
  select * into v_doc from public.transfers where id = p_id for update;
  if not found then raise exception 'Dokumen tidak ditemukan'; end if;
  perform public._require_warehouse(v_doc.to_warehouse_id);
  if v_doc.status <> 'dikirim' then raise exception 'Transfer % berstatus %', v_doc.doc_no, v_doc.status; end if;

  if p_all_to_location is not null then
    if not exists (select 1 from public.locations where id = p_all_to_location
                    and warehouse_id = v_doc.to_warehouse_id and active) then
      raise exception 'Lokasi simpan bukan milik gudang tujuan';
    end if;
    insert into public.transfer_receipts (transfer_line_id, transfer_id, location_id, qty, received_by)
    select tl.id, p_id, p_all_to_location, tl.qty - tl.received_qty, auth.uid()
      from public.transfer_lines tl where tl.transfer_id = p_id and tl.received_qty < tl.qty;
    update public.transfer_lines set received_qty = qty where transfer_id = p_id;
  end if;

  select string_agg(format('%s kurang %s', p.sku, public._q(s.q)), '; ') into v_short
    from (select product_id, sum(qty - received_qty) q from public.transfer_lines
           where transfer_id = p_id group by 1 having sum(qty - received_qty) > 0) s
    join public.products p on p.id = s.product_id;
  if v_short is not null and coalesce(trim(p_note), '') = '' then
    raise exception 'Ada selisih penerimaan (%). Isi keterangan selisih sebelum menyelesaikan.', v_short;
  end if;

  for r in
    select tr.*, tl.product_id, tl.batch_id, b.unit_cost
      from public.transfer_receipts tr
      join public.transfer_lines tl on tl.id = tr.transfer_line_id
      join public.batches b on b.id = tl.batch_id
     where tr.transfer_id = p_id order by tr.received_at, tr.id
  loop
    perform public._move(r.product_id, r.batch_id, r.location_id, r.qty, r.unit_cost,
                         'transfer_masuk', 'transfer', p_id, v_doc.doc_no, null);
  end loop;

  update public.transfers
     set status = 'diterima', received_by = auth.uid(), received_at = now(),
         receive_note = nullif(trim(coalesce(p_note, '')), '')
   where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- PINDAH LOKASI
-- ---------------------------------------------------------------------
create or replace function public.relocate_stock(
  p_from_location uuid, p_to_location uuid, p_code text, p_batch_id uuid, p_qty numeric, p_note text default null
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_from public.locations;
  v_to public.locations;
  v_p public.products;
  v_bal numeric;
  v_res numeric;
  v_id uuid;
  v_no text;
  v_cost numeric;
begin
  perform public._require_role('owner', 'admin', 'gudang');
  select * into v_from from public.locations where id = p_from_location;
  select * into v_to from public.locations where id = p_to_location;
  if v_from.id is null or v_to.id is null then raise exception 'Lokasi tidak ditemukan'; end if;
  if v_from.warehouse_id <> v_to.warehouse_id then
    raise exception 'Pindah lokasi hanya dalam satu gudang. Gunakan Transfer untuk antar gudang.';
  end if;
  if v_from.id = v_to.id then raise exception 'Lokasi asal dan tujuan sama'; end if;
  if not v_to.active then raise exception 'Lokasi tujuan nonaktif'; end if;
  perform public._require_warehouse(v_from.warehouse_id);
  if coalesce(p_qty, 0) <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  v_p := public._resolve_product(p_code);
  if not exists (select 1 from public.batches where id = p_batch_id and product_id = v_p.id) then
    raise exception 'Batch tidak cocok dengan produk %', v_p.sku;
  end if;

  select qty into v_bal from public.stock_balances where batch_id = p_batch_id and location_id = p_from_location for update;
  v_res := public._reserved_qty(p_batch_id, p_from_location, null);
  if coalesce(v_bal, 0) - v_res < p_qty then
    raise exception '%', format('Stok bebas %s di lokasi %s hanya %s%s',
      v_p.sku, v_from.code, public._q(greatest(coalesce(v_bal, 0) - v_res, 0)),
      case when v_res > 0 then format(' (%s sudah dialokasikan ke dokumen draft lain)', public._q(v_res)) else '' end);
  end if;

  insert into public.relocations (warehouse_id, product_id, batch_id, from_location_id, to_location_id, qty, note)
  values (v_from.warehouse_id, v_p.id, p_batch_id, p_from_location, p_to_location, p_qty, p_note)
  returning id, doc_no into v_id, v_no;
  select unit_cost into v_cost from public.batches where id = p_batch_id;
  perform public._move(v_p.id, p_batch_id, p_from_location, -p_qty, v_cost, 'pindah_lokasi', 'relocation', v_id, v_no, p_note);
  perform public._move(v_p.id, p_batch_id, p_to_location, p_qty, v_cost, 'pindah_lokasi', 'relocation', v_id, v_no, p_note);
  return v_no;
end $$;

-- ---------------------------------------------------------------------
-- STOCK OPNAME
-- ---------------------------------------------------------------------
create or replace function public.count_add(
  p_count_id uuid, p_location_id uuid, p_code text, p_qty numeric,
  p_batch_no text default null, p_expiry date default null, p_set boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.stock_counts;
  v_p public.products;
  v_batch uuid;
  v_qty numeric;
begin
  perform public._require_role('owner', 'admin', 'gudang');
  select * into v_doc from public.stock_counts where id = p_count_id for update;
  if not found then raise exception 'Dokumen opname tidak ditemukan'; end if;
  perform public._require_warehouse(v_doc.warehouse_id);
  if v_doc.status <> 'counting' then raise exception 'Opname % sudah %, tidak bisa menghitung lagi', v_doc.doc_no, v_doc.status; end if;
  if p_qty is null or p_qty < 0 or (not p_set and p_qty = 0) then
    raise exception 'Jumlah hitung tidak valid';
  end if;
  if not exists (select 1 from public.locations where id = p_location_id and warehouse_id = v_doc.warehouse_id) then
    raise exception 'Lokasi bukan milik gudang opname ini';
  end if;
  if v_doc.location_ids is not null and not (p_location_id = any(v_doc.location_ids)) then
    raise exception 'Lokasi ini tidak termasuk cakupan opname %', v_doc.doc_no;
  end if;
  v_p := public._resolve_product(p_code);
  v_batch := public._get_or_create_batch(v_p.id, p_batch_no, p_expiry, 0);

  insert into public.stock_count_lines (count_id, location_id, product_id, batch_id, counted_qty, counted_by, counted_at)
  values (p_count_id, p_location_id, v_p.id, v_batch, p_qty, auth.uid(), now())
  on conflict (count_id, location_id, batch_id) do update
    set counted_qty = case when p_set then excluded.counted_qty
                           else public.stock_count_lines.counted_qty + excluded.counted_qty end,
        counted_by = auth.uid(), counted_at = now()
  returning counted_qty into v_qty;
  return jsonb_build_object('sku', v_p.sku, 'name', v_p.name, 'counted_qty', v_qty);
end $$;

create or replace function public.submit_count(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.stock_counts;
  v_lines int;
  v_diff int;
begin
  perform public._require_role('owner', 'admin', 'gudang');
  select * into v_doc from public.stock_counts where id = p_id for update;
  if not found then raise exception 'Dokumen opname tidak ditemukan'; end if;
  perform public._require_warehouse(v_doc.warehouse_id);
  if v_doc.status <> 'counting' then raise exception 'Opname % sudah %', v_doc.doc_no, v_doc.status; end if;

  -- Barang yang tercatat di sistem tapi tidak dihitung = dihitung 0
  insert into public.stock_count_lines (count_id, location_id, product_id, batch_id, counted_qty, auto_added)
  select p_id, sb.location_id, sb.product_id, sb.batch_id, 0, true
    from public.stock_balances sb
   where sb.warehouse_id = v_doc.warehouse_id and sb.qty > 0
     and (v_doc.location_ids is null or sb.location_id = any(v_doc.location_ids))
     and not exists (select 1 from public.stock_count_lines cl
                      where cl.count_id = p_id and cl.location_id = sb.location_id and cl.batch_id = sb.batch_id);

  update public.stock_count_lines cl
     set system_qty = coalesce((select sb.qty from public.stock_balances sb
                                 where sb.batch_id = cl.batch_id and sb.location_id = cl.location_id), 0)
   where cl.count_id = p_id;

  update public.stock_counts set status = 'submitted', submitted_by = auth.uid(), submitted_at = now() where id = p_id;
  select count(*), count(*) filter (where diff_qty <> 0) into v_lines, v_diff
    from public.stock_count_lines where count_id = p_id;
  return jsonb_build_object('lines', v_lines, 'lines_with_diff', v_diff);
end $$;

create or replace function public.set_count_reasons(p_count_id uuid, p_reasons jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_doc public.stock_counts;
begin
  perform public._require_role('owner', 'admin', 'gudang');
  select * into v_doc from public.stock_counts where id = p_count_id for update;
  if not found then raise exception 'Dokumen opname tidak ditemukan'; end if;
  perform public._require_warehouse(v_doc.warehouse_id);
  if v_doc.status <> 'submitted' then raise exception 'Alasan selisih hanya bisa diisi setelah opname diajukan'; end if;
  update public.stock_count_lines cl
     set reason = nullif(trim(x.reason), '')
    from jsonb_to_recordset(p_reasons) as x(line_id uuid, reason text)
   where cl.id = x.line_id and cl.count_id = p_count_id;
end $$;

create or replace function public.reopen_count(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_doc public.stock_counts;
begin
  perform public._require_role('owner', 'admin');
  select * into v_doc from public.stock_counts where id = p_id for update;
  if not found then raise exception 'Dokumen opname tidak ditemukan'; end if;
  if v_doc.status <> 'submitted' then raise exception 'Hanya opname berstatus diajukan yang bisa dihitung ulang'; end if;
  delete from public.stock_count_lines where count_id = p_id and auto_added and counted_qty = 0;
  update public.stock_count_lines set system_qty = null where count_id = p_id;
  update public.stock_counts set status = 'counting', submitted_by = null, submitted_at = null where id = p_id;
end $$;

create or replace function public.approve_count(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.stock_counts;
  v_missing int;
  r record;
begin
  perform public._require_role('owner', 'admin');
  select * into v_doc from public.stock_counts where id = p_id for update;
  if not found then raise exception 'Dokumen opname tidak ditemukan'; end if;
  if v_doc.status <> 'submitted' then raise exception 'Opname % berstatus %, belum bisa disetujui', v_doc.doc_no, v_doc.status; end if;
  if public.my_role() = 'admin' and auth.uid() in (v_doc.submitted_by, v_doc.created_by) then
    raise exception 'Opname harus disetujui orang lain (bukan yang membuat/mengajukan)';
  end if;
  select count(*) into v_missing from public.stock_count_lines
   where count_id = p_id and diff_qty <> 0 and coalesce(trim(reason), '') = '';
  if v_missing > 0 then
    raise exception 'Masih ada % baris selisih tanpa alasan', v_missing;
  end if;

  for r in
    select cl.*, b.unit_cost from public.stock_count_lines cl join public.batches b on b.id = cl.batch_id
     where cl.count_id = p_id and cl.diff_qty <> 0 order by cl.id
  loop
    perform public._move(r.product_id, r.batch_id, r.location_id, r.diff_qty, r.unit_cost,
                         'opname', 'stock_count', p_id, v_doc.doc_no, r.reason);
  end loop;
  update public.stock_counts set status = 'approved', approved_by = auth.uid(), approved_at = now() where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- PENYESUAIAN
-- ---------------------------------------------------------------------
create or replace function public.adjustment_add_line(
  p_adjustment_id uuid, p_code text, p_location_id uuid, p_qty_change numeric,
  p_batch_no text default null, p_expiry date default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.adjustments;
  v_p public.products;
  v_batch text;
  v_id uuid;
begin
  perform public._require_role('owner', 'admin', 'gudang');
  select * into v_doc from public.adjustments where id = p_adjustment_id for update;
  if not found then raise exception 'Dokumen tidak ditemukan'; end if;
  perform public._require_warehouse(v_doc.warehouse_id);
  if v_doc.status <> 'draft' then raise exception 'Penyesuaian % sudah %', v_doc.doc_no, v_doc.status; end if;
  if coalesce(p_qty_change, 0) = 0 then raise exception 'Jumlah perubahan tidak boleh 0'; end if;
  if not exists (select 1 from public.locations where id = p_location_id and warehouse_id = v_doc.warehouse_id) then
    raise exception 'Lokasi bukan milik gudang dokumen ini';
  end if;
  v_p := public._resolve_product(p_code);
  if p_qty_change < 0 then
    -- pengurangan harus dari batch yang sudah ada
    v_batch := case when v_p.track_batch then upper(trim(coalesce(p_batch_no, ''))) else '-' end;
    if not exists (select 1 from public.batches where product_id = v_p.id and batch_no = v_batch) then
      raise exception 'Batch % untuk % tidak ditemukan', v_batch, v_p.sku;
    end if;
  else
    v_batch := public._check_batch_input(v_p.id, p_batch_no, p_expiry);
  end if;
  insert into public.adjustment_lines (adjustment_id, product_id, batch_no, expiry_date, location_id, qty_change)
  values (p_adjustment_id, v_p.id, v_batch, case when v_batch = '-' then null else p_expiry end, p_location_id, p_qty_change)
  returning id into v_id;
  return jsonb_build_object('line_id', v_id, 'sku', v_p.sku, 'name', v_p.name, 'batch_no', v_batch);
end $$;

create or replace function public.submit_adjustment(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_doc public.adjustments;
begin
  perform public._require_role('owner', 'admin', 'gudang');
  select * into v_doc from public.adjustments where id = p_id for update;
  if not found then raise exception 'Dokumen tidak ditemukan'; end if;
  perform public._require_warehouse(v_doc.warehouse_id);
  if v_doc.status <> 'draft' then raise exception 'Penyesuaian % sudah %', v_doc.doc_no, v_doc.status; end if;
  if not exists (select 1 from public.adjustment_lines where adjustment_id = p_id) then
    raise exception 'Penyesuaian % belum berisi barang', v_doc.doc_no;
  end if;
  if coalesce(trim(v_doc.note), '') = '' then
    raise exception 'Isi keterangan/kronologi penyesuaian dulu';
  end if;
  update public.adjustments set status = 'pending', submitted_at = now() where id = p_id;
end $$;

create or replace function public.decide_adjustment(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.adjustments;
  r record;
  v_batch uuid;
  v_cost numeric;
begin
  perform public._require_role('owner', 'admin');
  select * into v_doc from public.adjustments where id = p_id for update;
  if not found then raise exception 'Dokumen tidak ditemukan'; end if;
  if v_doc.status <> 'pending' then raise exception 'Penyesuaian % berstatus %, bukan menunggu persetujuan', v_doc.doc_no, v_doc.status; end if;

  if not p_approve then
    if coalesce(trim(p_note), '') = '' then raise exception 'Isi alasan penolakan'; end if;
    update public.adjustments set status = 'rejected', decided_by = auth.uid(), decided_at = now(), decision_note = p_note where id = p_id;
    return;
  end if;

  if public.my_role() = 'admin' and auth.uid() = v_doc.created_by then
    raise exception 'Penyesuaian harus disetujui orang lain (bukan pembuatnya)';
  end if;

  for r in select * from public.adjustment_lines where adjustment_id = p_id order by id loop
    if r.qty_change > 0 then
      v_batch := public._get_or_create_batch(r.product_id, r.batch_no, r.expiry_date, 0);
    else
      select id into v_batch from public.batches where product_id = r.product_id and batch_no = r.batch_no;
      if v_batch is null then raise exception 'Batch % tidak ditemukan', r.batch_no; end if;
    end if;
    select unit_cost into v_cost from public.batches where id = v_batch;
    perform public._move(r.product_id, v_batch, r.location_id, r.qty_change, v_cost,
                         'penyesuaian', 'adjustment', p_id, v_doc.doc_no, v_doc.reason);
  end loop;
  update public.adjustments set status = 'approved', decided_by = auth.uid(), decided_at = now(),
         decision_note = nullif(trim(coalesce(p_note, '')), '')
   where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- PEMBATALAN DOKUMEN
-- ---------------------------------------------------------------------
create or replace function public.cancel_document(p_doc_type text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_status text;
  v_wh uuid;
  v_so uuid;
begin
  if p_doc_type = 'inbound' then
    perform public._require_role('owner', 'admin', 'gudang');
    select status, warehouse_id into v_status, v_wh from public.inbounds where id = p_id for update;
    if v_wh is null then raise exception 'Dokumen tidak ditemukan'; end if;
    perform public._require_warehouse(v_wh);
    if v_status <> 'draft' then raise exception 'Hanya draft yang bisa dibatalkan (status: %)', v_status; end if;
    update public.inbounds set status = 'cancelled' where id = p_id;

  elsif p_doc_type = 'outbound' then
    perform public._require_role('owner', 'admin', 'gudang');
    select status, warehouse_id, sales_order_id into v_status, v_wh, v_so from public.outbounds where id = p_id for update;
    if v_wh is null then raise exception 'Dokumen tidak ditemukan'; end if;
    perform public._require_warehouse(v_wh);
    if v_status <> 'draft' then raise exception 'Hanya draft yang bisa dibatalkan (status: %)', v_status; end if;
    update public.outbounds set status = 'cancelled' where id = p_id;
    if v_so is not null then
      update public.sales_orders set status = 'confirmed' where id = v_so and status = 'diproses';
    end if;
    update public.marketplace_orders set status = 'baru', outbound_id = null, updated_at = now()
     where outbound_id = p_id and status = 'diproses';

  elsif p_doc_type = 'transfer' then
    perform public._require_role('owner', 'admin', 'gudang');
    select status, from_warehouse_id into v_status, v_wh from public.transfers where id = p_id for update;
    if v_wh is null then raise exception 'Dokumen tidak ditemukan'; end if;
    perform public._require_warehouse(v_wh);
    if v_status <> 'draft' then
      raise exception 'Transfer yang sudah dikirim tidak bisa dibatalkan. Selesaikan penerimaan dengan jumlah aktual.';
    end if;
    update public.transfers set status = 'cancelled' where id = p_id;

  elsif p_doc_type = 'adjustment' then
    perform public._require_role('owner', 'admin', 'gudang');
    select status, warehouse_id into v_status, v_wh from public.adjustments where id = p_id for update;
    if v_wh is null then raise exception 'Dokumen tidak ditemukan'; end if;
    perform public._require_warehouse(v_wh);
    if v_status not in ('draft', 'pending') then raise exception 'Penyesuaian berstatus % tidak bisa dibatalkan', v_status; end if;
    update public.adjustments set status = 'cancelled' where id = p_id;

  elsif p_doc_type = 'stock_count' then
    perform public._require_role('owner', 'admin', 'gudang');
    select status, warehouse_id into v_status, v_wh from public.stock_counts where id = p_id for update;
    if v_wh is null then raise exception 'Dokumen tidak ditemukan'; end if;
    perform public._require_warehouse(v_wh);
    if v_status not in ('counting', 'submitted') then raise exception 'Opname berstatus % tidak bisa dibatalkan', v_status; end if;
    update public.stock_counts set status = 'cancelled' where id = p_id;

  elsif p_doc_type = 'sales_order' then
    perform public._require_role('owner', 'admin', 'sales');
    select status into v_status from public.sales_orders where id = p_id for update;
    if v_status is null then raise exception 'Dokumen tidak ditemukan'; end if;
    if v_status not in ('draft', 'confirmed') then
      raise exception 'SO berstatus % tidak bisa dibatalkan. Batalkan dokumen keluarnya dulu.', v_status;
    end if;
    if exists (select 1 from public.invoices where sales_order_id = p_id and status <> 'void') then
      raise exception 'SO sudah punya faktur aktif. Void fakturnya dulu.';
    end if;
    update public.sales_orders set status = 'batal' where id = p_id;
  else
    raise exception 'Jenis dokumen tidak dikenal: %', p_doc_type;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- PENJUALAN B2B
-- ---------------------------------------------------------------------
create or replace function public.so_totals(p_id uuid)
returns table (subtotal numeric, discount_amount numeric, tax_percent numeric, tax_amount numeric, total numeric)
language sql stable security definer set search_path = public as $$
  with s as (
    select coalesce((select sum(line_total) from public.sales_order_lines where sales_order_id = so.id), 0) as sub,
           so.discount_amount as disc, so.tax_percent as tp
      from public.sales_orders so where so.id = p_id
  )
  select sub, disc, tp,
         round(greatest(sub - disc, 0) * tp / 100, 2),
         greatest(sub - disc, 0) + round(greatest(sub - disc, 0) * tp / 100, 2)
    from s
$$;

create or replace function public.confirm_sales_order(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_so public.sales_orders;
  v_c public.customers;
  v_total numeric;
  v_outstanding numeric;
  v_bad text;
begin
  perform public._require_role('owner', 'admin', 'sales');
  select * into v_so from public.sales_orders where id = p_id for update;
  if not found then raise exception 'SO tidak ditemukan'; end if;
  if v_so.status <> 'draft' then raise exception 'SO % sudah %', v_so.doc_no, v_so.status; end if;
  if not exists (select 1 from public.sales_order_lines where sales_order_id = p_id) then
    raise exception 'SO % belum berisi barang', v_so.doc_no;
  end if;
  select string_agg(p.sku, ', ') into v_bad from public.sales_order_lines l
    join public.products p on p.id = l.product_id where l.sales_order_id = p_id and not p.active;
  if v_bad is not null then raise exception 'Produk nonaktif: %', v_bad; end if;

  select * into v_c from public.customers where id = v_so.customer_id;
  if not v_c.active then raise exception 'Pelanggan % nonaktif', v_c.name; end if;
  if v_c.credit_limit > 0 then
    select total into v_total from public.so_totals(p_id);
    select coalesce(sum(total - paid_amount), 0) into v_outstanding
      from public.invoices where customer_id = v_c.id and status in ('belum_lunas', 'sebagian');
    -- SO terkonfirmasi yang belum difakturkan ikut dihitung
    v_outstanding := v_outstanding + coalesce((
      select sum(t.total) from public.sales_orders so2
        cross join lateral public.so_totals(so2.id) t
       where so2.customer_id = v_c.id and so2.status in ('confirmed', 'diproses', 'dikirim')
         and not exists (select 1 from public.invoices i where i.sales_order_id = so2.id and i.status <> 'void')), 0);
    if v_outstanding + v_total > v_c.credit_limit then
      raise exception 'Melebihi limit kredit %: piutang & order berjalan %, order ini %, limit %',
        v_c.name, public._rp(v_outstanding), public._rp(v_total), public._rp(v_c.credit_limit);
    end if;
  end if;
  update public.sales_orders set status = 'confirmed', confirmed_by = auth.uid(), confirmed_at = now() where id = p_id;
end $$;

create or replace function public.create_outbound_from_so(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_so public.sales_orders;
  v_cust text;
  v_out uuid;
begin
  perform public._require_role('owner', 'admin', 'sales', 'gudang');
  select * into v_so from public.sales_orders where id = p_id for update;
  if not found then raise exception 'SO tidak ditemukan'; end if;
  if v_so.status <> 'confirmed' then
    raise exception 'SO % harus berstatus confirmed (sekarang: %)', v_so.doc_no, v_so.status;
  end if;
  if exists (select 1 from public.outbounds where sales_order_id = p_id and status in ('draft', 'posted')) then
    raise exception 'SO % sudah punya dokumen keluar', v_so.doc_no;
  end if;
  select name into v_cust from public.customers where id = v_so.customer_id;

  insert into public.outbounds (warehouse_id, purpose, sales_order_id, partner_name, reference_no, mode, note)
  values (v_so.warehouse_id, 'b2b', p_id, v_cust, coalesce(v_so.customer_po, v_so.doc_no), 'scan',
          'Dari ' || v_so.doc_no)
  returning id into v_out;
  insert into public.outbound_items (outbound_id, product_id, qty)
  select v_out, product_id, sum(qty) from public.sales_order_lines where sales_order_id = p_id group by product_id;
  perform public._allocate_outbound(v_out);
  update public.sales_orders set status = 'diproses' where id = p_id;
  return v_out;
end $$;

create or replace function public.create_invoice(p_so_id uuid, p_invoice_date date default current_date) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_so public.sales_orders;
  v_terms int;
  t record;
  v_id uuid;
begin
  perform public._require_role('owner', 'admin', 'finance', 'sales');
  select * into v_so from public.sales_orders where id = p_so_id for update;
  if not found then raise exception 'SO tidak ditemukan'; end if;
  if v_so.status not in ('confirmed', 'diproses', 'dikirim') then
    raise exception 'SO % berstatus %, belum bisa difakturkan', v_so.doc_no, v_so.status;
  end if;
  if exists (select 1 from public.invoices where sales_order_id = p_so_id and status <> 'void') then
    raise exception 'SO % sudah punya faktur aktif', v_so.doc_no;
  end if;
  select payment_terms_days into v_terms from public.customers where id = v_so.customer_id;
  select * into t from public.so_totals(p_so_id);

  insert into public.invoices (invoice_no, sales_order_id, customer_id, invoice_date, due_date,
                               subtotal, discount_amount, tax_percent, tax_amount, total, created_by)
  values (public._next_doc_no('INV'), p_so_id, v_so.customer_id, coalesce(p_invoice_date, current_date),
          coalesce(p_invoice_date, current_date) + coalesce(v_terms, 0),
          t.subtotal, t.discount_amount, t.tax_percent, t.tax_amount, t.total, auth.uid())
  returning id into v_id;

  insert into public.invoice_lines (invoice_id, product_id, description, qty, unit_price, discount_percent, line_total)
  select v_id, l.product_id, p.sku || ' - ' || p.name, l.qty, l.unit_price, l.discount_percent, l.line_total
    from public.sales_order_lines l join public.products p on p.id = l.product_id
   where l.sales_order_id = p_so_id order by l.created_at, l.id;
  return v_id;
end $$;

create or replace function public.add_payment(
  p_invoice_id uuid, p_amount numeric, p_paid_at date default current_date,
  p_method text default 'transfer', p_reference text default null, p_note text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare v_inv public.invoices;
begin
  perform public._require_role('owner', 'admin', 'finance');
  select * into v_inv from public.invoices where id = p_invoice_id for update;
  if not found then raise exception 'Faktur tidak ditemukan'; end if;
  if v_inv.status = 'void' then raise exception 'Faktur % sudah void', v_inv.invoice_no; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Nominal pembayaran harus lebih dari 0'; end if;
  if v_inv.paid_amount + p_amount > v_inv.total then
    raise exception 'Pembayaran melebihi sisa tagihan (sisa %)', public._rp(v_inv.total - v_inv.paid_amount);
  end if;
  insert into public.payments (invoice_id, paid_at, amount, method, reference, note, created_by)
  values (p_invoice_id, coalesce(p_paid_at, current_date), p_amount, coalesce(p_method, 'transfer'), p_reference, p_note, auth.uid());
  update public.invoices
     set paid_amount = paid_amount + p_amount,
         status = case when paid_amount + p_amount >= total then 'lunas' else 'sebagian' end
   where id = p_invoice_id;
end $$;

create or replace function public.void_invoice(p_id uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare v_inv public.invoices;
begin
  perform public._require_role('owner', 'admin', 'finance');
  select * into v_inv from public.invoices where id = p_id for update;
  if not found then raise exception 'Faktur tidak ditemukan'; end if;
  if v_inv.status = 'void' then raise exception 'Faktur sudah void'; end if;
  if exists (select 1 from public.payments where invoice_id = p_id) then
    raise exception 'Faktur yang sudah ada pembayarannya tidak bisa di-void';
  end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Isi alasan void'; end if;
  update public.invoices set status = 'void', note = trim(coalesce(note, '') || ' [VOID: ' || p_note || ']') where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- MARKETPLACE
-- ---------------------------------------------------------------------
create or replace function public._is_cancel_status(p text) returns boolean
language sql immutable as $$
  select coalesce(lower(p) ~ '(batal|cancel)', false)
$$;

-- Produk untuk satu SKU marketplace: pemetaan khusus toko > pemetaan
-- umum > SKU/barcode produk yang sama persis.
create or replace function public.mp_resolve_sku(p_store uuid, p_sku text)
returns table (product_id uuid, multiplier numeric)
language sql stable security definer set search_path = public as $$
  with s as (
    select m.product_id, m.multiplier from public.sku_mappings m
     where m.store_id = p_store and lower(m.external_sku) = lower(trim(p_sku))
  ), g as (
    select m.product_id, m.multiplier from public.sku_mappings m
     where m.store_id is null and lower(m.external_sku) = lower(trim(p_sku))
       and not exists (select 1 from s)
  ), d as (
    select p.id, 1::numeric from public.products p
     where p.active and (lower(p.sku) = lower(trim(p_sku)) or p.barcode = trim(p_sku))
       and not exists (select 1 from s) and not exists (select 1 from g)
     limit 1
  )
  select * from s union all select * from g union all select * from d
$$;

create or replace function public.import_marketplace_orders(p_store_id uuid, p_file_name text, p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_store public.stores;
  v_tz text;
  v_import uuid;
  v_total int;
  v_new int;
  v_dup int;
  v_cancel_new int;
  v_cancel_upd int;
  v_lines int;
  v_unmapped int;
  v_bad text;
begin
  perform public._require_role('owner', 'admin', 'sales');
  select * into v_store from public.stores where id = p_store_id;
  if not found then raise exception 'Toko tidak ditemukan'; end if;
  if not v_store.active then raise exception 'Toko % nonaktif', v_store.name; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'Tidak ada baris pesanan di file';
  end if;
  perform pg_advisory_xact_lock(hashtext('mpimport:' || p_store_id::text));
  select timezone into v_tz from public.settings where id = 1;

  drop table if exists _mp_rows;
  create temp table _mp_rows on commit drop as
  select row_number() over () as rn,
         trim(x.order_id) as order_id,
         nullif(trim(x.order_date), '') as order_date,
         nullif(trim(x.status), '') as status,
         nullif(trim(x.buyer), '') as buyer,
         nullif(trim(x.sku), '') as sku,
         nullif(trim(x.product_name), '') as product_name,
         x.qty, coalesce(x.price, 0) as price,
         coalesce(x.amount, x.qty * coalesce(x.price, 0)) as amount
    from jsonb_to_recordset(p_rows) as x(order_id text, order_date text, status text, buyer text,
                                         sku text, product_name text, qty numeric, price numeric, amount numeric);
  v_total := (select count(*) from _mp_rows);

  select string_agg(rn::text, ', ') into v_bad from (select rn from _mp_rows where coalesce(order_id, '') = '' limit 10) z;
  if v_bad is not null then raise exception 'Baris tanpa nomor pesanan (baris data ke-%)', v_bad; end if;
  select string_agg(rn::text, ', ') into v_bad from (select rn from _mp_rows where qty is null or qty <= 0 limit 10) z;
  if v_bad is not null then raise exception 'Jumlah barang kosong/0 di baris data ke-%', v_bad; end if;

  drop table if exists _mp_orders;
  create temp table _mp_orders on commit drop as
  select order_id,
         min(case when order_date ~ '^\d{4}-\d{2}-\d{2}' then (order_date::timestamp at time zone coalesce(v_tz, 'Asia/Jakarta')) end) as order_date,
         max(status) as status, max(buyer) as buyer, sum(amount) as amount,
         exists (select 1 from public.marketplace_orders m
                  where m.store_id = p_store_id and m.external_order_id = r.order_id) as already
    from _mp_rows r group by order_id;

  select count(*) filter (where already),
         count(*) filter (where not already and public._is_cancel_status(status))
    into v_dup, v_cancel_new from _mp_orders;

  -- Pesanan lama: perbarui status marketplace; yang belum diproses & kini batal -> batal
  with u as (
    update public.marketplace_orders m
       set external_status = o.status,
           status = case when m.status = 'baru' and public._is_cancel_status(o.status) then 'batal' else m.status end,
           updated_at = now()
      from _mp_orders o
     where o.already and m.store_id = p_store_id and m.external_order_id = o.order_id
    returning (m.status = 'batal' and public._is_cancel_status(o.status)) as became
  ) select count(*) filter (where became) into v_cancel_upd from u;

  insert into public.marketplace_imports (store_id, file_name, total_rows, created_by)
  values (p_store_id, p_file_name, v_total, auth.uid()) returning id into v_import;

  with ins as (
    insert into public.marketplace_orders (store_id, external_order_id, order_date, external_status,
                                           buyer_name, status, total_amount, import_id)
    select p_store_id, o.order_id, o.order_date, o.status, o.buyer,
           case when public._is_cancel_status(o.status) then 'batal' else 'baru' end,
           coalesce(o.amount, 0), v_import
      from _mp_orders o where not o.already
    returning id, external_order_id
  )
  insert into public.marketplace_order_lines (order_id, external_sku, product_name, qty, unit_price, line_amount)
  select ins.id, r.sku, r.product_name, r.qty, r.price, coalesce(r.amount, 0)
    from ins join _mp_rows r on r.order_id = ins.external_order_id
   order by r.rn;
  get diagnostics v_lines = row_count;

  select count(*) into v_new from public.marketplace_orders where import_id = v_import;
  select count(*) into v_unmapped
    from public.marketplace_order_lines l join public.marketplace_orders o on o.id = l.order_id
   where o.import_id = v_import and o.status <> 'batal'
     and not exists (select 1 from public.mp_resolve_sku(p_store_id, l.external_sku));

  update public.marketplace_imports
     set orders_new = v_new, orders_duplicate = v_dup, orders_cancelled = v_cancel_new + coalesce(v_cancel_upd, 0),
         lines_new = v_lines, lines_unmapped = v_unmapped
   where id = v_import;

  return jsonb_build_object('import_id', v_import, 'rows', v_total, 'orders_new', v_new,
                            'orders_duplicate', v_dup, 'orders_cancelled', v_cancel_new + coalesce(v_cancel_upd, 0),
                            'lines_new', v_lines, 'lines_unmapped', v_unmapped);
end $$;

create or replace function public.create_outbound_from_marketplace(p_order_ids uuid[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_wh uuid;
  v_n int;
  v_bad text;
  v_out uuid;
  v_stores text;
begin
  perform public._require_role('owner', 'admin', 'gudang', 'sales');
  if p_order_ids is null or cardinality(p_order_ids) = 0 then
    raise exception 'Pilih pesanan dulu';
  end if;
  perform 1 from public.marketplace_orders where id = any(p_order_ids) for update;

  select count(*) into v_n from public.marketplace_orders where id = any(p_order_ids);
  if v_n <> cardinality(p_order_ids) then raise exception 'Sebagian pesanan tidak ditemukan'; end if;
  select string_agg(external_order_id || ' (' || status || ')', ', ') into v_bad
    from public.marketplace_orders where id = any(p_order_ids) and status <> 'baru';
  if v_bad is not null then raise exception 'Hanya pesanan berstatus baru yang bisa diproses: %', v_bad; end if;

  select count(distinct s.warehouse_id), min(s.warehouse_id::text)::uuid, string_agg(distinct s.name, ', ')
    into v_n, v_wh, v_stores
    from public.marketplace_orders o join public.stores s on s.id = o.store_id
   where o.id = any(p_order_ids);
  if v_n > 1 then raise exception 'Pesanan berasal dari toko dengan gudang pengirim berbeda. Proses terpisah per gudang.'; end if;
  perform public._require_warehouse(v_wh);

  select string_agg(distinct coalesce(l.external_sku, '(SKU kosong)'), ', ') into v_bad
    from public.marketplace_order_lines l join public.marketplace_orders o on o.id = l.order_id
   where o.id = any(p_order_ids)
     and not exists (select 1 from public.mp_resolve_sku(o.store_id, l.external_sku));
  if v_bad is not null then
    raise exception 'SKU marketplace belum dipetakan ke produk: %. Atur di menu Pemetaan SKU.', v_bad;
  end if;

  insert into public.outbounds (warehouse_id, purpose, partner_name, reference_no, mode, note)
  values (v_wh, 'marketplace', v_stores, cardinality(p_order_ids) || ' pesanan', 'scan',
          'Batch pesanan marketplace')
  returning id into v_out;

  insert into public.outbound_items (outbound_id, product_id, qty)
  select v_out, r.product_id, sum(l.qty * r.multiplier)
    from public.marketplace_order_lines l
    join public.marketplace_orders o on o.id = l.order_id
    cross join lateral public.mp_resolve_sku(o.store_id, l.external_sku) r
   where o.id = any(p_order_ids)
   group by r.product_id;

  update public.marketplace_orders set status = 'diproses', outbound_id = v_out, updated_at = now()
   where id = any(p_order_ids);
  perform public._allocate_outbound(v_out);
  return v_out;
end $$;

create or replace function public.cancel_marketplace_order(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_status text;
begin
  perform public._require_role('owner', 'admin', 'sales', 'gudang');
  select status into v_status from public.marketplace_orders where id = p_id for update;
  if v_status is null then raise exception 'Pesanan tidak ditemukan'; end if;
  if v_status <> 'baru' then
    raise exception 'Hanya pesanan baru yang bisa dibatalkan di sini (status: %). Batalkan dokumen keluarnya dulu.', v_status;
  end if;
  update public.marketplace_orders set status = 'batal', updated_at = now() where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- IMPOR MASTER DATA & SALDO AWAL
-- ---------------------------------------------------------------------
-- rows: [{brand_code, sku, barcode, name, category, uom, track_batch, min_stock, default_cost, default_price}]
create or replace function public.upsert_products(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_bad text;
  v_ins int;
  v_upd int;
begin
  perform public._require_role('owner', 'admin');
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Data tidak valid'; end if;

  drop table if exists _pr;
  create temp table _pr on commit drop as
  select row_number() over () rn, upper(trim(x.brand_code)) brand_code, trim(x.sku) sku,
         nullif(trim(coalesce(x.barcode, '')), '') barcode, trim(x.name) as name, nullif(trim(x.category), '') category,
         coalesce(nullif(trim(x.uom), ''), 'pcs') uom, coalesce(x.track_batch, true) track_batch,
         coalesce(x.min_stock, 0) min_stock, coalesce(x.default_cost, 0) default_cost,
         coalesce(x.default_price, 0) default_price
    from jsonb_to_recordset(p_rows) as x(brand_code text, sku text, barcode text, name text, category text,
                                         uom text, track_batch boolean, min_stock numeric,
                                         default_cost numeric, default_price numeric);

  select string_agg(rn::text, ', ') into v_bad from (select rn from _pr where coalesce(sku, '') = '' or coalesce(name, '') = '' limit 10) z;
  if v_bad is not null then raise exception 'SKU/nama kosong di baris ke-%', v_bad; end if;
  select string_agg(distinct coalesce(brand_code, '(kosong)'), ', ') into v_bad
    from _pr where not exists (select 1 from public.brands b where b.code = _pr.brand_code);
  if v_bad is not null then raise exception 'Kode brand tidak dikenal: %. Buat brand dulu.', v_bad; end if;
  select string_agg(s, ', ') into v_bad from (select min(sku) s from _pr group by lower(sku) having count(*) > 1) z;
  if v_bad is not null then raise exception 'SKU ganda di file: %', v_bad; end if;
  select string_agg(barcode, ', ') into v_bad from (select barcode from _pr where barcode is not null group by barcode having count(*) > 1) z;
  if v_bad is not null then raise exception 'Barcode ganda di file: %', v_bad; end if;
  select string_agg(pr.barcode || ' (dipakai ' || p.sku || ')', ', ') into v_bad
    from _pr pr join public.products p on p.barcode = pr.barcode and lower(p.sku) <> lower(pr.sku);
  if v_bad is not null then raise exception 'Barcode sudah dipakai produk lain: %', v_bad; end if;

  select count(*) into v_upd from _pr where exists (select 1 from public.products p where lower(p.sku) = lower(_pr.sku));
  update public.products p
     set brand_id = b.id, barcode = pr.barcode, name = pr.name, category = pr.category, uom = pr.uom,
         track_batch = pr.track_batch, min_stock = pr.min_stock, default_cost = pr.default_cost,
         default_price = pr.default_price
    from _pr pr join public.brands b on b.code = pr.brand_code
   where lower(p.sku) = lower(pr.sku);
  insert into public.products (brand_id, sku, barcode, name, category, uom, track_batch, min_stock, default_cost, default_price)
  select b.id, pr.sku, pr.barcode, pr.name, pr.category, pr.uom, pr.track_batch, pr.min_stock, pr.default_cost, pr.default_price
    from _pr pr join public.brands b on b.code = pr.brand_code
   where not exists (select 1 from public.products p where lower(p.sku) = lower(pr.sku));
  get diagnostics v_ins = row_count;
  return jsonb_build_object('inserted', v_ins, 'updated', v_upd);
end $$;

-- Saldo awal: membuat draft Barang Masuk (sumber saldo_awal) untuk diperiksa
-- lalu diposting. rows: [{sku, batch_no, expiry_date, location_code, qty, unit_cost}]
create or replace function public.create_opening_stock(p_warehouse_id uuid, p_rows jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_bad text;
begin
  perform public._require_role('owner', 'admin');
  if not exists (select 1 from public.warehouses where id = p_warehouse_id) then raise exception 'Gudang tidak ditemukan'; end if;

  drop table if exists _os;
  create temp table _os on commit drop as
  select row_number() over () rn, trim(x.sku) sku, nullif(trim(x.batch_no), '') batch_no,
         x.expiry_date, upper(trim(coalesce(x.location_code, 'TERIMA'))) location_code,
         x.qty, coalesce(x.unit_cost, 0) unit_cost
    from jsonb_to_recordset(p_rows) as x(sku text, batch_no text, expiry_date date, location_code text, qty numeric, unit_cost numeric);

  select string_agg(distinct sku, ', ') into v_bad from _os
   where not exists (select 1 from public.products p where lower(p.sku) = lower(_os.sku));
  if v_bad is not null then raise exception 'SKU tidak dikenal: %', v_bad; end if;
  select string_agg(distinct location_code, ', ') into v_bad from _os
   where not exists (select 1 from public.locations l where l.warehouse_id = p_warehouse_id and l.code = _os.location_code);
  if v_bad is not null then raise exception 'Kode lokasi tidak ada di gudang ini: %', v_bad; end if;
  select string_agg(rn::text, ', ') into v_bad from (select rn from _os where qty is null or qty <= 0 limit 10) z;
  if v_bad is not null then raise exception 'Jumlah kosong/0 di baris ke-%', v_bad; end if;

  -- validasi batch & expired per baris
  perform public._check_batch_input(p.id, o.batch_no, o.expiry_date)
     from _os o join public.products p on lower(p.sku) = lower(o.sku);

  insert into public.inbounds (warehouse_id, source, mode, note, reference_no)
  values (p_warehouse_id, 'saldo_awal', 'manual', 'Saldo awal dari impor file', 'SALDO AWAL')
  returning id into v_id;
  insert into public.inbound_lines (inbound_id, product_id, batch_no, expiry_date, location_id, qty, unit_cost, scanned)
  select v_id, p.id,
         case when p.track_batch then upper(o.batch_no) else '-' end,
         case when p.track_batch then o.expiry_date end,
         l.id, o.qty, o.unit_cost, false
    from _os o join public.products p on lower(p.sku) = lower(o.sku)
    join public.locations l on l.warehouse_id = p_warehouse_id and l.code = o.location_code
   order by o.rn;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- PENGGUNA
-- ---------------------------------------------------------------------
create or replace function public.update_user(
  p_user_id uuid, p_role text, p_active boolean, p_warehouse_id uuid default null, p_full_name text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_me text := public.my_role();
  v_old public.profiles;
begin
  perform public._require_role('owner', 'admin');
  select * into v_old from public.profiles where id = p_user_id for update;
  if not found then raise exception 'Pengguna tidak ditemukan'; end if;
  if p_role not in ('owner', 'admin', 'gudang', 'finance', 'sales') then raise exception 'Peran tidak dikenal'; end if;
  if v_me <> 'owner' and (p_role in ('owner', 'admin') or v_old.role in ('owner', 'admin')) then
    raise exception 'Hanya owner yang boleh mengatur akun owner/admin';
  end if;
  if v_old.role = 'owner' and v_old.active and (p_role <> 'owner' or not p_active)
     and (select count(*) from public.profiles where role = 'owner' and active) <= 1 then
    raise exception 'Minimal harus ada satu owner aktif';
  end if;
  update public.profiles
     set role = p_role, active = p_active, warehouse_id = p_warehouse_id,
         full_name = coalesce(nullif(trim(p_full_name), ''), full_name)
   where id = p_user_id;
end $$;

-- =====================================================================
-- WAREHOUSE SISTEM 4 KELEDAI — database produksi (Supabase)
-- Cara pakai: Supabase → SQL Editor → New query → tempel SELURUH isi file
-- ini → Run. Cukup sekali di project baru.
--
-- Prinsip:
--  * Stok hanya berubah lewat fungsi (barang masuk, barang keluar, SO).
--    Tidak ada yang bisa mengedit angka stok langsung.
--  * Riwayat stok (moves) permanen: tidak bisa diubah / dihapus.
--  * Stok disimpan per tanggal ED. Barang keluar otomatis mengambil
--    ED terdekat (FEFO); barang kedaluwarsa hanya boleh keluar sebagai "rusak".
--  * HPP & nilai Rupiah hanya terlihat oleh owner dan finance.
--  * Aplikasi hanya membaca lewat view v_* dan menulis lewat fungsi.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- TABEL
-- ---------------------------------------------------------------------
create table public.settings (
  id            int primary key default 1 check (id = 1),
  company_name  text not null default '4 Keledai',
  timezone      text not null default 'Asia/Jakarta',
  warn_months   int  not null default 6 check (warn_months between 1 and 24),
  updated_at    timestamptz not null default now()
);
insert into public.settings default values;

create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text,
  full_name   text,
  role        text not null default 'staf' check (role in ('owner','staf','sales','finance')),
  active      boolean not null default false,
  created_at  timestamptz not null default now()
);

create table public.brands (
  code  text primary key check (code ~ '^[A-Z0-9_-]{1,20}$'),
  name  text not null check (length(trim(name)) > 0)
);

create table public.products (
  sku         text primary key check (sku ~ '^[A-Z0-9._-]{2,40}$'),
  barcode     text unique,
  name        text not null check (length(trim(name)) > 0),
  brand_code  text not null references public.brands(code) on update cascade,
  track_ed    boolean not null default true,
  min_stock   numeric(14,3) not null default 0 check (min_stock >= 0),
  cost        numeric(16,2) not null default 0 check (cost >= 0),
  price       numeric(16,2) not null default 0 check (price >= 0),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.suppliers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (length(trim(name)) > 0),
  phone       text,
  note        text,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- Stok per produk per ED (ed null = produk tanpa ED)
create table public.lots (
  id     uuid primary key default gen_random_uuid(),
  sku    text not null references public.products(sku) on update cascade,
  ed     date,
  qty    numeric(14,3) not null default 0 check (qty >= 0),
  updated_at timestamptz not null default now(),
  unique nulls not distinct (sku, ed)
);
create index on public.lots (sku);

create table public.doc_counters (
  prefix text not null, period text not null, last_no int not null default 0,
  primary key (prefix, period)
);

-- Buku besar stok (permanen)
create table public.moves (
  id        bigint generated always as identity primary key,
  at        timestamptz not null default now(),
  sku       text not null references public.products(sku) on update cascade,
  ed        date,
  qty       numeric(14,3) not null check (qty <> 0),
  kind      text not null check (kind in ('masuk','keluar','so')),
  doc_no    text not null,
  note      text,
  by_id     uuid,
  by_name   text
);
create index on public.moves (at);
create index on public.moves (sku, at);
create index on public.moves (doc_no);

create table public.inbounds (
  id             uuid primary key default gen_random_uuid(),
  doc_no         text not null unique,
  doc_date       date not null,
  source         text not null default 'supplier' check (source in ('supplier','retur','saldo_awal','lainnya')),
  supplier_id    uuid references public.suppliers(id),
  sj_no          text,
  sj_date        date,
  no_sj_note     text,
  has_photo      boolean not null default false,
  note           text,
  received_by    uuid,
  received_name  text,
  created_at     timestamptz not null default now(),
  verified_by    uuid,
  verified_name  text,
  verified_at    timestamptz
);
create index on public.inbounds (doc_date);

create table public.inbound_lines (
  id          uuid primary key default gen_random_uuid(),
  inbound_id  uuid not null references public.inbounds(id) on delete cascade,
  sku         text not null references public.products(sku) on update cascade,
  ed          date,
  batch_no    text,
  qty         numeric(14,3) not null check (qty > 0)
);
create index on public.inbound_lines (inbound_id);

create table public.inbound_photos (
  inbound_id  uuid primary key references public.inbounds(id) on delete cascade,
  data        text not null check (length(data) < 2000000)
);

create table public.outbounds (
  id             uuid primary key default gen_random_uuid(),
  doc_no         text not null unique,
  doc_date       date not null,
  purpose        text not null check (purpose in ('shopee','tiktok','tokopedia','lazada','website','b2b','offline','sampel','rusak','internal','lainnya')),
  ref            text,
  customer       text,
  note           text,
  status         text not null check (status in ('posted','pending','rejected')),
  created_by     uuid,
  created_name   text,
  created_at     timestamptz not null default now(),
  decided_by     uuid,
  decided_name   text,
  decided_at     timestamptz,
  decided_note   text
);
create index on public.outbounds (doc_date);
create index on public.outbounds (status);

create table public.outbound_lines (
  id           uuid primary key default gen_random_uuid(),
  outbound_id  uuid not null references public.outbounds(id) on delete cascade,
  sku          text not null references public.products(sku) on update cascade,
  qty          numeric(14,3) not null check (qty > 0),
  allocation   jsonb   -- [{ed, qty}] diisi saat stok benar-benar keluar
);
create index on public.outbound_lines (outbound_id);

create table public.opnames (
  id              uuid primary key default gen_random_uuid(),
  doc_no          text not null unique,
  period          text not null,           -- contoh 2026-W43
  status          text not null default 'counting' check (status in ('counting','submitted','approved','cancelled')),
  note            text,
  created_by      uuid, created_name text, created_at timestamptz not null default now(),
  submitted_by    uuid, submitted_name text, submitted_at timestamptz,
  approved_by     uuid, approved_name text, approved_at timestamptz
);
create unique index opnames_one_open on public.opnames ((true)) where status in ('counting','submitted');

create table public.opname_lines (
  id          uuid primary key default gen_random_uuid(),
  opname_id   uuid not null references public.opnames(id) on delete cascade,
  sku         text not null references public.products(sku) on update cascade,
  counted     numeric(14,3) check (counted >= 0),
  system_qty  numeric(14,3),
  diff        numeric(14,3) generated always as (counted - system_qty) stored,
  reason      text,
  counted_name text,
  unique (opname_id, sku)
);

-- ---------------------------------------------------------------------
-- HELPER
-- ---------------------------------------------------------------------
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and active
$$;
create or replace function public.is_active() returns boolean
language sql stable security definer set search_path = public as $$
  select public.my_role() is not null
$$;
create or replace function public.can_see_cost() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() in ('owner','finance'), false)
$$;
create or replace function public._me_name() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(trim(full_name),''), email, 'tanpa nama') from public.profiles where id = auth.uid()
$$;
create or replace function public._require(variadic p_roles text[]) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if public.my_role() is null then
    raise exception 'Akun Anda belum aktif. Minta owner mengaktifkan di menu Pengguna.' using errcode = '42501';
  end if;
  if not (public.my_role() = any(p_roles)) then
    raise exception 'Akses ditolak: hanya untuk %', array_to_string(p_roles, ', ') using errcode = '42501';
  end if;
end $$;
create or replace function public._q(p numeric) returns text
language sql immutable as $$ select trim_scale(coalesce(p,0))::text $$;
create or replace function public._today() returns date
language sql stable security definer set search_path = public as $$
  select (now() at time zone (select timezone from public.settings where id = 1))::date
$$;
create or replace function public._next_no(p_prefix text) returns text
language plpgsql security definer set search_path = public as $$
declare v_period text := to_char(public._today(), 'YYMM'); v_no int;
begin
  insert into public.doc_counters values (p_prefix, v_period, 1)
  on conflict (prefix, period) do update set last_no = public.doc_counters.last_no + 1
  returning last_no into v_no;
  return p_prefix || '-' || v_period || '-' || lpad(v_no::text, 4, '0');
end $$;

-- Ubah stok satu lot + catat ke buku besar
create or replace function public._move(p_sku text, p_ed date, p_qty numeric, p_kind text, p_doc text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare v_cur numeric;
begin
  if p_qty = 0 then return; end if;
  insert into public.lots (sku, ed, qty) values (p_sku, p_ed, 0)
  on conflict (sku, ed) do nothing;
  select qty into v_cur from public.lots where sku = p_sku and ed is not distinct from p_ed for update;
  if v_cur + p_qty < 0 then
    raise exception 'Stok % % tidak cukup (ada %, butuh %)', p_sku,
      coalesce('ED ' || to_char(p_ed, 'DD-MM-YYYY'), ''), public._q(v_cur), public._q(-p_qty);
  end if;
  update public.lots set qty = qty + p_qty, updated_at = now() where sku = p_sku and ed is not distinct from p_ed;
  insert into public.moves (sku, ed, qty, kind, doc_no, note, by_id, by_name)
  values (p_sku, p_ed, p_qty, p_kind, p_doc, p_note, auth.uid(), public._me_name());
end $$;

create or replace function public._tg_immutable() returns trigger language plpgsql as $$
begin raise exception 'Riwayat stok tidak boleh diubah atau dihapus'; end $$;
create trigger moves_no_update before update or delete on public.moves for each row execute function public._tg_immutable();
create trigger moves_no_truncate before truncate on public.moves for each statement execute function public._tg_immutable();

-- Profil otomatis. Akun pertama = owner aktif; berikutnya menunggu aktivasi.
create or replace function public._tg_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_first boolean;
begin
  perform pg_advisory_xact_lock(4444);
  select not exists (select 1 from public.profiles) into v_first;
  insert into public.profiles (id, email, full_name, role, active)
  values (new.id, new.email,
          coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(new.email, '@', 1)),
          case when v_first then 'owner' else 'staf' end, v_first)
  on conflict (id) do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public._tg_new_user();

-- Alokasi FEFO: ED terdekat dulu. Mode rusak: yang kedaluwarsa dulu.
create or replace function public._plan_out(p_sku text, p_qty numeric, p_allow_expired boolean)
returns table (ed date, take numeric) language plpgsql stable security definer set search_path = public as $$
declare r record; v_left numeric := p_qty; v_today date := public._today();
begin
  for r in
    select l.ed, l.qty from public.lots l
     where l.sku = p_sku and l.qty > 0
       and (p_allow_expired or l.ed is null or l.ed >= v_today)
     order by case when p_allow_expired and l.ed < v_today then 0 else 1 end, l.ed nulls last
  loop
    exit when v_left <= 0;
    ed := r.ed; take := least(r.qty, v_left); v_left := v_left - take;
    return next;
  end loop;
  if v_left > 0 then
    raise exception '%', format('Stok %s tidak cukup: kurang %s%s', p_sku, public._q(v_left),
      case when not p_allow_expired and exists (select 1 from public.lots l where l.sku = p_sku and l.qty > 0 and l.ed < v_today)
           then ' (stok kedaluwarsa tidak boleh dijual, keluarkan sebagai "Rusak")' else '' end);
  end if;
end $$;

-- ---------------------------------------------------------------------
-- FUNGSI APLIKASI
-- ---------------------------------------------------------------------
create or replace function public.my_profile() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', id, 'email', email, 'full_name', full_name, 'role', role, 'active', active,
                            'is_first', (select count(*) from public.profiles) = 1)
    from public.profiles where id = auth.uid()
$$;

-- Produk (owner). p: {sku, barcode, name, brand_code, track_ed, min_stock, cost, price, active}
create or replace function public.save_product(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare v_sku text := upper(trim(p->>'sku')); v_bc text := nullif(trim(coalesce(p->>'barcode','')), '');
begin
  perform public._require('owner');
  if v_sku is null or v_sku !~ '^[A-Z0-9._-]{2,40}$' then
    raise exception 'Kode SKU tidak valid: 2–40 huruf/angka/titik/minus, tanpa spasi';
  end if;
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'Nama produk wajib diisi'; end if;
  if not exists (select 1 from public.brands where code = upper(trim(p->>'brand_code'))) then
    raise exception 'Brand % belum ada', p->>'brand_code';
  end if;
  if v_bc is not null and exists (select 1 from public.products where barcode = v_bc and sku <> v_sku) then
    raise exception 'Barcode % sudah dipakai produk lain', v_bc;
  end if;
  insert into public.products (sku, barcode, name, brand_code, track_ed, min_stock, cost, price, active)
  values (v_sku, v_bc, trim(p->>'name'), upper(trim(p->>'brand_code')),
          coalesce((p->>'track_ed')::boolean, true), coalesce((p->>'min_stock')::numeric, 0),
          coalesce((p->>'cost')::numeric, 0), coalesce((p->>'price')::numeric, 0), coalesce((p->>'active')::boolean, true))
  on conflict (sku) do update set barcode = excluded.barcode, name = excluded.name, brand_code = excluded.brand_code,
      track_ed = excluded.track_ed, min_stock = excluded.min_stock, cost = excluded.cost, price = excluded.price,
      active = excluded.active, updated_at = now();
  return v_sku;
end $$;

-- Impor banyak produk sekaligus dari Excel. rows: [{sku,name,brand_code,track_ed,min_stock,cost,price,barcode}]
create or replace function public.import_products(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb; n_new int := 0; n_upd int := 0; i int := 0;
begin
  perform public._require('owner');
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'File kosong'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    insert into public.brands (code, name)
    values (upper(trim(r->>'brand_code')), coalesce(nullif(trim(r->>'brand_name'),''), upper(trim(r->>'brand_code'))))
    on conflict (code) do nothing;
    if exists (select 1 from public.products where sku = upper(trim(r->>'sku'))) then n_upd := n_upd + 1; else n_new := n_new + 1; end if;
    begin
      perform public.save_product(r);
    exception when others then
      raise exception 'Baris % (%): %', i + 1, coalesce(r->>'sku','tanpa SKU'), sqlerrm;
    end;
  end loop;
  return jsonb_build_object('baru', n_new, 'diperbarui', n_upd);
end $$;

create or replace function public.save_brand(p_code text, p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require('owner');
  insert into public.brands values (upper(trim(p_code)), trim(p_name))
  on conflict (code) do update set name = excluded.name;
end $$;

create or replace function public.save_supplier(p_name text, p_phone text default null, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public._require('owner','staf');
  if coalesce(trim(p_name),'') = '' then raise exception 'Nama supplier wajib diisi'; end if;
  select id into v_id from public.suppliers where lower(name) = lower(trim(p_name));
  if v_id is not null then return v_id; end if;
  insert into public.suppliers (name, phone, note) values (trim(p_name), p_phone, p_note) returning id into v_id;
  return v_id;
end $$;

-- BARANG MASUK (langsung menambah stok)
-- p: {doc_date, source, supplier_id, sj_no, sj_date, no_sj_note, note, photo, lines:[{sku, ed, batch_no, qty}]}
create or replace function public.create_inbound(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_no text; r jsonb; v_prod public.products; v_ed date; v_qty numeric;
  v_source text := coalesce(p->>'source', 'supplier');
  v_photo text := nullif(p->>'photo', '');
begin
  perform public._require('owner','staf');
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then
    raise exception 'Belum ada barang di daftar';
  end if;
  if v_source = 'supplier' then
    if (p->>'supplier_id') is null or not exists (select 1 from public.suppliers where id = (p->>'supplier_id')::uuid) then
      raise exception 'Pilih supplier';
    end if;
    if coalesce(trim(p->>'sj_no'),'') = '' and coalesce(trim(p->>'no_sj_note'),'') = '' then
      raise exception 'Isi nomor surat jalan, atau beri keterangan kenapa tidak ada surat jalan';
    end if;
  end if;
  if v_source = 'saldo_awal' then perform public._require('owner'); end if;

  v_no := public._next_no('IN');
  insert into public.inbounds (doc_no, doc_date, source, supplier_id, sj_no, sj_date, no_sj_note, has_photo, note, received_by, received_name)
  values (v_no, coalesce((p->>'doc_date')::date, public._today()), v_source, (p->>'supplier_id')::uuid,
          nullif(trim(p->>'sj_no'),''), (p->>'sj_date')::date, nullif(trim(p->>'no_sj_note'),''), v_photo is not null,
          nullif(trim(p->>'note'),''), auth.uid(), public._me_name())
  returning id into v_id;
  if v_photo is not null then insert into public.inbound_photos values (v_id, v_photo); end if;

  for r in select * from jsonb_array_elements(p->'lines') loop
    select * into v_prod from public.products where sku = upper(trim(r->>'sku'));
    if not found then raise exception 'SKU % tidak dikenal', r->>'sku'; end if;
    if not v_prod.active then raise exception 'Produk % nonaktif', v_prod.sku; end if;
    v_qty := (r->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'Jumlah % harus lebih dari 0', v_prod.sku; end if;
    v_ed := nullif(r->>'ed','')::date;
    if v_prod.track_ed then
      if v_ed is null then raise exception 'Tanggal ED wajib untuk % (%)', v_prod.name, v_prod.sku; end if;
      if v_ed < public._today() and v_source <> 'saldo_awal' then
        raise exception 'ED % untuk % sudah lewat. Periksa kemasan.', to_char(v_ed,'DD-MM-YYYY'), v_prod.sku;
      end if;
    else
      v_ed := null;
    end if;
    insert into public.inbound_lines (inbound_id, sku, ed, batch_no, qty)
    values (v_id, v_prod.sku, v_ed, nullif(upper(trim(r->>'batch_no')),''), v_qty);
    perform public._move(v_prod.sku, v_ed, v_qty, 'masuk', v_no,
      concat_ws(' · ', case v_source when 'saldo_awal' then 'Saldo awal' when 'retur' then 'Retur' else null end,
                (select name from public.suppliers where id = (p->>'supplier_id')::uuid),
                'SJ ' || nullif(trim(p->>'sj_no'),'')));
  end loop;
  return v_no;
end $$;

create or replace function public.verify_inbound(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require('owner','finance');
  update public.inbounds set verified_by = auth.uid(), verified_name = public._me_name(), verified_at = now()
   where id = p_id and verified_at is null;
  if not found then raise exception 'Dokumen tidak ditemukan atau sudah diverifikasi'; end if;
end $$;

create or replace function public.inbound_photo(p_id uuid) returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_active() then raise exception 'Akses ditolak'; end if;
  return (select data from public.inbound_photos where inbound_id = p_id);
end $$;

-- BARANG KELUAR
-- p: {doc_date, purpose, ref, customer, note, lines:[{sku, qty}]}
-- Penjualan (marketplace/b2b/offline) langsung mengurangi stok.
-- Sampel/rusak/internal/lainnya oleh staf menunggu persetujuan owner.
create or replace function public._post_outbound(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.outbounds; l record; a record; v_alloc jsonb;
begin
  select * into o from public.outbounds where id = p_id for update;
  for l in select * from public.outbound_lines where outbound_id = p_id order by sku loop
    v_alloc := '[]'::jsonb;
    for a in select * from public._plan_out(l.sku, l.qty, o.purpose = 'rusak') loop
      perform public._move(l.sku, a.ed, -a.take, 'keluar', o.doc_no,
        concat_ws(' · ', o.purpose, nullif(o.ref,''), nullif(o.customer,'')));
      v_alloc := v_alloc || jsonb_build_object('ed', a.ed, 'qty', a.take);
    end loop;
    update public.outbound_lines set allocation = v_alloc where id = l.id;
  end loop;
end $$;

create or replace function public.create_outbound(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_no text; r jsonb; v_prod public.products; v_qty numeric;
  v_purpose text := p->>'purpose'; v_need_approval boolean; v_skus text[] := '{}';
begin
  perform public._require('owner','staf');
  if v_purpose is null then raise exception 'Pilih tujuan barang keluar'; end if;
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then
    raise exception 'Belum ada barang di daftar';
  end if;
  v_need_approval := v_purpose in ('sampel','rusak','internal','lainnya') and public.my_role() <> 'owner';
  if v_purpose in ('sampel','rusak','internal','lainnya') and coalesce(trim(p->>'note'),'') = '' then
    raise exception 'Keterangan wajib diisi untuk barang keluar non-penjualan';
  end if;

  v_no := public._next_no('OUT');
  insert into public.outbounds (doc_no, doc_date, purpose, ref, customer, note, status, created_by, created_name)
  values (v_no, coalesce((p->>'doc_date')::date, public._today()), v_purpose, nullif(trim(p->>'ref'),''),
          nullif(trim(p->>'customer'),''), nullif(trim(p->>'note'),''),
          case when v_need_approval then 'pending' else 'posted' end, auth.uid(), public._me_name())
  returning id into v_id;

  for r in select * from jsonb_array_elements(p->'lines') loop
    select * into v_prod from public.products where sku = upper(trim(r->>'sku'));
    if not found then raise exception 'SKU % tidak dikenal', r->>'sku'; end if;
    if v_prod.sku = any(v_skus) then raise exception 'SKU % tercantum dua kali, gabungkan jumlahnya', v_prod.sku; end if;
    v_skus := v_skus || v_prod.sku;
    v_qty := (r->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'Jumlah % harus lebih dari 0', v_prod.sku; end if;
    insert into public.outbound_lines (outbound_id, sku, qty) values (v_id, v_prod.sku, v_qty);
    -- cek ketersediaan sekarang juga (termasuk untuk yang menunggu persetujuan)
    perform 1 from public._plan_out(v_prod.sku, v_qty, v_purpose = 'rusak');
  end loop;

  if not v_need_approval then perform public._post_outbound(v_id); end if;
  return jsonb_build_object('doc_no', v_no, 'status', case when v_need_approval then 'pending' else 'posted' end);
end $$;

create or replace function public.decide_outbound(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare o public.outbounds;
begin
  perform public._require('owner');
  select * into o from public.outbounds where id = p_id for update;
  if not found or o.status <> 'pending' then raise exception 'Dokumen tidak menunggu persetujuan'; end if;
  if not p_approve and coalesce(trim(p_note),'') = '' then raise exception 'Isi alasan penolakan'; end if;
  if p_approve then perform public._post_outbound(p_id); end if;
  update public.outbounds set status = case when p_approve then 'posted' else 'rejected' end,
         decided_by = auth.uid(), decided_name = public._me_name(), decided_at = now(), decided_note = nullif(trim(p_note),'')
   where id = p_id;
end $$;

-- STOCK OPNAME (SO) MINGGUAN
create or replace function public.so_start(p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public._require('owner','staf');
  if exists (select 1 from public.opnames where status in ('counting','submitted')) then
    raise exception 'Masih ada SO yang belum selesai. Selesaikan dulu.';
  end if;
  insert into public.opnames (doc_no, period, note, created_by, created_name)
  values (public._next_no('SO'), to_char(public._today(), 'IYYY-"W"IW'), p_note, auth.uid(), public._me_name())
  returning id into v_id;
  insert into public.opname_lines (opname_id, sku)
  select v_id, sku from public.products where active order by sku;
  return v_id;
end $$;

-- counts: [{sku, counted}] (counted null = belum dihitung)
create or replace function public.so_save(p_id uuid, p_counts jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require('owner','staf');
  if not exists (select 1 from public.opnames where id = p_id and status = 'counting') then
    raise exception 'SO ini tidak sedang dihitung';
  end if;
  update public.opname_lines l set counted = (x.counted)::numeric, counted_name = public._me_name()
    from jsonb_to_recordset(p_counts) as x(sku text, counted numeric)
   where l.opname_id = p_id and l.sku = x.sku and (x.counted is null or x.counted >= 0);
end $$;

create or replace function public.so_submit(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_missing int; v_diff int;
begin
  perform public._require('owner','staf');
  perform 1 from public.opnames where id = p_id and status = 'counting' for update;
  if not found then raise exception 'SO ini tidak sedang dihitung'; end if;
  select count(*) into v_missing from public.opname_lines where opname_id = p_id and counted is null;
  if v_missing > 0 then raise exception '% produk belum dihitung. Isi 0 kalau barangnya memang tidak ada.', v_missing; end if;
  update public.opname_lines l set system_qty = coalesce((select sum(qty) from public.lots where sku = l.sku), 0)
   where l.opname_id = p_id;
  update public.opnames set status = 'submitted', submitted_by = auth.uid(), submitted_name = public._me_name(), submitted_at = now()
   where id = p_id;
  select count(*) into v_diff from public.opname_lines where opname_id = p_id and diff <> 0;
  return jsonb_build_object('selisih', v_diff);
end $$;

create or replace function public.so_set_reasons(p_id uuid, p_reasons jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require('owner','staf');
  if not exists (select 1 from public.opnames where id = p_id and status = 'submitted') then
    raise exception 'Alasan hanya bisa diisi setelah hasil hitung dikirim';
  end if;
  update public.opname_lines l set reason = nullif(trim(x.reason),'')
    from jsonb_to_recordset(p_reasons) as x(sku text, reason text)
   where l.opname_id = p_id and l.sku = x.sku;
end $$;

create or replace function public.so_reopen(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require('owner');
  update public.opnames set status = 'counting', submitted_by = null, submitted_name = null, submitted_at = null
   where id = p_id and status = 'submitted';
  if not found then raise exception 'SO ini tidak menunggu persetujuan'; end if;
  update public.opname_lines set system_qty = null where opname_id = p_id;
end $$;

create or replace function public.so_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require('owner');
  update public.opnames set status = 'cancelled' where id = p_id and status in ('counting','submitted');
  if not found then raise exception 'SO ini tidak bisa dibatalkan'; end if;
end $$;

-- Setujui SO: stok disesuaikan dengan hasil hitung fisik.
-- Kurang: dikurangi dari ED terdekat. Lebih: ditambahkan ke ED terlama yang ada.
create or replace function public.so_approve(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.opnames; l record; lot record; v_left numeric; v_n int; v_ed date;
begin
  perform public._require('owner');
  select * into o from public.opnames where id = p_id for update;
  if not found or o.status <> 'submitted' then raise exception 'SO ini belum dikirim untuk disetujui'; end if;
  select count(*) into v_n from public.opname_lines where opname_id = p_id and diff <> 0 and coalesce(reason,'') = '';
  if v_n > 0 then raise exception 'Masih ada % selisih tanpa alasan', v_n; end if;
  -- stok bisa berubah sejak dihitung: pakai stok saat ini sebagai acuan
  update public.opname_lines x set system_qty = coalesce((select sum(qty) from public.lots where sku = x.sku), 0)
   where x.opname_id = p_id;
  for l in select * from public.opname_lines where opname_id = p_id and diff <> 0 order by sku loop
    if l.diff < 0 then
      v_left := -l.diff;
      for lot in select ed, qty from public.lots where sku = l.sku and qty > 0 order by ed nulls last loop
        exit when v_left <= 0;
        perform public._move(l.sku, lot.ed, -least(lot.qty, v_left), 'so', o.doc_no, l.reason);
        v_left := v_left - least(lot.qty, v_left);
      end loop;
    else
      select ed into v_ed from public.lots where sku = l.sku order by (qty > 0) desc, ed desc nulls last limit 1;
      perform public._move(l.sku, v_ed, l.diff, 'so', o.doc_no, l.reason);
    end if;
  end loop;
  update public.opnames set status = 'approved', approved_by = auth.uid(), approved_name = public._me_name(), approved_at = now()
   where id = p_id;
end $$;

-- PENGGUNA
create or replace function public.list_users() returns setof jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require('owner');
  return query select jsonb_build_object('id', id, 'email', email, 'full_name', full_name, 'role', role, 'active', active, 'created_at', created_at)
    from public.profiles order by created_at;
end $$;

create or replace function public.update_user(p_id uuid, p_role text, p_active boolean, p_name text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_old public.profiles;
begin
  perform public._require('owner');
  select * into v_old from public.profiles where id = p_id for update;
  if not found then raise exception 'Pengguna tidak ditemukan'; end if;
  if p_role not in ('owner','staf','sales','finance') then raise exception 'Peran tidak dikenal'; end if;
  if v_old.role = 'owner' and v_old.active and (p_role <> 'owner' or not p_active)
     and (select count(*) from public.profiles where role = 'owner' and active) <= 1 then
    raise exception 'Minimal harus ada satu owner aktif';
  end if;
  update public.profiles set role = p_role, active = p_active, full_name = coalesce(nullif(trim(p_name),''), full_name)
   where id = p_id;
end $$;

create or replace function public.update_my_name(p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set full_name = trim(p_name) where id = auth.uid() and length(trim(p_name)) > 0;
end $$;

create or replace function public.save_settings(p_company text, p_warn int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require('owner');
  update public.settings set company_name = trim(p_company), warn_months = p_warn, updated_at = now() where id = 1;
end $$;

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
  select o.id, o.doc_no, o.doc_date, o.purpose, o.ref, o.customer, o.note, o.status, o.created_name, o.created_at,
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
                public.v_opnames, public.v_opname_lines
   to authenticated;

grant execute on function
  public.my_role(), public.is_active(), public.can_see_cost(), public._me_name(), public._today(), public._q(numeric),
  public.my_profile(), public.save_product(jsonb), public.import_products(jsonb), public.save_brand(text, text),
  public.save_supplier(text, text, text), public.create_inbound(jsonb), public.verify_inbound(uuid), public.inbound_photo(uuid),
  public.create_outbound(jsonb), public.decide_outbound(uuid, boolean, text),
  public.so_start(text), public.so_save(uuid, jsonb), public.so_submit(uuid), public.so_set_reasons(uuid, jsonb),
  public.so_reopen(uuid), public.so_cancel(uuid), public.so_approve(uuid),
  public.list_users(), public.update_user(uuid, text, boolean, text), public.update_my_name(text),
  public.save_settings(text, int), public.dashboard()
to authenticated;

-- Brand awal (bisa diubah di aplikasi)
insert into public.brands values ('ZDO', 'Zerodeo'), ('DKM', 'Depot Kimia') on conflict do nothing;

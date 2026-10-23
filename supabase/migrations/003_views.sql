-- =====================================================================
-- Warehouse Sistem 4 Keledai — 003 View laporan & export
-- Semua view memakai security_invoker supaya aturan akses tabel ikut
-- berlaku. Waktu ditampilkan dalam zona waktu di Pengaturan.
-- =====================================================================

-- Stok yang sedang dialokasikan ke dokumen draft (belum keluar fisik)
create view public.v_reservations with (security_invoker = true) as
select batch_id, location_id, sum(qty) as qty, string_agg(distinct doc_no, ', ') as docs
  from (
    select op.batch_id, op.location_id, op.qty, o.doc_no
      from public.outbound_picks op join public.outbounds o on o.id = op.outbound_id
     where o.status = 'draft'
    union all
    select tl.batch_id, tl.from_location_id, tl.qty, t.doc_no
      from public.transfer_lines tl join public.transfers t on t.id = tl.transfer_id
     where t.status = 'draft'
  ) x
 group by batch_id, location_id;

-- Stok per batch per lokasi
create view public.v_stock with (security_invoker = true) as
select sb.product_id, sb.batch_id, sb.location_id, sb.warehouse_id,
       w.code as warehouse_code, w.name as warehouse_name,
       l.code as location_code, l.kind as location_kind, l.barcode as location_barcode,
       br.id as brand_id, br.code as brand_code, br.name as brand_name,
       p.sku, p.barcode, p.name as product_name, p.category, p.uom, p.track_batch,
       b.batch_no, b.expiry_date, (b.expiry_date - current_date) as days_to_expiry,
       sb.qty,
       coalesce(r.qty, 0) as reserved_qty,
       sb.qty - coalesce(r.qty, 0) as available_qty,
       b.unit_cost,
       round(sb.qty * b.unit_cost, 2) as stock_value,
       sb.updated_at
  from public.stock_balances sb
  join public.products p on p.id = sb.product_id
  join public.brands br on br.id = p.brand_id
  join public.batches b on b.id = sb.batch_id
  join public.locations l on l.id = sb.location_id
  join public.warehouses w on w.id = sb.warehouse_id
  left join public.v_reservations r on r.batch_id = sb.batch_id and r.location_id = sb.location_id
 where sb.qty > 0;

-- Ringkasan stok per produk per gudang (termasuk yang stoknya 0)
create view public.v_stock_summary with (security_invoker = true) as
with agg as (
  select sb.product_id, sb.warehouse_id,
         sum(sb.qty) as qty,
         sum(round(sb.qty * b.unit_cost, 2)) as stock_value,
         min(b.expiry_date) filter (where sb.qty > 0) as nearest_expiry
    from public.stock_balances sb join public.batches b on b.id = sb.batch_id
   group by sb.product_id, sb.warehouse_id
), res as (
  select b.product_id, l.warehouse_id, sum(r.qty) as qty
    from public.v_reservations r
    join public.batches b on b.id = r.batch_id
    join public.locations l on l.id = r.location_id
   group by b.product_id, l.warehouse_id
)
select p.id as product_id, w.id as warehouse_id, w.code as warehouse_code, w.name as warehouse_name,
       br.id as brand_id, br.code as brand_code, br.name as brand_name,
       p.sku, p.barcode, p.name as product_name, p.category, p.uom, p.min_stock,
       coalesce(a.qty, 0) as qty,
       coalesce(rs.qty, 0) as reserved_qty,
       coalesce(a.qty, 0) - coalesce(rs.qty, 0) as available_qty,
       coalesce(a.stock_value, 0) as stock_value,
       a.nearest_expiry,
       (coalesce(a.qty, 0) - coalesce(rs.qty, 0)) < p.min_stock as below_min
  from public.products p
  join public.brands br on br.id = p.brand_id
  cross join public.warehouses w
  left join agg a on a.product_id = p.id and a.warehouse_id = w.id
  left join res rs on rs.product_id = p.id and rs.warehouse_id = w.id
 where p.active and w.active;

-- Buku besar stok (kartu stok)
create view public.v_stock_moves with (security_invoker = true) as
select m.id,
       (m.moved_at at time zone st.timezone) as waktu,
       ((m.moved_at at time zone st.timezone))::date as tanggal,
       m.moved_at,
       m.warehouse_id, w.code as warehouse_code,
       m.location_id, l.code as location_code,
       br.code as brand_code,
       m.product_id, p.sku, p.name as product_name, p.uom,
       m.batch_id, b.batch_no, b.expiry_date,
       m.move_type, m.qty, m.unit_cost, round(m.qty * m.unit_cost, 2) as value,
       m.doc_type, m.doc_id, m.doc_no, m.note,
       pr.full_name as created_by_name
  from public.stock_moves m
  join public.products p on p.id = m.product_id
  join public.brands br on br.id = p.brand_id
  join public.batches b on b.id = m.batch_id
  join public.locations l on l.id = m.location_id
  join public.warehouses w on w.id = m.warehouse_id
  cross join public.settings st
  left join public.profiles pr on pr.id = m.created_by;

-- Stok mendekati / sudah kedaluwarsa
create view public.v_expiring with (security_invoker = true) as
select s.*
  from public.v_stock s cross join public.settings st
 where s.expiry_date is not null
   and s.expiry_date <= current_date + st.expiry_warning_days;

-- Detail dokumen untuk export
create view public.v_inbound_lines with (security_invoker = true) as
select d.id as inbound_id, d.doc_no, d.status, d.source, d.partner_name, d.reference_no, d.mode,
       (d.created_at at time zone st.timezone) as dibuat, (d.posted_at at time zone st.timezone) as diposting,
       w.code as warehouse_code, br.code as brand_code, p.sku, p.name as product_name,
       il.batch_no, il.expiry_date, l.code as location_code, il.qty, il.unit_cost,
       round(il.qty * il.unit_cost, 2) as value, il.scanned, d.note
  from public.inbound_lines il
  join public.inbounds d on d.id = il.inbound_id
  join public.warehouses w on w.id = d.warehouse_id
  join public.products p on p.id = il.product_id
  join public.brands br on br.id = p.brand_id
  join public.locations l on l.id = il.location_id
  cross join public.settings st;

create view public.v_outbound_lines with (security_invoker = true) as
select d.id as outbound_id, d.doc_no, d.status, d.purpose, d.partner_name, d.reference_no, d.mode,
       so.doc_no as sales_order_no,
       (d.created_at at time zone st.timezone) as dibuat, (d.posted_at at time zone st.timezone) as diposting,
       w.code as warehouse_code, br.code as brand_code, p.sku, p.name as product_name,
       b.batch_no, b.expiry_date, l.code as location_code, op.qty, op.picked_qty,
       b.unit_cost, round(op.qty * b.unit_cost, 2) as cost_value, d.note
  from public.outbound_picks op
  join public.outbounds d on d.id = op.outbound_id
  join public.warehouses w on w.id = d.warehouse_id
  join public.products p on p.id = op.product_id
  join public.brands br on br.id = p.brand_id
  join public.batches b on b.id = op.batch_id
  join public.locations l on l.id = op.location_id
  left join public.sales_orders so on so.id = d.sales_order_id
  cross join public.settings st;

create view public.v_transfer_lines with (security_invoker = true) as
select t.id as transfer_id, t.doc_no, t.status, fw.code as from_warehouse, tw.code as to_warehouse,
       (t.sent_at at time zone st.timezone) as dikirim, (t.received_at at time zone st.timezone) as diterima,
       br.code as brand_code, p.sku, p.name as product_name, b.batch_no, b.expiry_date,
       l.code as from_location, tl.qty as qty_kirim, tl.picked_qty, tl.received_qty as qty_terima,
       tl.received_qty - tl.qty as selisih, round((tl.received_qty - tl.qty) * b.unit_cost, 2) as nilai_selisih,
       t.receive_note
  from public.transfer_lines tl
  join public.transfers t on t.id = tl.transfer_id
  join public.warehouses fw on fw.id = t.from_warehouse_id
  join public.warehouses tw on tw.id = t.to_warehouse_id
  join public.products p on p.id = tl.product_id
  join public.brands br on br.id = p.brand_id
  join public.batches b on b.id = tl.batch_id
  join public.locations l on l.id = tl.from_location_id
  cross join public.settings st;

-- Semua selisih stok: opname, penyesuaian, transfer
create view public.v_discrepancies with (security_invoker = true) as
select 'opname'::text as sumber, sc.doc_no, (sc.approved_at at time zone st.timezone) as waktu,
       w.code as warehouse_code, l.code as location_code, br.code as brand_code,
       p.sku, p.name as product_name, b.batch_no,
       cl.system_qty as qty_sistem, cl.counted_qty as qty_fisik, cl.diff_qty as qty_selisih,
       round(cl.diff_qty * b.unit_cost, 2) as nilai_selisih, cl.reason as alasan,
       pa.full_name as disetujui_oleh
  from public.stock_count_lines cl
  join public.stock_counts sc on sc.id = cl.count_id
  join public.warehouses w on w.id = sc.warehouse_id
  join public.locations l on l.id = cl.location_id
  join public.products p on p.id = cl.product_id
  join public.brands br on br.id = p.brand_id
  join public.batches b on b.id = cl.batch_id
  cross join public.settings st
  left join public.profiles pa on pa.id = sc.approved_by
 where sc.status = 'approved' and cl.diff_qty <> 0
union all
select 'penyesuaian', a.doc_no, (a.decided_at at time zone st.timezone),
       w.code, l.code, br.code, p.sku, p.name, al.batch_no,
       null, null, al.qty_change,
       round(al.qty_change * coalesce(b.unit_cost, 0), 2),
       a.reason || coalesce(': ' || a.note, ''),
       pa.full_name
  from public.adjustment_lines al
  join public.adjustments a on a.id = al.adjustment_id
  join public.warehouses w on w.id = a.warehouse_id
  join public.locations l on l.id = al.location_id
  join public.products p on p.id = al.product_id
  join public.brands br on br.id = p.brand_id
  left join public.batches b on b.product_id = al.product_id and b.batch_no = al.batch_no
  cross join public.settings st
  left join public.profiles pa on pa.id = a.decided_by
 where a.status = 'approved'
union all
select 'transfer', t.doc_no, (t.received_at at time zone st.timezone),
       tw.code, null, br.code, p.sku, p.name, b.batch_no,
       tl.qty, tl.received_qty, tl.received_qty - tl.qty,
       round((tl.received_qty - tl.qty) * b.unit_cost, 2),
       t.receive_note, pr.full_name
  from public.transfer_lines tl
  join public.transfers t on t.id = tl.transfer_id
  join public.warehouses tw on tw.id = t.to_warehouse_id
  join public.products p on p.id = tl.product_id
  join public.brands br on br.id = p.brand_id
  join public.batches b on b.id = tl.batch_id
  cross join public.settings st
  left join public.profiles pr on pr.id = t.received_by
 where t.status = 'diterima' and tl.received_qty <> tl.qty;

-- Sales order dengan total
create view public.v_sales_orders with (security_invoker = true) as
select so.*, c.code as customer_code, c.name as customer_name, w.code as warehouse_code,
       t.subtotal, t.tax_amount, t.total,
       (select i.invoice_no from public.invoices i where i.sales_order_id = so.id and i.status <> 'void' limit 1) as invoice_no,
       (select o.doc_no from public.outbounds o where o.sales_order_id = so.id and o.status <> 'cancelled'
         order by o.created_at desc limit 1) as outbound_no
  from public.sales_orders so
  join public.customers c on c.id = so.customer_id
  join public.warehouses w on w.id = so.warehouse_id
  cross join lateral public.so_totals(so.id) t;

-- Faktur & piutang
create view public.v_invoices with (security_invoker = true) as
select i.*, c.code as customer_code, c.name as customer_name, so.doc_no as sales_order_no,
       i.total - i.paid_amount as outstanding,
       case when i.status in ('belum_lunas', 'sebagian') then greatest(current_date - i.due_date, 0) end as days_overdue,
       case
         when i.status not in ('belum_lunas', 'sebagian') then null
         when current_date <= i.due_date then 'belum jatuh tempo'
         when current_date - i.due_date <= 30 then '1-30 hari'
         when current_date - i.due_date <= 60 then '31-60 hari'
         when current_date - i.due_date <= 90 then '61-90 hari'
         else '> 90 hari'
       end as aging
  from public.invoices i
  join public.customers c on c.id = i.customer_id
  join public.sales_orders so on so.id = i.sales_order_id;

create view public.v_payments with (security_invoker = true) as
select pm.id, pm.paid_at, pm.amount, pm.method, pm.reference, pm.note,
       i.invoice_no, c.code as customer_code, c.name as customer_name,
       pr.full_name as created_by_name, pm.created_at
  from public.payments pm
  join public.invoices i on i.id = pm.invoice_id
  join public.customers c on c.id = i.customer_id
  left join public.profiles pr on pr.id = pm.created_by;

-- Pesanan marketplace
create view public.v_marketplace_orders with (security_invoker = true) as
select o.*, s.channel, s.name as store_name, s.warehouse_id,
       (o.order_date at time zone st.timezone) as waktu_pesanan,
       ob.doc_no as outbound_no,
       (select count(*) from public.marketplace_order_lines l where l.order_id = o.id) as line_count,
       (select count(*) from public.marketplace_order_lines l where l.order_id = o.id
          and not exists (select 1 from public.mp_resolve_sku(o.store_id, l.external_sku))) as unmapped_count
  from public.marketplace_orders o
  join public.stores s on s.id = o.store_id
  cross join public.settings st
  left join public.outbounds ob on ob.id = o.outbound_id;

create view public.v_marketplace_unmapped with (security_invoker = true) as
select o.store_id, s.name as store_name, s.channel, l.external_sku,
       max(l.product_name) as product_name, count(*) as line_count, count(distinct o.id) as order_count
  from public.marketplace_order_lines l
  join public.marketplace_orders o on o.id = l.order_id
  join public.stores s on s.id = o.store_id
 where o.status in ('baru', 'diproses')
   and not exists (select 1 from public.mp_resolve_sku(o.store_id, l.external_sku))
 group by o.store_id, s.name, s.channel, l.external_sku;

-- Penjualan gabungan (B2B dari faktur + marketplace) untuk finance
create view public.v_sales with (security_invoker = true) as
select 'b2b'::text as kanal, null::text as toko, i.invoice_date as tanggal,
       i.invoice_no as no_dokumen, so.doc_no as no_referensi, c.name as pelanggan,
       br.code as brand_code, p.sku, p.name as product_name,
       il.qty, il.unit_price, il.discount_percent, il.line_total as nilai,
       i.status as status_dokumen
  from public.invoice_lines il
  join public.invoices i on i.id = il.invoice_id
  join public.sales_orders so on so.id = i.sales_order_id
  join public.customers c on c.id = i.customer_id
  join public.products p on p.id = il.product_id
  join public.brands br on br.id = p.brand_id
 where i.status <> 'void'
union all
select s.channel, s.name, ((o.order_date at time zone st.timezone))::date,
       o.external_order_id, ob.doc_no, o.buyer_name,
       coalesce((select br2.code from public.mp_resolve_sku(o.store_id, l.external_sku) r
                   join public.products p2 on p2.id = r.product_id
                   join public.brands br2 on br2.id = p2.brand_id limit 1), sb.code),
       l.external_sku, l.product_name,
       l.qty, l.unit_price, 0::numeric, l.line_amount,
       o.status
  from public.marketplace_order_lines l
  join public.marketplace_orders o on o.id = l.order_id
  join public.stores s on s.id = o.store_id
  cross join public.settings st
  left join public.brands sb on sb.id = s.brand_id
  left join public.outbounds ob on ob.id = o.outbound_id
 where o.status <> 'batal';

-- Ringkasan untuk beranda
create or replace function public.dashboard_stats() returns jsonb
language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'inbound_draft',      (select count(*) from public.inbounds where status = 'draft'),
    'outbound_draft',     (select count(*) from public.outbounds where status = 'draft'),
    'transfer_draft',     (select count(*) from public.transfers where status = 'draft'),
    'transfer_transit',   (select count(*) from public.transfers where status = 'dikirim'),
    'count_open',         (select count(*) from public.stock_counts where status = 'counting'),
    'count_submitted',    (select count(*) from public.stock_counts where status = 'submitted'),
    'adjustment_pending', (select count(*) from public.adjustments where status = 'pending'),
    'mp_new',             (select count(*) from public.marketplace_orders where status = 'baru'),
    'mp_unmapped',        (select count(*) from public.v_marketplace_unmapped),
    'so_confirmed',       (select count(*) from public.sales_orders where status = 'confirmed'),
    'invoice_overdue',    (select count(*) from public.invoices where status in ('belum_lunas', 'sebagian') and due_date < current_date),
    'receivable_total',   (select coalesce(sum(total - paid_amount), 0) from public.invoices where status in ('belum_lunas', 'sebagian')),
    'stock_value',        (select coalesce(sum(stock_value), 0) from public.v_stock),
    'expiring',           (select count(*) from public.v_expiring where days_to_expiry >= 0),
    'expired',            (select count(*) from public.v_expiring where days_to_expiry < 0),
    'below_min',          (select count(*) from public.v_stock_summary where below_min and min_stock > 0)
  )
$$;

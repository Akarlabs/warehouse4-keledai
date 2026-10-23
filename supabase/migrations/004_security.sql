-- =====================================================================
-- Warehouse Sistem 4 Keledai — 004 Keamanan (RLS & hak akses)
-- Peran:
--   owner   : semua akses, termasuk mengatur owner/admin
--   admin   : semua akses operasional & master data, menyetujui selisih
--   gudang  : barang masuk/keluar, transfer, pindah rak, opname, usul penyesuaian
--   finance : faktur, pembayaran, laporan & export
--   sales   : pelanggan, sales order, impor pesanan marketplace
-- Akun nonaktif tidak bisa melihat apa pun.
-- =====================================================================

-- RPC tambahan: simpan pemetaan kolom impor per toko
create or replace function public.save_import_mapping(p_store_id uuid, p_mapping jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_role('owner', 'admin', 'sales');
  update public.stores set import_mapping = p_mapping where id = p_store_id;
  if not found then raise exception 'Toko tidak ditemukan'; end if;
end $$;

-- ---------------------------------------------------------------------
-- Cabut semua hak bawaan, lalu beri ulang secara spesifik
-- ---------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

grant usage on schema public to authenticated;
grant select on all tables in schema public to authenticated;   -- termasuk view
revoke select on public.doc_counters from authenticated;

-- Fungsi yang boleh dipanggil aplikasi (selain ini hanya dipakai internal)
grant execute on function
  public.my_role(), public.my_warehouse(), public.has_role(text[]), public.can_use_warehouse(uuid),
  public._q(numeric), public._rp(numeric), public._is_cancel_status(text),
  public.lookup_code(text),
  public.inbound_add_line(uuid, text, numeric, uuid, text, date, numeric, boolean),
  public.post_inbound(uuid),
  public.outbound_set_item(uuid, text, numeric, boolean),
  public.allocate_outbound(uuid),
  public.pick_scan(text, uuid, text, numeric, uuid),
  public.pick_reset(text, uuid),
  public.post_outbound(uuid),
  public.transfer_set_item(uuid, text, numeric, boolean),
  public.allocate_transfer(uuid),
  public.send_transfer(uuid),
  public.receive_scan(uuid, text, numeric, uuid),
  public.complete_transfer(uuid, uuid, text),
  public.relocate_stock(uuid, uuid, text, uuid, numeric, text),
  public.count_add(uuid, uuid, text, numeric, text, date, boolean),
  public.submit_count(uuid),
  public.set_count_reasons(uuid, jsonb),
  public.reopen_count(uuid),
  public.approve_count(uuid),
  public.adjustment_add_line(uuid, text, uuid, numeric, text, date),
  public.submit_adjustment(uuid),
  public.decide_adjustment(uuid, boolean, text),
  public.cancel_document(text, uuid),
  public.so_totals(uuid),
  public.confirm_sales_order(uuid),
  public.create_outbound_from_so(uuid),
  public.create_invoice(uuid, date),
  public.add_payment(uuid, numeric, date, text, text, text),
  public.void_invoice(uuid, text),
  public.mp_resolve_sku(uuid, text),
  public.import_marketplace_orders(uuid, text, jsonb),
  public.create_outbound_from_marketplace(uuid[]),
  public.cancel_marketplace_order(uuid),
  public.save_import_mapping(uuid, jsonb),
  public.upsert_products(jsonb),
  public.create_opening_stock(uuid, jsonb),
  public.update_user(uuid, text, boolean, uuid, text),
  public.dashboard_stats()
to authenticated;

-- ---------------------------------------------------------------------
-- Aktifkan RLS + kebijakan baca untuk semua tabel
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  for t in
    select tablename from pg_tables where schemaname = 'public'
  loop
    execute format('alter table public.%I enable row level security', t);
    if t <> 'doc_counters' then
      execute format(
        'create policy %I on public.%I for select to authenticated using ((select public.my_role()) is not null)',
        t || '_read', t);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Master data
-- ---------------------------------------------------------------------
grant update (company_name, company_address, company_phone, company_npwp, timezone,
              default_tax_percent, expiry_warning_days, invoice_footer, updated_at)
  on public.settings to authenticated;
create policy settings_update on public.settings for update to authenticated
  using ((select public.has_role('owner', 'admin'))) with check (true);

grant insert (code, name, legal_entity, active), update (code, name, legal_entity, active)
  on public.brands to authenticated;
create policy brands_insert on public.brands for insert to authenticated
  with check ((select public.has_role('owner', 'admin')));
create policy brands_update on public.brands for update to authenticated
  using ((select public.has_role('owner', 'admin'))) with check (true);

grant insert (code, name, city, address, active), update (name, city, address, active)
  on public.warehouses to authenticated;
create policy warehouses_insert on public.warehouses for insert to authenticated
  with check ((select public.has_role('owner', 'admin')));
create policy warehouses_update on public.warehouses for update to authenticated
  using ((select public.has_role('owner', 'admin'))) with check (true);

grant insert (warehouse_id, code, name, kind, barcode, active), update (name, kind, active)
  on public.locations to authenticated;
create policy locations_insert on public.locations for insert to authenticated
  with check ((select public.has_role('owner', 'admin')));
create policy locations_update on public.locations for update to authenticated
  using ((select public.has_role('owner', 'admin'))) with check (true);

grant insert (brand_id, sku, barcode, name, category, uom, track_batch, min_stock, default_cost, default_price, active),
      update (brand_id, barcode, name, category, uom, track_batch, min_stock, default_cost, default_price, active)
  on public.products to authenticated;
create policy products_insert on public.products for insert to authenticated
  with check ((select public.has_role('owner', 'admin')));
create policy products_update on public.products for update to authenticated
  using ((select public.has_role('owner', 'admin'))) with check (true);

grant insert (code, name, contact_name, phone, email, npwp, address, city, payment_terms_days, credit_limit, active),
      update (name, contact_name, phone, email, npwp, address, city, payment_terms_days, credit_limit, active)
  on public.customers to authenticated;
create policy customers_insert on public.customers for insert to authenticated
  with check ((select public.has_role('owner', 'admin', 'sales')));
create policy customers_update on public.customers for update to authenticated
  using ((select public.has_role('owner', 'admin', 'sales'))) with check (true);

grant insert (channel, name, brand_id, warehouse_id, active), update (name, brand_id, warehouse_id, active)
  on public.stores to authenticated;
create policy stores_insert on public.stores for insert to authenticated
  with check ((select public.has_role('owner', 'admin')));
create policy stores_update on public.stores for update to authenticated
  using ((select public.has_role('owner', 'admin'))) with check (true);

grant insert (store_id, external_sku, product_id, multiplier), update (multiplier), delete
  on public.sku_mappings to authenticated;
create policy sku_mappings_insert on public.sku_mappings for insert to authenticated
  with check ((select public.has_role('owner', 'admin', 'sales')));
create policy sku_mappings_update on public.sku_mappings for update to authenticated
  using ((select public.has_role('owner', 'admin', 'sales'))) with check (true);
create policy sku_mappings_delete on public.sku_mappings for delete to authenticated
  using ((select public.has_role('owner', 'admin', 'sales')));

-- ---------------------------------------------------------------------
-- Dokumen gudang (header boleh dibuat & diedit selama draft;
-- status hanya berubah lewat fungsi)
-- ---------------------------------------------------------------------
grant insert (warehouse_id, source, partner_name, reference_no, mode, note),
      update (source, partner_name, reference_no, mode, note)
  on public.inbounds to authenticated;
create policy inbounds_insert on public.inbounds for insert to authenticated
  with check ((select public.has_role('owner', 'admin', 'gudang')) and public.can_use_warehouse(warehouse_id));
create policy inbounds_update on public.inbounds for update to authenticated
  using (status = 'draft' and (select public.has_role('owner', 'admin', 'gudang')) and public.can_use_warehouse(warehouse_id))
  with check (status = 'draft');

grant update (qty, unit_cost, location_id, batch_no, expiry_date), delete on public.inbound_lines to authenticated;
create policy inbound_lines_update on public.inbound_lines for update to authenticated
  using (exists (select 1 from public.inbounds d where d.id = inbound_id and d.status = 'draft'
                  and public.can_use_warehouse(d.warehouse_id))
         and (select public.has_role('owner', 'admin', 'gudang')))
  with check (qty > 0);
create policy inbound_lines_delete on public.inbound_lines for delete to authenticated
  using (exists (select 1 from public.inbounds d where d.id = inbound_id and d.status = 'draft'
                  and public.can_use_warehouse(d.warehouse_id))
         and (select public.has_role('owner', 'admin', 'gudang')));

grant insert (warehouse_id, purpose, partner_name, reference_no, mode, note),
      update (partner_name, reference_no, mode, note)
  on public.outbounds to authenticated;
create policy outbounds_insert on public.outbounds for insert to authenticated
  with check ((select public.has_role('owner', 'admin', 'gudang')) and public.can_use_warehouse(warehouse_id)
              and purpose <> 'marketplace' and sales_order_id is null);
create policy outbounds_update on public.outbounds for update to authenticated
  using (status = 'draft' and (select public.has_role('owner', 'admin', 'gudang')) and public.can_use_warehouse(warehouse_id))
  with check (status = 'draft');

-- Alokasi manual (mode manual): pilih sendiri batch & rak
grant insert (outbound_id, product_id, batch_id, location_id, qty),
      update (batch_id, location_id, qty), delete
  on public.outbound_picks to authenticated;
create policy outbound_picks_insert on public.outbound_picks for insert to authenticated
  with check (exists (select 1 from public.outbounds d where d.id = outbound_id and d.status = 'draft'
                       and public.can_use_warehouse(d.warehouse_id))
              and (select public.has_role('owner', 'admin', 'gudang')) and picked_qty = 0);
create policy outbound_picks_update on public.outbound_picks for update to authenticated
  using (exists (select 1 from public.outbounds d where d.id = outbound_id and d.status = 'draft'
                  and public.can_use_warehouse(d.warehouse_id))
         and (select public.has_role('owner', 'admin', 'gudang')))
  with check (picked_qty <= qty);
create policy outbound_picks_delete on public.outbound_picks for delete to authenticated
  using (exists (select 1 from public.outbounds d where d.id = outbound_id and d.status = 'draft'
                  and public.can_use_warehouse(d.warehouse_id))
         and (select public.has_role('owner', 'admin', 'gudang')));

grant insert (from_warehouse_id, to_warehouse_id, mode, note), update (mode, note)
  on public.transfers to authenticated;
create policy transfers_insert on public.transfers for insert to authenticated
  with check ((select public.has_role('owner', 'admin', 'gudang')) and public.can_use_warehouse(from_warehouse_id));
create policy transfers_update on public.transfers for update to authenticated
  using (status = 'draft' and (select public.has_role('owner', 'admin', 'gudang')) and public.can_use_warehouse(from_warehouse_id))
  with check (status = 'draft');

grant insert (warehouse_id, title, location_ids, note), update (title, note)
  on public.stock_counts to authenticated;
create policy stock_counts_insert on public.stock_counts for insert to authenticated
  with check ((select public.has_role('owner', 'admin', 'gudang')) and public.can_use_warehouse(warehouse_id));
create policy stock_counts_update on public.stock_counts for update to authenticated
  using (status = 'counting' and (select public.has_role('owner', 'admin', 'gudang')) and public.can_use_warehouse(warehouse_id))
  with check (status = 'counting');

grant delete on public.stock_count_lines to authenticated;
create policy stock_count_lines_delete on public.stock_count_lines for delete to authenticated
  using (exists (select 1 from public.stock_counts d where d.id = count_id and d.status = 'counting'
                  and public.can_use_warehouse(d.warehouse_id))
         and (select public.has_role('owner', 'admin', 'gudang')));

grant insert (warehouse_id, reason, note), update (reason, note) on public.adjustments to authenticated;
create policy adjustments_insert on public.adjustments for insert to authenticated
  with check ((select public.has_role('owner', 'admin', 'gudang')) and public.can_use_warehouse(warehouse_id));
create policy adjustments_update on public.adjustments for update to authenticated
  using (status = 'draft' and (select public.has_role('owner', 'admin', 'gudang')) and public.can_use_warehouse(warehouse_id))
  with check (status = 'draft');

grant delete on public.adjustment_lines to authenticated;
create policy adjustment_lines_delete on public.adjustment_lines for delete to authenticated
  using (exists (select 1 from public.adjustments d where d.id = adjustment_id and d.status = 'draft'
                  and public.can_use_warehouse(d.warehouse_id))
         and (select public.has_role('owner', 'admin', 'gudang')));

-- ---------------------------------------------------------------------
-- Penjualan B2B
-- ---------------------------------------------------------------------
grant insert (customer_id, warehouse_id, order_date, customer_po, tax_percent, discount_amount, note),
      update (customer_id, warehouse_id, order_date, customer_po, tax_percent, discount_amount, note)
  on public.sales_orders to authenticated;
create policy sales_orders_insert on public.sales_orders for insert to authenticated
  with check ((select public.has_role('owner', 'admin', 'sales')));
create policy sales_orders_update on public.sales_orders for update to authenticated
  using (status = 'draft' and (select public.has_role('owner', 'admin', 'sales')))
  with check (status = 'draft');

grant insert (sales_order_id, product_id, qty, unit_price, discount_percent),
      update (product_id, qty, unit_price, discount_percent), delete
  on public.sales_order_lines to authenticated;
create policy sales_order_lines_insert on public.sales_order_lines for insert to authenticated
  with check (exists (select 1 from public.sales_orders d where d.id = sales_order_id and d.status = 'draft')
              and (select public.has_role('owner', 'admin', 'sales')));
create policy sales_order_lines_update on public.sales_order_lines for update to authenticated
  using (exists (select 1 from public.sales_orders d where d.id = sales_order_id and d.status = 'draft')
         and (select public.has_role('owner', 'admin', 'sales')))
  with check (true);
create policy sales_order_lines_delete on public.sales_order_lines for delete to authenticated
  using (exists (select 1 from public.sales_orders d where d.id = sales_order_id and d.status = 'draft')
         and (select public.has_role('owner', 'admin', 'sales')));

grant update (note) on public.invoices to authenticated;
create policy invoices_update on public.invoices for update to authenticated
  using ((select public.has_role('owner', 'admin', 'finance'))) with check (true);

begin;

create or replace function public.process_personal_books_purchase_record(target_record_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  purchase_row public.books_personal_purchase_records%rowtype;
  target_personal_organization_id uuid;
  target_expense_id uuid;
  target_vendor_name text;
  target_vendor_email text;
  target_vendor_phone text;
  target_vendor_contact_id uuid;
  expense_description text;
  item_details text;
  menu_order public.menu_orders%rowtype;
begin
  select * into purchase_row
    from public.books_personal_purchase_records
   where id = target_record_id
   for update;
  if not found then raise exception 'Purchase record was not found'; end if;
  if purchase_row.status = 'posted' then return 'posted'; end if;
  if purchase_row.status = 'reversed' then return 'reversed'; end if;

  target_personal_organization_id := public.ensure_personal_books_workspace(purchase_row.buyer_user_id);
  if target_personal_organization_id is null then
    update public.books_personal_purchase_records
       set status = 'failed', error_message = 'Buyer does not have a registered account', updated_at = now()
     where id = target_record_id;
    return 'failed';
  end if;

  select organization.name, organization.email, organization.phone
    into target_vendor_name, target_vendor_email, target_vendor_phone
    from public.books_organizations organization
   where organization.id = purchase_row.hotel_organization_id;

  select contact.id into target_vendor_contact_id
    from public.books_contacts contact
   where contact.organization_id = target_personal_organization_id
     and lower(contact.name) = lower(target_vendor_name)
     and contact.type in ('vendor', 'both')
   order by contact.created_at
   limit 1;

  if target_vendor_contact_id is null then
    insert into public.books_contacts (organization_id, name, type, email, phone)
    values (target_personal_organization_id, target_vendor_name, 'vendor', target_vendor_email, target_vendor_phone)
    returning id into target_vendor_contact_id;
  end if;

  expense_description := purchase_row.description;
  if purchase_row.source_type = 'menu_order' then
    select * into menu_order
      from public.menu_orders
     where id = purchase_row.source_id;
    select string_agg(
      format('%s (%s × %s)', item.item_name, item.quantity, to_char(item.unit_price, 'FM999999999999990D00')),
      ', ' order by item.created_at, item.id
    ) into item_details
      from public.menu_order_items item
     where item.order_id = purchase_row.source_id;
    expense_description := concat_ws(' — ', purchase_row.description, nullif(item_details, '')) ||
      ' | Subtotal: ' || to_char(menu_order.subtotal, 'FM999999999999990D00') || ' ' || purchase_row.currency_code ||
      '; tax: ' || to_char(menu_order.tax_amount, 'FM999999999999990D00') || ' ' || purchase_row.currency_code ||
      '; service fee: ' || to_char(menu_order.service_fee, 'FM999999999999990D00') || ' ' || purchase_row.currency_code ||
      '; tip: ' || to_char(menu_order.tip_amount, 'FM999999999999990D00') || ' ' || purchase_row.currency_code;
  end if;

  insert into public.books_expenses (
    organization_id, contact_id, description, expense_date, currency_code, amount, tax_amount,
    payment_status, purchase_source_type, purchase_source_id
  ) values (
    target_personal_organization_id, target_vendor_contact_id, expense_description,
    purchase_row.purchase_date, purchase_row.currency_code, purchase_row.amount, 0,
    'paid', 'hotel_purchase', purchase_row.id
  )
  on conflict (organization_id, purchase_source_type, purchase_source_id)
    where purchase_source_type is not null and purchase_source_id is not null
    do nothing
  returning id into target_expense_id;

  if target_expense_id is null then
    select expense.id into target_expense_id
      from public.books_expenses expense
     where expense.organization_id = target_personal_organization_id
       and expense.purchase_source_type = 'hotel_purchase'
       and expense.purchase_source_id = purchase_row.id;
  end if;
  if target_expense_id is null then raise exception 'Personal Books expense was not created'; end if;

  update public.books_personal_purchase_records
     set personal_organization_id = target_personal_organization_id,
         expense_id = target_expense_id,
         status = 'posted', error_message = null, updated_at = now()
   where id = target_record_id;
  return 'posted';
exception when others then
  update public.books_personal_purchase_records
     set status = 'failed', error_message = left(sqlerrm, 2000), updated_at = now()
   where id = target_record_id;
  return 'failed';
end;
$$;
revoke all on function public.process_personal_books_purchase_record(uuid) from public, anon, authenticated;
grant execute on function public.process_personal_books_purchase_record(uuid) to service_role;

create or replace function public.retry_my_personal_books_purchases()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  purchase_row record;
  retried_count integer := 0;
begin
  if auth.uid() is null then raise exception 'Sign in to retry Personal Books purchases'; end if;
  for purchase_row in
    select purchase.id
      from public.books_personal_purchase_records purchase
     where purchase.buyer_user_id = auth.uid()
       and purchase.status in ('pending', 'failed')
     order by purchase.created_at
     for update skip locked
  loop
    perform public.process_personal_books_purchase_record(purchase_row.id);
    retried_count := retried_count + 1;
  end loop;
  return retried_count;
end;
$$;
revoke all on function public.retry_my_personal_books_purchases() from public, anon;
grant execute on function public.retry_my_personal_books_purchases() to authenticated;

create or replace function public.apply_hotel_loyalty_delta(
  target_organization_id uuid,
  target_user_id uuid,
  target_entry_type text,
  target_points_delta bigint,
  target_source_type text,
  target_source_id uuid,
  target_description text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  account_row public.hotel_loyalty_accounts%rowtype;
  entry_uuid uuid;
  applied_positive bigint;
  applied_negative bigint;
  posting_amount numeric(20,4);
begin
  if target_points_delta = 0 or target_source_id is null then raise exception 'A valid hotel loyalty entry is required'; end if;
  select * into account_row
    from public.hotel_loyalty_accounts
   where organization_id = target_organization_id and user_id = target_user_id
   for update;
  if not found then
    perform public.hotel_loyalty_make_account(target_organization_id, target_user_id);
    select * into account_row
      from public.hotel_loyalty_accounts
     where organization_id = target_organization_id and user_id = target_user_id
     for update;
  end if;
  if target_points_delta > 0 and not account_row.is_enrolled then return null; end if;

  insert into public.hotel_loyalty_ledger_entries (
    organization_id, user_id, entry_type, points_delta, source_type, source_id, description
  ) values (
    target_organization_id, target_user_id, target_entry_type, target_points_delta,
    target_source_type, target_source_id, target_description
  )
  on conflict (organization_id, user_id, source_type, source_id, entry_type) do nothing
  returning id into entry_uuid;
  if entry_uuid is null then return null; end if;

  if target_points_delta > 0 then
    applied_negative := least(account_row.debt_points, target_points_delta);
    applied_positive := target_points_delta - applied_negative;
    update public.hotel_loyalty_accounts
       set available_points = available_points + applied_positive,
           debt_points = debt_points - applied_negative,
           lifetime_points_earned = lifetime_points_earned + target_points_delta,
           updated_at = now()
     where organization_id = target_organization_id and user_id = target_user_id;
  else
    applied_positive := least(account_row.available_points, abs(target_points_delta));
    applied_negative := abs(target_points_delta) - applied_positive;
    update public.hotel_loyalty_accounts
       set available_points = available_points - applied_positive,
           debt_points = debt_points + applied_negative,
           updated_at = now()
     where organization_id = target_organization_id and user_id = target_user_id;
  end if;

  select abs(target_points_delta) * program.ugx_value_per_point
    into posting_amount
    from public.hotel_loyalty_programs program
   where program.organization_id = target_organization_id;
  begin
    perform public.post_hotel_loyalty_ledger_entry(entry_uuid);
  exception when others then
    insert into public.hotel_loyalty_books_postings (
      ledger_entry_id, organization_id, amount_ugx, status, error_message
    ) values (
      entry_uuid, target_organization_id, posting_amount, 'failed', left(sqlerrm, 1000)
    )
    on conflict (ledger_entry_id) do update
      set status = 'failed', journal_transaction_id = null,
          error_message = excluded.error_message, updated_at = now();
  end;
  return entry_uuid;
end;
$$;
revoke all on function public.apply_hotel_loyalty_delta(uuid, uuid, text, bigint, text, uuid, text) from public, anon, authenticated;

notify pgrst, 'reload schema';
commit;

alter table public.menu_orders add column if not exists buyer_tax_id text;
alter table public.hotel_bookings add column if not exists buyer_tax_id text;
alter table public.special_event_bookings add column if not exists buyer_tax_id text;
alter table public.books_invoices add column if not exists buyer_tax_id text;

alter table public.menu_orders drop constraint if exists menu_orders_buyer_tax_id_check;
alter table public.menu_orders add constraint menu_orders_buyer_tax_id_check
  check (buyer_tax_id is null or length(trim(buyer_tax_id)) between 1 and 30);
alter table public.hotel_bookings drop constraint if exists hotel_bookings_buyer_tax_id_check;
alter table public.hotel_bookings add constraint hotel_bookings_buyer_tax_id_check
  check (buyer_tax_id is null or length(trim(buyer_tax_id)) between 1 and 30);
alter table public.special_event_bookings drop constraint if exists special_event_bookings_buyer_tax_id_check;
alter table public.special_event_bookings add constraint special_event_bookings_buyer_tax_id_check
  check (buyer_tax_id is null or length(trim(buyer_tax_id)) between 1 and 30);
alter table public.books_invoices drop constraint if exists books_invoices_buyer_tax_id_check;
alter table public.books_invoices add constraint books_invoices_buyer_tax_id_check
  check (buyer_tax_id is null or length(trim(buyer_tax_id)) between 1 and 30);

create or replace function public.resolve_checkout_buyer_tax_id(
  target_user_id uuid,
  target_business_purchase boolean,
  target_supplied_tax_id text
)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  supplied_tax_id text := nullif(trim(target_supplied_tax_id), '');
  saved_tax_id text;
begin
  if not coalesce(target_business_purchase, false) then
    return null;
  end if;

  select nullif(trim(profile.buyer_tin), '') into saved_tax_id
    from public.user_profiles profile
   where profile.user_id = target_user_id;

  if coalesce(supplied_tax_id, saved_tax_id) is null then
    raise exception 'Enter your business TIN, BRN, or NIN to continue with a business purchase';
  end if;

  if supplied_tax_id is not null and supplied_tax_id is distinct from saved_tax_id then
    update public.user_profiles set buyer_tin = supplied_tax_id where user_id = target_user_id;
  end if;

  return coalesce(supplied_tax_id, saved_tax_id);
end;
$$;
revoke all on function public.resolve_checkout_buyer_tax_id(uuid, boolean, text) from public, anon, authenticated;

create or replace function public.apply_checkout_buyer_tax_id()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  new.buyer_tax_id := nullif(current_setting('app.checkout_buyer_tax_id', true), '');
  return new;
end;
$$;

create or replace function public.copy_checkout_buyer_tax_id_to_invoice()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if new.books_invoice_id is not null and new.buyer_tax_id is not null then
    update public.books_invoices
       set buyer_tax_id = new.buyer_tax_id
     where id = new.books_invoice_id
       and buyer_tax_id is distinct from new.buyer_tax_id;
  end if;
  return null;
end;
$$;

drop trigger if exists menu_orders_apply_checkout_buyer_tax_id on public.menu_orders;
create trigger menu_orders_apply_checkout_buyer_tax_id
  before insert on public.menu_orders
  for each row execute function public.apply_checkout_buyer_tax_id();
drop trigger if exists menu_orders_copy_checkout_buyer_tax_id on public.menu_orders;
create trigger menu_orders_copy_checkout_buyer_tax_id
  after insert or update of books_invoice_id, buyer_tax_id on public.menu_orders
  for each row execute function public.copy_checkout_buyer_tax_id_to_invoice();

drop trigger if exists hotel_bookings_apply_checkout_buyer_tax_id on public.hotel_bookings;
create trigger hotel_bookings_apply_checkout_buyer_tax_id
  before insert on public.hotel_bookings
  for each row execute function public.apply_checkout_buyer_tax_id();
drop trigger if exists hotel_bookings_copy_checkout_buyer_tax_id on public.hotel_bookings;
create trigger hotel_bookings_copy_checkout_buyer_tax_id
  after insert or update of books_invoice_id, buyer_tax_id on public.hotel_bookings
  for each row execute function public.copy_checkout_buyer_tax_id_to_invoice();

drop trigger if exists special_event_bookings_apply_checkout_buyer_tax_id on public.special_event_bookings;
create trigger special_event_bookings_apply_checkout_buyer_tax_id
  before insert on public.special_event_bookings
  for each row execute function public.apply_checkout_buyer_tax_id();
drop trigger if exists special_event_bookings_copy_checkout_buyer_tax_id on public.special_event_bookings;
create trigger special_event_bookings_copy_checkout_buyer_tax_id
  after insert or update of books_invoice_id, buyer_tax_id on public.special_event_bookings
  for each row execute function public.copy_checkout_buyer_tax_id_to_invoice();

create or replace function public.create_menu_order_for_tenant(
  target_organization_id uuid,
  target_user_id uuid,
  target_items jsonb,
  target_order_type text,
  target_payment_method text,
  target_tip_amount numeric,
  target_customer jsonb,
  target_cart_id uuid,
  target_idempotency_key uuid
)
returns table (
  order_id uuid,
  order_number text,
  currency text,
  subtotal numeric,
  tax_amount numeric,
  service_fee numeric,
  tip_amount numeric,
  points_discount numeric,
  total_amount numeric
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare item_count integer; tenant_item_count integer; tenant_count integer; existing_organization_id uuid; cart_organization_id uuid; resolved_buyer_tax_id text;
begin
  if not exists (
    select 1 from public.hotel_tenant_settings settings
     where settings.organization_id = target_organization_id and settings.is_active
  ) then raise exception 'Hotel domain is not configured'; end if;
  if target_cart_id is not null then
    select organization_id into cart_organization_id
      from public.menu_carts
     where id = target_cart_id and user_id = target_user_id and status = 'active';
    if cart_organization_id is distinct from target_organization_id then
      raise exception 'Saved menu cart belongs to a different hotel';
    end if;
  end if;
  if target_items is null or jsonb_typeof(target_items) is distinct from 'array'
     or jsonb_array_length(target_items) = 0 then
    raise exception 'Select at least one menu item';
  end if;
  if exists (
    select 1 from jsonb_array_elements(target_items) requested(value)
     where coalesce(requested.value->>'menuItemId', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ) then raise exception 'A menu item is invalid'; end if;

  select count(*), count(item.id), count(distinct item.organization_id)
    into item_count, tenant_item_count, tenant_count
    from jsonb_array_elements(target_items) requested(value)
    left join public.menu_items item
      on item.id = (requested.value->>'menuItemId')::uuid
     and item.is_published;
  if item_count <> tenant_item_count or tenant_count <> 1
     or not exists (
       select 1 from jsonb_array_elements(target_items) requested(value)
       join public.menu_items item on item.id = (requested.value->>'menuItemId')::uuid
       where item.is_published and item.organization_id = target_organization_id
     )
     or exists (
       select 1 from jsonb_array_elements(target_items) requested(value)
       left join public.menu_items item on item.id = (requested.value->>'menuItemId')::uuid and item.is_published
       where item.id is null or item.organization_id is distinct from target_organization_id
     ) then
    raise exception 'A selected menu item is unavailable for this hotel';
  end if;

  select organization_id into existing_organization_id
    from public.menu_orders
   where user_id = target_user_id and checkout_idempotency_key = target_idempotency_key;
  if found and existing_organization_id is distinct from target_organization_id then
    raise exception 'Checkout belongs to a different or unmapped hotel';
  end if;

  resolved_buyer_tax_id := public.resolve_checkout_buyer_tax_id(
    target_user_id,
    coalesce((target_customer->>'businessPurchase')::boolean, false),
    target_customer->>'buyerTaxId'
  );
  perform set_config('app.checkout_buyer_tax_id', coalesce(resolved_buyer_tax_id, ''), true);
  return query select * from public.create_menu_order(
    target_user_id, target_items, target_order_type, target_payment_method,
    target_tip_amount, target_customer, target_cart_id, target_idempotency_key
  );
  perform set_config('app.checkout_buyer_tax_id', '', true);
end;
$$;
revoke all on function public.create_menu_order_for_tenant(uuid, uuid, jsonb, text, text, numeric, jsonb, uuid, uuid) from public, anon, authenticated;
grant execute on function public.create_menu_order_for_tenant(uuid, uuid, jsonb, text, text, numeric, jsonb, uuid, uuid) to service_role;

create or replace function public.create_hotel_booking_for_tenant(
  target_organization_id uuid,
  target_room_id uuid,
  target_guest jsonb,
  target_check_in date,
  target_check_out date,
  target_guest_count integer,
  target_room_count integer,
  target_special_requests text,
  target_preferences jsonb,
  target_user_id uuid,
  target_idempotency_key uuid,
  target_access_token_hash text,
  target_fx_rates jsonb
)
returns table (
  booking_id uuid,
  confirmation_number text,
  currency_code char(3),
  nights integer,
  nightly_subtotal numeric,
  discount_amount numeric,
  taxable_subtotal numeric,
  vat_amount numeric,
  lht_amount numeric,
  total_amount numeric,
  hotel_classification smallint,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare existing_organization_id uuid; existing_room_id uuid; room_organization_id uuid; resolved_buyer_tax_id text;
begin
  if not exists (
    select 1 from public.hotel_tenant_settings settings
     where settings.organization_id = target_organization_id and settings.is_active
  ) then raise exception 'Hotel domain is not configured'; end if;

  select organization_id, room_id into existing_organization_id, existing_room_id
    from public.hotel_bookings where idempotency_key = target_idempotency_key;
  if found then
    if existing_organization_id is distinct from target_organization_id
       or existing_room_id is distinct from target_room_id then
      raise exception 'Reservation belongs to a different or unmapped hotel';
    end if;
  else
    select organization_id into room_organization_id
      from public.hotel_rooms where id = target_room_id and status = 'published';
    if room_organization_id is distinct from target_organization_id then
      raise exception 'This room is not available for this hotel';
    end if;
  end if;

  resolved_buyer_tax_id := public.resolve_checkout_buyer_tax_id(
    target_user_id,
    coalesce((target_guest->>'business_purchase')::boolean, false),
    target_guest->>'buyer_tax_id'
  );
  perform set_config('app.checkout_buyer_tax_id', coalesce(resolved_buyer_tax_id, ''), true);
  return query select * from public.create_hotel_booking(
    target_room_id, target_guest, target_check_in, target_check_out,
    target_guest_count, target_room_count, target_special_requests,
    target_preferences, target_user_id, target_idempotency_key,
    target_access_token_hash, target_fx_rates
  );
  perform set_config('app.checkout_buyer_tax_id', '', true);
end;
$$;
revoke all on function public.create_hotel_booking_for_tenant(uuid, uuid, jsonb, date, date, integer, integer, text, jsonb, uuid, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.create_hotel_booking_for_tenant(uuid, uuid, jsonb, date, date, integer, integer, text, jsonb, uuid, uuid, text, jsonb) to service_role;

drop function if exists public.create_special_event_booking_for_tenant(uuid, uuid, uuid, integer, text, text, text, text, text, uuid, uuid, text[], uuid, uuid);
create or replace function public.create_special_event_booking_for_tenant(
  target_organization_id uuid,
  target_user_id uuid,
  target_event_id uuid,
  target_quantity integer,
  guest_first_name text,
  guest_last_name text,
  guest_email text,
  guest_phone text,
  special_requests text,
  target_ticket_type_id uuid,
  target_idempotency_key uuid,
  target_attendee_names text[],
  target_invitation_id uuid,
  target_share_token uuid,
  target_business_purchase boolean default false,
  target_buyer_tax_id text default null
)
returns table (booking_id uuid, order_number text, total_amount numeric, currency text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare event_organization_id uuid; resolved_buyer_tax_id text;
begin
  if not exists (
    select 1 from public.hotel_tenant_settings settings
     where settings.organization_id = target_organization_id and settings.is_active
  ) then raise exception 'Hotel domain is not configured'; end if;
  select organization_id into event_organization_id
    from public.special_events where id = target_event_id;
  if event_organization_id is distinct from target_organization_id then
    raise exception 'This event is not available for this hotel';
  end if;

  resolved_buyer_tax_id := public.resolve_checkout_buyer_tax_id(target_user_id, target_business_purchase, target_buyer_tax_id);
  perform set_config('request.jwt.claim.sub', target_user_id::text, true);
  perform set_config('app.checkout_buyer_tax_id', coalesce(resolved_buyer_tax_id, ''), true);
  return query select * from public.create_special_event_booking(
    target_event_id, target_quantity, guest_first_name, guest_last_name,
    guest_email, guest_phone, special_requests, target_ticket_type_id,
    target_idempotency_key, target_attendee_names, target_invitation_id,
    target_share_token
  );
  perform set_config('app.checkout_buyer_tax_id', '', true);
end;
$$;
revoke all on function public.create_special_event_booking(uuid, integer, text, text, text, text, text, uuid, uuid, text[], uuid, uuid) from public, anon, authenticated;
revoke all on function public.create_special_event_booking_for_tenant(uuid, uuid, uuid, integer, text, text, text, text, text, uuid, uuid, text[], uuid, uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.create_special_event_booking_for_tenant(uuid, uuid, uuid, integer, text, text, text, text, text, uuid, uuid, text[], uuid, uuid, boolean, text) to service_role;

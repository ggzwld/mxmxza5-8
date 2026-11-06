begin;

create or replace function public.enqueue_hotel_loyalty_purchase()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  tenant_id uuid;
  member_id uuid;
  purchase_source_id uuid;
  amount_value numeric;
  currency_value text;
  source_created_at_value timestamptz;
  confirmed boolean := false;
  booking public.special_event_bookings%rowtype;
  menu_order public.menu_orders%rowtype;
  hotel_booking public.hotel_bookings%rowtype;
begin
  if tg_table_name = 'menu_payment_attempts' then
    if new.status <> 'completed' or new.transaction_id is null then return new; end if;
    select * into menu_order from public.menu_orders where id = new.order_id;
    if not found or menu_order.payment_status <> 'paid' or menu_order.flutterwave_transaction_id is distinct from new.transaction_id or menu_order.organization_id is null then return new; end if;
    tenant_id := menu_order.organization_id; member_id := menu_order.user_id; purchase_source_id := menu_order.id;
    amount_value := greatest(menu_order.subtotal, 0); currency_value := menu_order.currency; source_created_at_value := menu_order.created_at;
  elsif tg_table_name = 'hotel_payment_attempts' then
    if new.status <> 'completed' or new.transaction_id is null then return new; end if;
    select * into hotel_booking from public.hotel_bookings where id = new.booking_id;
    if not found or hotel_booking.payment_status <> 'paid' or hotel_booking.user_id is null then return new; end if;
    tenant_id := hotel_booking.organization_id; member_id := hotel_booking.user_id; purchase_source_id := hotel_booking.id;
    amount_value := greatest(hotel_booking.taxable_subtotal, 0); currency_value := trim(hotel_booking.currency_code); source_created_at_value := hotel_booking.created_at;
  elsif tg_table_name = 'menu_orders' then
    if new.payment_status <> 'paid' or (tg_op = 'UPDATE' and old.payment_status = 'paid') then return new; end if;
    if new.organization_id is null or new.payment_method not in ('card', 'mobile-money') or new.flutterwave_transaction_id is null then return new; end if;
    select exists (
      select 1 from public.menu_payment_attempts attempt
       where attempt.order_id = new.id
         and attempt.status = 'completed'
         and attempt.transaction_id = new.flutterwave_transaction_id
    ) into confirmed;
    if not confirmed then return new; end if;
    tenant_id := new.organization_id; member_id := new.user_id; purchase_source_id := new.id;
    amount_value := greatest(coalesce(new.subtotal, 0), 0); currency_value := new.currency; source_created_at_value := new.created_at;
  elsif tg_table_name = 'hotel_bookings' then
    if new.payment_status <> 'paid' or (tg_op = 'UPDATE' and old.payment_status = 'paid') or new.user_id is null then return new; end if;
    select exists (
      select 1 from public.hotel_payment_attempts attempt
       where attempt.booking_id = new.id
         and attempt.status = 'completed'
         and attempt.transaction_id is not null
    ) into confirmed;
    if not confirmed then return new; end if;
    tenant_id := new.organization_id; member_id := new.user_id; purchase_source_id := new.id;
    amount_value := greatest(new.taxable_subtotal, 0); currency_value := trim(new.currency_code); source_created_at_value := new.created_at;
  elsif tg_table_name = 'special_event_payments' then
    if new.status <> 'successful' or (tg_op = 'UPDATE' and old.status = 'successful') then return new; end if;
    select * into booking from public.special_event_bookings where id = new.booking_id;
    if not found or booking.user_id is null or booking.organization_id is null then return new; end if;
    tenant_id := booking.organization_id; member_id := booking.user_id; purchase_source_id := new.id;
    amount_value := greatest(coalesce(booking.subtotal, 0) - coalesce(booking.discount_amount, 0), 0); currency_value := new.currency; source_created_at_value := booking.created_at;
  else
    return new;
  end if;

  if not exists (
    select 1 from public.hotel_loyalty_programs
     where organization_id = tenant_id and program_enabled
  ) then return new; end if;

  insert into public.hotel_loyalty_award_queue (
    organization_id, user_id, source_type, source_id,
    eligible_amount, eligible_currency, source_created_at
  ) values (
    tenant_id,
    member_id,
    case
      when tg_table_name = 'special_event_payments' then 'special_event_payment'
      when tg_table_name = 'hotel_bookings' then 'hotel_booking'
      else 'menu_order'
    end,
    purchase_source_id,
    amount_value,
    upper(currency_value),
    source_created_at_value
  )
  on conflict (organization_id, source_type, source_id) do nothing;

  if auth.role() = 'service_role' then
    perform public.process_hotel_loyalty_awards();
  end if;
  return new;
end;
$$;

revoke all on function public.enqueue_hotel_loyalty_purchase() from public, anon, authenticated;
notify pgrst, 'reload schema';
commit;

begin;

create or replace function public.get_paid_invoice_loyalty_receipt(target_invoice_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  source_row record;
  account_row public.hotel_loyalty_accounts%rowtype;
  award_row public.hotel_loyalty_award_queue%rowtype;
  earned_points bigint := 0;
  award_status text := 'pending';
begin
  select source.source_type, source.source_id, source.user_id, source.organization_id, source.created_at
    into source_row
    from (
      select 'menu_order'::text as source_type, orders.id as source_id, orders.user_id, orders.organization_id, orders.created_at
        from public.menu_orders orders
       where orders.books_invoice_id = target_invoice_id
      union all
      select 'hotel_booking'::text, booking.id, booking.user_id, booking.organization_id, booking.created_at
        from public.hotel_bookings booking
       where booking.books_invoice_id = target_invoice_id
      union all
      select 'special_event_payment'::text, payment.id, booking.user_id, booking.organization_id, booking.created_at
        from public.special_event_payments payment
        join public.special_event_bookings booking on booking.id = payment.booking_id
       where payment.books_invoice_id = target_invoice_id
    ) source
   limit 1;

  if not found or source_row.user_id is null or source_row.organization_id is null then return null; end if;

  select * into account_row
    from public.hotel_loyalty_accounts account
   where account.organization_id = source_row.organization_id
     and account.user_id = source_row.user_id;
  if not found or not account_row.is_enrolled or account_row.enrolled_at > source_row.created_at then return null; end if;

  select * into award_row
    from public.hotel_loyalty_award_queue award
   where award.organization_id = source_row.organization_id
     and award.source_type = source_row.source_type
     and award.source_id = source_row.source_id;

  if award_row.status = 'posted' then
    select coalesce(sum(entry.points_delta), 0) into earned_points
      from public.hotel_loyalty_ledger_entries entry
     where entry.organization_id = source_row.organization_id
       and entry.user_id = source_row.user_id
       and entry.source_type = source_row.source_type
       and entry.source_id = source_row.source_id
       and entry.entry_type = 'purchase_earn';
  end if;

  return jsonb_build_object(
    'status', coalesce(award_row.status, 'pending'),
    'pointsEarned', greatest(earned_points, 0),
    'currentBalance', account_row.available_points
  );
end;
$$;
revoke all on function public.get_paid_invoice_loyalty_receipt(uuid) from public, anon, authenticated;
grant execute on function public.get_paid_invoice_loyalty_receipt(uuid) to service_role;

notify pgrst, 'reload schema';
commit;

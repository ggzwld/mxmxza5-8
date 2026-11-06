create or replace function public.notify_hotel_loyalty_purchase_activity()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  available_balance bigint;
  current_debt bigint;
  current_balance bigint;
begin
  if new.entry_type not in ('purchase_earn', 'purchase_reversal') then return new; end if;

  select account.available_points, account.debt_points
    into available_balance, current_debt
    from public.hotel_loyalty_accounts account
   where account.organization_id = new.organization_id and account.user_id = new.user_id;

  if new.points_delta > 0 then
    current_balance := coalesce(available_balance, 0) + greatest(new.points_delta - coalesce(current_debt, 0), 0);
  else
    current_balance := coalesce(available_balance, 0) - least(coalesce(available_balance, 0), abs(new.points_delta));
  end if;

  insert into public.notifications (user_id, type, message, action_url)
  values (
    new.user_id,
    'hotel_loyalty_activity',
    case when new.points_delta > 0 then 'You earned ' else 'A purchase refund reversed ' end || abs(new.points_delta)::text ||
      ' hotel loyalty points. Your current balance is ' || coalesce(current_balance, 0)::text || '.',
    '/profile?tab=hotel-rewards'
  );

  insert into public.notifications (user_id, type, message, action_url)
  select distinct membership.user_id,
    'hotel_loyalty_activity',
    'Hotel loyalty activity: ' || abs(new.points_delta)::text || ' points ' ||
      case when new.points_delta > 0 then 'earned' else 'reversed' end || ' for a member purchase.',
    '/management?tab=rewards'
  from public.books_memberships membership
  where membership.organization_id = new.organization_id
    and membership.role in ('owner', 'admin');
  return new;
end;
$$;
revoke all on function public.notify_hotel_loyalty_purchase_activity() from public, anon, authenticated;
notify pgrst, 'reload schema';

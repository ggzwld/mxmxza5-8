begin;

create or replace function public.get_hotel_loyalty_activity(target_organization_id uuid)
returns table (
  created_at timestamptz,
  member_name text,
  entry_type text,
  points_delta bigint,
  available_points bigint,
  description text
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if not exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = target_organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin')
  ) then raise exception 'Not authorized to view this hotel’s loyalty activity'; end if;

  return query
  select entry.created_at,
    coalesce(nullif(trim(concat_ws(' ', profile.first_name, profile.last_name)), ''), 'Hotel member'),
    entry.entry_type,
    entry.points_delta,
    coalesce(account.available_points, 0),
    entry.description
  from public.hotel_loyalty_ledger_entries entry
  left join public.user_profiles profile on profile.user_id = entry.user_id
  left join public.hotel_loyalty_accounts account
    on account.organization_id = entry.organization_id and account.user_id = entry.user_id
  where entry.organization_id = target_organization_id
  order by entry.created_at desc
  limit 100;
end;
$$;
revoke all on function public.get_hotel_loyalty_activity(uuid) from public, anon;
grant execute on function public.get_hotel_loyalty_activity(uuid) to authenticated;

notify pgrst, 'reload schema';
commit;

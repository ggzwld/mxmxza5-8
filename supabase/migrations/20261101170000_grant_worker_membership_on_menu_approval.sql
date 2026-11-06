drop function if exists public.approve_menu_access(uuid);

create or replace function public.approve_menu_access(target_user_id uuid, target_organization_id uuid)
returns void
language plpgsql
security definer
volatile
set search_path = public
as $$
begin
  if not public.is_manager() then
    raise exception 'Only managers can approve menu access';
  end if;

  if not exists (
    select 1
      from public.books_memberships membership
     where membership.organization_id = target_organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin')
  ) then
    raise exception 'Manager is not an owner or admin of this hotel';
  end if;

  update public.user_profiles
  set
    menu_access_approved = true,
    updated_at = now()
  where user_id = target_user_id
    and role = 'worker'
    and menu_access_role in ('chef', 'food_beverage_manager');

  if not found then
    raise exception 'Worker is not an eligible culinary access request';
  end if;

  insert into public.books_memberships (organization_id, user_id, role)
  values (target_organization_id, target_user_id, 'worker')
  on conflict (organization_id, user_id) do nothing;
end;
$$;

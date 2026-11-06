begin;

alter table public.user_profiles
  add column if not exists hotel_organization_id uuid references public.books_organizations(id) on delete set null;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
volatile
set search_path = public
as $$
DECLARE
  requested_role text;
BEGIN
  requested_role := CASE
    WHEN new.raw_user_meta_data ->> 'role' IN ('guest', 'manager', 'worker')
    THEN new.raw_user_meta_data ->> 'role'
    ELSE 'guest'
  END;

  INSERT INTO public.user_profiles (
    user_id,
    email,
    role,
    first_name,
    last_name,
    phone,
    service_type,
    service_category,
    menu_access_role,
    menu_access_approved
  )
  VALUES (
    new.id,
    COALESCE(new.email, ''),
    requested_role,
    COALESCE(new.raw_user_meta_data ->> 'first_name', ''),
    COALESCE(new.raw_user_meta_data ->> 'last_name', ''),
    NULLIF(new.raw_user_meta_data ->> 'phone', ''),
    NULLIF(new.raw_user_meta_data ->> 'service_type', ''),
    NULLIF(new.raw_user_meta_data ->> 'service_category', ''),
    COALESCE(new.raw_user_meta_data ->> 'menu_access_role', 'none'),
    false
  )
  ON CONFLICT (user_id) DO UPDATE SET
    email = EXCLUDED.email,
    first_name = CASE
      WHEN public.user_profiles.first_name IS NULL OR public.user_profiles.first_name = ''
      THEN EXCLUDED.first_name
      ELSE public.user_profiles.first_name
    END,
    last_name = CASE
      WHEN public.user_profiles.last_name IS NULL OR public.user_profiles.last_name = ''
      THEN EXCLUDED.last_name
      ELSE public.user_profiles.last_name
    END,
    phone = COALESCE(public.user_profiles.phone, EXCLUDED.phone),
    role = CASE
      WHEN public.user_profiles.role = 'guest' AND EXCLUDED.role <> 'guest'
      THEN EXCLUDED.role
      ELSE public.user_profiles.role
    END,
    service_type = COALESCE(public.user_profiles.service_type, EXCLUDED.service_type),
    service_category = COALESCE(public.user_profiles.service_category, EXCLUDED.service_category),
    menu_access_role = COALESCE(public.user_profiles.menu_access_role, EXCLUDED.menu_access_role);

  RETURN new;
END;
$$;

create or replace function public.protect_worker_hotel_and_menu_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null
     and old.user_id = auth.uid()
     and (
       new.hotel_organization_id is distinct from old.hotel_organization_id
       or new.menu_access_approved is distinct from old.menu_access_approved
     ) then
    raise exception 'Hotel affiliation and menu access approval can only be changed by a hotel manager';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_worker_hotel_and_menu_approval on public.user_profiles;
create trigger protect_worker_hotel_and_menu_approval
  before update on public.user_profiles
  for each row execute function public.protect_worker_hotel_and_menu_approval();

create or replace function public.can_manage_hotel_menu(target_organization_id uuid)
returns boolean
language sql
security definer
stable
set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = target_organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin', 'manager')
  ) or exists (
    select 1
      from public.user_profiles profile
     where profile.user_id = auth.uid()
       and profile.role = 'worker'
       and profile.hotel_organization_id = target_organization_id
       and profile.menu_access_approved
       and profile.menu_access_role in ('chef', 'food_beverage_manager')
  );
$$;

create or replace function public.bind_worker_to_hotel(target_organization_id uuid, target_user_id uuid)
returns void
language plpgsql
security definer
volatile
set search_path = public
as $$
begin
  update public.user_profiles
     set hotel_organization_id = target_organization_id,
         updated_at = now()
   where user_id = target_user_id
     and role = 'worker'
     and hotel_organization_id is null;
end;
$$;

revoke all on function public.bind_worker_to_hotel(uuid, uuid) from public, anon, authenticated;
grant execute on function public.bind_worker_to_hotel(uuid, uuid) to service_role;

drop function if exists public.approve_menu_access(uuid, uuid);

create or replace function public.approve_menu_access(target_user_id uuid)
returns void
language plpgsql
security definer
volatile
set search_path = public
as $$
declare
  worker_hotel_id uuid;
begin
  if not public.is_manager() then
    raise exception 'Only managers can approve menu access';
  end if;

  select profile.hotel_organization_id into worker_hotel_id
    from public.user_profiles profile
   where profile.user_id = target_user_id
     and profile.role = 'worker'
     and profile.menu_access_role in ('chef', 'food_beverage_manager');

  if worker_hotel_id is null then
    raise exception 'Worker is not an eligible culinary access request';
  end if;

  if not exists (
    select 1
      from public.books_memberships membership
     where membership.organization_id = worker_hotel_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin')
  ) then
    raise exception 'Only the owner or an admin of this hotel can approve its menu access requests';
  end if;

  update public.user_profiles
  set menu_access_approved = true,
      updated_at = now()
  where user_id = target_user_id;
end;
$$;

notify pgrst, 'reload schema';

commit;

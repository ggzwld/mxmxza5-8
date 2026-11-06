begin;

create table if not exists public.platform_admins (
  user_id uuid primary key references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table if not exists public.platform_admin_bootstrap_emails (
  email text primary key,
  claimed_user_id uuid unique references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  check (email = lower(trim(email)))
);

insert into public.platform_admin_bootstrap_emails (email)
values ('empowise1@gmail.com')
on conflict (email) do nothing;

alter table public.platform_admins enable row level security;
alter table public.platform_admin_bootstrap_emails enable row level security;
revoke all on public.platform_admins, public.platform_admin_bootstrap_emails from public, anon, authenticated;
grant select, insert, update, delete on public.platform_admins, public.platform_admin_bootstrap_emails to service_role;

create or replace function public.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
  select auth.uid() is not null and exists (
    select 1 from public.platform_admins admin
     where admin.user_id = auth.uid()
  );
$$;
revoke all on function public.is_platform_admin() from public, anon;
grant execute on function public.is_platform_admin() to authenticated;

create or replace function public.claim_platform_admin_bootstrap()
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare current_email text;
begin
  if auth.uid() is null then
    return false;
  end if;

  select lower(user_row.email)
    into current_email
    from auth.users user_row
   where user_row.id = auth.uid()
     and user_row.email_confirmed_at is not null;

  if current_email is null then
    return false;
  end if;

  update public.platform_admin_bootstrap_emails bootstrap
     set claimed_user_id = auth.uid(),
         claimed_at = coalesce(bootstrap.claimed_at, now())
   where bootstrap.email = current_email
     and (bootstrap.claimed_user_id is null or bootstrap.claimed_user_id = auth.uid());

  if not found then
    return public.is_platform_admin();
  end if;

  insert into public.platform_admins (user_id)
  values (auth.uid())
  on conflict (user_id) do nothing;

  return true;
end;
$$;
revoke all on function public.claim_platform_admin_bootstrap() from public, anon;
grant execute on function public.claim_platform_admin_bootstrap() to authenticated;

alter table public.hotel_tenant_domains
  add column if not exists verification_status text,
  add column if not exists verification_method text,
  add column if not exists verification_challenge_hash text,
  add column if not exists verification_expires_at timestamptz,
  add column if not exists verified_at timestamptz,
  add column if not exists verified_by uuid references auth.users(id) on delete set null,
  add column if not exists created_by uuid references auth.users(id) on delete set null;

update public.hotel_tenant_domains
   set verification_status = 'legacy',
       verification_method = 'legacy'
 where verification_status is null;

alter table public.hotel_tenant_domains
  alter column verification_status set default 'pending',
  alter column verification_status set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.hotel_tenant_domains'::regclass
       and conname = 'hotel_tenant_domains_verification_status_check'
  ) then
    alter table public.hotel_tenant_domains
      add constraint hotel_tenant_domains_verification_status_check
      check (verification_status in ('pending', 'verified', 'legacy', 'rejected'));
  end if;
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.hotel_tenant_domains'::regclass
       and conname = 'hotel_tenant_domains_verification_method_check'
  ) then
    alter table public.hotel_tenant_domains
      add constraint hotel_tenant_domains_verification_method_check
      check (verification_method is null or verification_method in ('dns_txt', 'vercel_project', 'legacy'));
  end if;
end;
$$;

create index if not exists hotel_tenant_domains_org_status_idx
  on public.hotel_tenant_domains (organization_id, verification_status);

create or replace function public.resolve_hotel_tenant(target_hostname text)
returns table (
  organization_id uuid,
  name text,
  domain text,
  logo_url text,
  primary_color text,
  accent_color text
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select settings.organization_id,
         settings.display_name,
         domains.domain,
         settings.logo_url,
         settings.primary_color,
         settings.accent_color
    from public.hotel_tenant_domains domains
    join public.hotel_tenant_settings settings using (organization_id)
   where domains.domain = lower(trim(target_hostname))
     and domains.verification_status in ('verified', 'legacy')
     and settings.is_active;
$$;
revoke all on function public.resolve_hotel_tenant(text) from public, anon, authenticated;
grant execute on function public.resolve_hotel_tenant(text) to service_role;

create or replace function public.platform_admin_onboard_hotel(
  target_admin_user_id uuid,
  target_organization_id uuid,
  target_organization_name text,
  target_owner_email text,
  target_country_code text,
  target_base_currency text,
  target_display_name text,
  target_booking_title text,
  target_booking_subtitle text,
  target_logo_url text,
  target_primary_color text,
  target_accent_color text,
  target_domain text,
  target_challenge_hash text,
  target_verification_method text
)
returns table (
  organization_id uuid,
  domain text,
  verification_status text
)
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
#variable_conflict use_column
declare
  selected_organization_id uuid := target_organization_id;
  owner_user_id uuid;
  existing_domain_organization_id uuid;
  existing_verification_status text;
begin
  if not exists (select 1 from public.platform_admins admin where admin.user_id = target_admin_user_id) then
    raise exception 'Platform administrator access is required';
  end if;
  if target_domain is null or length(target_domain) > 253
     or target_domain <> lower(trim(target_domain))
     or target_domain !~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$' then
    raise exception 'Enter a valid lowercase hostname';
  end if;
  if target_challenge_hash is null or length(target_challenge_hash) <> 64
     or target_challenge_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'Domain verification challenge is invalid';
  end if;
  if target_verification_method is null or target_verification_method not in ('dns_txt', 'vercel_project') then
    raise exception 'Domain verification method is invalid';
  end if;
  if target_domain like '%.vercel.app' and target_verification_method <> 'vercel_project' then
    raise exception 'Vercel hostnames require platform-admin assignment review';
  end if;
  if target_domain not like '%.vercel.app' and target_verification_method = 'vercel_project' then
    raise exception 'Vercel assignment review is only valid for Vercel hostnames';
  end if;
  if nullif(trim(target_display_name), '') is null
     or nullif(trim(target_booking_title), '') is null
     or nullif(trim(target_booking_subtitle), '') is null then
    raise exception 'Complete the hotel display and booking details';
  end if;
  if nullif(trim(target_primary_color), '') is not null
     and trim(target_primary_color) !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception 'Primary color must use #RRGGBB format';
  end if;
  if nullif(trim(target_accent_color), '') is not null
     and trim(target_accent_color) !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception 'Accent color must use #RRGGBB format';
  end if;

  if selected_organization_id is null then
    if nullif(trim(target_organization_name), '') is null
       or nullif(trim(target_owner_email), '') is null
       or target_country_code is null or target_country_code !~ '^[A-Za-z]{2}$'
       or target_base_currency is null or target_base_currency !~ '^[A-Za-z]{3}$' then
      raise exception 'Complete the organization name, verified owner email, country, and currency';
    end if;
    if exists (
      select 1 from public.books_organizations organization
       where lower(trim(organization.name)) = lower(trim(target_organization_name))
    ) then
      raise exception 'An organization with that name already exists; select it instead';
    end if;

    select user_row.id into owner_user_id
      from auth.users user_row
      join public.user_profiles profile
        on profile.user_id = user_row.id and profile.role = 'manager'
     where lower(user_row.email) = lower(trim(target_owner_email))
       and user_row.email_confirmed_at is not null
     limit 1;
    if owner_user_id is null then
      raise exception 'The organization owner must have a confirmed Supabase account with a manager profile';
    end if;

    insert into public.books_organizations (name, country_code, base_currency, owner_id)
    values (trim(target_organization_name), upper(target_country_code), upper(target_base_currency), owner_user_id)
    returning id into selected_organization_id;

    -- The existing organization insert trigger can substitute the owner's profile organization name.
    update public.books_organizations
       set name = trim(target_organization_name)
     where id = selected_organization_id;

    insert into public.books_accounts (organization_id, code, name, type, is_system) values
      (selected_organization_id, '1000', 'Cash and bank', 'asset', true),
      (selected_organization_id, '1100', 'Accounts receivable', 'asset', true),
      (selected_organization_id, '2000', 'Accounts payable', 'liability', true),
      (selected_organization_id, '3000', 'Owner equity', 'equity', true),
      (selected_organization_id, '4000', 'Sales revenue', 'income', true),
      (selected_organization_id, '5000', 'Operating expenses', 'expense', true);
  else
    select organization.owner_id into owner_user_id
      from public.books_organizations organization
     where organization.id = selected_organization_id;
    if not found then
      raise exception 'Select an existing organization';
    end if;
    if not exists (
      select 1 from public.user_profiles profile
       where profile.user_id = owner_user_id and profile.role = 'manager'
    ) then
      raise exception 'The selected organization owner must have a manager profile';
    end if;
  end if;

  insert into public.books_memberships (organization_id, user_id, role)
  values (selected_organization_id, owner_user_id, 'owner')
  on conflict (organization_id, user_id) do update set role = 'owner';

  insert into public.hotel_tenant_settings (
    organization_id, display_name, logo_url, primary_color, accent_color,
    booking_title, booking_subtitle, is_active
  ) values (
    selected_organization_id, trim(target_display_name), nullif(trim(target_logo_url), ''),
    nullif(trim(target_primary_color), ''), nullif(trim(target_accent_color), ''),
    trim(target_booking_title), trim(target_booking_subtitle), false
  )
  on conflict (organization_id) do update
    set display_name = excluded.display_name,
        logo_url = excluded.logo_url,
        primary_color = excluded.primary_color,
        accent_color = excluded.accent_color,
        booking_title = excluded.booking_title,
        booking_subtitle = excluded.booking_subtitle,
        updated_at = now();

  select tenant_domain.organization_id, tenant_domain.verification_status
    into existing_domain_organization_id, existing_verification_status
    from public.hotel_tenant_domains tenant_domain
   where tenant_domain.domain = target_domain
   for update;

  if found then
    if existing_domain_organization_id is distinct from selected_organization_id then
      raise exception 'This hostname is already assigned to another hotel';
    end if;
    if existing_verification_status = 'legacy' then
      update public.hotel_tenant_domains
         set verification_method = target_verification_method,
             verification_challenge_hash = target_challenge_hash,
             verification_expires_at = now() + interval '24 hours',
             created_by = target_admin_user_id
       where hotel_tenant_domains.domain = target_domain;
    elsif existing_verification_status <> 'verified' then
      update public.hotel_tenant_domains
         set verification_status = 'pending',
             verification_method = target_verification_method,
             verification_challenge_hash = target_challenge_hash,
             verification_expires_at = now() + interval '24 hours',
             verified_at = null,
             verified_by = null,
             created_by = target_admin_user_id
       where hotel_tenant_domains.domain = target_domain;
      existing_verification_status := 'pending';
    end if;
  else
    insert into public.hotel_tenant_domains (
      domain, organization_id, verification_status, verification_method,
      verification_challenge_hash, verification_expires_at, created_by
    ) values (
      target_domain, selected_organization_id, 'pending', target_verification_method,
      target_challenge_hash, now() + interval '24 hours', target_admin_user_id
    );
  end if;

  return query
  select selected_organization_id, target_domain,
         coalesce(existing_verification_status, 'pending');
end;
$$;
revoke all on function public.platform_admin_onboard_hotel(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.platform_admin_onboard_hotel(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text,text) to service_role;

create or replace function public.platform_admin_record_domain_verification(
  target_admin_user_id uuid,
  target_domain text,
  target_organization_id uuid,
  target_verification_method text
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  update public.hotel_tenant_domains
     set verification_status = 'verified',
         verification_method = target_verification_method,
         verification_challenge_hash = null,
         verification_expires_at = null,
         verified_at = now(),
         verified_by = target_admin_user_id
   where domain = target_domain
     and organization_id = target_organization_id
     and verification_status in ('pending', 'legacy')
     and verification_expires_at > now()
     and target_verification_method in ('dns_txt', 'vercel_project')
     and exists (select 1 from public.platform_admins admin where admin.user_id = target_admin_user_id);
  return found;
end;
$$;
revoke all on function public.platform_admin_record_domain_verification(uuid,text,uuid,text) from public, anon, authenticated;
grant execute on function public.platform_admin_record_domain_verification(uuid,text,uuid,text) to service_role;

create or replace function public.platform_admin_activate_hotel(target_admin_user_id uuid, target_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not exists (select 1 from public.platform_admins admin where admin.user_id = target_admin_user_id) then
    raise exception 'Platform administrator access is required';
  end if;
  if not exists (
    select 1 from public.hotel_tenant_domains tenant_domain
     where tenant_domain.organization_id = target_organization_id
       and tenant_domain.verification_status = 'verified'
  ) then
    raise exception 'Verify at least one hotel hostname before activation';
  end if;

  update public.hotel_tenant_settings
     set is_active = true,
         updated_at = now()
   where organization_id = target_organization_id;
  if not found then
    raise exception 'Hotel tenant settings were not found';
  end if;
end;
$$;
revoke all on function public.platform_admin_activate_hotel(uuid,uuid) from public, anon, authenticated;
grant execute on function public.platform_admin_activate_hotel(uuid,uuid) to service_role;

notify pgrst, 'reload schema';
commit;

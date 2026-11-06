begin;

create or replace function public.get_or_create_worker_books_organization()
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  worker_organization_id uuid;
  worker_profile record;
  registered_business_name text;
  worker_entity_type text;
begin
  if auth.uid() is null then raise exception 'Sign in to access Books'; end if;

  perform pg_advisory_xact_lock(hashtextextended('worker-books:' || auth.uid()::text, 0));
  select workspace.organization_id into worker_organization_id
    from public.books_worker_workspaces workspace
   where workspace.user_id = auth.uid();
  if worker_organization_id is not null then return worker_organization_id; end if;

  select profile.role, profile.first_name, profile.last_name, profile.buyer_business_name, profile.tax_entity_type
    into worker_profile
    from public.user_profiles profile
   where profile.user_id = auth.uid();
  if worker_profile.role is distinct from 'worker' then
    raise exception 'Worker Books are available to worker accounts';
  end if;

  registered_business_name := nullif(trim(worker_profile.buyer_business_name), '');
  worker_entity_type := coalesce(
    worker_profile.tax_entity_type,
    case when registered_business_name is null then 'sole_proprietor' end
  );

  insert into public.books_organizations (name, owner_id, tax_entity_type)
  values (
    coalesce(
      registered_business_name,
      nullif(trim(concat_ws(' ', worker_profile.first_name, worker_profile.last_name)), ''),
      'Worker Books'
    ),
    auth.uid(),
    worker_entity_type
  )
  returning id into worker_organization_id;

  insert into public.books_memberships (organization_id, user_id, role)
  values (worker_organization_id, auth.uid(), 'owner');

  insert into public.books_accounts (organization_id, code, name, type, is_system) values
    (worker_organization_id, '1000', 'Cash and bank', 'asset', true),
    (worker_organization_id, '1100', 'Accounts receivable', 'asset', true),
    (worker_organization_id, '2000', 'Accounts payable', 'liability', true),
    (worker_organization_id, '3000', 'Owner equity', 'equity', true),
    (worker_organization_id, '4000', 'Sales revenue', 'income', true),
    (worker_organization_id, '5000', 'Operating expenses', 'expense', true)
  on conflict (organization_id, code) do nothing;

  perform public.seed_books_tax_rates(worker_organization_id);

  insert into public.books_worker_workspaces (user_id, organization_id)
  values (auth.uid(), worker_organization_id);

  update public.user_profiles profile
     set tax_entity_type = worker_entity_type
   where profile.user_id = auth.uid()
     and profile.tax_entity_type is distinct from worker_entity_type;

  return worker_organization_id;
end;
$$;
revoke all on function public.get_or_create_worker_books_organization() from public, anon;
grant execute on function public.get_or_create_worker_books_organization() to authenticated;

create or replace function public.sync_worker_books_organization_name()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.buyer_business_name is distinct from old.buyer_business_name
     or new.first_name is distinct from old.first_name
     or new.last_name is distinct from old.last_name then
    update public.books_organizations organization
       set name = coalesce(
         nullif(trim(new.buyer_business_name), ''),
         nullif(trim(concat_ws(' ', new.first_name, new.last_name)), ''),
         organization.name
       )
      from public.books_worker_workspaces workspace
     where workspace.organization_id = organization.id
       and workspace.user_id = new.user_id;
  end if;

  if new.tax_entity_type is distinct from old.tax_entity_type then
    update public.books_organizations organization
       set tax_entity_type = new.tax_entity_type,
           income_tax_regime_confirmed_at = null
      from public.books_worker_workspaces workspace
     where workspace.organization_id = organization.id
       and workspace.user_id = new.user_id
       and organization.tax_entity_type is distinct from new.tax_entity_type;
  end if;
  return new;
end;
$$;

drop trigger if exists sync_worker_books_organization_name on public.user_profiles;
create trigger sync_worker_books_organization_name
after update of buyer_business_name, first_name, last_name, tax_entity_type
on public.user_profiles
for each row
execute function public.sync_worker_books_organization_name();

create or replace function public.sync_worker_profile_tax_entity_type()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.user_profiles profile
     set tax_entity_type = new.tax_entity_type
    from public.books_worker_workspaces workspace
   where workspace.organization_id = new.id
     and profile.user_id = workspace.user_id
     and profile.tax_entity_type is distinct from new.tax_entity_type;
  return new;
end;
$$;

drop trigger if exists sync_worker_profile_tax_entity_type on public.books_organizations;
create trigger sync_worker_profile_tax_entity_type
after update of tax_entity_type
on public.books_organizations
for each row
execute function public.sync_worker_profile_tax_entity_type();

revoke all on function public.sync_worker_books_organization_name() from public;
revoke all on function public.sync_worker_profile_tax_entity_type() from public;

update public.books_organizations organization
   set name = coalesce(
     nullif(trim(profile.buyer_business_name), ''),
     nullif(trim(concat_ws(' ', profile.first_name, profile.last_name)), ''),
     organization.name
   )
  from public.books_worker_workspaces workspace
  join public.user_profiles profile on profile.user_id = workspace.user_id
 where organization.id = workspace.organization_id;

update public.books_organizations organization
   set tax_entity_type = profile.tax_entity_type
  from public.books_worker_workspaces workspace
  join public.user_profiles profile on profile.user_id = workspace.user_id
 where organization.id = workspace.organization_id
   and organization.tax_entity_type is null
   and profile.tax_entity_type is not null;

update public.user_profiles profile
   set tax_entity_type = organization.tax_entity_type
  from public.books_worker_workspaces workspace
  join public.books_organizations organization on organization.id = workspace.organization_id
 where profile.user_id = workspace.user_id
   and profile.tax_entity_type is null
   and organization.tax_entity_type is not null;

commit;

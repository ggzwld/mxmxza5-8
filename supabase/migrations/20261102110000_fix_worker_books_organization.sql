drop function if exists public.ensure_worker_books_organization(uuid);
drop function if exists public.record_worker_task_payment(uuid, text, text);

create or replace function public.ensure_worker_books_organization(target_user_id uuid, org_currency char(3) default null)
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
  perform pg_advisory_xact_lock(hashtextextended('worker-books:' || target_user_id::text, 0));
  select workspace.organization_id into worker_organization_id
    from public.books_worker_workspaces workspace
   where workspace.user_id = target_user_id;
  if worker_organization_id is not null then
    return worker_organization_id;
  end if;

  select profile.role, profile.first_name, profile.last_name, profile.buyer_business_name, profile.tax_entity_type
    into worker_profile
    from public.user_profiles profile
   where profile.user_id = target_user_id;
  if worker_profile.role is distinct from 'worker' then
    raise exception 'Worker Books are available to worker accounts';
  end if;

  registered_business_name := nullif(trim(worker_profile.buyer_business_name), '');
  worker_entity_type := coalesce(
    worker_profile.tax_entity_type,
    case when registered_business_name is null then 'sole_proprietor' end
  );

  insert into public.books_organizations (name, owner_id, tax_entity_type, base_currency)
  values (
    coalesce(
      registered_business_name,
      nullif(trim(concat_ws(' ', worker_profile.first_name, worker_profile.last_name)), ''),
      'Worker Books'
    ),
    target_user_id,
    worker_entity_type,
    coalesce(org_currency, 'UGX')
  )
  returning id into worker_organization_id;

  insert into public.books_memberships (organization_id, user_id, role)
  values (worker_organization_id, target_user_id, 'owner');

  insert into public.books_accounts (organization_id, code, name, type, is_system) values
    (worker_organization_id, '1000', 'Cash and bank', 'asset', true),
    (worker_organization_id, '1100', 'Accounts receivable', 'asset', true),
    (worker_organization_id, '2000', 'Accounts payable', 'liability', true),
    (worker_organization_id, '2100', 'VAT payable', 'liability', true),
    (worker_organization_id, '3000', 'Owner equity', 'equity', true),
    (worker_organization_id, '4000', 'Sales revenue', 'income', true),
    (worker_organization_id, '5000', 'Operating expenses', 'expense', true)
  on conflict (organization_id, code) do nothing;

  perform public.seed_books_tax_rates(worker_organization_id);

  insert into public.books_worker_workspaces (user_id, organization_id)
  values (target_user_id, worker_organization_id);

  update public.user_profiles profile
     set tax_entity_type = worker_entity_type
   where profile.user_id = target_user_id
     and profile.tax_entity_type is distinct from worker_entity_type;

  return worker_organization_id;
end;
$$;
revoke all on function public.ensure_worker_books_organization(uuid, char(3)) from public, anon, authenticated;

create or replace function public.get_or_create_worker_books_organization()
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in to access Books'; end if;
  return public.ensure_worker_books_organization(auth.uid());
end;
$$;
revoke all on function public.get_or_create_worker_books_organization() from public, anon;
grant execute on function public.get_or_create_worker_books_organization() to authenticated;

notify pgrst, 'reload schema';

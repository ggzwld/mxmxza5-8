begin;

create table if not exists public.books_worker_workspaces (
  user_id uuid primary key references auth.users(id) on delete cascade,
  organization_id uuid not null unique references public.books_organizations(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.books_worker_workspaces enable row level security;
revoke all on public.books_worker_workspaces from public, anon, authenticated;

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
begin
  if auth.uid() is null then raise exception 'Sign in to access Books'; end if;

  perform pg_advisory_xact_lock(hashtextextended('worker-books:' || auth.uid()::text, 0));
  select workspace.organization_id into worker_organization_id
    from public.books_worker_workspaces workspace
   where workspace.user_id = auth.uid();
  if worker_organization_id is not null then return worker_organization_id; end if;

  select profile.role, profile.first_name, profile.last_name, profile.buyer_business_name
    into worker_profile
    from public.user_profiles profile
   where profile.user_id = auth.uid();
  if worker_profile.role is distinct from 'worker' then
    raise exception 'Worker Books are available to worker accounts';
  end if;

  registered_business_name := nullif(trim(worker_profile.buyer_business_name), '');

  insert into public.books_organizations (name, owner_id, tax_entity_type)
  values (
    coalesce(
      registered_business_name,
      nullif(trim(concat_ws(' ', worker_profile.first_name, worker_profile.last_name)), ''),
      'Worker Books'
    ),
    auth.uid(),
    case when registered_business_name is null then 'sole_proprietor' end
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

  return worker_organization_id;
end;
$$;
revoke all on function public.get_or_create_worker_books_organization() from public, anon;
grant execute on function public.get_or_create_worker_books_organization() to authenticated;

notify pgrst, 'reload schema';
commit;

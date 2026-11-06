begin;

create table if not exists public.books_personal_workspaces (
  user_id uuid primary key references auth.users(id) on delete cascade,
  organization_id uuid not null unique references public.books_organizations(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.books_personal_workspaces enable row level security;
revoke all on public.books_personal_workspaces from public, anon, authenticated;
grant select on public.books_personal_workspaces to authenticated;
drop policy if exists books_personal_workspaces_owner_read on public.books_personal_workspaces;
create policy books_personal_workspaces_owner_read on public.books_personal_workspaces
  for select to authenticated using (user_id = auth.uid());

alter table public.books_expenses
  add column if not exists purchase_source_type text,
  add column if not exists purchase_source_id uuid;

alter table public.books_expenses
  drop constraint if exists books_expenses_payment_status_check;
alter table public.books_expenses
  add constraint books_expenses_payment_status_check
  check (payment_status in ('paid', 'unpaid', 'refunded'));

create unique index if not exists books_expenses_purchase_source_uidx
  on public.books_expenses (organization_id, purchase_source_type, purchase_source_id)
  where purchase_source_type is not null and purchase_source_id is not null;

create or replace function public.ensure_personal_books_workspace(target_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  personal_organization_id uuid;
begin
  if target_user_id is null then return null; end if;
  if not exists (select 1 from auth.users auth_user where auth_user.id = target_user_id and not auth_user.is_anonymous) then
    return null;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('personal-books:' || target_user_id::text, 0));
  select workspace.organization_id into personal_organization_id
    from public.books_personal_workspaces workspace
   where workspace.user_id = target_user_id;
  if personal_organization_id is not null then return personal_organization_id; end if;

  insert into public.books_organizations (name, owner_id)
  values ('Personal Books', target_user_id)
  returning id into personal_organization_id;

  insert into public.books_personal_workspaces (user_id, organization_id)
  values (target_user_id, personal_organization_id);

  insert into public.books_memberships (organization_id, user_id, role)
  values (personal_organization_id, target_user_id, 'owner');

  insert into public.books_accounts (organization_id, code, name, type, is_system)
  values
    (personal_organization_id, '1000', 'Cash and bank', 'asset', true),
    (personal_organization_id, '1100', 'Accounts receivable', 'asset', true),
    (personal_organization_id, '2000', 'Accounts payable', 'liability', true),
    (personal_organization_id, '3000', 'Personal funds', 'equity', true),
    (personal_organization_id, '4000', 'Sales revenue', 'income', true),
    (personal_organization_id, '5000', 'Personal and household expenses', 'expense', true)
  on conflict (organization_id, code) do nothing;

  return personal_organization_id;
end;
$$;
revoke all on function public.ensure_personal_books_workspace(uuid) from public, anon, authenticated;
grant execute on function public.ensure_personal_books_workspace(uuid) to service_role;

create or replace function public.get_or_create_personal_books_organization()
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare personal_organization_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to access personal Books'; end if;
  personal_organization_id := public.ensure_personal_books_workspace(auth.uid());
  if personal_organization_id is null then raise exception 'Personal Books are available to registered accounts'; end if;
  return personal_organization_id;
end;
$$;
revoke all on function public.get_or_create_personal_books_organization() from public, anon;
grant execute on function public.get_or_create_personal_books_organization() to authenticated;

create or replace function public.get_or_create_books_organization()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare organization_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to access Books'; end if;
  select membership.organization_id into organization_id
    from public.books_memberships membership
   where membership.user_id = auth.uid()
     and not exists (
       select 1 from public.books_personal_workspaces personal
        where personal.organization_id = membership.organization_id
     )
   order by membership.created_at
   limit 1;

  if organization_id is null then
    insert into public.books_organizations (name, owner_id)
    values ('My business', auth.uid())
    returning id into organization_id;
    insert into public.books_memberships (organization_id, user_id, role)
    values (organization_id, auth.uid(), 'owner');
    insert into public.books_accounts (organization_id, code, name, type, is_system) values
      (organization_id, '1000', 'Cash and bank', 'asset', true),
      (organization_id, '1100', 'Accounts receivable', 'asset', true),
      (organization_id, '2000', 'Accounts payable', 'liability', true),
      (organization_id, '3000', 'Owner equity', 'equity', true),
      (organization_id, '4000', 'Sales revenue', 'income', true),
      (organization_id, '5000', 'Operating expenses', 'expense', true)
    on conflict (organization_id, code) do nothing;
  end if;
  perform public.seed_books_tax_rates(organization_id);
  return organization_id;
end;
$$;
revoke all on function public.get_or_create_books_organization() from public, anon;
grant execute on function public.get_or_create_books_organization() to authenticated;

create or replace function public.post_books_expense()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.post_books_journal_entry(
    new.organization_id,
    'expense',
    new.id,
    new.expense_date,
    'Expense: ' || new.description,
    '5000',
    case when new.purchase_source_type is null then '1000' else '3000' end,
    new.amount + new.tax_amount,
    new.currency_code,
    auth.uid()
  );
  return new;
end;
$$;
revoke all on function public.post_books_expense() from public, anon, authenticated;

notify pgrst, 'reload schema';
commit;

alter table public.tasks add column if not exists final_amount numeric(20,4) check (final_amount >= 0);

update public.tasks t
   set final_amount = coalesce(
     (select n.final_price from public.task_negotiation_status n where n.task_id = t.id),
     (select p.quoted_price from public.task_proposals p
       where p.task_id = t.id and p.status = 'accepted'
       order by p.created_at desc limit 1),
     t.budget
   )
 where t.final_amount is null and t.assigned_to is not null;

create or replace function public.sync_task_final_amount_from_response()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if new.action = 'accept' then
    update public.tasks set final_amount = budget where id = new.task_id;
  end if;
  return new;
end;
$$;

drop trigger if exists sync_task_final_amount_on_response on public.task_responses;
create trigger sync_task_final_amount_on_response
after insert or update of action on public.task_responses
for each row execute function public.sync_task_final_amount_from_response();

create or replace function public.sync_task_final_amount_from_proposal()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if new.status = 'accepted' then
    update public.tasks set final_amount = coalesce(new.quoted_price, budget) where id = new.task_id;
  end if;
  return new;
end;
$$;

drop trigger if exists sync_task_final_amount_on_proposal on public.task_proposals;
create trigger sync_task_final_amount_on_proposal
after insert or update of status, quoted_price on public.task_proposals
for each row execute function public.sync_task_final_amount_from_proposal();

create or replace function public.sync_task_final_amount_from_negotiation()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if new.final_price is not null then
    update public.tasks set final_amount = new.final_price where id = new.task_id;
  end if;
  return new;
end;
$$;

drop trigger if exists sync_task_final_amount_on_negotiation on public.task_negotiation_status;
create trigger sync_task_final_amount_on_negotiation
after insert or update of final_price on public.task_negotiation_status
for each row execute function public.sync_task_final_amount_from_negotiation();

create table if not exists public.worker_task_payments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null unique references public.tasks(id) on delete restrict,
  hotel_organization_id uuid not null references public.books_organizations(id) on delete restrict,
  worker_user_id uuid not null references auth.users(id) on delete restrict,
  amount numeric(20,4) not null check (amount > 0),
  tax_amount numeric(20,4) not null default 0 check (tax_amount >= 0 and tax_amount < amount),
  currency_code char(3) not null,
  worker_currency_code char(3),
  fx_rate numeric(24,12) check (fx_rate > 0),
  fx_rate_source text,
  fx_rate_fetched_at timestamptz,
  converted_amount numeric(20,4) check (converted_amount > 0),
  converted_tax_amount numeric(20,4) not null default 0 check (converted_tax_amount >= 0),
  payment_method text not null check (payment_method in ('cash', 'bank_transfer', 'mobile_money', 'card', 'other')),
  payment_reference text not null,
  paid_at timestamptz not null default now(),
  recorded_by uuid not null references auth.users(id) on delete restrict,
  hotel_expense_id uuid references public.books_expenses(id) on delete restrict,
  worker_journal_transaction_id uuid references public.books_journal_transactions(id) on delete restrict,
  created_at timestamptz not null default now()
);

alter table public.worker_task_payments
  add column if not exists tax_amount numeric(20,4) not null default 0,
  add column if not exists worker_currency_code char(3),
  add column if not exists fx_rate numeric(24,12),
  add column if not exists fx_rate_source text,
  add column if not exists fx_rate_fetched_at timestamptz,
  add column if not exists converted_amount numeric(20,4),
  add column if not exists converted_tax_amount numeric(20,4) not null default 0;

alter table public.worker_task_payments drop constraint if exists worker_task_payments_fx_rate_source_check;
alter table public.worker_task_payments
  add constraint worker_task_payments_fx_rate_source_check
  check (fx_rate_source in ('same_currency', 'stored', 'manual'));

alter table public.worker_task_payments enable row level security;
revoke all on public.worker_task_payments from public, anon, authenticated;
grant select on public.worker_task_payments to authenticated;

drop policy if exists "Hotel managers read worker task payments" on public.worker_task_payments;
create policy "Hotel managers read worker task payments"
on public.worker_task_payments for select to authenticated
using (public.hotel_user_manages_organization(hotel_organization_id, auth.uid()));

drop policy if exists "Workers read own task payments" on public.worker_task_payments;
create policy "Workers read own task payments"
on public.worker_task_payments for select to authenticated
using (worker_user_id = auth.uid());

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

create or replace function public.books_task_payment_fx_rate(from_currency char(3), to_currency char(3))
returns table (fx_rate numeric, rate_fetched_at timestamptz, rate_status text)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  from_leg numeric;
  to_leg numeric;
  from_fetched timestamptz;
  to_fetched timestamptz;
begin
  if from_currency = to_currency then
    return query select 1::numeric, now(), 'same_currency'::text;
    return;
  end if;

  if from_currency = 'UGX' then
    from_leg := 1;
  else
    select f.rate, f.fetched_at into from_leg, from_fetched
      from public.books_fx_rates f
     where f.base_currency = 'UGX' and f.quote_currency = from_currency;
  end if;
  if to_currency = 'UGX' then
    to_leg := 1;
  else
    select f.rate, f.fetched_at into to_leg, to_fetched
      from public.books_fx_rates f
     where f.base_currency = 'UGX' and f.quote_currency = to_currency;
  end if;

  if from_leg is null or to_leg is null then
    return query select null::numeric, null::timestamptz, 'missing'::text;
    return;
  end if;

  return query select
    round(to_leg / from_leg, 12),
    least(from_fetched, to_fetched),
    case when least(from_fetched, to_fetched) < now() - interval '7 days' then 'stale' else 'stored' end;
end;
$$;
revoke all on function public.books_task_payment_fx_rate(char(3), char(3)) from public, anon, authenticated;

drop function if exists public.record_worker_task_payment(uuid, text, text, numeric);

create or replace function public.record_worker_task_payment(
  p_task_id uuid,
  p_payment_method text,
  p_payment_reference text,
  p_tax_amount numeric default 0,
  p_manual_fx_rate numeric default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  task_row public.tasks%rowtype;
  worker_user_id uuid;
  hotel_currency char(3);
  hotel_vat_registered boolean;
  worker_organization_id uuid;
  worker_currency char(3);
  worker_vat_registered boolean;
  fx_row record;
  applied_rate numeric;
  applied_source text;
  applied_fetched_at timestamptz;
  vat_amount numeric := coalesce(p_tax_amount, 0);
  converted_total numeric;
  converted_vat numeric;
  hotel_recoverable boolean;
  worker_name text;
  worker_contact_id uuid;
  reference_text text := nullif(trim(p_payment_reference), '');
  payment_id uuid;
  expense_id uuid;
  journal_id uuid;
  cash_account_id uuid;
  revenue_account_id uuid;
  vat_account_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to record payments'; end if;
  if reference_text is null then raise exception 'A payment reference is required'; end if;

  select * into task_row from public.tasks where id = p_task_id for update;
  if not found then raise exception 'Task not found'; end if;
  if task_row.organization_id is null
     or not public.hotel_user_manages_organization(task_row.organization_id, auth.uid()) then
    raise exception 'Only this hotel''s manager can record task payments';
  end if;
  if task_row.status <> 'completed' then raise exception 'Task must be approved before payment'; end if;
  if not exists (
    select 1 from public.task_reports report
     where report.task_id = task_row.id and report.status = 'approved'
  ) then
    raise exception 'Task report must be approved before payment';
  end if;
  if task_row.final_amount is null or task_row.final_amount <= 0 then
    raise exception 'Task has no agreed amount';
  end if;
  if task_row.assigned_to is null then raise exception 'Task has no assigned worker'; end if;
  if vat_amount < 0 or vat_amount >= task_row.final_amount then
    raise exception 'VAT must be zero or less than the payment amount';
  end if;
  if p_manual_fx_rate is not null and p_manual_fx_rate <= 0 then
    raise exception 'Manual FX rate must be greater than zero';
  end if;
  if exists (select 1 from public.worker_task_payments where task_id = task_row.id) then
    raise exception 'Payment is already recorded for this task';
  end if;

  select profile.user_id,
         coalesce(nullif(trim(concat_ws(' ', profile.first_name, profile.last_name)), ''), 'Worker')
    into worker_user_id, worker_name
    from public.user_profiles profile where profile.id = task_row.assigned_to;
  if worker_user_id is null then raise exception 'Assigned worker profile not found'; end if;

  select organization.base_currency, organization.vat_registered
    into hotel_currency, hotel_vat_registered
    from public.books_organizations organization
   where organization.id = task_row.organization_id;

  worker_organization_id := public.ensure_worker_books_organization(worker_user_id, hotel_currency);
  select organization.base_currency, organization.vat_registered
    into worker_currency, worker_vat_registered
    from public.books_organizations organization
   where organization.id = worker_organization_id;

  select * into fx_row from public.books_task_payment_fx_rate(hotel_currency, worker_currency);
  if fx_row.rate_status in ('same_currency', 'stored') then
    applied_rate := fx_row.fx_rate;
    applied_source := fx_row.rate_status;
    applied_fetched_at := fx_row.rate_fetched_at;
  elsif p_manual_fx_rate is not null then
    applied_rate := p_manual_fx_rate;
    applied_source := 'manual';
    applied_fetched_at := null;
  elsif fx_row.rate_status = 'stale' then
    raise exception 'FX_RATE_STALE: The stored % to % rate is older than 7 days. Enter a manual rate to record this payment.',
      hotel_currency, worker_currency;
  else
    raise exception 'FX_RATE_MISSING: No stored % to % rate exists. Enter a manual rate to record this payment.',
      hotel_currency, worker_currency;
  end if;

  converted_total := round(task_row.final_amount * applied_rate, public.checkout_currency_minor_units(worker_currency));
  converted_vat := case
    when worker_vat_registered then round(vat_amount * applied_rate, public.checkout_currency_minor_units(worker_currency))
    else 0
  end;
  if converted_total <= 0 then raise exception 'Converted payment amount is zero'; end if;

  insert into public.worker_task_payments (
    task_id, hotel_organization_id, worker_user_id, amount, tax_amount, currency_code,
    worker_currency_code, fx_rate, fx_rate_source, fx_rate_fetched_at,
    converted_amount, converted_tax_amount,
    payment_method, payment_reference, recorded_by
  ) values (
    task_row.id, task_row.organization_id, worker_user_id, task_row.final_amount, vat_amount, hotel_currency,
    worker_currency, applied_rate, applied_source, applied_fetched_at,
    converted_total, converted_vat,
    p_payment_method, reference_text, auth.uid()
  )
  returning id into payment_id;

  select contact.id into worker_contact_id
    from public.books_contacts contact
   where contact.organization_id = task_row.organization_id
     and contact.name = worker_name
     and contact.type in ('vendor', 'both')
   limit 1;
  if worker_contact_id is null then
    insert into public.books_contacts (organization_id, name, type)
    values (task_row.organization_id, worker_name, 'vendor')
    returning id into worker_contact_id;
  end if;

  hotel_recoverable := coalesce(hotel_vat_registered, false) and vat_amount > 0;
  if hotel_recoverable then
    insert into public.books_accounts (organization_id, code, name, type, is_system)
    values (task_row.organization_id, '1400', 'Input VAT recoverable', 'asset', true)
    on conflict (organization_id, code) do nothing;
  end if;

  insert into public.books_expenses (
    organization_id, contact_id, description, expense_date, currency_code, amount, tax_amount,
    vat_recoverable, payment_status
  ) values (
    task_row.organization_id, worker_contact_id, 'Worker payment: ' || task_row.title, current_date,
    hotel_currency, task_row.final_amount - vat_amount, vat_amount, hotel_recoverable, 'paid'
  )
  returning id into expense_id;

  select account.id into cash_account_id from public.books_accounts account
   where account.organization_id = worker_organization_id and account.code = '1000';
  select account.id into revenue_account_id from public.books_accounts account
   where account.organization_id = worker_organization_id and account.code = '4000';
  select account.id into vat_account_id from public.books_accounts account
   where account.organization_id = worker_organization_id and account.code = '2100';
  if cash_account_id is null or revenue_account_id is null or (converted_vat > 0 and vat_account_id is null) then
    raise exception 'Required worker Books account is missing';
  end if;

  insert into public.books_journal_transactions (
    organization_id, source_type, source_id, transaction_date, description, created_by
  ) values (
    worker_organization_id, 'worker_task_payment', payment_id, current_date,
    'Task payment received: ' || task_row.title, worker_user_id
  )
  returning id into journal_id;

  insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
  values (journal_id, cash_account_id, converted_total, 0, worker_currency, 1),
         (journal_id, revenue_account_id, 0, converted_total - converted_vat, worker_currency, 1);
  if converted_vat > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
    values (journal_id, vat_account_id, 0, converted_vat, worker_currency, 1);
  end if;

  update public.worker_task_payments
     set hotel_expense_id = expense_id,
         worker_journal_transaction_id = journal_id
   where id = payment_id;

  insert into public.notifications (user_id, task_id, type, message)
  values (
    worker_user_id, task_row.id, 'task_updated',
    'Payment recorded for "' || task_row.title || '". Reference: ' || reference_text
  );

  return payment_id;
end;
$$;

revoke all on function public.record_worker_task_payment(uuid, text, text, numeric, numeric) from public, anon;
grant execute on function public.record_worker_task_payment(uuid, text, text, numeric, numeric) to authenticated;

create or replace function public.conclude_negotiation(task_id_param uuid, provider_id_param uuid, final_price_param numeric default null::numeric, final_timeline_param character varying default null::character varying, final_notes_param text default null::text)
returns void
language plpgsql
as $function$
declare
  v_task_record tasks%rowtype;
  v_proposal_record task_proposals%rowtype;
begin
  select * into v_task_record from tasks where id = task_id_param;

  if not found then
    raise exception 'Task not found: %', task_id_param;
  end if;

  select * into v_proposal_record from task_proposals
  where task_id = task_id_param and worker_id = provider_id_param
  order by created_at desc limit 1;

  insert into public.task_negotiation_status (task_id, status, final_price, final_timeline, final_notes)
  values (task_id_param, 'agreed', final_price_param, final_timeline_param, final_notes_param)
  on conflict (task_id) do update set
    status = 'agreed',
    final_price = coalesce(final_price_param, task_negotiation_status.final_price),
    final_timeline = final_timeline_param,
    final_notes = final_notes_param,
    updated_at = now();

  insert into public.todo_list (
    task_id,
    worker_id,
    title,
    description,
    priority,
    due_date,
    details,
    status
  )
  values (
    task_id_param,
    provider_id_param,
    v_task_record.title,
    v_task_record.description,
    v_task_record.priority,
    v_task_record.due_date,
    jsonb_build_object(
      'category', v_task_record.category,
      'estimated_time', v_task_record.estimated_time,
      'payment_terms', v_task_record.payment_terms,
      'budget', v_task_record.budget,
      'agreed_price', coalesce(final_price_param, v_proposal_record.quoted_price, v_task_record.budget),
      'agreed_timeline', coalesce(final_timeline_param, v_proposal_record.proposed_timeline, v_task_record.estimated_time),
      'final_notes', final_notes_param
    ),
    'pending'::character varying
  )
  on conflict do nothing;

  insert into public.notifications (user_id, task_id, type, message)
  select
    up.user_id,
    task_id_param,
    'todo_created'::character varying,
    'Negotiation complete! A todo has been created with the final agreed terms.'
  from user_profiles up
  where up.id = provider_id_param;

  update public.task_negotiation_status
  set status = 'concluded', updated_at = now()
  where task_id = task_id_param;

end;
$function$;

notify pgrst, 'reload schema';

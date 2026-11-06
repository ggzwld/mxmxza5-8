drop function if exists public.approve_task_report_and_award_points(uuid);
drop function if exists public.record_worker_task_payment(uuid, text, text);
drop function if exists public.record_worker_task_payment(uuid, text, text, numeric);
drop function if exists public.record_worker_task_payment(uuid, text, text, numeric, numeric);
drop function if exists public.ensure_worker_books_organization(uuid);

create table if not exists public.worker_task_invoices (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null unique references public.tasks(id) on delete restrict,
  invoice_id uuid not null unique,
  worker_organization_id uuid not null references public.books_organizations(id) on delete restrict,
  hotel_organization_id uuid not null references public.books_organizations(id) on delete restrict,
  hotel_currency_code char(3) not null,
  hotel_amount numeric(20,4) not null check (hotel_amount > 0),
  hotel_tax_amount numeric(20,4) not null default 0 check (hotel_tax_amount >= 0 and hotel_tax_amount < hotel_amount),
  worker_currency_code char(3) not null,
  fx_rate numeric(24,12) not null check (fx_rate > 0),
  fx_rate_source text not null check (fx_rate_source in ('same_currency', 'stored', 'manual')),
  fx_rate_fetched_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (invoice_id, worker_organization_id) references public.books_invoices(id, organization_id) on delete restrict
);

alter table public.worker_task_invoices enable row level security;
revoke all on public.worker_task_invoices from public, anon, authenticated;

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

create or replace function public.post_books_paid_invoice()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.status = 'paid'
     and (tg_op = 'INSERT' or old.status is distinct from 'paid')
     and not exists (select 1 from public.worker_task_invoices invoice_link where invoice_link.invoice_id = new.id) then
    perform public.post_books_journal_entry(new.organization_id, 'invoice_payment', new.id, new.issue_date, 'Payment received for invoice ' || new.invoice_number, '1000', '1100', new.total, new.currency_code, auth.uid());
  end if;
  return new;
end;
$$;

create or replace function public.create_worker_task_invoice(target_task_id uuid, manual_fx_rate numeric)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  task_row public.tasks%rowtype;
  invoice_row public.books_invoices%rowtype;
  existing_link public.worker_task_invoices%rowtype;
  worker_user_id uuid;
  hotel_name text;
  hotel_currency char(3);
  worker_organization_id uuid;
  worker_currency char(3);
  worker_vat_registered boolean;
  worker_tax_country text;
  fx_row record;
  applied_rate numeric;
  applied_source text;
  applied_fetched_at timestamptz;
  gross_amount numeric;
  vat_rate_id uuid;
  vat_rate_percentage numeric := 0;
  subtotal_amount numeric;
  hotel_tax numeric := 0;
  customer_id uuid;
  journal_id uuid;
  receivable_id uuid;
  revenue_id uuid;
  vat_payable_id uuid;
begin
  select * into task_row from public.tasks where id = target_task_id for update;
  if not found then raise exception 'Task not found'; end if;

  select * into existing_link from public.worker_task_invoices where task_id = target_task_id;
  if found then return existing_link.invoice_id; end if;

  if task_row.organization_id is null or task_row.assigned_to is null
     or coalesce(task_row.final_amount, 0) <= 0 then
    return null;
  end if;
  if manual_fx_rate is not null and manual_fx_rate <= 0 then
    raise exception 'Manual FX rate must be greater than zero';
  end if;

  select profile.user_id into worker_user_id
    from public.user_profiles profile where profile.id = task_row.assigned_to;
  if worker_user_id is null then raise exception 'Assigned worker profile not found'; end if;

  select organization.name, organization.base_currency
    into hotel_name, hotel_currency
    from public.books_organizations organization where organization.id = task_row.organization_id;

  worker_organization_id := public.ensure_worker_books_organization(worker_user_id, hotel_currency);
  select organization.base_currency, organization.vat_registered, organization.tax_country_code
    into worker_currency, worker_vat_registered, worker_tax_country
    from public.books_organizations organization where organization.id = worker_organization_id;

  select * into fx_row from public.books_task_payment_fx_rate(hotel_currency, worker_currency);
  if fx_row.rate_status in ('same_currency', 'stored') then
    applied_rate := fx_row.fx_rate;
    applied_source := fx_row.rate_status;
    applied_fetched_at := fx_row.rate_fetched_at;
  elsif manual_fx_rate is not null then
    applied_rate := manual_fx_rate;
    applied_source := 'manual';
  elsif fx_row.rate_status = 'stale' then
    raise exception 'FX_RATE_STALE: The stored % to % rate is older than 7 days. Enter a manual rate to continue.', hotel_currency, worker_currency;
  else
    raise exception 'FX_RATE_MISSING: No stored % to % rate exists. Enter a manual rate to continue.', hotel_currency, worker_currency;
  end if;

  gross_amount := round(task_row.final_amount * applied_rate, public.checkout_currency_minor_units(worker_currency));
  if gross_amount <= 0 then raise exception 'Converted task amount is zero'; end if;

  if worker_vat_registered then
    select rate.id, rate.rate_percentage into vat_rate_id, vat_rate_percentage
      from public.books_tax_rates rate
     where rate.organization_id = worker_organization_id
       and rate.country_code = worker_tax_country
       and rate.tax_scope = 'invoice'
       and rate.is_active
       and rate.confirmed_at is not null
       and rate.effective_from <= current_date
       and (rate.effective_to is null or rate.effective_to >= current_date)
     order by rate.effective_from desc, rate.confirmed_at desc
     limit 1;
    if vat_rate_id is null then
      raise exception 'Confirm a VAT rate in your Books tax settings before this task can be approved';
    end if;
    subtotal_amount := round(gross_amount / (1 + vat_rate_percentage / 100), 4);
    hotel_tax := task_row.final_amount - round(
      task_row.final_amount / (1 + vat_rate_percentage / 100),
      public.checkout_currency_minor_units(hotel_currency)
    );
  else
    subtotal_amount := gross_amount;
  end if;

  select contact.id into customer_id from public.books_contacts contact
   where contact.organization_id = worker_organization_id
     and lower(contact.name) = lower(hotel_name)
     and contact.type in ('customer', 'both')
   order by contact.created_at
   limit 1;
  if customer_id is null then
    insert into public.books_contacts (organization_id, name, type)
    values (worker_organization_id, hotel_name, 'customer')
    returning id into customer_id;
  end if;

  insert into public.books_invoices (
    organization_id, contact_id, invoice_number, issue_date, due_date, currency_code,
    subtotal, tax_rate_id, status, notes
  ) values (
    worker_organization_id, customer_id, 'TASK-' || task_row.id::text, current_date, current_date, worker_currency,
    subtotal_amount, vat_rate_id, 'sent', 'Approved task: ' || task_row.title
  )
  returning * into invoice_row;

  insert into public.worker_task_invoices (
    task_id, invoice_id, worker_organization_id, hotel_organization_id,
    hotel_currency_code, hotel_amount, hotel_tax_amount,
    worker_currency_code, fx_rate, fx_rate_source, fx_rate_fetched_at
  ) values (
    task_row.id, invoice_row.id, worker_organization_id, task_row.organization_id,
    hotel_currency, task_row.final_amount, hotel_tax,
    worker_currency, applied_rate, applied_source, applied_fetched_at
  );

  select account.id into receivable_id from public.books_accounts account
   where account.organization_id = worker_organization_id and account.code = '1100';
  select account.id into revenue_id from public.books_accounts account
   where account.organization_id = worker_organization_id and account.code = '4000';
  select account.id into vat_payable_id from public.books_accounts account
   where account.organization_id = worker_organization_id and account.code = '2100';
  if receivable_id is null or revenue_id is null or (invoice_row.tax_amount > 0 and vat_payable_id is null) then
    raise exception 'Required worker Books account is missing';
  end if;

  insert into public.books_journal_transactions (organization_id, source_type, source_id, transaction_date, description, created_by)
  values (worker_organization_id, 'worker_task_invoice', invoice_row.id, current_date, 'Task invoice ' || invoice_row.invoice_number, worker_user_id)
  returning id into journal_id;

  insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
  values (journal_id, receivable_id, invoice_row.total, 0, worker_currency, 1),
         (journal_id, revenue_id, 0, invoice_row.subtotal, worker_currency, 1);
  if invoice_row.tax_amount > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
    values (journal_id, vat_payable_id, 0, invoice_row.tax_amount, worker_currency, 1);
  end if;

  return invoice_row.id;
end;
$$;
revoke all on function public.create_worker_task_invoice(uuid, numeric) from public, anon, authenticated;

create or replace function public.approve_task_report_and_award_points(target_report_id uuid, p_manual_fx_rate numeric default null)
returns integer language plpgsql security definer volatile set search_path = pg_catalog, public
as $$
declare
  report_row public.task_reports%rowtype;
  task_row public.tasks%rowtype;
  worker_user_id uuid;
  actor_role text;
  points_this_month bigint;
  reward_points integer;
  program_row public.hotel_loyalty_programs%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in to approve task work'; end if;
  select role into actor_role from public.user_profiles where user_id = auth.uid();
  select * into report_row from public.task_reports where id = target_report_id for update;
  if not found then raise exception 'Task report was not found'; end if;
  select * into task_row from public.tasks where id = report_row.task_id for update;
  if not found or task_row.created_by <> auth.uid() or actor_role <> 'manager' then raise exception 'Only the task manager can approve this report'; end if;
  if task_row.assigned_to is distinct from report_row.worker_id or report_row.status <> 'completed_pending_approval' then
    raise exception 'This task report is not ready for approval';
  end if;
  select user_id into worker_user_id from public.user_profiles where id = report_row.worker_id and role = 'worker';
  if worker_user_id is null then raise exception 'Assigned worker account was not found'; end if;
  update public.task_reports set status = 'approved', last_updated_by = auth.uid(), updated_at = now() where id = report_row.id;
  update public.tasks set status = 'completed', updated_at = now() where id = task_row.id;
  perform public.create_worker_task_invoice(task_row.id, p_manual_fx_rate);
  insert into public.notifications (user_id, task_id, type, message)
  values (worker_user_id, task_row.id, 'task_updated', 'Your task "' || task_row.title || '" has been approved and marked complete.');
  if task_row.organization_id is null then return 0; end if;
  select * into program_row from public.hotel_loyalty_programs where organization_id = task_row.organization_id and program_enabled;
  if not found then return 0; end if;
  perform public.hotel_loyalty_make_account(task_row.organization_id, worker_user_id);
  select * into program_row from public.hotel_loyalty_programs where organization_id = task_row.organization_id;
  select coalesce(sum(points_delta), 0) into points_this_month from public.hotel_loyalty_ledger_entries
  where organization_id = task_row.organization_id and user_id = worker_user_id and entry_type = 'task_earn'
    and created_at >= date_trunc('month', now());
  reward_points := least(program_row.task_approval_points, greatest(program_row.monthly_task_points_cap - points_this_month, 0)::integer);
  if reward_points > 0 and exists (select 1 from public.hotel_loyalty_accounts where organization_id = task_row.organization_id and user_id = worker_user_id and is_enrolled) then
    if public.apply_hotel_loyalty_delta(task_row.organization_id, worker_user_id, 'task_earn', reward_points,
      'approved_task', task_row.id, 'Manager-approved hotel task reward') is null then reward_points := 0; end if;
  else reward_points := 0; end if;
  perform public.qualify_hotel_loyalty_referral(task_row.organization_id, worker_user_id, 'task', 'approved_task', task_row.id, null);
  return reward_points;
end;
$$;
revoke all on function public.approve_task_report_and_award_points(uuid, numeric) from public, anon;
grant execute on function public.approve_task_report_and_award_points(uuid, numeric) to authenticated;

create or replace function public.record_worker_task_payment(
  p_task_id uuid,
  p_payment_method text,
  p_payment_reference text,
  p_manual_fx_rate numeric default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  task_row public.tasks%rowtype;
  invoice_row public.books_invoices%rowtype;
  invoice_link public.worker_task_invoices%rowtype;
  worker_user_id uuid;
  worker_name text;
  hotel_vat_registered boolean;
  worker_currency char(3);
  fx_row record;
  applied_rate numeric;
  applied_source text;
  applied_fetched_at timestamptz;
  cash_amount numeric;
  settlement_difference numeric;
  reference_text text := nullif(trim(p_payment_reference), '');
  payment_id uuid;
  expense_id uuid;
  journal_id uuid;
  worker_contact_id uuid;
  hotel_recoverable boolean;
  cash_account_id uuid;
  receivable_id uuid;
  fx_gain_id uuid;
  fx_loss_id uuid;
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
  if exists (select 1 from public.worker_task_payments where task_id = task_row.id) then
    raise exception 'Payment is already recorded for this task';
  end if;

  select profile.user_id,
         coalesce(nullif(trim(concat_ws(' ', profile.first_name, profile.last_name)), ''), 'Worker')
    into worker_user_id, worker_name
    from public.user_profiles profile where profile.id = task_row.assigned_to;
  if worker_user_id is null then raise exception 'Assigned worker profile not found'; end if;

  select organization.vat_registered into hotel_vat_registered
    from public.books_organizations organization where organization.id = task_row.organization_id;

  perform public.create_worker_task_invoice(task_row.id, p_manual_fx_rate);
  select * into invoice_link from public.worker_task_invoices where task_id = task_row.id;
  select * into invoice_row from public.books_invoices where id = invoice_link.invoice_id for update;
  if invoice_row.status not in ('sent', 'overdue') then raise exception 'Task invoice is not open for payment'; end if;
  worker_currency := invoice_link.worker_currency_code;

  select * into fx_row from public.books_task_payment_fx_rate(invoice_link.hotel_currency_code, worker_currency);
  if fx_row.rate_status in ('same_currency', 'stored') then
    applied_rate := fx_row.fx_rate;
    applied_source := fx_row.rate_status;
    applied_fetched_at := fx_row.rate_fetched_at;
  elsif p_manual_fx_rate is not null then
    applied_rate := p_manual_fx_rate;
    applied_source := 'manual';
  elsif fx_row.rate_status = 'stale' then
    raise exception 'FX_RATE_STALE: The stored % to % rate is older than 7 days. Enter a manual rate to record this payment.',
      invoice_link.hotel_currency_code, worker_currency;
  else
    raise exception 'FX_RATE_MISSING: No stored % to % rate exists. Enter a manual rate to record this payment.',
      invoice_link.hotel_currency_code, worker_currency;
  end if;

  cash_amount := round(task_row.final_amount * applied_rate, public.checkout_currency_minor_units(worker_currency));
  if cash_amount <= 0 then raise exception 'Converted payment amount is zero'; end if;
  settlement_difference := cash_amount - invoice_row.total;

  insert into public.worker_task_payments (
    task_id, hotel_organization_id, worker_user_id, amount, tax_amount, currency_code,
    worker_currency_code, fx_rate, fx_rate_source, fx_rate_fetched_at,
    converted_amount, converted_tax_amount,
    payment_method, payment_reference, recorded_by
  ) values (
    task_row.id, task_row.organization_id, worker_user_id, task_row.final_amount, invoice_link.hotel_tax_amount, invoice_link.hotel_currency_code,
    worker_currency, applied_rate, applied_source, applied_fetched_at,
    cash_amount, invoice_row.tax_amount,
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

  hotel_recoverable := coalesce(hotel_vat_registered, false) and invoice_link.hotel_tax_amount > 0;
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
    invoice_link.hotel_currency_code, task_row.final_amount - invoice_link.hotel_tax_amount, invoice_link.hotel_tax_amount,
    hotel_recoverable, 'paid'
  )
  returning id into expense_id;

  insert into public.books_accounts (organization_id, code, name, type, is_system) values
    (invoice_link.worker_organization_id, '4900', 'Exchange gains', 'income', true),
    (invoice_link.worker_organization_id, '5900', 'Exchange losses', 'expense', true)
  on conflict (organization_id, code) do nothing;

  select account.id into cash_account_id from public.books_accounts account
   where account.organization_id = invoice_link.worker_organization_id and account.code = '1000';
  select account.id into receivable_id from public.books_accounts account
   where account.organization_id = invoice_link.worker_organization_id and account.code = '1100';
  select account.id into fx_gain_id from public.books_accounts account
   where account.organization_id = invoice_link.worker_organization_id and account.code = '4900';
  select account.id into fx_loss_id from public.books_accounts account
   where account.organization_id = invoice_link.worker_organization_id and account.code = '5900';
  if cash_account_id is null or receivable_id is null or fx_gain_id is null or fx_loss_id is null then
    raise exception 'Required worker Books account is missing';
  end if;

  insert into public.books_journal_transactions (organization_id, source_type, source_id, transaction_date, description, created_by)
  values (invoice_link.worker_organization_id, 'worker_task_settlement', payment_id, current_date, 'Task payment received: ' || task_row.title, worker_user_id)
  returning id into journal_id;

  insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
  values (journal_id, cash_account_id, cash_amount, 0, worker_currency, 1),
         (journal_id, receivable_id, 0, invoice_row.total, worker_currency, 1);
  if settlement_difference > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
    values (journal_id, fx_gain_id, 0, settlement_difference, worker_currency, 1);
  elsif settlement_difference < 0 then
    insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
    values (journal_id, fx_loss_id, -settlement_difference, 0, worker_currency, 1);
  end if;

  update public.worker_task_payments
     set hotel_expense_id = expense_id,
         worker_journal_transaction_id = journal_id
   where id = payment_id;

  update public.books_invoices set status = 'paid' where id = invoice_row.id;

  insert into public.notifications (user_id, task_id, type, message)
  values (
    worker_user_id, task_row.id, 'task_updated',
    'Payment recorded for "' || task_row.title || '". Reference: ' || reference_text
  );

  return payment_id;
end;
$$;
revoke all on function public.record_worker_task_payment(uuid, text, text, numeric) from public, anon;
grant execute on function public.record_worker_task_payment(uuid, text, text, numeric) to authenticated;

notify pgrst, 'reload schema';

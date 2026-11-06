alter table public.worker_task_payments
  add column if not exists confirmation_status text,
  add column if not exists worker_acknowledged_at timestamptz;

update public.worker_task_payments
   set confirmation_status = 'legacy_settled'
 where confirmation_status is null;

alter table public.worker_task_payments
  alter column confirmation_status set default 'pending_confirmation',
  alter column confirmation_status set not null;

alter table public.worker_task_payments
  drop constraint if exists worker_task_payments_confirmation_status_check;
alter table public.worker_task_payments
  add constraint worker_task_payments_confirmation_status_check
  check (confirmation_status in ('pending_confirmation', 'confirmed', 'legacy_settled'));

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
  converted_amount numeric;
  reference_text text := nullif(trim(p_payment_reference), '');
  payment_id uuid;
  expense_id uuid;
  worker_contact_id uuid;
  hotel_recoverable boolean;
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

  converted_amount := round(task_row.final_amount * applied_rate, public.checkout_currency_minor_units(worker_currency));
  if converted_amount <= 0 then raise exception 'Converted payment amount is zero'; end if;

  insert into public.worker_task_payments (
    task_id, hotel_organization_id, worker_user_id, amount, tax_amount, currency_code,
    worker_currency_code, fx_rate, fx_rate_source, fx_rate_fetched_at,
    converted_amount, converted_tax_amount, payment_method, payment_reference,
    recorded_by, confirmation_status
  ) values (
    task_row.id, task_row.organization_id, worker_user_id, task_row.final_amount, invoice_link.hotel_tax_amount, invoice_link.hotel_currency_code,
    worker_currency, applied_rate, applied_source, applied_fetched_at,
    converted_amount, invoice_row.tax_amount, p_payment_method, reference_text,
    auth.uid(), 'pending_confirmation'
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

  update public.worker_task_payments
     set hotel_expense_id = expense_id
   where id = payment_id;

  insert into public.notifications (user_id, task_id, type, message, action_url)
  values (
    worker_user_id, task_row.id, 'task_updated',
    'The hotel recorded payment for "' || task_row.title || '". Review the payment and confirm receipt in Books.',
    '/books'
  );

  return payment_id;
end;
$$;
revoke all on function public.record_worker_task_payment(uuid, text, text, numeric) from public, anon;
grant execute on function public.record_worker_task_payment(uuid, text, text, numeric) to authenticated;

create or replace function public.confirm_worker_task_payment(p_task_id uuid)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  payment_row public.worker_task_payments%rowtype;
  invoice_link public.worker_task_invoices%rowtype;
  invoice_row public.books_invoices%rowtype;
  cash_amount numeric;
  settlement_difference numeric;
  journal_id uuid;
  cash_account_id uuid;
  receivable_id uuid;
  fx_gain_id uuid;
  fx_loss_id uuid;
  task_title text;
begin
  if auth.uid() is null then raise exception 'Sign in to confirm payment receipt'; end if;

  select * into payment_row
    from public.worker_task_payments
   where task_id = p_task_id
   for update;
  if not found then raise exception 'No payment has been recorded for this task'; end if;
  if payment_row.worker_user_id <> auth.uid()
     or not exists (
       select 1
         from public.tasks task
         join public.user_profiles profile on profile.id = task.assigned_to
        where task.id = p_task_id
          and profile.user_id = auth.uid()
          and profile.role = 'worker'
     ) then
    raise exception 'Only the assigned worker can confirm receipt of this payment';
  end if;
  if payment_row.confirmation_status in ('confirmed', 'legacy_settled') then return payment_row.id; end if;

  select * into invoice_link from public.worker_task_invoices where task_id = p_task_id;
  if not found then raise exception 'Task invoice was not found'; end if;
  select * into invoice_row from public.books_invoices where id = invoice_link.invoice_id for update;
  if invoice_row.status not in ('sent', 'overdue') then raise exception 'Task invoice is not awaiting payment confirmation'; end if;
  if payment_row.converted_amount is null or payment_row.worker_currency_code is null then
    raise exception 'Recorded payment is missing its worker Books amount';
  end if;

  select title into task_title from public.tasks where id = p_task_id;
  cash_amount := payment_row.converted_amount;
  settlement_difference := cash_amount - invoice_row.total;

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
  values (invoice_link.worker_organization_id, 'worker_task_settlement', payment_row.id, current_date, 'Task payment received: ' || task_title, auth.uid())
  returning id into journal_id;

  insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
  values (journal_id, cash_account_id, cash_amount, 0, payment_row.worker_currency_code, 1),
         (journal_id, receivable_id, 0, invoice_row.total, payment_row.worker_currency_code, 1);
  if settlement_difference > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
    values (journal_id, fx_gain_id, 0, settlement_difference, payment_row.worker_currency_code, 1);
  elsif settlement_difference < 0 then
    insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
    values (journal_id, fx_loss_id, -settlement_difference, 0, payment_row.worker_currency_code, 1);
  end if;

  update public.worker_task_payments
     set confirmation_status = 'confirmed',
         worker_acknowledged_at = now(),
         worker_journal_transaction_id = journal_id
   where id = payment_row.id;

  update public.books_invoices set status = 'paid' where id = invoice_row.id;

  insert into public.notifications (user_id, task_id, type, message, action_url)
  values (
    payment_row.recorded_by, p_task_id, 'task_updated',
    'The worker confirmed receipt of payment for task "' || task_title || '". The payment receipt is available in Books.',
    '/books'
  );

  return payment_row.id;
end;
$$;
revoke all on function public.confirm_worker_task_payment(uuid) from public, anon;
grant execute on function public.confirm_worker_task_payment(uuid) to authenticated;

create or replace function public.protect_worker_task_invoice_payment()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.status = 'paid' and old.status is distinct from 'paid' and exists (
    select 1 from public.worker_task_invoices invoice_link
     where invoice_link.invoice_id = new.id
       and not exists (
         select 1 from public.worker_task_payments payment
          where payment.task_id = invoice_link.task_id
            and payment.confirmation_status = 'confirmed'
            and payment.worker_acknowledged_at is not null
       )
  ) then
    raise exception 'Worker task invoices can only be marked paid after the assigned worker confirms receipt';
  end if;
  return new;
end;
$$;

notify pgrst, 'reload schema';

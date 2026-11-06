begin;

create table if not exists public.books_personal_purchase_records (
  id uuid primary key default gen_random_uuid(),
  source_type text not null check (source_type in ('menu_order', 'hotel_booking', 'special_event_payment')),
  source_id uuid not null,
  buyer_user_id uuid not null references auth.users(id) on delete restrict,
  hotel_organization_id uuid not null references public.books_organizations(id) on delete restrict,
  amount numeric(20,4) not null check (amount > 0),
  currency_code char(3) not null,
  purchase_date date not null,
  description text not null,
  status text not null default 'pending' check (status in ('pending', 'posted', 'failed', 'reversed')),
  personal_organization_id uuid references public.books_organizations(id) on delete restrict,
  expense_id uuid references public.books_expenses(id) on delete restrict,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (source_type, source_id)
);

alter table public.books_personal_purchase_records enable row level security;
revoke all on public.books_personal_purchase_records from public, anon, authenticated;
grant select on public.books_personal_purchase_records to authenticated;
drop policy if exists books_personal_purchase_records_buyer_read on public.books_personal_purchase_records;
create policy books_personal_purchase_records_buyer_read on public.books_personal_purchase_records
  for select to authenticated using (buyer_user_id = auth.uid());

alter table public.books_expenses
  add column if not exists purchase_source_type text,
  add column if not exists purchase_source_id uuid;
create unique index if not exists books_expenses_purchase_source_uidx
  on public.books_expenses (organization_id, purchase_source_type, purchase_source_id)
  where purchase_source_type is not null and purchase_source_id is not null;

alter table public.books_expenses drop constraint if exists books_expenses_payment_status_check;
alter table public.books_expenses add constraint books_expenses_payment_status_check
  check (payment_status in ('paid', 'unpaid', 'refunded'));

alter table public.notifications add column if not exists action_url text;

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
    '1000',
    new.amount + new.tax_amount,
    new.currency_code,
    auth.uid()
  );
  return new;
end;
$$;
revoke all on function public.post_books_expense() from public, anon, authenticated;

create or replace function public.process_personal_books_purchase_record(target_record_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  purchase_row public.books_personal_purchase_records%rowtype;
  target_personal_organization_id uuid;
  target_expense_id uuid;
begin
  select * into purchase_row
    from public.books_personal_purchase_records
   where id = target_record_id
   for update;
  if not found then raise exception 'Purchase record was not found'; end if;
  if purchase_row.status = 'posted' then return 'posted'; end if;
  if purchase_row.status = 'reversed' then return 'reversed'; end if;

  target_personal_organization_id := public.ensure_personal_books_workspace(purchase_row.buyer_user_id);
  if target_personal_organization_id is null then
    update public.books_personal_purchase_records
       set status = 'failed', error_message = 'Buyer does not have a registered account', updated_at = now()
     where id = target_record_id;
    return 'failed';
  end if;

  insert into public.books_expenses (
    organization_id, description, expense_date, currency_code, amount, tax_amount,
    payment_status, purchase_source_type, purchase_source_id
  ) values (
    target_personal_organization_id,
    purchase_row.description,
    purchase_row.purchase_date,
    purchase_row.currency_code,
    purchase_row.amount,
    0,
    'paid',
    'hotel_purchase',
    purchase_row.id
  )
  on conflict (organization_id, purchase_source_type, purchase_source_id)
    where purchase_source_type is not null and purchase_source_id is not null
    do nothing
  returning id into target_expense_id;

  if target_expense_id is null then
    select expense.id into target_expense_id
      from public.books_expenses expense
     where expense.organization_id = target_personal_organization_id
       and expense.purchase_source_type = 'hotel_purchase'
       and expense.purchase_source_id = purchase_row.id;
  end if;
  if target_expense_id is null then raise exception 'Personal Books expense was not created'; end if;

  update public.books_personal_purchase_records
     set personal_organization_id = target_personal_organization_id,
         expense_id = target_expense_id,
         status = 'posted', error_message = null, updated_at = now()
   where id = target_record_id;
  return 'posted';
exception when others then
  update public.books_personal_purchase_records
     set status = 'failed', error_message = left(sqlerrm, 2000), updated_at = now()
   where id = target_record_id;
  return 'failed';
end;
$$;
revoke all on function public.process_personal_books_purchase_record(uuid) from public, anon, authenticated;
grant execute on function public.process_personal_books_purchase_record(uuid) to service_role;

create or replace function public.enqueue_personal_books_purchase(
  target_source_type text,
  target_source_id uuid,
  target_buyer_user_id uuid,
  target_hotel_organization_id uuid,
  target_amount numeric,
  target_currency_code text,
  target_purchase_date date,
  target_description text,
  target_action_url text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  purchase_record_id uuid;
  record_was_created boolean := false;
  purchase_status text;
begin
  if target_buyer_user_id is null or target_amount <= 0 or target_hotel_organization_id is null then return; end if;
  if not exists (
    select 1 from auth.users auth_user
     where auth_user.id = target_buyer_user_id and not auth_user.is_anonymous
  ) then return; end if;

  insert into public.books_personal_purchase_records (
    source_type, source_id, buyer_user_id, hotel_organization_id,
    amount, currency_code, purchase_date, description
  ) values (
    target_source_type, target_source_id, target_buyer_user_id, target_hotel_organization_id,
    target_amount, upper(target_currency_code), target_purchase_date, target_description
  )
  on conflict (source_type, source_id) do nothing
  returning id into purchase_record_id;
  record_was_created := purchase_record_id is not null;

  if purchase_record_id is null then
    select purchase.id into purchase_record_id
      from public.books_personal_purchase_records purchase
     where purchase.source_type = target_source_type and purchase.source_id = target_source_id;
  end if;
  if purchase_record_id is null then return; end if;

  purchase_status := public.process_personal_books_purchase_record(purchase_record_id);

  if record_was_created then
    insert into public.notifications (user_id, type, message, action_url)
    values (
      target_buyer_user_id,
      'personal_purchase_recorded',
      'Your ' || target_description || ' was added to Personal Books as an expense (' || purchase_status || ').',
      '/books?workspace=personal'
    );

    insert into public.notifications (user_id, type, message, action_url)
    select distinct membership.user_id,
      'hotel_purchase_recorded',
      'A paid ' || target_description || ' for ' || to_char(target_amount, 'FM999999999990D00') || ' ' || upper(target_currency_code) || ' was recorded by this hotel.',
      target_action_url
    from public.books_memberships membership
    where membership.organization_id = target_hotel_organization_id
      and membership.role in ('owner', 'admin');
  end if;
exception when others then
  raise warning 'Personal Books purchase capture failed for source %/%: %', target_source_type, target_source_id, left(sqlerrm, 500);
end;
$$;
revoke all on function public.enqueue_personal_books_purchase(text, uuid, uuid, uuid, numeric, text, date, text, text) from public, anon, authenticated;
grant execute on function public.enqueue_personal_books_purchase(text, uuid, uuid, uuid, numeric, text, date, text, text) to service_role;

create or replace function public.record_paid_menu_purchase_in_personal_books()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if new.payment_status = 'paid' and old.payment_status is distinct from 'paid' then
    perform public.enqueue_personal_books_purchase(
      'menu_order', new.id, new.user_id, new.organization_id, new.total_amount, new.currency,
      new.created_at::date, 'menu order ' || new.order_number,
      '/books?organization=' || new.organization_id::text
    );
  end if;
  return new;
end;
$$;
revoke all on function public.record_paid_menu_purchase_in_personal_books() from public, anon, authenticated;
drop trigger if exists record_paid_menu_purchase_in_personal_books on public.menu_orders;
create trigger record_paid_menu_purchase_in_personal_books
after update of payment_status on public.menu_orders
for each row execute function public.record_paid_menu_purchase_in_personal_books();

create or replace function public.record_paid_hotel_purchase_in_personal_books()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if new.payment_status = 'paid' and old.payment_status is distinct from 'paid' then
    perform public.enqueue_personal_books_purchase(
      'hotel_booking', new.id, new.user_id, new.organization_id, new.total_amount, new.currency_code,
      new.created_at::date, 'hotel room booking ' || new.confirmation_number,
      '/books?organization=' || new.organization_id::text
    );
  end if;
  return new;
end;
$$;
revoke all on function public.record_paid_hotel_purchase_in_personal_books() from public, anon, authenticated;
drop trigger if exists record_paid_hotel_purchase_in_personal_books on public.hotel_bookings;
create trigger record_paid_hotel_purchase_in_personal_books
after update of payment_status on public.hotel_bookings
for each row execute function public.record_paid_hotel_purchase_in_personal_books();

create or replace function public.record_paid_event_purchase_in_personal_books()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare booking_row public.special_event_bookings%rowtype;
  event_name text;
begin
  if new.status <> 'successful' or (tg_op = 'UPDATE' and old.status = 'successful') then return new; end if;
  select * into booking_row from public.special_event_bookings where id = new.booking_id;
  if not found or booking_row.payment_status <> 'paid' then return new; end if;
  select event.title into event_name from public.special_events event where event.id = new.event_id;
  perform public.enqueue_personal_books_purchase(
    'special_event_payment', new.id, booking_row.user_id, booking_row.organization_id, new.amount, new.currency,
    coalesce(new.paid_at::date, booking_row.created_at::date),
    'event booking ' || booking_row.order_number || ' — ' || coalesce(event_name, 'event'),
    '/books?organization=' || booking_row.organization_id::text
  );
  return new;
end;
$$;
revoke all on function public.record_paid_event_purchase_in_personal_books() from public, anon, authenticated;
drop trigger if exists record_paid_event_purchase_in_personal_books on public.special_event_payments;
create trigger record_paid_event_purchase_in_personal_books
after insert or update of status on public.special_event_payments
for each row execute function public.record_paid_event_purchase_in_personal_books();

create or replace function public.reverse_personal_books_purchase(target_source_type text, target_source_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  purchase_record public.books_personal_purchase_records%rowtype;
  original_journal_id uuid;
  reversal_journal_id uuid;
  original_line_count integer;
begin
  select * into purchase_record
    from public.books_personal_purchase_records
   where source_type = target_source_type and source_id = target_source_id
   for update;
  if not found or purchase_record.status = 'reversed' or purchase_record.expense_id is null then return; end if;

  select transaction.id into original_journal_id
    from public.books_journal_transactions transaction
   where transaction.organization_id = purchase_record.personal_organization_id
     and transaction.source_type = 'expense'
     and transaction.source_id = purchase_record.expense_id;
  if original_journal_id is null then raise exception 'Original personal expense journal is missing'; end if;

  insert into public.books_journal_transactions (
    organization_id, source_type, source_id, transaction_date, description, created_by
  ) values (
    purchase_record.personal_organization_id, 'expense_refund', purchase_record.expense_id,
    current_date, 'Refund reversal: ' || purchase_record.description,
    (select organization.owner_id from public.books_organizations organization where organization.id = purchase_record.personal_organization_id)
  )
  on conflict do nothing returning id into reversal_journal_id;

  if reversal_journal_id is null then
    select transaction.id into reversal_journal_id
      from public.books_journal_transactions transaction
     where transaction.organization_id = purchase_record.personal_organization_id
       and transaction.source_type = 'expense_refund'
       and transaction.source_id = purchase_record.expense_id;
  else
    insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
    select reversal_journal_id, line.account_id, line.credit, line.debit, line.currency_code, line.exchange_rate
      from public.books_journal_lines line
     where line.transaction_id = original_journal_id;
    get diagnostics original_line_count = row_count;
    if original_line_count = 0 then raise exception 'Original personal expense journal has no lines'; end if;
  end if;

  update public.books_expenses set payment_status = 'refunded' where id = purchase_record.expense_id;
  update public.books_personal_purchase_records set status = 'reversed', updated_at = now(), error_message = null where id = purchase_record.id;
  insert into public.notifications (user_id, type, message, action_url)
  values (
    purchase_record.buyer_user_id,
    'personal_purchase_refunded',
    'A refund reversal was recorded in Personal Books for ' || purchase_record.description || '.',
    '/books?workspace=personal'
  );
end;
$$;
revoke all on function public.reverse_personal_books_purchase(text, uuid) from public, anon, authenticated;

create or replace function public.reverse_refunded_menu_purchase_in_personal_books()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if new.payment_status in ('refunded', 'chargeback') and old.payment_status is distinct from new.payment_status then
    perform public.reverse_personal_books_purchase('menu_order', new.id);
  end if;
  return new;
end;
$$;
revoke all on function public.reverse_refunded_menu_purchase_in_personal_books() from public, anon, authenticated;
drop trigger if exists reverse_refunded_menu_purchase_in_personal_books on public.menu_orders;
create trigger reverse_refunded_menu_purchase_in_personal_books
after update of payment_status on public.menu_orders
for each row execute function public.reverse_refunded_menu_purchase_in_personal_books();

create or replace function public.reverse_refunded_hotel_purchase_in_personal_books()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if new.payment_status in ('refunded', 'chargeback') and old.payment_status is distinct from new.payment_status then
    perform public.reverse_personal_books_purchase('hotel_booking', new.id);
  end if;
  return new;
end;
$$;
revoke all on function public.reverse_refunded_hotel_purchase_in_personal_books() from public, anon, authenticated;
drop trigger if exists reverse_refunded_hotel_purchase_in_personal_books on public.hotel_bookings;
create trigger reverse_refunded_hotel_purchase_in_personal_books
after update of payment_status on public.hotel_bookings
for each row execute function public.reverse_refunded_hotel_purchase_in_personal_books();

create or replace function public.reverse_refunded_event_purchase_in_personal_books()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if new.status = 'refunded' and old.status is distinct from 'refunded' then
    perform public.reverse_personal_books_purchase('special_event_payment', new.id);
  end if;
  return new;
end;
$$;
revoke all on function public.reverse_refunded_event_purchase_in_personal_books() from public, anon, authenticated;
drop trigger if exists reverse_refunded_event_purchase_in_personal_books on public.special_event_payments;
create trigger reverse_refunded_event_purchase_in_personal_books
after update of status on public.special_event_payments
for each row execute function public.reverse_refunded_event_purchase_in_personal_books();

create or replace function public.notify_hotel_loyalty_purchase_activity()
returns trigger language plpgsql security definer set search_path = public
as $$
declare current_balance bigint;
begin
  if new.entry_type not in ('purchase_earn', 'purchase_reversal') then return new; end if;
  select account.available_points into current_balance
    from public.hotel_loyalty_accounts account
   where account.organization_id = new.organization_id and account.user_id = new.user_id;

  insert into public.notifications (user_id, type, message, action_url)
  values (
    new.user_id,
    'hotel_loyalty_activity',
    case when new.points_delta > 0 then 'You earned ' else 'A purchase refund reversed ' end || abs(new.points_delta)::text ||
      ' hotel loyalty points. Your current balance is ' || coalesce(current_balance, 0)::text || '.',
    '/profile?tab=hotel-rewards'
  );

  insert into public.notifications (user_id, type, message, action_url)
  select distinct membership.user_id,
    'hotel_loyalty_activity',
    'Hotel loyalty activity: ' || abs(new.points_delta)::text || ' points ' ||
      case when new.points_delta > 0 then 'earned' else 'reversed' end || ' for a member purchase.',
    '/management?tab=rewards'
  from public.books_memberships membership
  where membership.organization_id = new.organization_id
    and membership.role in ('owner', 'admin');
  return new;
end;
$$;
revoke all on function public.notify_hotel_loyalty_purchase_activity() from public, anon, authenticated;
drop trigger if exists notify_hotel_loyalty_purchase_activity on public.hotel_loyalty_ledger_entries;
create trigger notify_hotel_loyalty_purchase_activity
after insert on public.hotel_loyalty_ledger_entries
for each row execute function public.notify_hotel_loyalty_purchase_activity();

create or replace function public.retry_personal_books_purchase_record(target_record_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare purchase_row public.books_personal_purchase_records%rowtype;
begin
  if auth.role() <> 'service_role' then raise exception 'Only the service role may retry personal Books purchase posting'; end if;
  select * into purchase_row from public.books_personal_purchase_records where id = target_record_id for update;
  if not found then raise exception 'Purchase record was not found'; end if;
  if purchase_row.status = 'reversed' then return 'reversed'; end if;
  return public.process_personal_books_purchase_record(target_record_id);
end;
$$;
revoke all on function public.retry_personal_books_purchase_record(uuid) from public, anon, authenticated;
grant execute on function public.retry_personal_books_purchase_record(uuid) to service_role;

create or replace function public.get_books_currency_totals(target_organization_id uuid)
returns table (
  currency_code char(3), invoice_total numeric, income numeric, expenses numeric,
  net_result numeric, tax_total numeric, receivables numeric, assets numeric,
  liabilities numeric, equity numeric
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = target_organization_id and membership.user_id = auth.uid()
  ) then raise exception 'Not authorized for this Books organization'; end if;

  return query
  with invoice_totals as (
    select invoice.currency_code::char(3) as currency_code,
      sum(invoice.total) filter (where invoice.status <> 'void') as invoice_total,
      sum(invoice.subtotal) filter (where invoice.status in ('sent', 'overdue', 'paid')) as income,
      sum(invoice.tax_amount + invoice.other_charges) filter (where invoice.status <> 'void') as tax_total,
      sum(invoice.total) filter (where invoice.status in ('sent', 'overdue')) as receivables
    from public.books_invoices invoice
    where invoice.organization_id = target_organization_id
    group by invoice.currency_code
  ), expense_totals as (
    select expense.currency_code::char(3) as currency_code,
      sum(expense.amount + expense.tax_amount) as expenses
    from public.books_expenses expense
    where expense.organization_id = target_organization_id and expense.payment_status <> 'refunded'
    group by expense.currency_code
  ), ledger_totals as (
    select line.currency_code::char(3) as currency_code,
      sum(line.credit - line.debit) filter (where account.type = 'income') as income,
      sum(line.debit - line.credit) filter (where account.type = 'expense') as expenses,
      sum(line.debit - line.credit) filter (where account.type = 'asset') as assets,
      sum(line.credit - line.debit) filter (where account.type = 'liability') as liabilities,
      sum(line.credit - line.debit) filter (where account.type = 'equity') as equity
    from public.books_journal_lines line
    join public.books_journal_transactions transaction on transaction.id = line.transaction_id
    join public.books_accounts account on account.id = line.account_id
    where transaction.organization_id = target_organization_id
    group by line.currency_code
  ), currencies as (
    select currency_code from invoice_totals
    union select currency_code from expense_totals
    union select currency_code from ledger_totals
  )
  select currencies.currency_code,
    coalesce(invoice_totals.invoice_total, 0), coalesce(invoice_totals.income, 0), coalesce(expense_totals.expenses, 0),
    coalesce(invoice_totals.income, 0) - coalesce(expense_totals.expenses, 0),
    coalesce(invoice_totals.tax_total, 0), coalesce(invoice_totals.receivables, 0),
    coalesce(ledger_totals.assets, 0), coalesce(ledger_totals.liabilities, 0),
    coalesce(ledger_totals.equity, 0) + coalesce(invoice_totals.income, 0) - coalesce(expense_totals.expenses, 0)
  from currencies
  left join invoice_totals using (currency_code)
  left join expense_totals using (currency_code)
  left join ledger_totals using (currency_code)
  order by currencies.currency_code;
end;
$$;
revoke all on function public.get_books_currency_totals(uuid) from public, anon;
grant execute on function public.get_books_currency_totals(uuid) to authenticated;

notify pgrst, 'reload schema';
commit;

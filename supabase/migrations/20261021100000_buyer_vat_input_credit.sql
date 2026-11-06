begin;

alter table public.books_organizations
  add column if not exists vat_registered boolean not null default false;

alter table public.books_expenses
  add column if not exists vat_recoverable boolean not null default false;

alter table public.books_personal_purchase_records
  add column if not exists vat_rate_percentage numeric(8,4),
  add column if not exists vat_amount numeric(20,4) not null default 0;

alter table public.books_personal_purchase_records
  drop constraint if exists books_personal_purchase_records_vat_amount_check;
alter table public.books_personal_purchase_records
  add constraint books_personal_purchase_records_vat_amount_check
  check (vat_amount >= 0 and vat_amount <= amount);

create or replace function public.set_books_vat_registration(
  target_organization_id uuid,
  target_vat_registered boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
      from public.books_memberships membership
     where membership.organization_id = target_organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin')
  ) then
    raise exception 'Only owners or admins can change VAT registration';
  end if;

  update public.books_organizations
     set vat_registered = target_vat_registered
   where id = target_organization_id;
end;
$$;
revoke all on function public.set_books_vat_registration(uuid, boolean) from public, anon;
grant execute on function public.set_books_vat_registration(uuid, boolean) to authenticated;

create or replace function public.post_books_expense()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  journal_id uuid;
  expense_account_id uuid;
  input_vat_account_id uuid;
  cash_account_id uuid;
begin
  if not new.vat_recoverable or new.tax_amount <= 0 then
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
  end if;

  select id into expense_account_id from public.books_accounts
   where organization_id = new.organization_id and code = '5000' and type = 'expense';
  select id into input_vat_account_id from public.books_accounts
   where organization_id = new.organization_id and code = '1400' and type = 'asset';
  select id into cash_account_id from public.books_accounts
   where organization_id = new.organization_id and code = '1000' and type = 'asset';
  if expense_account_id is null or input_vat_account_id is null or cash_account_id is null then
    raise exception 'Required Books account is missing';
  end if;

  insert into public.books_journal_transactions (
    organization_id, source_type, source_id, transaction_date, description, created_by
  ) values (
    new.organization_id, 'expense', new.id, new.expense_date, 'Expense: ' || new.description,
    coalesce(auth.uid(), (select owner_id from public.books_organizations where id = new.organization_id))
  )
  on conflict do nothing
  returning id into journal_id;
  if journal_id is null then return new; end if;

  insert into public.books_journal_lines (transaction_id, account_id, debit, currency_code)
  values
    (journal_id, expense_account_id, new.amount, new.currency_code),
    (journal_id, input_vat_account_id, new.tax_amount, new.currency_code);
  insert into public.books_journal_lines (transaction_id, account_id, credit, currency_code)
  values (journal_id, cash_account_id, new.amount + new.tax_amount, new.currency_code);
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
  target_vendor_name text;
  target_vendor_contact_id uuid;
  expense_description text;
  item_details text;
  menu_order public.menu_orders%rowtype;
  buyer_vat_registered boolean;
  purchase_vat_rate numeric;
  purchase_vat_amount numeric;
  vat_base numeric;
  recoverable boolean;
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

  select organization.name
    into target_vendor_name
    from public.books_organizations organization
   where organization.id = purchase_row.hotel_organization_id;
  perform pg_advisory_xact_lock(hashtextextended(
    'personal-books-vendor:' || target_personal_organization_id::text || ':' || lower(target_vendor_name), 0
  ));
  select contact.id into target_vendor_contact_id
    from public.books_contacts contact
   where contact.organization_id = target_personal_organization_id
     and lower(contact.name) = lower(target_vendor_name)
     and contact.type in ('vendor', 'both')
   order by contact.created_at
   limit 1;
  if target_vendor_contact_id is null then
    insert into public.books_contacts (organization_id, name, type)
    values (target_personal_organization_id, target_vendor_name, 'vendor')
    returning id into target_vendor_contact_id;
  end if;

  select organization.vat_registered into buyer_vat_registered
    from public.books_organizations organization
   where organization.id = target_personal_organization_id;

  if purchase_row.source_type = 'hotel_booking' then
    select booking.vat_rate_percentage, booking.vat_amount
      into purchase_vat_rate, purchase_vat_amount
      from public.hotel_bookings booking
     where booking.id = purchase_row.source_id;
  else
    if purchase_row.source_type = 'menu_order' then
      select * into menu_order from public.menu_orders where id = purchase_row.source_id;
      vat_base := menu_order.subtotal + menu_order.tax_amount - menu_order.points_discount;
    else
      vat_base := purchase_row.amount;
    end if;
    vat_base := least(greatest(coalesce(vat_base, 0), 0), purchase_row.amount);
    purchase_vat_rate := public.books_confirmed_invoice_vat_rate(
      purchase_row.hotel_organization_id, purchase_row.purchase_date
    );
    if purchase_vat_rate is not null then
      purchase_vat_amount := vat_base - round(
        vat_base / (1 + purchase_vat_rate / 100),
        public.checkout_currency_minor_units(purchase_row.currency_code)
      );
    end if;
  end if;
  purchase_vat_amount := least(coalesce(purchase_vat_amount, 0), purchase_row.amount);
  recoverable := coalesce(buyer_vat_registered, false) and purchase_vat_amount > 0;

  expense_description := purchase_row.description;
  if purchase_row.source_type = 'menu_order' then
    select string_agg(
      format('%s (%s × %s)', item.item_name, item.quantity, to_char(item.unit_price, 'FM999999999999990D00')),
      ', ' order by item.created_at, item.id
    ) into item_details
      from public.menu_order_items item
     where item.order_id = purchase_row.source_id;
    expense_description := concat_ws(' — ', purchase_row.description, nullif(item_details, '')) ||
      ' | Subtotal: ' || to_char(menu_order.subtotal, 'FM999999999999990D00') || ' ' || purchase_row.currency_code ||
      '; tax: ' || to_char(menu_order.tax_amount, 'FM999999999999990D00') || ' ' || purchase_row.currency_code ||
      '; service fee: ' || to_char(menu_order.service_fee, 'FM999999999999990D00') || ' ' || purchase_row.currency_code ||
      '; tip: ' || to_char(menu_order.tip_amount, 'FM999999999999990D00') || ' ' || purchase_row.currency_code;
  end if;

  if recoverable then
    insert into public.books_accounts (organization_id, code, name, type, is_system)
    values (target_personal_organization_id, '1400', 'Input VAT recoverable', 'asset', true)
    on conflict (organization_id, code) do nothing;
  end if;

  insert into public.books_expenses (
    organization_id, contact_id, description, expense_date, currency_code, amount, tax_amount,
    vat_recoverable, payment_status, purchase_source_type, purchase_source_id
  ) values (
    target_personal_organization_id,
    target_vendor_contact_id,
    expense_description,
    purchase_row.purchase_date,
    purchase_row.currency_code,
    case when recoverable then purchase_row.amount - purchase_vat_amount else purchase_row.amount end,
    case when recoverable then purchase_vat_amount else 0 end,
    recoverable,
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
         vat_rate_percentage = purchase_vat_rate,
         vat_amount = purchase_vat_amount,
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

create or replace function public.get_books_currency_totals(target_organization_id uuid)
returns table (
  currency_code char(3),
  invoice_total numeric,
  income numeric,
  expenses numeric,
  net_result numeric,
  tax_total numeric,
  receivables numeric,
  assets numeric,
  liabilities numeric,
  equity numeric
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if auth.uid() is null or not exists (
    select 1
    from public.books_organizations organization
    where organization.id = target_organization_id
      and (
        organization.owner_id = auth.uid()
        or exists (
          select 1
          from public.books_memberships membership
          where membership.organization_id = organization.id
            and membership.user_id = auth.uid()
        )
      )
  ) then
    raise exception 'Not authorized for this Books organization' using errcode = '42501';
  end if;

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
      sum(expense.amount + case when expense.vat_recoverable then 0 else expense.tax_amount end) as expenses
    from public.books_expenses expense
    where expense.organization_id = target_organization_id
      and expense.payment_status <> 'refunded'
    group by expense.currency_code
  ), ledger_totals as (
    select journal_line.currency_code::char(3) as currency_code,
      sum(journal_line.credit - journal_line.debit) filter (where account.type = 'income') as income,
      sum(journal_line.debit - journal_line.credit) filter (where account.type = 'expense') as expenses,
      sum(journal_line.debit - journal_line.credit) filter (where account.type = 'asset') as assets,
      sum(journal_line.credit - journal_line.debit) filter (where account.type = 'liability') as liabilities,
      sum(journal_line.credit - journal_line.debit) filter (where account.type = 'equity') as equity
    from public.books_journal_lines journal_line
    join public.books_journal_transactions journal_transaction
      on journal_transaction.id = journal_line.transaction_id
    join public.books_accounts account on account.id = journal_line.account_id
    where journal_transaction.organization_id = target_organization_id
    group by journal_line.currency_code
  ), currencies as (
    select invoice_totals.currency_code from invoice_totals
    union
    select expense_totals.currency_code from expense_totals
    union
    select ledger_totals.currency_code from ledger_totals
  ), base_currency as (
    select organization.base_currency::char(3) as currency_code
    from public.books_organizations organization
    where organization.id = target_organization_id
  )
  select currencies.currency_code,
    coalesce(invoice_totals.invoice_total, 0),
    coalesce(invoice_totals.income, 0),
    coalesce(expense_totals.expenses, 0),
    coalesce(invoice_totals.income, 0) - coalesce(expense_totals.expenses, 0),
    coalesce(invoice_totals.tax_total, 0),
    coalesce(invoice_totals.receivables, 0),
    coalesce(ledger_totals.assets, 0),
    coalesce(ledger_totals.liabilities, 0),
    coalesce(ledger_totals.equity, 0) + coalesce(invoice_totals.income, 0) - coalesce(expense_totals.expenses, 0)
  from currencies
  left join invoice_totals
    on invoice_totals.currency_code = currencies.currency_code
  left join expense_totals
    on expense_totals.currency_code = currencies.currency_code
  left join ledger_totals
    on ledger_totals.currency_code = currencies.currency_code

  union all

  select base_currency.currency_code, 0, 0, 0, 0, 0, 0, 0, 0, 0
  from base_currency
  where not exists (select 1 from currencies)
  order by 1;
end;
$$;

revoke all on function public.get_books_currency_totals(uuid) from public, anon, authenticated;
grant execute on function public.get_books_currency_totals(uuid) to authenticated;

notify pgrst, 'reload schema';
commit;

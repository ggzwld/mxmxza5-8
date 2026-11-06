begin;

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
      sum(expense.amount + expense.tax_amount) as expenses
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
    select currency_code from invoice_totals
    union
    select currency_code from expense_totals
    union
    select currency_code from ledger_totals
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
  left join invoice_totals using (currency_code)
  left join expense_totals using (currency_code)
  left join ledger_totals using (currency_code)

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

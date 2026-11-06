create or replace function public.post_sales_invoice_recognition(target_invoice_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare
  invoice_row public.books_invoices%rowtype;
  owner_user_id uuid;
  journal_id uuid;
  receivable_id uuid;
  revenue_id uuid;
  vat_payable_id uuid;
  other_charges_account_code text;
  other_charges_account_id uuid;
  vat_rate numeric;
  service_fee_amount numeric := 0;
  taxable_gross numeric;
  revenue_amount numeric;
  vat_amount numeric;
  non_vat_other_charges numeric;
begin
  select * into invoice_row from public.books_invoices where id = target_invoice_id;
  if not found or invoice_row.status <> 'paid' or invoice_row.invoice_number !~ '^(HOTEL|MENU|EVENT)-' then return; end if;
  if exists (
    select 1 from public.books_journal_transactions
     where organization_id = invoice_row.organization_id
       and source_type in ('hotel_invoice_recognition', 'sales_invoice_recognition')
       and source_id = invoice_row.id
  ) then return; end if;

  if invoice_row.invoice_number like 'HOTEL-%' then
    revenue_amount := invoice_row.subtotal;
    vat_amount := invoice_row.tax_amount;
  else
    vat_rate := public.books_confirmed_invoice_vat_rate(invoice_row.organization_id, invoice_row.issue_date);
    if vat_rate is null then
      raise notice 'Skipped sales recognition for %: no confirmed VAT rate on the effective date', invoice_row.invoice_number;
      return;
    end if;
    select coalesce(sum(menu_order.service_fee), 0) into service_fee_amount
      from public.menu_orders as menu_order
     where menu_order.books_invoice_id = invoice_row.id;
    taxable_gross := invoice_row.subtotal + invoice_row.tax_amount + service_fee_amount;
    revenue_amount := round(taxable_gross / (1 + vat_rate / 100),
      public.checkout_currency_minor_units(invoice_row.currency_code));
    vat_amount := taxable_gross - revenue_amount;
  end if;
  non_vat_other_charges := invoice_row.other_charges - service_fee_amount;

  select owner_id into owner_user_id from public.books_organizations where id = invoice_row.organization_id;
  insert into public.books_accounts (organization_id, code, name, type, is_system)
  values
    (invoice_row.organization_id, '1000', 'Cash and bank', 'asset', true),
    (invoice_row.organization_id, '1100', 'Accounts receivable', 'asset', true),
    (invoice_row.organization_id, '2100', 'VAT payable', 'liability', true),
    (invoice_row.organization_id, '2200', 'Local hotel tax payable', 'liability', true),
    (invoice_row.organization_id, '2300', 'Service fees and tips payable', 'liability', true),
    (invoice_row.organization_id, '4000', 'Sales revenue', 'income', true)
  on conflict (organization_id, code) do nothing;

  other_charges_account_code := case when invoice_row.invoice_number like 'HOTEL-%' then '2200' else '2300' end;
  select id into receivable_id from public.books_accounts where organization_id = invoice_row.organization_id and code = '1100' and type = 'asset';
  select id into revenue_id from public.books_accounts where organization_id = invoice_row.organization_id and code = '4000' and type = 'income';
  select id into vat_payable_id from public.books_accounts where organization_id = invoice_row.organization_id and code = '2100' and type = 'liability';
  select id into other_charges_account_id from public.books_accounts where organization_id = invoice_row.organization_id and code = other_charges_account_code and type = 'liability';
  if receivable_id is null or revenue_id is null or vat_payable_id is null or other_charges_account_id is null then
    raise exception 'Required Books accounts are missing for the sales invoice';
  end if;

  insert into public.books_journal_transactions (organization_id, source_type, source_id, transaction_date, description, created_by)
  values (invoice_row.organization_id, 'sales_invoice_recognition', invoice_row.id, invoice_row.issue_date, 'Recognize sales invoice ' || invoice_row.invoice_number, owner_user_id)
  on conflict do nothing returning id into journal_id;
  if journal_id is null then return; end if;

  insert into public.books_journal_lines (transaction_id, account_id, debit, currency_code)
  values (journal_id, receivable_id, invoice_row.subtotal + invoice_row.tax_amount + invoice_row.other_charges, invoice_row.currency_code);
  if revenue_amount > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, credit, currency_code)
    values (journal_id, revenue_id, revenue_amount, invoice_row.currency_code);
  end if;
  if vat_amount > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, credit, currency_code)
    values (journal_id, vat_payable_id, vat_amount, invoice_row.currency_code);
  end if;
  if non_vat_other_charges > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, credit, currency_code)
    values (journal_id, other_charges_account_id, non_vat_other_charges, invoice_row.currency_code);
  end if;
end;
$$;
revoke all on function public.post_sales_invoice_recognition(uuid) from public, anon, authenticated;

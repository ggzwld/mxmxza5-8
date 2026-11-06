begin;

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

notify pgrst, 'reload schema';
commit;

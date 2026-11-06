alter table public.books_expenses
  add column if not exists tax_treatment text not null default 'review';

alter table public.books_expenses
  drop constraint if exists books_expenses_tax_treatment_check;

alter table public.books_expenses
  add constraint books_expenses_tax_treatment_check
  check (tax_treatment in ('deductible', 'non_deductible', 'review'));

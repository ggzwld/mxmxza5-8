alter table public.books_organizations
  add column if not exists tax_country_code char(2),
  add column if not exists tax_entity_type text,
  add column if not exists income_tax_regime_confirmed_at timestamptz;

update public.books_organizations
   set tax_country_code = upper(country_code::text)
 where tax_country_code is null;

alter table public.books_organizations
  drop constraint if exists books_organizations_tax_entity_type_check;
alter table public.books_organizations
  add constraint books_organizations_tax_entity_type_check
  check (tax_entity_type is null or tax_entity_type in ('individual', 'sole_proprietor', 'company', 'partnership', 'trust', 'ngo', 'other'));

alter table public.user_profiles
  add column if not exists tax_entity_type text;
alter table public.user_profiles
  drop constraint if exists user_profiles_tax_entity_type_check;
alter table public.user_profiles
  add constraint user_profiles_tax_entity_type_check
  check (tax_entity_type is null or tax_entity_type in ('individual', 'sole_proprietor', 'company', 'partnership', 'trust', 'ngo', 'other'));

create or replace function public.initialize_books_tax_entity_type()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.tax_country_code is null then
    new.tax_country_code := upper(new.country_code::text);
  end if;
  if new.tax_entity_type is null then
    select profile.tax_entity_type into new.tax_entity_type
      from public.user_profiles as profile
     where profile.user_id = new.owner_id;
  end if;
  return new;
end;
$$;

drop trigger if exists initialize_books_tax_entity_type on public.books_organizations;
create trigger initialize_books_tax_entity_type
before insert on public.books_organizations
for each row execute function public.initialize_books_tax_entity_type();
revoke all on function public.initialize_books_tax_entity_type() from public, anon, authenticated;

alter table public.books_tax_rates
  add column if not exists confirmed_at timestamptz,
  add column if not exists tax_scope text not null default 'other' check (tax_scope in ('invoice', 'other'));

update public.books_tax_rates
   set tax_scope = 'invoice'
 where tax_scope = 'other'
   and (name ilike '%VAT%' or name ilike '%sales tax%');

alter table public.books_tax_rates enable row level security;
drop policy if exists books_tax_rates_member on public.books_tax_rates;
drop policy if exists books_tax_rates_member_select on public.books_tax_rates;
create policy books_tax_rates_member_select
  on public.books_tax_rates for select to authenticated
  using (organization_id in (select public.user_books_organization_ids()));
revoke insert, update, delete on public.books_tax_rates from public, anon, authenticated;
grant select on public.books_tax_rates to authenticated;

insert into public.books_tax_rates (
  organization_id, country_code, name, rate_percentage, effective_from, is_active, confirmed_at, tax_scope
)
select organization.id, 'UG', 'URA VAT · suggested default', 18, current_date, true, null, 'invoice'
  from public.books_organizations as organization
 where organization.tax_country_code = 'UG'
   and not exists (
     select 1 from public.books_tax_rates as rate
      where rate.organization_id = organization.id
        and rate.country_code = 'UG'
        and rate.tax_scope = 'invoice'
        and rate.is_active
        and rate.effective_from <= current_date
        and (rate.effective_to is null or rate.effective_to >= current_date)
   );

create or replace function public.seed_books_tax_rates(target_organization_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not exists (select 1 from public.books_memberships where organization_id = target_organization_id and user_id = auth.uid()) then
    raise exception 'Not authorized for this Books organization';
  end if;
  insert into public.books_tax_rates (organization_id, country_code, name, rate_percentage, effective_from, confirmed_at, tax_scope)
  select organization.id, organization.tax_country_code, 'URA VAT · suggested default', 18, current_date, null, 'invoice'
    from public.books_organizations as organization
   where organization.id = target_organization_id
     and organization.tax_country_code = 'UG'
     and not exists (
       select 1 from public.books_tax_rates as rate
        where rate.organization_id = organization.id
          and rate.country_code = organization.tax_country_code
          and rate.tax_scope = 'invoice'
          and rate.is_active
          and rate.effective_from <= current_date
          and (rate.effective_to is null or rate.effective_to >= current_date)
     );
end;
$$;

create or replace function public.seed_books_tax_default_for_new_organization()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.tax_country_code = 'UG' then
    insert into public.books_tax_rates (organization_id, country_code, name, rate_percentage, effective_from, confirmed_at, tax_scope)
    values (new.id, 'UG', 'URA VAT · suggested default', 18, current_date, null, 'invoice');
  end if;
  return new;
end;
$$;
revoke all on function public.seed_books_tax_default_for_new_organization() from public, anon, authenticated;
drop trigger if exists seed_books_tax_default_for_new_organization on public.books_organizations;
create trigger seed_books_tax_default_for_new_organization
after insert on public.books_organizations
for each row execute function public.seed_books_tax_default_for_new_organization();

create table if not exists public.books_income_tax_rates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.books_organizations(id) on delete cascade,
  country_code char(2) not null,
  tax_entity_type text not null check (tax_entity_type in ('company', 'individual', 'sole_proprietor', 'partnership', 'trust', 'ngo', 'other')),
  name text not null,
  rate_method text not null check (rate_method in ('flat', 'progressive')),
  rate_schedule jsonb not null check (jsonb_typeof(rate_schedule) = 'array'),
  effective_from date not null,
  effective_to date,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from),
  unique (organization_id, tax_entity_type, effective_from)
);

alter table public.books_income_tax_rates enable row level security;
drop policy if exists books_income_tax_rates_member_select on public.books_income_tax_rates;
create policy books_income_tax_rates_member_select
  on public.books_income_tax_rates for select to authenticated
  using (organization_id in (select public.user_books_organization_ids()));
revoke insert, update, delete on public.books_income_tax_rates from public, anon, authenticated;
grant select on public.books_income_tax_rates to authenticated;

create or replace function public.update_books_tax_profile(
  target_organization_id uuid,
  target_country_code text,
  target_tax_entity_type text
)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if target_country_code is null or target_country_code !~ '^[A-Z]{2}$'
     or (target_tax_entity_type is not null and target_tax_entity_type not in ('individual', 'sole_proprietor', 'company', 'partnership', 'trust', 'ngo', 'other')) then
    raise exception 'Select a valid tax jurisdiction and entity type';
  end if;
  if not exists (
    select 1 from public.books_memberships as membership
     where membership.organization_id = target_organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin')
  ) then
    raise exception 'Only a Books owner or administrator can change the tax profile';
  end if;
  update public.books_organizations
     set tax_country_code = target_country_code,
         tax_entity_type = target_tax_entity_type,
         income_tax_regime_confirmed_at = null
   where id = target_organization_id;
end;
$$;
revoke all on function public.update_books_tax_profile(uuid, text, text) from public, anon;
grant execute on function public.update_books_tax_profile(uuid, text, text) to authenticated;

create or replace function public.save_books_vat_rate(
  target_organization_id uuid,
  target_name text,
  target_rate_percentage numeric,
  target_effective_from date,
  target_country_code text default 'UG'
)
returns uuid language plpgsql security definer set search_path = public
as $$
declare rate_id uuid;
begin
  if not exists (
    select 1 from public.books_memberships as membership
     where membership.organization_id = target_organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin')
  ) then
    raise exception 'Only a Books owner or administrator can change tax rates';
  end if;
  if not exists (select 1 from public.books_organizations as organization where organization.id = target_organization_id and organization.tax_country_code = target_country_code) then
    raise exception 'VAT rate jurisdiction must match the saved Books tax profile';
  end if;
  if nullif(trim(target_name), '') is null or target_rate_percentage is null or target_rate_percentage < 0 or target_rate_percentage > 100
     or target_effective_from is null or target_country_code is null or target_country_code !~ '^[A-Z]{2}$' then
    raise exception 'Enter a valid tax name, country code, and rate';
  end if;
  if target_effective_from < current_date then
    raise exception 'New rates cannot be entered with a past effective date';
  end if;
  if exists (
    select 1 from public.books_tax_rates as future_rate
     where future_rate.organization_id = target_organization_id
       and future_rate.country_code = target_country_code
       and future_rate.tax_scope = 'invoice'
       and future_rate.effective_from > target_effective_from
       and future_rate.is_active
  ) then
    raise exception 'Add new rates after the latest scheduled rate date';
  end if;
  select id into rate_id from public.books_tax_rates
   where organization_id = target_organization_id
     and country_code = target_country_code
     and tax_scope = 'invoice'
     and is_active
     and effective_from = target_effective_from
   order by confirmed_at nulls first, created_at
   limit 1
   for update;

  update public.books_tax_rates
     set is_active = false
   where organization_id = target_organization_id
     and country_code = target_country_code
     and tax_scope = 'invoice'
     and is_active
     and effective_from = target_effective_from
     and id is distinct from rate_id;

  update public.books_tax_rates
     set effective_to = target_effective_from - 1
   where organization_id = target_organization_id
     and country_code = target_country_code
     and tax_scope = 'invoice'
     and is_active
     and effective_from < target_effective_from
     and (effective_to is null or effective_to >= target_effective_from);

  if rate_id is not null then
    update public.books_tax_rates
       set name = trim(target_name), rate_percentage = target_rate_percentage,
           effective_to = null, is_active = true, confirmed_at = now()
     where id = rate_id;
  else
    insert into public.books_tax_rates (
      organization_id, country_code, name, rate_percentage, effective_from,
      effective_to, is_active, confirmed_at, tax_scope
    ) values (
      target_organization_id, target_country_code, trim(target_name), target_rate_percentage,
      target_effective_from, null, true, now(), 'invoice'
    ) on conflict (organization_id, name, effective_from) do update set
      rate_percentage = excluded.rate_percentage,
      effective_to = null,
      is_active = true,
      confirmed_at = excluded.confirmed_at,
      tax_scope = 'invoice'
    returning id into rate_id;
  end if;
  return rate_id;
end;
$$;
revoke all on function public.save_books_vat_rate(uuid, text, numeric, date, text) from public, anon;
grant execute on function public.save_books_vat_rate(uuid, text, numeric, date, text) to authenticated;

create or replace function public.confirm_books_vat_rate(target_organization_id uuid, target_rate_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare selected_rate public.books_tax_rates%rowtype;
begin
  if not exists (
    select 1 from public.books_memberships as membership
     where membership.organization_id = target_organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin')
  ) then
    raise exception 'Only a Books owner or administrator can confirm tax rates';
  end if;
  select * into selected_rate from public.books_tax_rates
   where id = target_rate_id and organization_id = target_organization_id and is_active
     and tax_scope = 'invoice'
     and country_code = (select organization.tax_country_code from public.books_organizations as organization where organization.id = target_organization_id)
     and effective_from <= current_date
     and (effective_to is null or effective_to >= current_date);
  if not found then raise exception 'An active invoice-tax rate for today was not found'; end if;
  update public.books_tax_rates
     set confirmed_at = now()
   where id = target_rate_id;
end;
$$;
revoke all on function public.confirm_books_vat_rate(uuid, uuid) from public, anon;
grant execute on function public.confirm_books_vat_rate(uuid, uuid) to authenticated;

create or replace function public.save_books_income_tax_schedule(
  target_organization_id uuid,
  target_name text,
  target_tax_entity_type text,
  target_rate_method text,
  target_effective_from date,
  target_rate_schedule jsonb
)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  rate_id uuid;
  country text;
  bracket jsonb;
  bracket_count integer := 0;
  lower_bound numeric;
  upper_bound numeric;
  rate_percentage numeric;
  base_tax numeric;
  previous_upper numeric;
  previous_rate numeric;
  previous_base numeric;
  final_upper numeric;
begin
  if not exists (
    select 1 from public.books_memberships as membership
     where membership.organization_id = target_organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin')
  ) then
    raise exception 'Only a Books owner or administrator can change income-tax rates';
  end if;
  if target_tax_entity_type is null
     or target_tax_entity_type not in ('company', 'individual', 'sole_proprietor', 'partnership', 'trust', 'ngo', 'other')
     or target_rate_method is null or target_rate_method not in ('flat', 'progressive')
     or nullif(trim(target_name), '') is null or target_effective_from is null
     or target_rate_schedule is null or jsonb_typeof(target_rate_schedule) <> 'array' then
    raise exception 'Enter a valid income-tax schedule';
  end if;
  select tax_country_code into country
    from public.books_organizations
   where id = target_organization_id and tax_entity_type = target_tax_entity_type;
  if not found then
    raise exception 'Save this entity type in the Books tax profile first';
  end if;

  if target_effective_from < current_date then
    raise exception 'New income-tax schedules cannot have a past effective date';
  end if;
  if exists (
    select 1 from public.books_income_tax_rates as future_rate
     where future_rate.organization_id = target_organization_id
       and future_rate.tax_entity_type = target_tax_entity_type
       and future_rate.effective_from > target_effective_from
  ) then
    raise exception 'Add schedules after the latest scheduled date for this entity';
  end if;

  for bracket in select value from jsonb_array_elements(target_rate_schedule) loop
    bracket_count := bracket_count + 1;
    lower_bound := nullif(bracket ->> 'lower_bound', '')::numeric;
    upper_bound := nullif(bracket ->> 'upper_bound', 'null')::numeric;
    rate_percentage := nullif(bracket ->> 'rate_percentage', '')::numeric;
    base_tax := nullif(bracket ->> 'base_tax', '')::numeric;
    if lower_bound is null or rate_percentage is null or base_tax is null
       or lower_bound < 0
       or (upper_bound is not null and upper_bound <= lower_bound)
       or base_tax < 0
       or rate_percentage < 0 or rate_percentage > 100
       or (bracket_count = 1 and (lower_bound <> 0 or base_tax <> 0))
       or (bracket_count > 1 and (previous_upper is distinct from lower_bound or abs(base_tax - (previous_base + (lower_bound - previous_upper) * previous_rate / 100)) > 0.01)) then
      raise exception 'Income-tax brackets must be valid, ordered, contiguous, and mathematically consistent';
    end if;
    previous_upper := upper_bound;
    previous_rate := rate_percentage;
    previous_base := base_tax;
    final_upper := upper_bound;
  end loop;
  if bracket_count = 0 or final_upper is not null
     or (target_rate_method = 'flat' and bracket_count <> 1) then
    raise exception 'The income-tax schedule must cover all income and match its calculation method';
  end if;

  update public.books_income_tax_rates
     set effective_to = target_effective_from - 1
   where organization_id = target_organization_id
     and tax_entity_type = target_tax_entity_type
     and effective_from < target_effective_from
     and (effective_to is null or effective_to >= target_effective_from);
  insert into public.books_income_tax_rates (
    organization_id, country_code, tax_entity_type, name, rate_method,
    rate_schedule, effective_from, confirmed_at
  ) values (
    target_organization_id, country, target_tax_entity_type, trim(target_name),
    target_rate_method, target_rate_schedule, target_effective_from, now()
  ) on conflict (organization_id, tax_entity_type, effective_from) do update set
    country_code = excluded.country_code,
    name = excluded.name, rate_method = excluded.rate_method,
    rate_schedule = excluded.rate_schedule, effective_to = null,
    confirmed_at = excluded.confirmed_at
  returning id into rate_id;
  update public.books_organizations
     set income_tax_regime_confirmed_at = case
       when target_effective_from <= current_date then now()
       else income_tax_regime_confirmed_at
     end
   where id = target_organization_id;
  return rate_id;
end;
$$;
revoke all on function public.save_books_income_tax_schedule(uuid, text, text, text, date, jsonb) from public, anon;
grant execute on function public.save_books_income_tax_schedule(uuid, text, text, text, date, jsonb) to authenticated;

alter table public.hotel_bookings
  add column if not exists vat_rate_id uuid references public.books_tax_rates(id) on delete set null,
  add column if not exists vat_rate_percentage numeric(7,4) not null default 18 check (vat_rate_percentage >= 0 and vat_rate_percentage <= 100);

DO $$
declare
  function_source text;
  replacement_source text;
begin
  function_source := replace(pg_get_functiondef('public.create_hotel_booking(uuid,jsonb,date,date,integer,integer,text,jsonb,uuid,uuid,text,jsonb)'::regprocedure), E'\r', '');
  replacement_source := replace(function_source, '  vat_value numeric;', E'  vat_value numeric;\n  vat_rate_id uuid;\n  vat_rate_percentage numeric(7,4);');
  replacement_source := replace(replacement_source,
    '  vat_value := round(taxable_value * 0.18, currency_decimals);',
    E'  select rate.id, rate.rate_percentage into vat_rate_id, vat_rate_percentage\n    from public.books_tax_rates as rate\n    join public.books_organizations as organization on organization.id = rate.organization_id\n   where rate.organization_id = selected_room.organization_id\n     and rate.country_code = organization.tax_country_code\n     and rate.tax_scope = ''invoice''\n     and rate.is_active and rate.confirmed_at is not null\n     and rate.effective_from <= current_date\n     and (rate.effective_to is null or rate.effective_to >= current_date)\n   order by rate.effective_from desc, rate.confirmed_at desc\n   limit 1;\n  if vat_rate_id is null then raise exception ''Confirm an effective invoice-tax rate before accepting room bookings''; end if;\n  vat_value := round(taxable_value * vat_rate_percentage / 100, currency_decimals);');
  replacement_source := replace(replacement_source,
    E'    vat_amount, lht_amount, total_amount, hotel_classification,\n    fx_rates_snapshot',
    E'    vat_amount, vat_rate_id, vat_rate_percentage, lht_amount, total_amount, hotel_classification,\n    fx_rates_snapshot');
  replacement_source := replace(replacement_source,
    E'    taxable_value, vat_value, lht_value, total_value,\n    selected_classification, target_fx_rates',
    E'    taxable_value, vat_value, vat_rate_id, vat_rate_percentage, lht_value, total_value,\n    selected_classification, target_fx_rates');
  if replacement_source = function_source
     or position('Confirm an effective invoice-tax rate before accepting room bookings' in replacement_source) = 0
     or position('vat_rate_percentage, lht_amount' in replacement_source) = 0
     or position('vat_value, vat_rate_id, vat_rate_percentage, lht_value' in replacement_source) = 0 then
    raise exception 'Could not safely apply confirmed VAT rates to hotel-booking creation';
  end if;
  execute replacement_source;

  function_source := replace(pg_get_functiondef('public.apply_books_invoice_tax()'::regprocedure), E'\r', '');
  replacement_source := replace(function_source,
    E'begin\n  if new.tax_rate_id is not null then',
    E'begin\n  if new.invoice_number like ''HOTEL-%'' then\n    select * into selected_booking from public.hotel_bookings\n     where ''HOTEL-'' || confirmation_number = new.invoice_number;\n    if found then\n      new.tax_rate_id := selected_booking.vat_rate_id;\n      new.tax_rate_percentage := selected_booking.vat_rate_percentage;\n      new.tax_amount := selected_booking.vat_amount;\n      return new;\n    end if;\n  end if;\n  if new.tax_rate_id is not null then');
  replacement_source := replace(replacement_source,
    E'       and organization_id = new.organization_id\n       and is_active',
    E'       and organization_id = new.organization_id\n       and (tax_scope <> ''invoice'' or confirmed_at is not null)\n       and is_active');
  if position('confirmed_at is not null' in replacement_source) = 0 then
    raise exception 'Could not require confirmation when applying invoice-tax rates';
  end if;
  if replacement_source = function_source then
    raise exception 'Could not safely preserve hotel invoice tax snapshots';
  end if;
  execute replacement_source;

  function_source := replace(pg_get_functiondef('public.enforce_checkout_invoice_totals()'::regprocedure), E'\r', '');
  replacement_source := replace(function_source,
    E'    new.subtotal := selected_hotel_booking.taxable_subtotal;\n    new.tax_rate_percentage := 18;',
    E'    new.subtotal := selected_hotel_booking.taxable_subtotal;\n    new.tax_rate_id := selected_hotel_booking.vat_rate_id;\n    new.tax_rate_percentage := selected_hotel_booking.vat_rate_percentage;');
  if replacement_source = function_source then
    raise exception 'Could not safely update hotel invoice rate snapshots';
  end if;
  execute replacement_source;
end;
$$;

create or replace function public.post_paid_hotel_booking_to_books()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  customer_contact_id uuid;
  invoice_uuid uuid;
  organization_name text;
  room_name text;
begin
  if new.payment_status <> 'paid' or new.books_invoice_id is not null then
    return new;
  end if;

  insert into public.books_accounts (organization_id, code, name, type, is_system)
  values
    (new.organization_id, '1000', 'Cash and bank', 'asset', true),
    (new.organization_id, '1100', 'Accounts receivable', 'asset', true),
    (new.organization_id, '2100', 'VAT payable', 'liability', true),
    (new.organization_id, '2200', 'Local hotel tax payable', 'liability', true),
    (new.organization_id, '4000', 'Sales revenue', 'income', true)
  on conflict (organization_id, code) do nothing;

  select name into organization_name from public.books_organizations where id = new.organization_id;
  select name into room_name from public.hotel_rooms where id = new.room_id;
  select id into customer_contact_id from public.books_contacts
   where organization_id = new.organization_id and lower(email) = lower(new.guest_email) and type in ('customer', 'both')
   order by created_at limit 1;
  if customer_contact_id is null then
    insert into public.books_contacts (organization_id, name, type, email, phone)
    values (new.organization_id, trim(new.guest_first_name || ' ' || new.guest_last_name), 'customer', new.guest_email, new.guest_phone)
    returning id into customer_contact_id;
  end if;

  insert into public.books_invoices (
    organization_id, contact_id, invoice_number, issue_date, due_date, currency_code, subtotal,
    tax_rate_id, tax_rate_percentage, other_charges, status, notes
  ) values (
    new.organization_id, customer_contact_id, 'HOTEL-' || new.confirmation_number, current_date, current_date,
    new.currency_code, new.taxable_subtotal, new.vat_rate_id, new.vat_rate_percentage, new.lht_amount, 'draft',
    'Room reservation ' || new.confirmation_number || ' at ' || coalesce(organization_name, 'Hotel') ||
    '. Room: ' || coalesce(room_name, 'Room') || '. Check-in ' || new.check_in::text ||
    ', check-out ' || new.check_out::text || '. Hotel classification: ' || new.hotel_classification || ' stars.'
  ) returning id into invoice_uuid;

  insert into public.books_invoice_lines (invoice_id, organization_id, description, quantity, unit_price)
  values (invoice_uuid, new.organization_id, 'Accommodation (' || new.nights || ' night(s))', 1, new.taxable_subtotal);
  update public.books_invoices set status = 'paid' where id = invoice_uuid;
  perform public.post_hotel_invoice_recognition(invoice_uuid);
  update public.hotel_bookings
     set books_invoice_id = invoice_uuid, books_accounting_status = 'posted', books_accounting_error = null
   where id = new.id;
  return new;
exception when others then
  update public.hotel_bookings
     set books_accounting_status = 'failed', books_accounting_error = left(sqlerrm, 2000)
   where id = new.id;
  return new;
end;
$$;

revoke all on function public.post_paid_hotel_booking_to_books() from public;

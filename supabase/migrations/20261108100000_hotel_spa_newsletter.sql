alter table public.hotel_tenant_settings
  add column if not exists timezone text not null default 'Africa/Kampala';
grant update (timezone, updated_at) on public.hotel_tenant_settings to service_role;

create table if not exists public.hotel_spa_services (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.books_organizations(id) on delete restrict,
  name text not null,
  description text not null default '',
  price numeric(14,2) not null check (price >= 0),
  currency_code char(3) not null default 'UGX',
  duration_minutes integer not null check (duration_minutes between 10 and 480),
  slot_interval_minutes integer not null check (slot_interval_minutes between 5 and 240),
  capacity integer not null default 1 check (capacity between 1 and 100),
  weekly_hours jsonb not null default '{"0":[],"1":[],"2":[],"3":[],"4":[],"5":[],"6":[]}'::jsonb,
  deposit_type text not null default 'percentage' check (deposit_type in ('fixed', 'percentage')),
  deposit_value numeric(14,2) not null default 0 check (deposit_value >= 0),
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (deposit_type <> 'percentage' or deposit_value <= 100),
  check (deposit_type <> 'fixed' or deposit_value <= price)
);

create index if not exists hotel_spa_services_public_idx
  on public.hotel_spa_services (organization_id, is_active, name);

alter table public.hotel_spa_services enable row level security;
revoke all on public.hotel_spa_services from public, anon, authenticated;
grant all on public.hotel_spa_services to service_role;

create table if not exists public.hotel_spa_bookings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.books_organizations(id) on delete restrict,
  service_id uuid not null references public.hotel_spa_services(id) on delete restrict,
  confirmation_number text not null unique,
  guest_user_id uuid references auth.users(id) on delete set null,
  guest_first_name text not null,
  guest_last_name text not null,
  guest_email text not null,
  guest_phone text not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  timezone text not null,
  service_price numeric(14,2) not null,
  payment_choice text not null check (payment_choice in ('pay_at_spa', 'full', 'deposit')),
  amount_due numeric(14,2) not null check (amount_due >= 0),
  currency_code char(3) not null,
  booking_status text not null check (booking_status in ('confirmed', 'pending_payment', 'cancelled', 'expired')),
  payment_status text not null check (payment_status in ('unpaid', 'pending', 'paid', 'failed', 'cancelled')),
  access_token_hash text not null,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

create index if not exists hotel_spa_bookings_capacity_idx
  on public.hotel_spa_bookings (service_id, starts_at, ends_at)
  where booking_status in ('confirmed', 'pending_payment');
create index if not exists hotel_spa_bookings_tenant_recent_idx
  on public.hotel_spa_bookings (organization_id, created_at desc);

alter table public.hotel_spa_bookings enable row level security;
revoke all on public.hotel_spa_bookings from public, anon, authenticated;
grant all on public.hotel_spa_bookings to service_role;

create table if not exists public.hotel_spa_payment_attempts (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.hotel_spa_bookings(id) on delete restrict,
  tx_ref text not null unique,
  transaction_id text,
  amount numeric(14,2) not null,
  currency_code char(3) not null,
  status text not null check (status in ('initiated', 'redirected', 'verified', 'successful', 'failed', 'cancelled')),
  payment_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.hotel_spa_payment_attempts enable row level security;
revoke all on public.hotel_spa_payment_attempts from public, anon, authenticated;
grant all on public.hotel_spa_payment_attempts to service_role;

create table if not exists public.hotel_newsletter_lists (
  organization_id uuid primary key references public.books_organizations(id) on delete cascade,
  brevo_folder_id bigint,
  brevo_list_id bigint,
  provisioning_token uuid,
  provisioning_started_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.hotel_newsletter_lists enable row level security;
revoke all on public.hotel_newsletter_lists from public, anon, authenticated;
grant all on public.hotel_newsletter_lists to service_role;

create table if not exists public.hotel_newsletter_subscriptions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.books_organizations(id) on delete restrict,
  email text not null,
  normalized_email text not null,
  status text not null default 'subscribed' check (status in ('subscribed', 'unsubscribed')),
  consented_at timestamptz not null default now(),
  unsubscribed_at timestamptz,
  unsubscribe_token_hash text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists hotel_newsletter_subscriptions_tenant_email_idx
  on public.hotel_newsletter_subscriptions (organization_id, normalized_email);
create unique index if not exists hotel_newsletter_subscriptions_token_hash_idx
  on public.hotel_newsletter_subscriptions (unsubscribe_token_hash);

alter table public.hotel_newsletter_subscriptions enable row level security;
revoke all on public.hotel_newsletter_subscriptions from public, anon, authenticated;
grant all on public.hotel_newsletter_subscriptions to service_role;

create or replace function public.get_hotel_spa_availability(
  target_organization_id uuid,
  target_service_id uuid,
  target_date date
)
returns table (slot_start timestamptz, slot_end timestamptz, remaining_capacity integer)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  service_row public.hotel_spa_services%rowtype;
  hotel_timezone text;
  opening_window jsonb;
  local_open time;
  local_close time;
  local_slot timestamp without time zone;
  booked_count integer;
begin
  update public.hotel_spa_bookings
     set booking_status = 'expired', payment_status = 'failed', updated_at = now()
   where organization_id = target_organization_id
     and booking_status = 'pending_payment' and expires_at <= now();
  select settings.timezone into hotel_timezone
    from public.hotel_tenant_settings settings
   where settings.organization_id = target_organization_id and settings.is_active;
  if hotel_timezone is null then return; end if;
  select * into service_row
    from public.hotel_spa_services
   where id = target_service_id and organization_id = target_organization_id and is_active;
  if not found or target_date < (now() at time zone hotel_timezone)::date
     or target_date > (now() at time zone hotel_timezone)::date + 60 then return; end if;

  for opening_window in
    select value from jsonb_array_elements(coalesce(service_row.weekly_hours->(extract(dow from target_date)::integer)::text, '[]'::jsonb))
  loop
    local_open := (opening_window->>'open')::time;
    local_close := (opening_window->>'close')::time;
    if local_close <= local_open then continue; end if;
    for local_slot in
      select generate_series(
        target_date + local_open,
        target_date + local_close - make_interval(mins => service_row.duration_minutes),
        make_interval(mins => service_row.slot_interval_minutes)
      )
    loop
      slot_start := local_slot at time zone hotel_timezone;
      slot_end := (local_slot + make_interval(mins => service_row.duration_minutes)) at time zone hotel_timezone;
      if slot_start <= now() then continue; end if;
      select count(*)::integer into booked_count
        from public.hotel_spa_bookings booking
       where booking.service_id = target_service_id
         and booking.organization_id = target_organization_id
         and booking.starts_at < slot_end
         and booking.ends_at > slot_start
         and (booking.booking_status = 'confirmed'
           or (booking.booking_status = 'pending_payment' and booking.expires_at > now()));
      remaining_capacity := service_row.capacity - booked_count;
      if remaining_capacity > 0 then return next; end if;
    end loop;
  end loop;
end;
$$;
revoke all on function public.get_hotel_spa_availability(uuid, uuid, date) from public, anon, authenticated;
grant execute on function public.get_hotel_spa_availability(uuid, uuid, date) to service_role;

create or replace function public.create_hotel_spa_booking(
  target_organization_id uuid,
  target_service_id uuid,
  target_guest jsonb,
  target_slot_start timestamptz,
  target_payment_choice text,
  target_access_token_hash text
)
returns table (booking_id uuid, confirmation_number text, amount_due numeric, service_price numeric, currency_code char(3), booking_status text, payment_status text, starts_at timestamptz, expires_at timestamptz, timezone text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  service_row public.hotel_spa_services%rowtype;
  tenant_timezone text;
  selected_slot record;
  booking_uuid uuid := gen_random_uuid();
  confirmation text := 'SPA-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  due_amount numeric(14,2);
  currency_precision integer;
  selected_payment_choice text := target_payment_choice;
  expires timestamptz;
  selected_guest_user_id uuid;
begin
  if target_payment_choice not in ('pay_at_spa', 'full', 'deposit')
     or target_access_token_hash is null or length(target_access_token_hash) <> 64
     or jsonb_typeof(target_guest) is distinct from 'object'
     or coalesce(length(trim(target_guest->>'first_name')), 0) = 0
     or coalesce(length(trim(target_guest->>'last_name')), 0) = 0
     or coalesce(length(trim(target_guest->>'email')), 0) = 0
     or coalesce(length(trim(target_guest->>'phone')), 0) = 0 then
    raise exception 'Spa booking details are invalid';
  end if;
  if length(target_guest->>'first_name') > 100 or length(target_guest->>'last_name') > 100
     or length(target_guest->>'email') > 254 or length(target_guest->>'phone') > 40
     or lower(trim(target_guest->>'email')) !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception 'Spa guest details are invalid';
  end if;

  select settings.timezone into tenant_timezone
    from public.hotel_tenant_settings settings
   where settings.organization_id = target_organization_id and settings.is_active;
  if tenant_timezone is null then raise exception 'Hotel is not available for spa bookings'; end if;
  select * into service_row
    from public.hotel_spa_services
   where id = target_service_id and organization_id = target_organization_id and is_active
   for update;
  if not found then raise exception 'Spa service is not available'; end if;
  currency_precision := public.checkout_currency_minor_units(service_row.currency_code);
  if currency_precision is null then raise exception 'Service currency is not supported'; end if;

  select availability.slot_start, availability.slot_end into selected_slot
    from public.get_hotel_spa_availability(target_organization_id, target_service_id, (target_slot_start at time zone tenant_timezone)::date) availability
   where availability.slot_start = target_slot_start;
  if not found then raise exception 'This spa appointment time is no longer available'; end if;

  if target_payment_choice = 'pay_at_spa' then
    due_amount := 0;
    expires := null;
  elsif target_payment_choice = 'full' then
    due_amount := service_row.price;
    expires := now() + interval '20 minutes';
  else
    due_amount := case when service_row.deposit_type = 'fixed'
      then service_row.deposit_value
      else round(service_row.price * service_row.deposit_value / 100, currency_precision) end;
    if due_amount <= 0 then raise exception 'This service has no deposit configured'; end if;
    expires := now() + interval '20 minutes';
  end if;

  selected_guest_user_id := case
    when coalesce(target_guest->>'user_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then (target_guest->>'user_id')::uuid
    else null
  end;
  insert into public.hotel_spa_bookings (
    id, organization_id, service_id, confirmation_number, guest_user_id, guest_first_name, guest_last_name,
    guest_email, guest_phone, starts_at, ends_at, timezone, service_price, payment_choice, amount_due,
    currency_code, booking_status, payment_status, access_token_hash, expires_at
  ) values (
    booking_uuid, target_organization_id, target_service_id, confirmation, selected_guest_user_id,
    trim(target_guest->>'first_name'), trim(target_guest->>'last_name'), lower(trim(target_guest->>'email')),
    trim(target_guest->>'phone'), selected_slot.slot_start, selected_slot.slot_end, tenant_timezone,
    service_row.price, selected_payment_choice, due_amount, service_row.currency_code,
    case when selected_payment_choice = 'pay_at_spa' then 'confirmed' else 'pending_payment' end,
    case when selected_payment_choice = 'pay_at_spa' then 'unpaid' else 'pending' end,
    target_access_token_hash, expires
  );
  return query select booking_uuid, confirmation, due_amount, service_row.price, service_row.currency_code,
    case when selected_payment_choice = 'pay_at_spa' then 'confirmed' else 'pending_payment' end,
    case when selected_payment_choice = 'pay_at_spa' then 'unpaid' else 'pending' end,
    selected_slot.slot_start, expires, tenant_timezone;
end;
$$;
revoke all on function public.create_hotel_spa_booking(uuid, uuid, jsonb, timestamptz, text, text) from public, anon, authenticated;
grant execute on function public.create_hotel_spa_booking(uuid, uuid, jsonb, timestamptz, text, text) to service_role;

create or replace function public.create_hotel_spa_payment_attempt(
  target_booking_id uuid,
  target_access_token_hash text,
  target_tx_ref text
)
returns table (attempt_id uuid, attempt_tx_ref text, attempt_status text, attempt_payment_url text, amount numeric, currency_code char(3))
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  booking_row public.hotel_spa_bookings%rowtype;
  attempt_row public.hotel_spa_payment_attempts%rowtype;
begin
  select * into booking_row from public.hotel_spa_bookings
   where id = target_booking_id and access_token_hash = target_access_token_hash for update;
  if not found then raise exception 'Spa booking could not be verified'; end if;
  if booking_row.payment_status = 'paid' then raise exception 'Spa booking is already paid'; end if;
  if booking_row.booking_status <> 'pending_payment' or booking_row.expires_at <= now() then
    raise exception 'Spa booking hold has expired';
  end if;
  select * into attempt_row from public.hotel_spa_payment_attempts
   where booking_id = booking_row.id and status in ('initiated', 'redirected')
   order by created_at desc limit 1 for update;
  if found then
    if attempt_row.status = 'redirected' and attempt_row.payment_url is not null then
      return query select attempt_row.id, attempt_row.tx_ref, attempt_row.status, attempt_row.payment_url, attempt_row.amount, attempt_row.currency_code;
      return;
    end if;
    if attempt_row.created_at > now() - interval '2 minutes' then
      raise exception 'Spa checkout is being prepared; try again shortly';
    end if;
    update public.hotel_spa_payment_attempts set status = 'failed', updated_at = now() where id = attempt_row.id;
  end if;
  insert into public.hotel_spa_payment_attempts (booking_id, tx_ref, amount, currency_code, status)
  values (booking_row.id, target_tx_ref, booking_row.amount_due, booking_row.currency_code, 'initiated')
  returning * into attempt_row;
  return query select attempt_row.id, attempt_row.tx_ref, attempt_row.status, attempt_row.payment_url, attempt_row.amount, attempt_row.currency_code;
end;
$$;
revoke all on function public.create_hotel_spa_payment_attempt(uuid, text, text) from public, anon, authenticated;
grant execute on function public.create_hotel_spa_payment_attempt(uuid, text, text) to service_role;

create or replace function public.confirm_hotel_spa_booking_payment(
  target_booking_id uuid,
  target_access_token_hash text,
  target_tx_ref text,
  target_transaction_id text
)
returns table (booking_id uuid, confirmation_number text, booking_status text, payment_status text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  booking_row public.hotel_spa_bookings%rowtype;
  service_row public.hotel_spa_services%rowtype;
  target_service_id uuid;
  overlapping_bookings integer;
  can_confirm boolean;
begin
  select booking.service_id into target_service_id
    from public.hotel_spa_bookings booking
   where booking.id = target_booking_id and booking.access_token_hash = target_access_token_hash;
  if not found then raise exception 'Spa booking could not be verified'; end if;
  select * into service_row from public.hotel_spa_services where id = target_service_id for update;
  if not found then raise exception 'Spa service could not be found'; end if;
  select * into booking_row from public.hotel_spa_bookings
   where id = target_booking_id and access_token_hash = target_access_token_hash for update;
  if not found then raise exception 'Spa booking could not be verified'; end if;
  if booking_row.payment_status = 'paid' then
    return query select booking_row.id, booking_row.confirmation_number, booking_row.booking_status, booking_row.payment_status;
    return;
  end if;
  if not exists (
    select 1 from public.hotel_spa_payment_attempts attempt
     where attempt.booking_id = booking_row.id and attempt.tx_ref = target_tx_ref
       and attempt.amount = booking_row.amount_due and attempt.currency_code = booking_row.currency_code
  ) then raise exception 'Spa payment attempt does not match this booking'; end if;
  select count(*)::integer into overlapping_bookings
    from public.hotel_spa_bookings other_booking
   where other_booking.service_id = booking_row.service_id
     and other_booking.organization_id = booking_row.organization_id
     and other_booking.id <> booking_row.id
     and other_booking.starts_at < booking_row.ends_at
     and other_booking.ends_at > booking_row.starts_at
     and (other_booking.booking_status = 'confirmed'
       or (other_booking.booking_status = 'pending_payment' and other_booking.expires_at > now()));
  can_confirm := booking_row.starts_at > now()
    and booking_row.booking_status in ('pending_payment', 'expired')
    and overlapping_bookings < service_row.capacity;
  update public.hotel_spa_payment_attempts as attempt
     set status = 'successful', transaction_id = target_transaction_id, updated_at = now()
   where attempt.booking_id = booking_row.id and attempt.tx_ref = target_tx_ref;
  if can_confirm then
    update public.hotel_spa_bookings
       set booking_status = 'confirmed', payment_status = 'paid', updated_at = now()
     where id = booking_row.id;
    return query select booking_row.id, booking_row.confirmation_number, 'confirmed'::text, 'paid'::text;
  else
    update public.hotel_spa_bookings
       set booking_status = 'expired', payment_status = 'paid', updated_at = now()
     where id = booking_row.id;
    return query select booking_row.id, booking_row.confirmation_number, 'expired'::text, 'paid'::text;
  end if;
end;
$$;
revoke all on function public.confirm_hotel_spa_booking_payment(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.confirm_hotel_spa_booking_payment(uuid, text, text, text) to service_role;

create or replace function public.claim_hotel_newsletter_list(target_organization_id uuid, target_claim_token uuid)
returns table (brevo_folder_id bigint, brevo_list_id bigint, owns_claim boolean)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare list_row public.hotel_newsletter_lists%rowtype;
begin
  if not exists (select 1 from public.hotel_tenant_settings where organization_id = target_organization_id and is_active) then
    raise exception 'Hotel is not available for newsletter subscriptions';
  end if;
  insert into public.hotel_newsletter_lists (organization_id) values (target_organization_id) on conflict do nothing;
  select * into list_row from public.hotel_newsletter_lists where organization_id = target_organization_id for update;
  if list_row.brevo_list_id is not null then
    return query select list_row.brevo_folder_id, list_row.brevo_list_id, false;
    return;
  end if;
  if list_row.provisioning_token is null or list_row.provisioning_started_at < now() - interval '2 minutes' then
    update public.hotel_newsletter_lists
       set provisioning_token = target_claim_token, provisioning_started_at = now(), updated_at = now()
     where organization_id = target_organization_id
     returning * into list_row;
    return query select list_row.brevo_folder_id, list_row.brevo_list_id, true;
  else
    return query select list_row.brevo_folder_id, list_row.brevo_list_id, list_row.provisioning_token = target_claim_token;
  end if;
end;
$$;
revoke all on function public.claim_hotel_newsletter_list(uuid, uuid) from public, anon, authenticated;
grant execute on function public.claim_hotel_newsletter_list(uuid, uuid) to service_role;

create or replace function public.complete_hotel_newsletter_list(target_organization_id uuid, target_claim_token uuid, target_folder_id bigint, target_list_id bigint)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  update public.hotel_newsletter_lists
     set brevo_folder_id = target_folder_id, brevo_list_id = target_list_id,
         provisioning_token = null, provisioning_started_at = null, updated_at = now()
   where organization_id = target_organization_id and provisioning_token = target_claim_token and brevo_list_id is null;
  return found;
end;
$$;
revoke all on function public.complete_hotel_newsletter_list(uuid, uuid, bigint, bigint) from public, anon, authenticated;
grant execute on function public.complete_hotel_newsletter_list(uuid, uuid, bigint, bigint) to service_role;

create or replace function public.release_hotel_newsletter_list_claim(target_organization_id uuid, target_claim_token uuid)
returns void
language sql
security definer
set search_path = pg_catalog, public
as $$
  update public.hotel_newsletter_lists
     set provisioning_token = null, provisioning_started_at = null, updated_at = now()
   where organization_id = target_organization_id and provisioning_token = target_claim_token and brevo_list_id is null;
$$;
revoke all on function public.release_hotel_newsletter_list_claim(uuid, uuid) from public, anon, authenticated;
grant execute on function public.release_hotel_newsletter_list_claim(uuid, uuid) to service_role;

notify pgrst, 'reload schema';

alter table public.hotel_booking_offers
  add column if not exists category text not null default 'accommodation',
  add column if not exists discount_type text not null default 'percentage',
  add column if not exists discount_label text not null default '',
  add column if not exists discount_amount numeric(14,2) not null default 0,
  add column if not exists currency_code char(3) not null default 'USD',
  add column if not exists min_spend numeric(14,2) not null default 0,
  add column if not exists max_discount numeric(14,2) not null default 0,
  add column if not exists promo_code text,
  add column if not exists image text not null default '🏨',
  add column if not exists popularity integer not null default 0,
  add column if not exists limited_time boolean not null default false,
  add column if not exists max_uses integer,
  add column if not exists usage_count integer not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.hotel_booking_offers'::regclass
       and conname = 'hotel_booking_offers_organization_required'
  ) then
    alter table public.hotel_booking_offers
      add constraint hotel_booking_offers_organization_required
      check (organization_id is not null) not valid;
  end if;
end;
$$;

alter table public.hotel_bookings
  add column if not exists applied_offer_id uuid references public.hotel_booking_offers(id) on delete set null;

create table if not exists public.hotel_offer_redemptions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.books_organizations(id) on delete restrict,
  offer_id uuid not null references public.hotel_booking_offers(id) on delete restrict,
  booking_id uuid not null unique references public.hotel_bookings(id) on delete restrict,
  status text not null default 'reserved' check (status in ('reserved', 'redeemed', 'released')),
  created_at timestamptz not null default now(),
  redeemed_at timestamptz,
  released_at timestamptz
);

alter table public.hotel_offer_redemptions enable row level security;
revoke all on public.hotel_offer_redemptions from public, anon, authenticated;
grant all on public.hotel_offer_redemptions to service_role;

create index if not exists hotel_booking_offers_tenant_category_active_idx
  on public.hotel_booking_offers (organization_id, category, display_order)
  where is_active;
create unique index if not exists hotel_booking_offers_tenant_code_idx
  on public.hotel_booking_offers (organization_id, category, lower(trim(promo_code)))
  where promo_code is not null;
create index if not exists hotel_offer_redemptions_offer_status_idx
  on public.hotel_offer_redemptions (offer_id, status);

create or replace function public.release_expired_hotel_offer_holds_for_tenant(target_organization_id uuid)
returns integer language plpgsql security definer set search_path = pg_catalog, public
as $$
declare released_count integer;
begin
  update public.hotel_bookings booking
     set booking_status = 'expired', payment_status = 'cancelled'
   where booking.organization_id = target_organization_id
     and booking.applied_offer_id is not null
     and booking.booking_status = 'pending'
     and booking.payment_status = 'pending'
     and booking.expires_at <= now();
  get diagnostics released_count = row_count;
  return released_count;
end;
$$;
revoke all on function public.release_expired_hotel_offer_holds_for_tenant(uuid) from public, anon, authenticated;
grant execute on function public.release_expired_hotel_offer_holds_for_tenant(uuid) to service_role;

create or replace function public.release_or_redeem_hotel_offer()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if new.payment_status = 'paid' and old.payment_status is distinct from new.payment_status then
    update public.hotel_offer_redemptions
       set status = 'redeemed', redeemed_at = now()
     where booking_id = new.id and status = 'reserved';
  elsif (new.booking_status in ('expired', 'cancelled') or new.payment_status in ('failed', 'cancelled'))
        and (old.booking_status is distinct from new.booking_status or old.payment_status is distinct from new.payment_status) then
    with released as (
      update public.hotel_offer_redemptions
         set status = 'released', released_at = now()
       where booking_id = new.id and status = 'reserved'
       returning offer_id
    )
    update public.hotel_booking_offers offers
       set usage_count = greatest(offers.usage_count - 1, 0)
      from released
     where offers.id = released.offer_id;
  end if;
  return new;
end;
$$;
revoke all on function public.release_or_redeem_hotel_offer() from public, anon, authenticated;
drop trigger if exists hotel_booking_offer_redemption_status on public.hotel_bookings;
create trigger hotel_booking_offer_redemption_status
after update of payment_status, booking_status on public.hotel_bookings
for each row execute function public.release_or_redeem_hotel_offer();

do $$
declare
  function_source text;
  replacement_source text;
begin
  function_source := replace(pg_get_functiondef(
    'public.create_hotel_booking(uuid,jsonb,date,date,integer,integer,text,jsonb,uuid,uuid,text,jsonb)'::regprocedure
  ), E'\r', '');

  if position('selected_offer public.hotel_booking_offers%rowtype' in function_source) = 0 then
  replacement_source := replace(function_source,
    '  discount_rate numeric := 0;',
    E'  discount_rate numeric := 0;\n  selected_offer public.hotel_booking_offers%rowtype;\n  selected_offer_id uuid;\n  offer_currency_per_ugx numeric;\n  eligible_spend numeric;\n  maximum_discount_in_room_currency numeric;\n  current_offer_usage_count integer;'
  );
  if replacement_source = function_source then
    raise exception 'Could not add offer variables to hotel booking checkout';
  end if;
  function_source := replacement_source;

  replacement_source := replace(function_source,
    E'    ''userId'', target_user_id\n  );',
    E'    ''userId'', target_user_id,\n    ''promoCode'', upper(coalesce(nullif(trim(target_guest->>''promo_code''), ''''), ''''))\n  );'
  );
  if replacement_source = function_source then
    raise exception 'Could not add promo code to the hotel booking idempotency fingerprint';
  end if;
  function_source := replacement_source;

  replacement_source := regexp_replace(
    function_source,
    '  select coalesce\(max\(discount_percentage\), 0\)[[:space:]]+into discount_rate[[:space:]]+from public\.hotel_booking_offers[[:space:]]+where[[:space:]]+((organization_id[[:space:]]*=[[:space:]]*selected_room\.organization_id|category[[:space:]]*=[[:space:]]*''accommodation''|discount_type[[:space:]]*=[[:space:]]*''percentage'')[[:space:]]+and[[:space:]]+){0,3}is_active[[:space:]]+and minimum_nights <= nights_count[[:space:]]+and \(starts_at is null or starts_at <= now\(\)\)[[:space:]]+and \(ends_at is null or ends_at > now\(\)\);[[:space:]]+discount_value := round\([[:space:]]+room_subtotal \* discount_rate / 100,[[:space:]]+currency_decimals[[:space:]]+\);[[:space:]]+taxable_value := room_subtotal - discount_value;',
    $replacement$
  if nullif(trim(target_guest->>'promo_code'), '') is not null then
    select offer.* into selected_offer
      from public.hotel_booking_offers as offer
     where offer.organization_id = selected_room.organization_id
       and offer.category = 'accommodation'
       and offer.is_active
       and upper(trim(offer.promo_code)) = upper(trim(target_guest->>'promo_code'))
       and offer.minimum_nights <= nights_count
       and (offer.starts_at is null or offer.starts_at <= now())
       and (offer.ends_at is null or offer.ends_at > now())
     for update;
    if not found then
      raise exception 'Promo code is not valid for this stay';
    end if;
    update public.hotel_bookings as booking
       set booking_status = 'expired', payment_status = 'cancelled'
      from public.hotel_offer_redemptions as redemption
     where redemption.booking_id = booking.id
       and redemption.offer_id = selected_offer.id
       and redemption.status = 'reserved'
       and booking.booking_status = 'pending'
       and booking.expires_at <= now();
    select usage_count into current_offer_usage_count
      from public.hotel_booking_offers where id = selected_offer.id;
    if selected_offer.max_uses is not null and current_offer_usage_count >= selected_offer.max_uses then
      raise exception 'Promo code is not valid for this stay';
    end if;
  else
    select offer.* into selected_offer
      from public.hotel_booking_offers as offer
     where offer.organization_id = selected_room.organization_id
       and offer.category = 'accommodation'
       and offer.is_active
       and offer.promo_code is null
       and offer.discount_type = 'percentage'
       and offer.discount_percentage > 0
       and (offer.max_uses is null or offer.usage_count < offer.max_uses)
       and offer.minimum_nights <= nights_count
       and (offer.starts_at is null or offer.starts_at <= now())
       and (offer.ends_at is null or offer.ends_at > now())
       and (offer.min_spend = 0 or
         room_subtotal / nullif((target_fx_rates->>trim(selected_room.currency_code))::numeric, 0)
         * nullif((target_fx_rates->>trim(offer.currency_code))::numeric, 0) >= offer.min_spend)
     order by offer.discount_percentage desc
     limit 1
     for update;
  end if;

  if found then
    selected_offer_id := selected_offer.id;
    room_currency_per_ugx := (target_fx_rates->>trim(selected_room.currency_code))::numeric;
    offer_currency_per_ugx := (target_fx_rates->>trim(selected_offer.currency_code))::numeric;
    if room_currency_per_ugx is null or room_currency_per_ugx <= 0
       or offer_currency_per_ugx is null or offer_currency_per_ugx <= 0 then
      raise exception 'Offer currency is not supported for this booking';
    end if;
    eligible_spend := room_subtotal / room_currency_per_ugx * offer_currency_per_ugx;
    if eligible_spend < selected_offer.min_spend then
      raise exception 'Promo code minimum spend is not met';
    end if;
    if selected_offer.discount_type = 'percentage' then
      discount_rate := selected_offer.discount_percentage;
      discount_value := round(room_subtotal * discount_rate / 100, currency_decimals);
      if selected_offer.max_discount > 0 then
        maximum_discount_in_room_currency := selected_offer.max_discount / offer_currency_per_ugx * room_currency_per_ugx;
        discount_value := least(discount_value, round(maximum_discount_in_room_currency, currency_decimals));
      end if;
    elsif selected_offer.discount_type = 'fixed' then
      discount_value := round(selected_offer.discount_amount / offer_currency_per_ugx * room_currency_per_ugx, currency_decimals);
    else
      raise exception 'This offer type is not valid for room booking';
    end if;
    discount_value := least(discount_value, room_subtotal);
  else
    discount_value := 0;
  end if;
  discount_rate := case when room_subtotal > 0 then discount_value / room_subtotal * 100 else 0 end;
  taxable_value := room_subtotal - discount_value;
  $replacement$,
    'n'
  );
  if replacement_source = function_source then
    raise exception 'Could not add tenant-scoped offer validation to hotel booking checkout';
  end if;
  function_source := replacement_source;

  replacement_source := replace(function_source,
    'access_token_hash, checkout_request',
    'access_token_hash, checkout_request, applied_offer_id'
  );
  if replacement_source = function_source then
    raise exception 'Could not link hotel bookings to applied offers';
  end if;
  function_source := replacement_source;

  replacement_source := replace(function_source,
    'target_idempotency_key, target_access_token_hash, request_fingerprint',
    'target_idempotency_key, target_access_token_hash, request_fingerprint, selected_offer_id'
  );
  if replacement_source = function_source then
    raise exception 'Could not store the applied hotel offer';
  end if;
  function_source := replacement_source;

  replacement_source := replace(function_source,
    E'  return query\n  select new_booking_id,',
    E'  if selected_offer_id is not null then\n    insert into public.hotel_offer_redemptions (organization_id, offer_id, booking_id)\n    values (selected_room.organization_id, selected_offer_id, new_booking_id);\n    update public.hotel_booking_offers set usage_count = usage_count + 1 where id = selected_offer_id;\n  end if;\n\n  return query\n  select new_booking_id,'
  );
  if replacement_source = function_source then
    raise exception 'Could not reserve the applied hotel offer';
  end if;

  execute replacement_source;
  else
    raise notice 'Hotel promo-code checkout is already installed.';
  end if;
end;
$$;

notify pgrst, 'reload schema';

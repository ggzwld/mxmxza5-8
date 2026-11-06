alter table public.hotel_booking_offers
  add column if not exists featured boolean not null default false,
  add column if not exists terms text[] not null default '{}';

create index if not exists hotel_booking_offers_public_order_idx
  on public.hotel_booking_offers (organization_id, display_order, starts_at, ends_at)
  where is_active;

notify pgrst, 'reload schema';

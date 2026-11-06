begin;

alter table public.user_profiles
  add column if not exists buyer_business_name text,
  add column if not exists buyer_tin text;

alter table public.user_profiles
  drop constraint if exists user_profiles_buyer_business_name_check;
alter table public.user_profiles
  add constraint user_profiles_buyer_business_name_check
  check (buyer_business_name is null or length(trim(buyer_business_name)) between 1 and 200);

alter table public.user_profiles
  drop constraint if exists user_profiles_buyer_tin_check;
alter table public.user_profiles
  add constraint user_profiles_buyer_tin_check
  check (buyer_tin is null or length(trim(buyer_tin)) between 1 and 30);

alter table public.books_personal_purchase_records
  add column if not exists buyer_business_name text,
  add column if not exists buyer_tin text;

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
  buyer_profile public.user_profiles%rowtype;
begin
  if target_buyer_user_id is null or target_amount <= 0 or target_hotel_organization_id is null then return; end if;
  if not exists (
    select 1 from auth.users auth_user
     where auth_user.id = target_buyer_user_id and not auth_user.is_anonymous
  ) then return; end if;

  select * into buyer_profile
    from public.user_profiles profile
   where profile.user_id = target_buyer_user_id;

  insert into public.books_personal_purchase_records (
    source_type, source_id, buyer_user_id, hotel_organization_id,
    amount, currency_code, purchase_date, description, buyer_business_name, buyer_tin
  ) values (
    target_source_type, target_source_id, target_buyer_user_id, target_hotel_organization_id,
    target_amount, upper(target_currency_code), target_purchase_date, target_description,
    nullif(trim(buyer_profile.buyer_business_name), ''), nullif(trim(buyer_profile.buyer_tin), '')
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

notify pgrst, 'reload schema';
commit;

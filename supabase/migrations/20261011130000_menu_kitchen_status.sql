create table if not exists public.menu_kitchen_status (
  organization_id uuid primary key references public.books_organizations(id) on delete cascade,
  load_level text not null check (load_level in ('light', 'moderate', 'busy')),
  preparation_time_min integer not null check (preparation_time_min >= 0),
  preparation_time_max integer not null check (preparation_time_max >= preparation_time_min),
  stations_operational boolean not null,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.menu_kitchen_status enable row level security;
revoke all on public.menu_kitchen_status from anon;
grant select, insert, update, delete on public.menu_kitchen_status to authenticated;

drop policy if exists menu_kitchen_status_manager_access on public.menu_kitchen_status;
create policy menu_kitchen_status_manager_access on public.menu_kitchen_status
  for all to authenticated
  using (public.can_manage_hotel_menu(organization_id))
  with check (public.can_manage_hotel_menu(organization_id));

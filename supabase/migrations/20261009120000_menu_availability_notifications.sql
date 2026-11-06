begin;

create table if not exists public.menu_availability_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  organization_id uuid not null references public.books_organizations(id) on delete cascade,
  menu_item_id uuid not null references public.menu_items(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (user_id, menu_item_id)
);

create index if not exists menu_availability_subscriptions_item_idx
  on public.menu_availability_subscriptions (organization_id, menu_item_id);

alter table public.menu_availability_subscriptions enable row level security;
grant select on public.menu_availability_subscriptions to authenticated;

drop policy if exists menu_availability_subscriptions_select_own
  on public.menu_availability_subscriptions;
create policy menu_availability_subscriptions_select_own
  on public.menu_availability_subscriptions
  for select to authenticated
  using (user_id = auth.uid());

create or replace function public.request_menu_item_availability_for_tenant(
  target_user_id uuid,
  target_organization_id uuid,
  target_menu_item_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  menu_row public.menu_items%rowtype;
begin
  select * into menu_row
    from public.menu_items
   where id = target_menu_item_id
     and organization_id = target_organization_id
     and is_published = true;

  if not found then
    raise exception 'Menu item is unavailable';
  end if;

  if menu_row.availability > 0 then
    return false;
  end if;

  insert into public.menu_availability_subscriptions (user_id, organization_id, menu_item_id)
  values (target_user_id, target_organization_id, menu_row.id)
  on conflict (user_id, menu_item_id) do nothing;

  return true;
end;
$$;
revoke all on function public.request_menu_item_availability_for_tenant(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.request_menu_item_availability_for_tenant(uuid, uuid, uuid) to service_role;

create or replace function public.notify_menu_item_available()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if old.availability <= 0 and new.availability > 0 then
    insert into public.notifications (user_id, type, message, is_read, action_url)
    select
      subscription.user_id,
      'menu_item_available',
      format('%s is back in stock at %s.', new.name, organization.name),
      false,
      '/menu'
    from public.menu_availability_subscriptions subscription
    join public.books_organizations organization
      on organization.id = subscription.organization_id
    where subscription.menu_item_id = new.id
      and subscription.organization_id = new.organization_id;

    delete from public.menu_availability_subscriptions
     where menu_item_id = new.id
       and organization_id = new.organization_id;
  end if;

  return new;
end;
$$;
revoke all on function public.notify_menu_item_available() from public, anon, authenticated;

drop trigger if exists menu_item_available_notification on public.menu_items;
create trigger menu_item_available_notification
after update of availability on public.menu_items
for each row execute function public.notify_menu_item_available();

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications
  add constraint notifications_type_check
  check (type in (
    'complaint_filed', 'complaint_acknowledged', 'task_created', 'task_updated',
    'task_assigned', 'task_accepted', 'task_declined', 'task_proposed',
    'proposal_accepted', 'proposal_declined', 'proposal_updated', 'todo_created',
    'task_message', 'report_submitted', 'evidence_approved', 'issue_raised', 'issue_resolved',
    'task_flagged', 'task_approval_ready',
    'event_proposal_submitted', 'event_proposal_updated', 'event_proposal_scheduled',
    'event_proposal_declined', 'event_published',
    'event_invitation_received', 'event_invitation_responded',
    'personal_purchase_recorded', 'hotel_purchase_recorded',
    'personal_purchase_refunded', 'hotel_loyalty_activity', 'menu_item_available'
  ));

commit;

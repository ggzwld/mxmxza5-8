create or replace function public.special_event_vat_rate(target_event_id uuid)
returns numeric
language sql stable security definer set search_path = public
as $$
  select public.books_confirmed_invoice_vat_rate(event.organization_id, current_date)
    from public.special_events as event
   where event.id = target_event_id
     and event.organization_id is not null;
$$;

revoke all on function public.special_event_vat_rate(uuid) from public;
grant execute on function public.special_event_vat_rate(uuid) to anon, authenticated;

create or replace function public.menu_items_vat_rate(target_menu_item_ids uuid[])
returns numeric
language sql stable security definer set search_path = public
as $$
  with selected_items as (
    select item.id, item.organization_id
      from public.menu_items as item
     where item.id = any(target_menu_item_ids)
       and item.is_published
  ),
  requested_items as (
    select count(distinct requested_id) as requested_count
      from unnest(target_menu_item_ids) as requested_id
  )
  select case
    when (select count(*) from selected_items) = (select requested_count from requested_items)
     and (select count(*) from selected_items where organization_id is null) = 0
     and (select count(distinct organization_id) from selected_items) = 1
    then public.books_confirmed_invoice_vat_rate((select organization_id from selected_items limit 1), current_date)
  end;
$$;

revoke all on function public.menu_items_vat_rate(uuid[]) from public;
grant execute on function public.menu_items_vat_rate(uuid[]) to anon, authenticated;

-- Menu item prices are final prices: VAT is carved out for accounting, not added at checkout.
do $$
declare
  current_definition text;
  updated_definition text;
begin
  select pg_get_functiondef('public.create_menu_order(uuid, jsonb, text, text, numeric, jsonb, uuid, uuid)'::regprocedure)
    into current_definition;
  updated_definition := replace(current_definition,
    'tax_value := round(subtotal_value * 0.08, item_decimals);',
    'tax_value := 0;');
  if updated_definition = current_definition then
    raise exception 'create_menu_order does not contain the expected 8 percent add-on';
  end if;
  execute updated_definition;
end;
$$;

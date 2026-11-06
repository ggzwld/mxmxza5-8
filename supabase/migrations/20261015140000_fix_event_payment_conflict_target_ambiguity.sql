do $$
declare
  function_definition text;
  payment_constraint text;
  ticket_constraint text;
begin
  select constraint_row.conname into strict payment_constraint
    from pg_catalog.pg_constraint as constraint_row
   where constraint_row.conrelid = 'public.special_event_payments'::regclass
     and constraint_row.contype = 'u'
     and pg_catalog.pg_get_constraintdef(constraint_row.oid) = 'UNIQUE (booking_id)';

  select constraint_row.conname into strict ticket_constraint
    from pg_catalog.pg_constraint as constraint_row
   where constraint_row.conrelid = 'public.special_event_tickets'::regclass
     and constraint_row.contype = 'u'
     and pg_catalog.pg_get_constraintdef(constraint_row.oid) = 'UNIQUE (booking_id, ticket_number)';

  select pg_catalog.pg_get_functiondef(
    'public.confirm_special_event_payment(uuid,text)'::regprocedure
  ) into strict function_definition;

  if pg_catalog.strpos(function_definition, 'on conflict (booking_id, ticket_number) do nothing') = 0
     or pg_catalog.strpos(function_definition, 'on conflict (booking_id) do update set') = 0 then
    raise exception 'Expected event-payment conflict targets were not found; function was not changed';
  end if;

  function_definition := pg_catalog.replace(
    function_definition,
    'on conflict (booking_id, ticket_number) do nothing',
    pg_catalog.format('on conflict on constraint %I do nothing', ticket_constraint)
  );
  function_definition := pg_catalog.replace(
    function_definition,
    'on conflict (booking_id) do update set',
    pg_catalog.format('on conflict on constraint %I do update set', payment_constraint)
  );

  if pg_catalog.strpos(function_definition, 'on conflict (booking_id') > 0 then
    raise exception 'An ambiguous booking_id conflict target remains; function was not changed';
  end if;

  execute function_definition;
end;
$$;

notify pgrst, 'reload schema';

begin;

create or replace function public.confirm_menu_flutterwave_payment(
  target_order_id uuid,
  target_tx_ref text,
  target_transaction_id text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  selected_order public.menu_orders%rowtype;
  selected_attempt public.menu_payment_attempts%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Only the service role may confirm menu payments';
  end if;
  if target_order_id is null or nullif(trim(target_tx_ref), '') is null or nullif(trim(target_transaction_id), '') is null then
    raise exception 'Payment confirmation details are required';
  end if;

  select orders.*
    into selected_order
    from public.menu_orders orders
   where orders.id = target_order_id
   for update;
  if not found then
    raise exception 'Menu order was not found';
  end if;

  select attempt.*
    into selected_attempt
    from public.menu_payment_attempts attempt
   where attempt.order_id = selected_order.id
     and attempt.tx_ref = target_tx_ref
   for update;
  if not found then
    raise exception 'Menu payment attempt was not found';
  end if;
  if selected_attempt.amount <> selected_order.total_amount
     or upper(selected_attempt.currency) <> upper(selected_order.currency) then
    raise exception 'Menu payment attempt does not match the order';
  end if;

  if selected_order.payment_status = 'paid' then
    if selected_order.flutterwave_transaction_id = target_transaction_id then
      if selected_attempt.status <> 'completed' or selected_attempt.transaction_id is distinct from target_transaction_id then
        update public.menu_payment_attempts
           set transaction_id = target_transaction_id,
               status = 'completed',
               failure_reason = null,
               completed_at = coalesce(completed_at, now()),
               updated_at = now()
         where id = selected_attempt.id;
      end if;
      return jsonb_build_object(
        'orderId', selected_order.id,
        'orderNumber', selected_order.order_number,
        'paymentStatus', 'paid'
      );
    end if;

    update public.menu_payment_attempts
       set transaction_id = target_transaction_id,
           status = 'manual_review',
           failure_reason = 'A second successful payment was received for an already-paid order',
           completed_at = now(),
           updated_at = now()
     where id = selected_attempt.id;
    return jsonb_build_object(
      'orderId', selected_order.id,
      'orderNumber', selected_order.order_number,
      'paymentStatus', 'manual_review'
    );
  end if;

  if selected_order.status <> 'pending'
     or selected_order.payment_status not in ('pending', 'cancelled', 'failed') then
    raise exception 'Menu order is no longer awaiting payment';
  end if;
  if selected_attempt.transaction_id is not null
     and selected_attempt.transaction_id <> target_transaction_id then
    raise exception 'Menu payment attempt is already linked to another transaction';
  end if;

  update public.menu_payment_attempts
     set transaction_id = target_transaction_id,
         status = 'completed',
         failure_reason = null,
         completed_at = coalesce(completed_at, now()),
         updated_at = now()
   where id = selected_attempt.id;

  update public.menu_orders
     set status = 'confirmed',
         payment_status = 'paid',
         payment_reference = target_tx_ref,
         flutterwave_transaction_id = target_transaction_id
   where id = selected_order.id;

  return jsonb_build_object(
    'orderId', selected_order.id,
    'orderNumber', selected_order.order_number,
    'paymentStatus', 'paid'
  );
end;
$$;

revoke all on function public.confirm_menu_flutterwave_payment(uuid, text, text) from public, anon, authenticated;
grant execute on function public.confirm_menu_flutterwave_payment(uuid, text, text) to service_role;

notify pgrst, 'reload schema';
commit;

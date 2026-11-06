create or replace function public.confirm_special_event_payment(
  target_booking_id uuid,
  target_transaction_id text
)
returns table (booking_id uuid, confirmation_number text, ticket_code text, order_number text, payment_status text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_booking public.special_event_bookings%rowtype;
  v_payment public.special_event_payment_attempts%rowtype;
  v_event public.special_events%rowtype;
  existing_payment public.special_event_payments%rowtype;
  prior_payment public.special_event_payments%rowtype;
  v_confirmation text;
  v_ticket text;
  v_remaining bigint;
  v_type_remaining bigint;
  v_review boolean := false;
begin
  if target_booking_id is null or nullif(target_transaction_id, '') is null then
    raise exception 'Verified event payment details are required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('special-event-payment:' || target_transaction_id, 0));
  select booking.event_id into v_event.id
    from public.special_event_bookings as booking
   where booking.id = target_booking_id;
  if not found then raise exception 'Special event booking not found'; end if;
  select * into v_event from public.special_events where id = v_event.id for update;
  select * into v_booking from public.special_event_bookings where id = target_booking_id for update;

  select payment_attempt.* into v_payment
    from public.special_event_payment_attempts as payment_attempt
   where payment_attempt.booking_id = v_booking.id
     and payment_attempt.transaction_id = target_transaction_id
     and payment_attempt.status in ('verified', 'manual_review', 'successful')
   for update;
  if not found then raise exception 'Verified payment attempt not found'; end if;
  if v_payment.amount <> v_booking.total_amount or upper(v_payment.currency) <> upper(v_booking.currency) then
    raise exception 'Verified payment amount does not match booking';
  end if;

  select event_payment.* into existing_payment
    from public.special_event_payments as event_payment
   where event_payment.booking_id = v_booking.id
     and event_payment.transaction_id = target_transaction_id;
  if found and not (
    existing_payment.status = 'manual_review'
    and v_booking.status = 'manual_review'
    and v_booking.payment_status = 'manual_review'
    and v_payment.status = 'verified'
  ) then
    return query select v_booking.id, v_booking.confirmation_number, v_booking.ticket_code,
      v_booking.order_number, case when existing_payment.status = 'successful' then 'paid' else 'manual_review' end;
    return;
  end if;

  select event_payment.* into prior_payment
    from public.special_event_payments as event_payment
   where event_payment.booking_id = v_booking.id
   for update;
  if (found and prior_payment.transaction_id is distinct from target_transaction_id)
     or exists (
       select 1 from public.special_event_payments as other_payment
        where other_payment.transaction_id = target_transaction_id
          and other_payment.booking_id <> v_booking.id
     )
     or v_booking.payment_status in ('paid', 'refunded', 'partially_refunded')
     or v_booking.status in ('confirmed', 'refunded') then
    update public.special_event_payment_attempts
       set status = 'manual_review',
           transaction_id = coalesce(transaction_id, target_transaction_id),
           failure_reason = 'An additional successful payment requires reconciliation',
           updated_at = now()
     where id = v_payment.id;
    insert into public.special_event_duplicate_captures (
      event_id, booking_id, payment_attempt_id, transaction_id, tx_ref, amount, currency
    ) values (
      v_booking.event_id, v_booking.id, v_payment.id, target_transaction_id, v_payment.tx_ref,
      v_payment.amount, v_payment.currency
    ) on conflict (transaction_id) do nothing;
    return query select v_booking.id, v_booking.confirmation_number, v_booking.ticket_code,
      v_booking.order_number, 'manual_review'::text;
    return;
  end if;

  if not (
    (v_booking.status = 'pending' and v_booking.payment_status = 'pending')
    or (v_booking.status = 'expired' and v_booking.payment_status = 'expired')
    or (v_booking.status = 'cancelled' and v_booking.payment_status = 'cancelled')
    or (v_booking.status = 'manual_review' and v_booking.payment_status = 'manual_review')
  ) then raise exception 'Special event booking is not awaiting payment'; end if;

  select v_event.capacity - coalesce(sum(reserved_booking.quantity), 0) into v_remaining
    from public.special_event_bookings as reserved_booking
   where reserved_booking.event_id = v_event.id and reserved_booking.id <> v_booking.id
     and (reserved_booking.status = 'confirmed'
       or (reserved_booking.status = 'manual_review' and reserved_booking.payment_status = 'manual_review')
       or (reserved_booking.status = 'pending' and reserved_booking.payment_status = 'pending' and reserved_booking.expires_at > now()));
  select v_type.capacity - coalesce(sum(b.quantity), 0) into v_type_remaining
    from public.special_event_ticket_types v_type
    left join public.special_event_bookings b on b.ticket_type_id = v_type.id and b.id <> v_booking.id
      and (b.status = 'confirmed' or (b.status = 'manual_review' and b.payment_status = 'manual_review') or (b.status = 'pending' and b.payment_status = 'pending' and b.expires_at > now()))
   where v_type.id = v_booking.ticket_type_id
   group by v_type.capacity;
  v_review := v_booking.status = 'cancelled'
    or v_remaining < v_booking.quantity
    or (v_type_remaining is not null and v_type_remaining < v_booking.quantity);

  if v_review then
    update public.special_event_bookings
       set status = 'manual_review', payment_status = 'manual_review', payment_verified_at = now(), updated_at = now()
     where id = v_booking.id;
    update public.special_event_payment_attempts set status = 'manual_review', updated_at = now() where id = v_payment.id;
    insert into public.special_event_payments (
      event_id, booking_id, payment_attempt_id, transaction_id, tx_ref, amount, currency, status, paid_at
    ) values (
      v_booking.event_id, v_booking.id, v_payment.id, target_transaction_id, v_payment.tx_ref,
      v_payment.amount, v_payment.currency, 'manual_review', now()
    ) on conflict (booking_id) do update set
      status = 'manual_review', payment_attempt_id = excluded.payment_attempt_id,
      transaction_id = excluded.transaction_id, tx_ref = excluded.tx_ref,
      amount = excluded.amount, currency = excluded.currency, updated_at = now();
    return query select v_booking.id, v_booking.confirmation_number, null::text, v_booking.order_number, 'manual_review'::text;
    return;
  end if;

  v_confirmation := 'EVT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  insert into public.special_event_tickets (
    event_id, booking_id, ticket_type_id, ticket_number, ticket_token, attendee_name, attendee_email
  )
  select v_booking.event_id, v_booking.id, v_booking.ticket_type_id, seq,
    replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
    coalesce(nullif(trim(v_booking.attendee_names[seq]), ''), concat_ws(' ', v_booking.guest_first_name, v_booking.guest_last_name)), v_booking.guest_email
  from generate_series(1, v_booking.quantity) seq
  on conflict (booking_id, ticket_number) do nothing;
  select ticket.ticket_token into v_ticket
    from public.special_event_tickets as ticket
   where ticket.booking_id = v_booking.id and ticket.ticket_number = 1;

  update public.special_event_bookings
     set status = 'confirmed', payment_status = 'paid', payment_verified_at = now(),
         confirmation_number = v_confirmation, ticket_code = v_ticket, updated_at = now()
   where id = v_booking.id;
  update public.special_event_payment_attempts set status = 'successful', updated_at = now() where id = v_payment.id;
  update public.special_events set attendees_count = attendees_count + v_booking.quantity, updated_at = now() where id = v_event.id;
  insert into public.special_event_payments (
    event_id, booking_id, payment_attempt_id, transaction_id, tx_ref, amount, currency, status, paid_at
  ) values (
    v_booking.event_id, v_booking.id, v_payment.id, target_transaction_id, v_payment.tx_ref,
    v_payment.amount, v_payment.currency, 'successful', now()
  ) on conflict (booking_id) do update set
    status = 'successful', payment_attempt_id = excluded.payment_attempt_id,
    transaction_id = excluded.transaction_id, tx_ref = excluded.tx_ref,
    amount = excluded.amount, currency = excluded.currency, paid_at = excluded.paid_at, updated_at = now();
  return query select v_booking.id, v_confirmation, v_ticket, v_booking.order_number, 'paid'::text;
end;
$$;

revoke all on function public.confirm_special_event_payment(uuid, text) from public, anon, authenticated;
grant execute on function public.confirm_special_event_payment(uuid, text) to service_role;
notify pgrst, 'reload schema';

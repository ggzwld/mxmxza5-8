begin;

create or replace function public.post_paid_menu_order_to_books_v2()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  seller_organization_id uuid;
  customer_contact_id uuid;
  invoice_uuid uuid;
  tax_uuid uuid;
  customer_name text;
  customer_email text;
  customer_phone text;
  order_subtotal numeric;
  order_tax numeric;
  order_currency char(3);
  tax_percentage numeric;
  order_date date := coalesce(new.created_at::date, current_date);
begin
  if new.payment_status <> 'paid'
     or not (tg_op = 'INSERT' or old.payment_status is distinct from 'paid')
     or new.books_invoice_id is not null then
    return new;
  end if;

  seller_organization_id := new.organization_id;

  if seller_organization_id is null then
    update public.menu_orders
       set books_accounting_status = 'failed',
           books_accounting_error = 'Menu order has no hotel organization'
     where id = new.id;
    return new;
  end if;

  if exists (
    select 1
      from public.menu_order_items order_item
      join public.menu_items item on item.id = order_item.menu_item_id
     where order_item.order_id = new.id
       and item.organization_id is distinct from seller_organization_id
  ) then
    update public.menu_orders
       set books_accounting_status = 'failed',
           books_accounting_error = 'Menu order contains items from another or unmapped hotel'
     where id = new.id;
    return new;
  end if;

  customer_name := nullif(trim(concat_ws(' ', new.first_name, new.last_name)), '');
  customer_email := nullif(trim(new.email), '');
  customer_phone := nullif(trim(new.phone), '');

  if new.user_id is not null then
    select nullif(trim(concat_ws(' ', up.first_name, up.last_name)), ''),
           nullif(trim(up.email), ''),
           nullif(trim(up.phone), '')
      into customer_name, customer_email, customer_phone
      from public.user_profiles up
     where up.user_id = new.user_id;
    customer_name := coalesce(customer_name, nullif(trim(concat_ws(' ', new.first_name, new.last_name)), ''));
    customer_email := coalesce(customer_email, nullif(trim(new.email), ''));
    customer_phone := coalesce(customer_phone, nullif(trim(new.phone), ''));
  end if;

  if customer_email is null then
    update public.menu_orders
       set books_accounting_status = 'failed',
           books_accounting_error = 'A customer email is required for the Books invoice'
     where id = new.id;
    return new;
  end if;

  order_tax := coalesce(new.tax_amount, 0);
  order_subtotal := coalesce(new.subtotal, new.total_amount - order_tax);
  order_currency := upper(coalesce(new.currency, 'USD'))::char(3);

  select id
    into customer_contact_id
    from public.books_contacts
   where organization_id = seller_organization_id
     and lower(email) = lower(customer_email)
     and type in ('customer', 'both')
   order by created_at
   limit 1;

  if customer_contact_id is null then
    insert into public.books_contacts (organization_id, name, type, email, phone)
    values (seller_organization_id, coalesce(customer_name, customer_email), 'customer', customer_email, customer_phone)
    returning id into customer_contact_id;
  else
    update public.books_contacts
       set name = coalesce(customer_name, name),
           phone = coalesce(customer_phone, phone),
           updated_at = now()
     where id = customer_contact_id;
  end if;

  if order_tax > 0 and order_subtotal > 0 then
    tax_percentage := round(order_tax / order_subtotal * 100, 4);
    insert into public.books_tax_rates (organization_id, country_code, name, rate_percentage)
    values (seller_organization_id, 'UG', 'Menu sale tax ' || tax_percentage || '%', tax_percentage)
    on conflict (organization_id, name, effective_from) do nothing;

    select id
      into tax_uuid
      from public.books_tax_rates
     where organization_id = seller_organization_id
       and rate_percentage = tax_percentage
       and is_active
       and order_date >= effective_from
       and (effective_to is null or order_date <= effective_to)
     order by created_at desc
     limit 1;
  end if;

  select id
    into invoice_uuid
    from public.books_invoices
   where organization_id = seller_organization_id
     and invoice_number = 'MENU-' || new.order_number;

  if invoice_uuid is null then
    insert into public.books_invoices (
      organization_id, contact_id, invoice_number, issue_date, due_date,
      currency_code, subtotal, tax_amount, tax_rate_id, status, notes
    ) values (
      seller_organization_id, customer_contact_id, 'MENU-' || new.order_number,
      order_date, order_date, order_currency, order_subtotal, order_tax, tax_uuid,
      'paid', 'Digital menu order ' || new.order_number || ' (' || new.id || ')'
    ) returning id into invoice_uuid;
  end if;

  if not exists (select 1 from public.books_invoice_lines where invoice_id = invoice_uuid) then
    insert into public.books_invoice_lines (invoice_id, organization_id, description, quantity, unit_price)
    select invoice_uuid, seller_organization_id, item_name, quantity, unit_price
      from public.menu_order_items
     where order_id = new.id;
  end if;

  update public.menu_orders
     set books_invoice_id = invoice_uuid,
         books_accounting_status = 'posted',
         books_accounting_error = null
   where id = new.id;

  return new;
exception when others then
  update public.menu_orders
     set books_accounting_status = 'failed',
         books_accounting_error = left(sqlerrm, 2000)
   where id = new.id;
  return new;
end;
$$;

revoke all on function public.post_paid_menu_order_to_books_v2() from public;

do $$
declare
  target_invoice_id constant uuid := '65a3a1f7-0f80-4164-97f4-5d918e43671f';
  target_order_id constant uuid := 'e3f39cbe-9489-4a2c-8242-ca24236e36c8';
  target_organization_id constant uuid := '021b6cb3-b250-4454-9350-2883d4c50794';
  invoice_row public.books_invoices%rowtype;
  webhook_secret text;
  correlation_value uuid := gen_random_uuid();
  webhook_body jsonb;
  delivery_id uuid;
  request_id bigint;
begin
  update public.books_contacts contact
     set name = coalesce(nullif(trim(concat_ws(' ', profile.first_name, profile.last_name)), ''), contact.name),
         email = coalesce(nullif(trim(profile.email), ''), nullif(trim(menu_order.email), '')),
         phone = coalesce(nullif(trim(profile.phone), ''), nullif(trim(menu_order.phone), ''), contact.phone),
         updated_at = now()
    from public.books_invoices invoice
    join public.menu_orders menu_order
      on menu_order.books_invoice_id = invoice.id
    left join public.user_profiles profile
      on profile.user_id = menu_order.user_id
   where invoice.id = target_invoice_id
     and menu_order.id = target_order_id
     and invoice.organization_id = target_organization_id
     and menu_order.organization_id = target_organization_id
     and contact.id = invoice.contact_id
     and contact.organization_id = target_organization_id
     and (
       contact.email = 'Kons'
       or lower(contact.email) = lower(coalesce(nullif(trim(profile.email), ''), nullif(trim(menu_order.email), '')))
     )
     and coalesce(nullif(trim(profile.email), ''), nullif(trim(menu_order.email), '')) ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$';

  if not found then
    raise exception 'Expected paid invoice contact was not repaired; no receipt retry was queued';
  end if;

  select * into invoice_row
    from public.books_invoices
   where id = target_invoice_id
     and organization_id = target_organization_id
     and status = 'paid';
  if not found then
    raise exception 'Expected paid invoice was not found; no receipt retry was queued';
  end if;

  select decrypted_secret
    into webhook_secret
    from vault.decrypted_secrets
   where name = 'supabase_webhook_secret'
   limit 1;
  if webhook_secret is null or webhook_secret = '' then
    raise exception 'Vault secret supabase_webhook_secret is not configured';
  end if;

  webhook_body := jsonb_build_object(
    'correlationId', correlation_value::text,
    'type', 'UPDATE',
    'table', 'books_invoices',
    'schema', 'public',
    'record', to_jsonb(invoice_row),
    'old_record', jsonb_build_object('status', 'open')
  );

  insert into public.books_invoice_webhook_deliveries (
    invoice_id, organization_id, event_type, correlation_id, dedupe_key,
    sanitized_payload, attempt_count, status
  ) values (
    target_invoice_id, target_organization_id, 'invoice.paid', correlation_value,
    'invoice_receipt_retry:' || target_invoice_id::text || ':contact-email-fix-v1',
    webhook_body, 1, 'queued'
  )
  on conflict (organization_id, dedupe_key) do nothing
  returning id into delivery_id;

  if delivery_id is not null then
    select net.http_post(
      url := 'https://us-central1-speshio.cloudfunctions.net/generateAndSendInvoicePDF',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'X-Webhook-Secret', webhook_secret,
        'X-Correlation-ID', correlation_value::text
      ),
      body := webhook_body,
      timeout_milliseconds := 10000
    ) into request_id;

    update public.books_invoice_webhook_deliveries
       set pg_net_request_id = request_id,
           updated_at = now()
     where id = delivery_id;

    update public.books_invoices
       set receipt_delivery_status = 'queued',
           receipt_delivery_error = null,
           receipt_delivery_attempted_at = now()
     where id = target_invoice_id;
  end if;
end;
$$;

notify pgrst, 'reload schema';
commit;

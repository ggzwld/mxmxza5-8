alter table public.books_invoices
  add column if not exists invoice_url text,
  add column if not exists invoice_storage_key text,
  add column if not exists invoice_delivery_status text check (invoice_delivery_status is null or invoice_delivery_status in ('queued', 'sent', 'failed', 'skipped')),
  add column if not exists invoice_delivery_error text,
  add column if not exists invoice_delivery_attempted_at timestamptz;

create or replace function public.send_worker_task_invoice_email()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, net
as $$
declare
  invoice_row public.books_invoices%rowtype;
  task_row public.tasks%rowtype;
  webhook_body jsonb;
  webhook_secret text;
  delivery_id uuid;
  request_id bigint;
  correlation_value uuid := gen_random_uuid();
  dedupe_value text;
begin
  select * into invoice_row from public.books_invoices where id = new.invoice_id;
  select * into task_row from public.tasks where id = new.task_id;

  insert into public.books_invoice_lines (invoice_id, organization_id, description, quantity, unit_price)
  values (invoice_row.id, invoice_row.organization_id, 'Approved task: ' || task_row.title, 1, invoice_row.subtotal);

  begin
    select decrypted_secret into webhook_secret
      from vault.decrypted_secrets
     where name = 'supabase_webhook_secret'
     limit 1;
    if webhook_secret is null or webhook_secret = '' then
      raise exception 'Vault secret supabase_webhook_secret is not configured';
    end if;

    dedupe_value := 'task_invoice_issued:' || invoice_row.id::text;
    webhook_body := jsonb_build_object(
      'correlationId', correlation_value::text,
      'eventType', 'invoice.issued',
      'type', 'INSERT',
      'table', 'books_invoices',
      'schema', 'public',
      'record', to_jsonb(invoice_row),
      'old_record', null
    );

    insert into public.books_invoice_webhook_deliveries (
      invoice_id, organization_id, event_type, correlation_id, dedupe_key,
      sanitized_payload, attempt_count, status
    ) values (
      invoice_row.id, invoice_row.organization_id, 'invoice.issued', correlation_value,
      dedupe_value, webhook_body, 1, 'queued'
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
         set pg_net_request_id = request_id, updated_at = now()
       where id = delivery_id;
      update public.books_invoices
         set invoice_delivery_status = 'queued',
             invoice_delivery_error = null,
             invoice_delivery_attempted_at = now()
       where id = invoice_row.id;
    end if;
  exception when others then
    if delivery_id is not null then
      update public.books_invoice_webhook_deliveries
         set status = 'failed', sanitized_error = left(sqlerrm, 2000), updated_at = now()
       where id = delivery_id;
    end if;
    update public.books_invoices
       set invoice_delivery_status = 'failed',
           invoice_delivery_error = left(sqlerrm, 2000),
           invoice_delivery_attempted_at = now()
     where id = invoice_row.id;
  end;

  return new;
end;
$$;

revoke all on function public.send_worker_task_invoice_email() from public, anon, authenticated;
drop trigger if exists worker_task_invoice_email on public.worker_task_invoices;
create trigger worker_task_invoice_email
after insert on public.worker_task_invoices
for each row execute function public.send_worker_task_invoice_email();

create or replace function public.protect_worker_task_invoice_payment()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.status = 'paid' and old.status is distinct from 'paid' and exists (
    select 1 from public.worker_task_invoices invoice_link
     where invoice_link.invoice_id = new.id
       and not exists (
         select 1 from public.worker_task_payments payment
          where payment.task_id = invoice_link.task_id
       )
  ) then
    raise exception 'Worker task invoices can only be marked paid by recording the task payment';
  end if;
  return new;
end;
$$;

revoke all on function public.protect_worker_task_invoice_payment() from public, anon, authenticated;
drop trigger if exists protect_worker_task_invoice_payment on public.books_invoices;
create trigger protect_worker_task_invoice_payment
before update of status on public.books_invoices
for each row execute function public.protect_worker_task_invoice_payment();

notify pgrst, 'reload schema';

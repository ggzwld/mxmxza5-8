create or replace function public.conclude_negotiation(task_id_param uuid, provider_id_param uuid, final_price_param numeric default null::numeric, final_timeline_param character varying default null::character varying, final_notes_param text default null::text)
returns void
language plpgsql
as $function$
declare
  v_task_record tasks%rowtype;
  v_proposal_record task_proposals%rowtype;
begin
  select * into v_task_record from tasks where id = task_id_param;

  if not found then
    raise exception 'Task not found: %', task_id_param;
  end if;

  select * into v_proposal_record from task_proposals
  where task_id = task_id_param and worker_id = provider_id_param
  order by created_at desc limit 1;

  insert into public.task_negotiation_status (task_id, status, final_price, final_timeline, final_notes)
  values (task_id_param, 'agreed', final_price_param, final_timeline_param, final_notes_param)
  on conflict (task_id) do update set
    status = 'agreed',
    final_price = final_price_param,
    final_timeline = final_timeline_param,
    final_notes = final_notes_param,
    updated_at = now();

  insert into public.todo_list (
    task_id,
    worker_id,
    title,
    description,
    priority,
    due_date,
    details,
    status
  )
  values (
    task_id_param,
    provider_id_param,
    v_task_record.title,
    v_task_record.description,
    v_task_record.priority,
    v_task_record.due_date,
    jsonb_build_object(
      'category', v_task_record.category,
      'estimated_time', v_task_record.estimated_time,
      'payment_terms', v_task_record.payment_terms,
      'budget', v_task_record.budget,
      'agreed_price', coalesce(final_price_param, v_proposal_record.quoted_price, v_task_record.budget),
      'agreed_timeline', coalesce(final_timeline_param, v_proposal_record.proposed_timeline, v_task_record.estimated_time),
      'final_notes', final_notes_param
    ),
    'pending'::character varying
  )
  on conflict do nothing;

  insert into public.notifications (user_id, task_id, type, message)
  select
    up.user_id,
    task_id_param,
    'todo_created'::character varying,
    'Negotiation complete! A todo has been created with the final agreed terms.'
  from user_profiles up
  where up.id = provider_id_param;

  update public.task_negotiation_status
  set status = 'concluded', updated_at = now()
  where task_id = task_id_param;

end;
$function$;

create or replace function public.create_report_on_in_progress()
returns trigger
language plpgsql
security definer
as $function$
declare
  provider_user_id uuid;
begin
  if new.status = 'in_progress'
    and old.status != 'in_progress'
    and new.assigned_to is not null
  then
    select user_id into provider_user_id
    from user_profiles
    where id = new.assigned_to
    limit 1;

    insert into public.task_reports (
      task_id,
      worker_id,
      status,
      description,
      percentage_complete,
      last_updated_by
    )
    values (
      new.id,
      new.assigned_to,
      'in_progress',
      '',
      0,
      coalesce(provider_user_id, new.created_by)
    )
    on conflict do nothing;
  end if;

  return new;
end;
$function$;

create or replace function public.notify_manager_on_task_response()
returns trigger
language plpgsql
as $function$
begin
  insert into public.notifications (user_id, task_id, type, message)
  select
    t.created_by,
    new.task_id,
    case
      when new.action = 'accept' then 'task_accepted'::character varying
      when new.action = 'decline' then 'task_declined'::character varying
      when new.action = 'propose' then 'task_proposed'::character varying
    end,
    (
      select concat(up.first_name, ' ', up.last_name, ' has ', new.action, 'ed your task: ', t.title)
      from user_profiles up
      where up.id = new.worker_id
    )
  from tasks t
  where t.id = new.task_id;

  return new;
end;
$function$;

create or replace function public.notify_provider_on_proposal_update()
returns trigger
language plpgsql
as $function$
begin
  if new.status != old.status then
    insert into public.notifications (user_id, task_id, type, message)
    select
      up.user_id,
      new.task_id,
      case
        when new.status = 'accepted' then 'proposal_accepted'::character varying
        when new.status = 'declined' then 'proposal_declined'::character varying
        when new.status = 'counter_proposed' then 'proposal_updated'::character varying
        else 'task_updated'::character varying
      end,
      case
        when new.status = 'accepted' then 'Your proposal has been ACCEPTED! Check your Todo List for the task.'
        when new.status = 'declined' then 'Your proposal has been declined. You can submit a new proposal or chat with the manager.'
        when new.status = 'counter_proposed' then 'Manager has sent a counter-proposal. Review it and respond or chat to negotiate.'
        else 'Proposal status updated'
      end
    from user_profiles up
    where up.id = new.worker_id;
  end if;
  return new;
end;
$function$;

notify pgrst, 'reload schema';

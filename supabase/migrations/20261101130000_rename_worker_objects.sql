begin;

alter table public.service_provider_directory_profiles rename to worker_directory_profiles;
alter table public.service_provider_reviews rename to worker_reviews;
alter index public.service_provider_directory_listed_hotel_idx rename to worker_directory_listed_hotel_idx;
alter index public.service_provider_directory_listed_ecosystem_idx rename to worker_directory_listed_ecosystem_idx;
alter index public.service_provider_reviews_provider_idx rename to worker_reviews_worker_idx;

alter table public.worker_reviews rename column provider_profile_id to worker_profile_id;

alter table public.task_reports rename column provider_id to worker_id;
alter table public.task_evidence_submissions rename column provider_id to worker_id;
alter table public.task_issues rename column provider_id to worker_id;
alter table public.task_responses rename column provider_id to worker_id;
alter table public.task_proposals rename column provider_id to worker_id;
alter table public.todo_list rename column provider_id to worker_id;

alter index if exists public.idx_task_reports_provider_id rename to idx_task_reports_worker_id;
alter index if exists public.idx_task_evidence_submissions_provider_id rename to idx_task_evidence_submissions_worker_id;
alter index if exists public.idx_task_issues_provider_id rename to idx_task_issues_worker_id;

alter table public.books_memberships drop constraint if exists books_memberships_role_check;
update public.books_memberships set role = 'worker' where role = 'provider';
alter table public.books_memberships
  add constraint books_memberships_role_check
  check (role in ('owner', 'admin', 'member', 'worker'));

alter function public.get_my_service_provider_directory_profile() rename to get_my_worker_directory_profile;
alter function public.save_my_service_provider_directory_profile(boolean, text, uuid, text, text[], integer) rename to save_my_worker_directory_profile;
alter function public.delete_my_service_provider_directory_profile() rename to delete_my_worker_directory_profile;
alter function public.get_service_provider_directory(uuid) rename to get_worker_directory;
alter function public.submit_service_provider_review(uuid, integer, text) rename to submit_worker_review;
alter function public.get_service_provider_task_review(uuid) rename to get_worker_task_review;
alter function public.service_provider_is_listed_for_hotel(uuid, uuid) rename to worker_is_listed_for_hotel;

create or replace function public.get_my_worker_directory_profile()
returns table (
  is_listed boolean,
  visibility_scope text,
  organization_id uuid,
  professional_summary text,
  specialties text[],
  years_experience integer
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  return query
  select directory_profile.is_listed,
         directory_profile.visibility_scope,
         directory_profile.organization_id,
         directory_profile.professional_summary,
         directory_profile.specialties,
         directory_profile.years_experience
    from public.user_profiles profile
    join public.worker_directory_profiles directory_profile
      on directory_profile.profile_id = profile.id
   where profile.user_id = auth.uid()
     and profile.role in ('service_provider', 'worker')
     and profile.service_category = 'external';
end;
$$;

create or replace function public.delete_my_worker_directory_profile()
returns void
language plpgsql
security definer
volatile
set search_path = pg_catalog, public
as $$
declare
  worker_profile_id uuid;
begin
  select profile.id into worker_profile_id
    from public.user_profiles profile
   where profile.user_id = auth.uid()
     and profile.role in ('service_provider', 'worker')
     and profile.service_category = 'external'
   limit 1;
  if worker_profile_id is null then
    raise exception 'Only external workers can manage a directory profile';
  end if;

  delete from public.worker_directory_profiles
   where profile_id = worker_profile_id;
end;
$$;

create or replace function public.save_my_worker_directory_profile(
  target_is_listed boolean,
  target_visibility_scope text,
  target_organization_id uuid,
  target_professional_summary text,
  target_specialties text[],
  target_years_experience integer
)
returns void
language plpgsql
security definer
volatile
set search_path = pg_catalog, public
as $$
declare
  worker_profile_id uuid;
  cleaned_specialties text[];
begin
  select profile.id into worker_profile_id
    from public.user_profiles profile
   where profile.user_id = auth.uid()
     and profile.role in ('service_provider', 'worker')
     and profile.service_category = 'external'
   limit 1;
  if worker_profile_id is null then
    raise exception 'Only external workers can manage a directory profile';
  end if;
  if target_visibility_scope is null or target_visibility_scope not in ('hotel', 'ecosystem') then
    raise exception 'Invalid directory visibility scope';
  end if;
  if (target_visibility_scope = 'hotel') <> (target_organization_id is not null) then
    raise exception 'Choose a hotel for hotel-only visibility';
  end if;
  if target_is_listed and target_visibility_scope = 'hotel' and not exists (
    select 1 from public.hotel_tenant_settings settings
     where settings.organization_id = target_organization_id
       and settings.is_active
  ) then
    raise exception 'Choose an active hotel';
  end if;
  if char_length(coalesce(target_professional_summary, '')) > 1000 then
    raise exception 'Professional summary must be 1000 characters or fewer';
  end if;
  if target_years_experience is not null and target_years_experience not between 0 and 80 then
    raise exception 'Years of experience must be between 0 and 80';
  end if;
  if cardinality(coalesce(target_specialties, '{}')) > 12 then
    raise exception 'Choose no more than 12 specialties';
  end if;

  select coalesce(array_agg(distinct btrim(specialty)) filter (where btrim(specialty) <> ''), '{}')
    into cleaned_specialties
    from unnest(coalesce(target_specialties, '{}')) as input(specialty);
  if exists (select 1 from unnest(cleaned_specialties) as input(specialty) where char_length(specialty) > 80) then
    raise exception 'Each specialty must be 80 characters or fewer';
  end if;

  insert into public.worker_directory_profiles (
    profile_id, is_listed, visibility_scope, organization_id,
    professional_summary, specialties, years_experience, updated_at
  ) values (
    worker_profile_id, target_is_listed, target_visibility_scope, target_organization_id,
    coalesce(target_professional_summary, ''), cleaned_specialties, target_years_experience, now()
  )
  on conflict (profile_id) do update
     set is_listed = excluded.is_listed,
         visibility_scope = excluded.visibility_scope,
         organization_id = excluded.organization_id,
         professional_summary = excluded.professional_summary,
         specialties = excluded.specialties,
         years_experience = excluded.years_experience,
         updated_at = now();
end;
$$;

create or replace function public.worker_is_listed_for_hotel(target_profile_id uuid, target_organization_id uuid)
returns boolean
language sql
security definer
stable
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
      from public.worker_directory_profiles directory_profile
      join public.user_profiles profile on profile.id = directory_profile.profile_id
     where directory_profile.profile_id = target_profile_id
       and directory_profile.is_listed
       and profile.role in ('service_provider', 'worker')
       and profile.service_category = 'external'
       and exists (
         select 1 from public.hotel_tenant_settings settings
          where settings.organization_id = target_organization_id
            and settings.is_active
       )
       and (
         directory_profile.visibility_scope = 'ecosystem'
         or directory_profile.organization_id = target_organization_id
       )
  );
$$;

create or replace function public.submit_worker_review(
  target_task_id uuid,
  target_rating integer,
  target_testimonial text
)
returns void
language plpgsql
security definer
volatile
set search_path = pg_catalog, public
as $$
declare
  task_row public.tasks%rowtype;
begin
  if target_rating not between 1 and 5 then
    raise exception 'Rating must be between 1 and 5';
  end if;
  if char_length(coalesce(target_testimonial, '')) > 1000 then
    raise exception 'Testimonial must be 1000 characters or fewer';
  end if;

  select * into task_row
    from public.tasks task
   where task.id = target_task_id;
  if not found
     or not exists (
       select 1 from public.hotel_tenant_settings settings
        where settings.organization_id = task_row.organization_id
          and settings.is_active
     )
     or not public.hotel_user_manages_organization(task_row.organization_id) then
    raise exception 'Not authorized to review this task';
  end if;
  if task_row.status <> 'completed' or task_row.assigned_to is null or task_row.assigned_category <> 'external' then
    raise exception 'Only completed worker tasks can be reviewed';
  end if;
  if not exists (
    select 1 from public.task_reports report
     where report.task_id = task_row.id
       and report.worker_id = task_row.assigned_to
       and report.status = 'approved'
  ) then
    raise exception 'The worker report must be approved before review';
  end if;
  if not exists (
    select 1 from public.user_profiles profile
     where profile.id = task_row.assigned_to
       and profile.role in ('service_provider', 'worker')
       and profile.service_category = 'external'
  ) then
    raise exception 'Only external workers can be reviewed in the directory';
  end if;

  insert into public.worker_reviews (
    task_id, worker_profile_id, organization_id, reviewer_user_id, rating, testimonial, updated_at
  ) values (
    task_row.id, task_row.assigned_to, task_row.organization_id, auth.uid(), target_rating,
    btrim(coalesce(target_testimonial, '')), now()
  )
  on conflict (task_id) do update
     set worker_profile_id = excluded.worker_profile_id,
         organization_id = excluded.organization_id,
         rating = excluded.rating,
         testimonial = excluded.testimonial,
         reviewer_user_id = excluded.reviewer_user_id,
         updated_at = now();
end;
$$;

create or replace function public.get_worker_task_review(target_task_id uuid)
returns table (
  rating integer,
  testimonial text
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  task_organization_id uuid;
begin
  select task.organization_id into task_organization_id
    from public.tasks task
   where task.id = target_task_id;
  if task_organization_id is null
     or not exists (
       select 1 from public.hotel_tenant_settings settings
        where settings.organization_id = task_organization_id
          and settings.is_active
     )
     or not public.hotel_user_manages_organization(task_organization_id) then
    raise exception 'Not authorized to view this task review';
  end if;

  return query
  select review.rating, review.testimonial
    from public.worker_reviews review
   where review.task_id = target_task_id;
end;
$$;

create or replace function public.get_worker_directory(target_organization_id uuid)
returns table (
  profile_id uuid,
  full_name text,
  service_type text,
  location text,
  profile_picture text,
  professional_summary text,
  specialties text[],
  years_experience integer,
  completed_task_count bigint,
  average_rating numeric,
  review_count bigint,
  testimonials jsonb
)
language plpgsql
security definer
stable
set search_path = pg_catalog, public
as $$
begin
  if target_organization_id is null
     or not exists (
       select 1 from public.hotel_tenant_settings settings
        where settings.organization_id = target_organization_id
          and settings.is_active
     )
     or not public.hotel_user_manages_organization(target_organization_id) then
    raise exception 'Not authorized to browse workers for this hotel';
  end if;

  return query
  select profile.id,
         nullif(trim(concat_ws(' ', profile.first_name, profile.last_name)), '')::text,
         profile.service_type::text,
         profile.location::text,
         profile.profile_picture::text,
         directory_profile.professional_summary,
         directory_profile.specialties,
         directory_profile.years_experience,
         coalesce(completed.completed_task_count, 0),
         coalesce(reviews.average_rating, 0),
         coalesce(reviews.review_count, 0),
         coalesce(recent_testimonials.testimonials, '[]'::jsonb)
    from public.worker_directory_profiles directory_profile
    join public.user_profiles profile on profile.id = directory_profile.profile_id
    left join lateral (
      select count(*)::bigint as completed_task_count
        from public.tasks task
       where task.assigned_to = profile.id
         and task.organization_id = target_organization_id
         and task.status = 'completed'
         and exists (
           select 1 from public.task_reports report
            where report.task_id = task.id
              and report.worker_id = profile.id
              and report.status = 'approved'
         )
    ) completed on true
    left join lateral (
      select round(avg(review.rating)::numeric, 1) as average_rating,
             count(*)::bigint as review_count
        from public.worker_reviews review
       where review.worker_profile_id = profile.id
         and review.organization_id = target_organization_id
    ) reviews on true
    left join lateral (
      select jsonb_agg(
               jsonb_build_object(
                 'rating', recent_review.rating,
                 'testimonial', recent_review.testimonial,
                 'reviewer_name', recent_review.reviewer_name,
                 'created_at', recent_review.created_at
               ) order by recent_review.created_at desc
             ) as testimonials
        from (
          select review.rating,
                 review.testimonial,
                 coalesce(nullif(trim(concat_ws(' ', reviewer.first_name, reviewer.last_name)), ''), 'Hotel manager') as reviewer_name,
                 review.created_at
            from public.worker_reviews review
            left join public.user_profiles reviewer on reviewer.user_id = review.reviewer_user_id
           where review.worker_profile_id = profile.id
             and review.organization_id = target_organization_id
             and review.testimonial <> ''
           order by review.created_at desc
           limit 2
        ) recent_review
    ) recent_testimonials on true
   where directory_profile.is_listed
     and profile.role in ('service_provider', 'worker')
     and profile.service_category = 'external'
     and (
       directory_profile.visibility_scope = 'ecosystem'
       or directory_profile.organization_id = target_organization_id
     )
   order by profile.first_name, profile.last_name;
end;
$$;

create or replace function public.attach_task_hotel_organization()
returns trigger
language plpgsql
security definer
volatile
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'UPDATE' and old.organization_id is not null and new.organization_id is distinct from old.organization_id then
    raise exception 'Task hotel ownership cannot be changed';
  end if;
  if new.organization_id is null
     or not exists (
       select 1 from public.hotel_tenant_settings settings
        where settings.organization_id = new.organization_id
          and settings.is_active
     )
     or not public.hotel_user_manages_organization(new.organization_id, auth.uid()) then
    raise exception 'Task creator is not authorized for this hotel';
  end if;
  if new.complaint_id is not null and not exists (
    select 1 from public.complaints complaint
     where complaint.id = new.complaint_id and complaint.organization_id = new.organization_id
  ) then
    raise exception 'Task complaint must belong to the same hotel';
  end if;
  if new.assigned_to is not null
     and not exists (
       select 1
         from public.user_profiles profile
        where profile.id = new.assigned_to
          and (
            (
              new.assigned_category = 'external'
              and profile.role in ('service_provider', 'worker')
              and profile.service_category = 'external'
              and public.worker_is_listed_for_hotel(profile.id, new.organization_id)
            )
            or (
              new.assigned_category = 'internal'
              and profile.role in ('manager', 'service_provider', 'worker')
              and profile.service_category = 'internal'
              and exists (
                select 1 from public.books_memberships membership
                 where membership.user_id = profile.user_id
                   and membership.organization_id = new.organization_id
              )
            )
          )
     ) then
    raise exception 'Task assignee must match the assignment type and belong to this hotel';
  end if;
  return new;
end;
$$;

create or replace function public.can_manage_hotel_menu(target_organization_id uuid)
returns boolean
language sql
security definer
stable
set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.books_memberships membership
     where membership.organization_id = target_organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin', 'manager')
  ) or exists (
    select 1
      from public.books_memberships membership
      join public.user_profiles profile on profile.user_id = membership.user_id
     where membership.organization_id = target_organization_id
       and membership.user_id = auth.uid()
       and membership.role = 'worker'
       and profile.role in ('service_provider', 'worker')
       and profile.menu_access_approved
       and profile.menu_access_role in ('chef', 'food_beverage_manager')
  );
$$;

create or replace function public.approve_menu_access(target_user_id uuid)
returns void
language plpgsql
security definer
volatile
set search_path = public
as $$
begin
  if not public.is_manager() then
    raise exception 'Only managers can approve menu access';
  end if;

  update public.user_profiles
  set
    menu_access_approved = true,
    updated_at = now()
  where user_id = target_user_id
    and role in ('service_provider', 'worker')
    and menu_access_role in ('chef', 'food_beverage_manager');

  if not found then
    raise exception 'Worker is not an eligible culinary access request';
  end if;
end;
$$;

create or replace function public.approve_task_report_and_award_points(target_report_id uuid)
returns integer
language plpgsql
security definer
volatile
set search_path = pg_catalog, public
as $$
declare
  report_row public.task_reports%rowtype;
  task_row public.tasks%rowtype;
  worker_user_id uuid;
  actor_role text;
  points_this_month bigint;
  reward_points integer;
  program_row public.hotel_loyalty_programs%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in to approve task work'; end if;
  select role into actor_role from public.user_profiles where user_id = auth.uid();
  select * into report_row from public.task_reports where id = target_report_id for update;
  if not found then raise exception 'Task report was not found'; end if;
  select * into task_row from public.tasks where id = report_row.task_id for update;
  if not found or task_row.created_by <> auth.uid() or actor_role <> 'manager' then raise exception 'Only the task manager can approve this report'; end if;
  if task_row.assigned_to is distinct from report_row.worker_id or report_row.status <> 'completed_pending_approval' then
    raise exception 'This task report is not ready for approval';
  end if;
  select user_id into worker_user_id from public.user_profiles where id = report_row.worker_id and role in ('service_provider', 'worker');
  if worker_user_id is null then raise exception 'Assigned worker account was not found'; end if;
  update public.task_reports set status = 'approved', last_updated_by = auth.uid(), updated_at = now() where id = report_row.id;
  update public.tasks set status = 'completed', updated_at = now() where id = task_row.id;
  insert into public.notifications (user_id, task_id, type, message)
  values (worker_user_id, task_row.id, 'task_updated', 'Your task "' || task_row.title || '" has been approved and marked complete.');
  if task_row.organization_id is null then return 0; end if;
  select * into program_row from public.hotel_loyalty_programs where organization_id = task_row.organization_id and program_enabled;
  if not found then return 0; end if;
  perform public.hotel_loyalty_make_account(task_row.organization_id, worker_user_id);
  select * into program_row from public.hotel_loyalty_programs where organization_id = task_row.organization_id;
  select coalesce(sum(points_delta), 0) into points_this_month from public.hotel_loyalty_ledger_entries
  where organization_id = task_row.organization_id and user_id = worker_user_id and entry_type = 'task_earn'
    and created_at >= date_trunc('month', now());
  reward_points := least(program_row.task_approval_points, greatest(program_row.monthly_task_points_cap - points_this_month, 0)::integer);
  if reward_points > 0 and exists (select 1 from public.hotel_loyalty_accounts where organization_id = task_row.organization_id and user_id = worker_user_id and is_enrolled) then
    if public.apply_hotel_loyalty_delta(task_row.organization_id, worker_user_id, 'task_earn', reward_points,
      'approved_task', task_row.id, 'Manager-approved hotel task reward') is null then reward_points := 0; end if;
  else reward_points := 0; end if;
  perform public.qualify_hotel_loyalty_referral(task_row.organization_id, worker_user_id, 'task', 'approved_task', task_row.id, null);
  return reward_points;
end;
$$;

create or replace function public.submit_task_report_for_approval(target_report_id uuid)
returns void
language plpgsql
security definer
volatile
set search_path = pg_catalog, public
as $$
declare
  report_row public.task_reports%rowtype;
  worker_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to submit work for approval'; end if;
  select id into worker_profile_id from public.user_profiles
   where user_id = auth.uid() and role in ('service_provider', 'worker');
  if worker_profile_id is null then raise exception 'Only the assigned worker can submit this report'; end if;
  select * into report_row from public.task_reports where id = target_report_id for update;
  if not found or report_row.worker_id <> worker_profile_id then raise exception 'Task report was not found'; end if;
  if report_row.status <> 'in_progress' or report_row.percentage_complete < 100 then raise exception 'Complete the report before requesting approval'; end if;
  update public.task_reports set status = 'completed_pending_approval', last_updated_by = auth.uid(), updated_at = now() where id = target_report_id;
end;
$$;

create or replace function public.qualify_loyalty_referral(
  target_user_id uuid,
  target_qualification_type text,
  target_source_type text,
  target_source_id uuid,
  target_purchase_ugx numeric
)
returns void
language plpgsql
security definer
volatile
set search_path = pg_catalog, public
as $$
declare
  referral_row public.loyalty_referrals%rowtype;
  bonus_referrer integer;
  bonus_invitee integer;
  profile_role text;
  valid_milestone boolean := false;
  purchase_created_at timestamptz;
  referral_minimum numeric;
begin
  if target_qualification_type = 'purchase' then
    select created_at into purchase_created_at
      from public.loyalty_award_queue
     where user_id = target_user_id and source_type = target_source_type
       and source_id = target_source_id and status = 'posted';
    select guest_referral_minimum_ugx into referral_minimum
      from public.loyalty_program_settings where id = true;
    valid_milestone := coalesce(target_purchase_ugx >= referral_minimum, false)
      and purchase_created_at is not null
      and not exists (
        select 1 from public.loyalty_award_queue earlier_purchase
         where earlier_purchase.user_id = target_user_id
           and earlier_purchase.source_type in ('menu_order', 'hotel_booking', 'special_event_payment')
           and earlier_purchase.created_at < purchase_created_at
      );
  elsif target_qualification_type = 'task' then
    select exists (
      select 1 from public.task_reports report
      join public.tasks task on task.id = report.task_id
      join public.user_profiles worker on worker.id = report.worker_id
      where report.task_id = target_source_id and report.status = 'approved'
        and task.status = 'completed' and worker.user_id = target_user_id
        and worker.role in ('service_provider', 'worker')
    ) into valid_milestone;
  elsif target_qualification_type = 'manager_listing' then
    select exists (
      select 1 from public.hotel_rooms room
      join public.user_profiles manager on manager.user_id = room.created_by
      where room.id = target_source_id and room.status = 'published'
        and room.created_by = target_user_id and manager.role = 'manager'
    ) into valid_milestone;
  end if;
  if not exists (select 1 from public.loyalty_program_settings where id = true and program_enabled) then return; end if;
  if not valid_milestone then return; end if;
  if not exists (
    select 1
      from public.loyalty_referrals referral
      join public.loyalty_accounts invitee on invitee.user_id = referral.referred_user_id and invitee.is_enrolled
      join public.loyalty_accounts referrer on referrer.user_id = referral.referrer_user_id and referrer.is_enrolled
     where referral.referred_user_id = target_user_id and referral.status = 'pending'
  ) then return; end if;

  select role into profile_role from public.user_profiles where user_id = target_user_id;
  if target_qualification_type = 'purchase' and profile_role is distinct from 'guest' then return; end if;
  if target_qualification_type in ('task', 'manager_listing') and profile_role not in ('manager', 'service_provider', 'worker') then return; end if;

  perform 1 from public.loyalty_accounts where user_id = target_user_id for update;
  select * into referral_row from public.loyalty_referrals
   where referred_user_id = target_user_id and status = 'pending' for update;
  if not found then return; end if;
  select referrer_bonus_points, invitee_bonus_points into bonus_referrer, bonus_invitee
    from public.loyalty_program_settings where id = true;
  update public.loyalty_referrals
     set status = 'qualified', qualification_type = target_qualification_type,
         qualification_source_type = target_source_type, qualification_source_id = target_source_id,
         referrer_points = bonus_referrer, invitee_points = bonus_invitee, qualified_at = now()
   where id = referral_row.id;
  perform public.apply_loyalty_points_delta(
    referral_row.referrer_user_id, 'referral_earn', bonus_referrer, 'referral', referral_row.id,
    'Qualified referral reward'
  );
  perform public.apply_loyalty_points_delta(
    referral_row.referred_user_id, 'referral_welcome', bonus_invitee, 'referral', referral_row.id,
    'Referral welcome reward'
  );
end;
$$;

create or replace function public.qualify_hotel_loyalty_referral(
  target_organization_id uuid, target_user_id uuid, target_qualification_type text,
  target_source_type text, target_source_id uuid, target_purchase_ugx numeric default null
)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare referral_row public.hotel_loyalty_referrals%rowtype; program_row public.hotel_loyalty_programs%rowtype;
begin
  select * into program_row from public.hotel_loyalty_programs where organization_id = target_organization_id and program_enabled;
  if not found then return; end if;
  if target_qualification_type = 'purchase' then
    if target_purchase_ugx < program_row.guest_referral_minimum_ugx
       or not exists (select 1 from public.user_profiles where user_id = target_user_id and role = 'guest') then return; end if;
    if exists (
      select 1 from public.hotel_loyalty_award_queue prior
      where prior.organization_id = target_organization_id and prior.user_id = target_user_id
        and (prior.source_created_at, prior.id) < (
          select current.source_created_at, current.id from public.hotel_loyalty_award_queue current
          where current.organization_id = target_organization_id and current.source_type = target_source_type and current.source_id = target_source_id
        )
    ) then return; end if;
  elsif target_qualification_type = 'task' then
    if not exists (
      select 1 from public.task_reports report join public.tasks task on task.id = report.task_id
      join public.user_profiles worker on worker.id = report.worker_id
      where report.task_id = target_source_id and report.status = 'approved' and task.status = 'completed'
        and task.organization_id = target_organization_id and worker.user_id = target_user_id
    ) or exists (
      select 1 from public.task_reports prior_report join public.tasks prior_task on prior_task.id = prior_report.task_id
      join public.user_profiles worker on worker.id = prior_report.worker_id
      where prior_report.status = 'approved' and prior_task.status = 'completed'
        and prior_task.organization_id = target_organization_id and worker.user_id = target_user_id
        and prior_task.id <> target_source_id
    ) then return; end if;
  elsif target_qualification_type = 'manager_listing' then
    if not exists (select 1 from public.hotel_rooms room where room.id = target_source_id
      and room.organization_id = target_organization_id and room.status = 'published' and room.created_by = target_user_id)
       or exists (select 1 from public.hotel_rooms prior_room where prior_room.organization_id = target_organization_id
        and prior_room.created_by = target_user_id and prior_room.status = 'published' and prior_room.id <> target_source_id) then return; end if;
  else return;
  end if;
  select * into referral_row from public.hotel_loyalty_referrals
   where organization_id = target_organization_id and referred_user_id = target_user_id and status = 'pending' for update;
  if not found
     or not exists (select 1 from public.hotel_loyalty_accounts where organization_id = target_organization_id and user_id = referral_row.referrer_user_id and is_enrolled)
     or not exists (select 1 from public.hotel_loyalty_accounts where organization_id = target_organization_id and user_id = target_user_id and is_enrolled) then return; end if;
  update public.hotel_loyalty_referrals set status = 'qualified', qualification_type = target_qualification_type,
    qualification_source_type = target_source_type, qualification_source_id = target_source_id,
    referrer_points = program_row.referrer_bonus_points, invitee_points = program_row.invitee_bonus_points,
    qualified_at = now() where id = referral_row.id;
  perform public.apply_hotel_loyalty_delta(target_organization_id, referral_row.referrer_user_id, 'referral_earn',
    program_row.referrer_bonus_points, 'hotel_referral', referral_row.id, 'Qualified hotel referral reward');
  perform public.apply_hotel_loyalty_delta(target_organization_id, target_user_id, 'referral_welcome',
    program_row.invitee_bonus_points, 'hotel_referral', referral_row.id, 'Hotel referral welcome reward');
end;
$$;

notify pgrst, 'reload schema';

commit;

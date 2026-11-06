begin;

create table public.service_provider_directory_profiles (
  profile_id uuid primary key references public.user_profiles(id) on delete cascade,
  is_listed boolean not null default false,
  visibility_scope text not null default 'ecosystem' check (visibility_scope in ('hotel', 'ecosystem')),
  organization_id uuid references public.books_organizations(id) on delete cascade,
  professional_summary text not null default '',
  specialties text[] not null default '{}',
  years_experience integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((visibility_scope = 'hotel') = (organization_id is not null)),
  check (years_experience is null or years_experience between 0 and 80)
);

create index service_provider_directory_listed_hotel_idx
  on public.service_provider_directory_profiles (organization_id)
  where is_listed and visibility_scope = 'hotel';

create index service_provider_directory_listed_ecosystem_idx
  on public.service_provider_directory_profiles (profile_id)
  where is_listed and visibility_scope = 'ecosystem';

alter table public.service_provider_directory_profiles enable row level security;
revoke all on public.service_provider_directory_profiles from public, anon, authenticated;

create table public.service_provider_reviews (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null unique references public.tasks(id) on delete restrict,
  provider_profile_id uuid not null references public.user_profiles(id) on delete restrict,
  organization_id uuid not null references public.books_organizations(id) on delete restrict,
  reviewer_user_id uuid not null references auth.users(id) on delete restrict,
  rating integer not null check (rating between 1 and 5),
  testimonial text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index service_provider_reviews_provider_idx
  on public.service_provider_reviews (provider_profile_id, created_at desc);

alter table public.service_provider_reviews enable row level security;
revoke all on public.service_provider_reviews from public, anon, authenticated;

create or replace function public.get_my_service_provider_directory_profile()
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
    join public.service_provider_directory_profiles directory_profile
      on directory_profile.profile_id = profile.id
   where profile.user_id = auth.uid()
     and profile.role = 'service_provider'
     and profile.service_category = 'external';
end;
$$;
revoke all on function public.get_my_service_provider_directory_profile() from public, anon;
grant execute on function public.get_my_service_provider_directory_profile() to authenticated;

create or replace function public.save_my_service_provider_directory_profile(
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
set search_path = pg_catalog, public
as $$
declare
  provider_profile_id uuid;
  cleaned_specialties text[];
begin
  select profile.id into provider_profile_id
    from public.user_profiles profile
   where profile.user_id = auth.uid()
     and profile.role = 'service_provider'
     and profile.service_category = 'external'
   limit 1;
  if provider_profile_id is null then
    raise exception 'Only external service providers can manage a directory profile';
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

  insert into public.service_provider_directory_profiles (
    profile_id, is_listed, visibility_scope, organization_id,
    professional_summary, specialties, years_experience, updated_at
  ) values (
    provider_profile_id, target_is_listed, target_visibility_scope, target_organization_id,
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
revoke all on function public.save_my_service_provider_directory_profile(boolean, text, uuid, text, text[], integer) from public, anon;
grant execute on function public.save_my_service_provider_directory_profile(boolean, text, uuid, text, text[], integer) to authenticated;

create or replace function public.get_service_provider_directory(target_organization_id uuid)
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
stable
security definer
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
    raise exception 'Not authorized to browse providers for this hotel';
  end if;

  return query
  select profile.id,
         nullif(trim(concat_ws(' ', profile.first_name, profile.last_name)), ''),
         profile.service_type,
         profile.location,
         profile.profile_picture,
         directory_profile.professional_summary,
         directory_profile.specialties,
         directory_profile.years_experience,
         coalesce(completed.completed_task_count, 0),
         coalesce(reviews.average_rating, 0),
         coalesce(reviews.review_count, 0),
         coalesce(recent_testimonials.testimonials, '[]'::jsonb)
    from public.service_provider_directory_profiles directory_profile
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
              and report.provider_id = profile.id
              and report.status = 'approved'
         )
    ) completed on true
    left join lateral (
      select round(avg(review.rating)::numeric, 1) as average_rating,
             count(*)::bigint as review_count
        from public.service_provider_reviews review
       where review.provider_profile_id = profile.id
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
            from public.service_provider_reviews review
            left join public.user_profiles reviewer on reviewer.user_id = review.reviewer_user_id
           where review.provider_profile_id = profile.id
             and review.organization_id = target_organization_id
             and review.testimonial <> ''
           order by review.created_at desc
           limit 2
        ) recent_review
    ) recent_testimonials on true
   where directory_profile.is_listed
     and profile.role = 'service_provider'
     and profile.service_category = 'external'
     and (
       directory_profile.visibility_scope = 'ecosystem'
       or directory_profile.organization_id = target_organization_id
     )
   order by profile.first_name, profile.last_name;
end;
$$;
revoke all on function public.get_service_provider_directory(uuid) from public, anon;
grant execute on function public.get_service_provider_directory(uuid) to authenticated;

create or replace function public.submit_service_provider_review(
  target_task_id uuid,
  target_rating integer,
  target_testimonial text
)
returns void
language plpgsql
security definer
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
    raise exception 'Only completed provider tasks can be reviewed';
  end if;
  if not exists (
    select 1 from public.task_reports report
     where report.task_id = task_row.id
       and report.provider_id = task_row.assigned_to
       and report.status = 'approved'
  ) then
    raise exception 'The provider report must be approved before review';
  end if;
  if not exists (
    select 1 from public.user_profiles profile
     where profile.id = task_row.assigned_to
       and profile.role = 'service_provider'
       and profile.service_category = 'external'
  ) then
    raise exception 'Only external service providers can be reviewed in the directory';
  end if;

  insert into public.service_provider_reviews (
    task_id, provider_profile_id, organization_id, reviewer_user_id, rating, testimonial, updated_at
  ) values (
    task_row.id, task_row.assigned_to, task_row.organization_id, auth.uid(), target_rating,
    btrim(coalesce(target_testimonial, '')), now()
  )
  on conflict (task_id) do update
     set provider_profile_id = excluded.provider_profile_id,
         organization_id = excluded.organization_id,
         rating = excluded.rating,
         testimonial = excluded.testimonial,
         reviewer_user_id = excluded.reviewer_user_id,
         updated_at = now();
end;
$$;
revoke all on function public.submit_service_provider_review(uuid, integer, text) from public, anon;
grant execute on function public.submit_service_provider_review(uuid, integer, text) to authenticated;

create or replace function public.get_service_provider_task_review(target_task_id uuid)
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
    from public.service_provider_reviews review
   where review.task_id = target_task_id;
end;
$$;
revoke all on function public.get_service_provider_task_review(uuid) from public, anon;
grant execute on function public.get_service_provider_task_review(uuid) to authenticated;

create or replace function public.service_provider_is_listed_for_hotel(
  target_profile_id uuid,
  target_organization_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
      from public.service_provider_directory_profiles directory_profile
      join public.user_profiles profile on profile.id = directory_profile.profile_id
     where directory_profile.profile_id = target_profile_id
       and directory_profile.is_listed
       and profile.role = 'service_provider'
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
revoke all on function public.service_provider_is_listed_for_hotel(uuid, uuid) from public, anon, authenticated;

create or replace function public.attach_task_hotel_organization()
returns trigger
language plpgsql
security definer
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
              and profile.role = 'service_provider'
              and profile.service_category = 'external'
              and public.service_provider_is_listed_for_hotel(profile.id, new.organization_id)
            )
            or (
              new.assigned_category = 'internal'
              and profile.role in ('manager', 'service_provider')
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
revoke all on function public.attach_task_hotel_organization() from public, anon, authenticated;
drop trigger if exists task_hotel_organization on public.tasks;
create trigger task_hotel_organization
before insert or update of organization_id, created_by, complaint_id, assigned_to, assigned_category
on public.tasks
for each row execute function public.attach_task_hotel_organization();

notify pgrst, 'reload schema';
commit;

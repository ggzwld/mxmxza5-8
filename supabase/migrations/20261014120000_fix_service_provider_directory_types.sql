begin;

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

notify pgrst, 'reload schema';
commit;

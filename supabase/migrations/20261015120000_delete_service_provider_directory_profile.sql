begin;

create or replace function public.delete_my_service_provider_directory_profile()
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  provider_profile_id uuid;
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

  delete from public.service_provider_directory_profiles
   where profile_id = provider_profile_id;
end;
$$;

revoke all on function public.delete_my_service_provider_directory_profile() from public, anon;
grant execute on function public.delete_my_service_provider_directory_profile() to authenticated;

notify pgrst, 'reload schema';
commit;

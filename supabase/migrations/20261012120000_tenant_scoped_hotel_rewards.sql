revoke all on function public.get_my_hotel_loyalty_programs() from public, anon, authenticated;
revoke all on function public.set_my_hotel_loyalty_enrollment(uuid, boolean) from public, anon, authenticated;
revoke all on public.hotel_loyalty_accounts, public.hotel_loyalty_ledger_entries,
  public.hotel_loyalty_referrals, public.hotel_loyalty_books_postings
  from public, anon, authenticated;

create or replace function public.get_hotel_loyalty_program_for_tenant(target_organization_id uuid, target_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path = pg_catalog, public
as $$
declare result jsonb;
begin
  if target_organization_id is null or target_user_id is null then
    raise exception 'Hotel and user are required';
  end if;
  select jsonb_build_object(
    'organizationId', program.organization_id, 'organizationName', organization.name,
    'programName', program.program_name, 'availablePoints', coalesce(account.available_points, 0),
    'lifetimePoints', coalesce(account.lifetime_points_earned, 0), 'debtPoints', coalesce(account.debt_points, 0),
    'enrolled', coalesce(account.is_enrolled, false), 'referralCode', account.referral_code,
    'programEnabled', program.program_enabled, 'redemptionEnabled', false,
    'referrals', jsonb_build_object(
      'total', (select count(*) from public.hotel_loyalty_referrals referral where referral.organization_id = program.organization_id and referral.referrer_user_id = target_user_id),
      'qualified', (select count(*) from public.hotel_loyalty_referrals referral where referral.organization_id = program.organization_id and referral.referrer_user_id = target_user_id and referral.status = 'qualified'),
      'pending', (select count(*) from public.hotel_loyalty_referrals referral where referral.organization_id = program.organization_id and referral.referrer_user_id = target_user_id and referral.status = 'pending'),
      'pointsEarned', coalesce((select sum(points_delta) from public.hotel_loyalty_ledger_entries where organization_id = program.organization_id and user_id = target_user_id and entry_type = 'referral_earn'), 0)
    ),
    'entries', coalesce((select jsonb_agg(jsonb_build_object('id', recent.id, 'entryType', recent.entry_type, 'pointsDelta', recent.points_delta, 'description', recent.description, 'createdAt', recent.created_at) order by recent.created_at desc) from (select id, entry_type, points_delta, description, created_at from public.hotel_loyalty_ledger_entries where organization_id = program.organization_id and user_id = target_user_id order by created_at desc limit 30) recent), '[]'::jsonb),
    'policy', jsonb_build_object('pointsPer1000Ugx', program.points_per_1000_ugx, 'guestReferralMinimumUgx', program.guest_referral_minimum_ugx, 'referrerBonusPoints', program.referrer_bonus_points, 'inviteeBonusPoints', program.invitee_bonus_points, 'taskApprovalPoints', program.task_approval_points, 'monthlyTaskPointsCap', program.monthly_task_points_cap, 'ugxValuePerPoint', program.ugx_value_per_point, 'programEnabled', program.program_enabled, 'redemptionEnabled', false, 'pointsExpire', false)
  ) into result
  from public.hotel_loyalty_programs program
  join public.books_organizations organization on organization.id = program.organization_id
  left join public.hotel_loyalty_accounts account on account.organization_id = program.organization_id and account.user_id = target_user_id
  where program.organization_id = target_organization_id
    and (program.program_enabled or account.user_id is not null);
  return result;
end;
$$;
revoke all on function public.get_hotel_loyalty_program_for_tenant(uuid, uuid) from public, anon, authenticated;
grant execute on function public.get_hotel_loyalty_program_for_tenant(uuid, uuid) to service_role;

create or replace function public.set_hotel_loyalty_enrollment_for_tenant(target_organization_id uuid, target_user_id uuid, target_enrolled boolean)
returns boolean language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if target_organization_id is null or target_user_id is null or target_enrolled is null then
    raise exception 'Hotel, user, and enrollment preference are required';
  end if;
  if not exists (select 1 from public.hotel_loyalty_programs where organization_id = target_organization_id) then
    raise exception 'This hotel rewards program is not available';
  end if;
  if target_enrolled and not exists (select 1 from public.hotel_loyalty_programs where organization_id = target_organization_id and program_enabled) then
    raise exception 'This hotel rewards program is not active';
  end if;
  if target_enrolled then
    perform public.hotel_loyalty_make_account(target_organization_id, target_user_id);
  end if;
  update public.hotel_loyalty_accounts set is_enrolled = target_enrolled,
    enrolled_at = case when target_enrolled and not is_enrolled then now() when not target_enrolled then null else enrolled_at end,
    updated_at = now()
  where organization_id = target_organization_id and user_id = target_user_id;
  return target_enrolled;
end;
$$;
revoke all on function public.set_hotel_loyalty_enrollment_for_tenant(uuid, uuid, boolean) from public, anon, authenticated;
grant execute on function public.set_hotel_loyalty_enrollment_for_tenant(uuid, uuid, boolean) to service_role;

notify pgrst, 'reload schema';

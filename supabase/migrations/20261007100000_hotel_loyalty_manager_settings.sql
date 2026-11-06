begin;

create or replace function public.get_hotel_loyalty_manager_settings(target_organization_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  organization_currency text;
  program_settings jsonb;
begin
  if auth.uid() is null
     or not public.hotel_loyalty_has_manager_access(target_organization_id, auth.uid()) then
    raise exception 'Only this hotel''s finance manager can view rewards settings';
  end if;

  select organization.base_currency::text
    into organization_currency
    from public.books_organizations organization
   where organization.id = target_organization_id;

  if not found then
    raise exception 'Hotel Books organization was not found';
  end if;

  select jsonb_build_object(
    'programName', program.program_name,
    'pointsPer1000Ugx', program.points_per_1000_ugx,
    'guestReferralMinimumUgx', program.guest_referral_minimum_ugx,
    'referrerBonusPoints', program.referrer_bonus_points,
    'inviteeBonusPoints', program.invitee_bonus_points,
    'taskApprovalPoints', program.task_approval_points,
    'monthlyTaskPointsCap', program.monthly_task_points_cap,
    'ugxValuePerPoint', program.ugx_value_per_point,
    'booksExpenseAccountCode', program.books_expense_account_code,
    'booksLiabilityAccountCode', program.books_liability_account_code,
    'programEnabled', program.program_enabled
  )
    into program_settings
    from public.hotel_loyalty_programs program
   where program.organization_id = target_organization_id;

  return jsonb_build_object(
    'organizationId', target_organization_id,
    'baseCurrency', organization_currency,
    'program', program_settings
  );
end;
$$;

revoke all on function public.get_hotel_loyalty_manager_settings(uuid) from public, anon;
grant execute on function public.get_hotel_loyalty_manager_settings(uuid) to authenticated;

notify pgrst, 'reload schema';
commit;

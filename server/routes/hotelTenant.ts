import type { Request, RequestHandler } from "express";

export type ResolvedHotelTenant = {
  organizationId: string;
  domain: string;
  name: string;
  logoUrl: string | null;
  primaryColor: string | null;
  accentColor: string | null;
};

type TenantRow = {
  organization_id: string;
  name: string;
  domain: string;
  logo_url: string | null;
  primary_color: string | null;
  accent_color: string | null;
};

type MenuItemRow = Record<string, unknown> & {
  id: string;
  media_type: string | null;
  media_attachment_id: string | null;
  media_aspect_ratio?: number | null;
};

const configuration = () => {
  const supabaseUrl = process.env.VITE_SUPABASE_URL;
  const supabaseAnonKey = process.env.VITE_SUPABASE_ANON_KEY;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !supabaseAnonKey || !serviceRoleKey) {
    throw new Error("Hotel tenant database configuration is incomplete");
  }
  return { supabaseUrl: supabaseUrl.replace(/\/$/, ""), supabaseAnonKey, serviceRoleKey };
};

const serviceHeaders = (json = false) => {
  const { supabaseAnonKey, serviceRoleKey } = configuration();
  return {
    apikey: supabaseAnonKey,
    Authorization: `Bearer ${serviceRoleKey}`,
    ...(json ? { "content-type": "application/json" } : {}),
  };
};

const hostnameFromRequest = (request: Request) => {
  const hostname = request.hostname.toLowerCase().replace(/\.$/, "");
  if (process.env.NODE_ENV !== "development") return hostname;

  const forwardedHost = request.headers?.["x-forwarded-host"];
  const forwardedHostname = (Array.isArray(forwardedHost) ? forwardedHost[0] : forwardedHost)
    ?.split(",")[0]
    .trim()
    .toLowerCase()
    .replace(/:\d+$/, "")
    .replace(/\.$/, "");
  return forwardedHostname?.endsWith(".projects.builder.my") ? forwardedHostname : hostname;
};

export const resolveRequestHotelTenant = async (request: Request): Promise<ResolvedHotelTenant> => {
  const hostname = hostnameFromRequest(request);
  if (!hostname) throw new Error("Hotel domain is missing");

  const previewOrganizationId = process.env.BUILDER_PREVIEW_TENANT_ORGANIZATION_ID;
  const isBuilderPreviewHost = hostname.endsWith(".projects.builder.my")
    || hostname === "localhost"
    || hostname === "127.0.0.1"
    || hostname === "::1";
  if (process.env.NODE_ENV === "development" && isBuilderPreviewHost && previewOrganizationId) {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(previewOrganizationId)) {
      throw new Error("Builder preview tenant configuration is invalid");
    }
    const previewTenants = await readService<Array<{
      organization_id: string;
      display_name: string;
      logo_url: string | null;
      primary_color: string | null;
      accent_color: string | null;
    }>>(
      `hotel_tenant_settings?organization_id=eq.${encodeURIComponent(previewOrganizationId)}&is_active=eq.true&select=organization_id,display_name,logo_url,primary_color,accent_color&limit=1`,
    );
    const previewTenant = previewTenants[0];
    if (!previewTenant) throw new Error("Builder preview hotel is not active");
    return {
      organizationId: previewTenant.organization_id,
      domain: hostname,
      name: previewTenant.display_name,
      logoUrl: previewTenant.logo_url,
      primaryColor: previewTenant.primary_color,
      accentColor: previewTenant.accent_color,
    };
  }

  const { supabaseUrl } = configuration();
  const tenantResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/resolve_hotel_tenant`, {
    method: "POST",
    headers: serviceHeaders(true),
    body: JSON.stringify({ target_hostname: hostname }),
    signal: AbortSignal.timeout(10_000),
  });
  const payload = await tenantResponse.json().catch(() => null) as TenantRow[] | TenantRow | null;
  const tenants = Array.isArray(payload) ? payload : payload ? [payload] : [];
  if (!tenantResponse.ok || tenants.length !== 1) throw new Error("This hotel domain is not configured");
  const tenant = tenants[0];

  return {
    organizationId: tenant.organization_id,
    domain: tenant.domain,
    name: tenant.name,
    logoUrl: tenant.logo_url,
    primaryColor: tenant.primary_color,
    accentColor: tenant.accent_color,
  };
};

const setPrivateTenantResponse = (response: { setHeader: (name: string, value: string) => unknown }) => response.setHeader("Cache-Control", "private, no-store");

const readService = async <T>(path: string): Promise<T> => {
  const { supabaseUrl } = configuration();
  const response = await fetch(`${supabaseUrl}/rest/v1/${path}`, {
    headers: serviceHeaders(),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error("Hotel information could not be loaded");
  return response.json() as Promise<T>;
};

const updateService = async (path: string, body: Record<string, unknown>) => {
  const { supabaseUrl } = configuration();
  const response = await fetch(`${supabaseUrl}/rest/v1/${path}`, {
    method: "PATCH",
    headers: { ...serviceHeaders(true), Prefer: "return=minimal" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error("Menu media information could not be saved");
};

const hotelOfferError = (message: string, status: number) => Object.assign(new Error(message), { status });

const writeService = async <T>(path: string, method: "POST" | "PATCH", body: Record<string, unknown>): Promise<T> => {
  const { supabaseUrl } = configuration();
  const response = await fetch(`${supabaseUrl}/rest/v1/${path}`, {
    method,
    headers: { ...serviceHeaders(true), Prefer: "return=representation" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw hotelOfferError("Hotel offer could not be saved", 503);
  return response.json() as Promise<T>;
};

const requireHotelManager = async (request: Request) => {
  const tenant = await resolveRequestHotelTenant(request);
  const userId = await getAuthenticatedUserId(request.headers.authorization);
  const organizationId = encodeURIComponent(tenant.organizationId);
  const userFilter = encodeURIComponent(userId);
  let profiles: Array<{ role: string }>;
  let memberships: Array<{ role: string }>;
  try {
    [profiles, memberships] = await Promise.all([
      readService<Array<{ role: string }>>(`user_profiles?user_id=eq.${userFilter}&select=role&limit=1`),
      readService<Array<{ role: string }>>(`books_memberships?organization_id=eq.${organizationId}&user_id=eq.${userFilter}&role=in.(owner,admin)&select=role&limit=1`),
    ]);
  } catch {
    throw hotelOfferError("Hotel manager access could not be verified", 503);
  }
  if (profiles[0]?.role !== "manager" || !memberships[0]) {
    throw hotelOfferError("Only a hotel manager can manage offers", 403);
  }
  return tenant;
};

const validateHotelOffer = (value: unknown) => {
  const input = value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
  const title = typeof input.title === "string" ? input.title.trim() : "";
  const description = typeof input.description === "string" ? input.description.trim() : "";
  const discountType = input.discount_type;
  const discountPercentage = Number(input.discount_percentage);
  const discountAmount = Number(input.discount_amount);
  const currencyCode = typeof input.currency_code === "string" ? input.currency_code.trim().toUpperCase() : "";
  const minimumSpend = Number(input.min_spend);
  const maximumDiscount = Number(input.max_discount);
  const maximumUses = input.max_uses === null || input.max_uses === "" ? null : Number(input.max_uses);
  const minimumNights = Number(input.minimum_nights);
  const displayOrder = Number(input.display_order);
  const promoCode = typeof input.promo_code === "string" && input.promo_code.trim() ? input.promo_code.trim().toUpperCase() : null;
  const terms = input.terms;
  const startsAt = input.starts_at === null || input.starts_at === "" ? null : input.starts_at;
  const endsAt = input.ends_at === null || input.ends_at === "" ? null : input.ends_at;
  const startsAtTimestamp = typeof startsAt === "string" ? Date.parse(startsAt) : null;
  const endsAtTimestamp = typeof endsAt === "string" ? Date.parse(endsAt) : null;
  if (!title || title.length > 120 || !description || description.length > 2000
    || (discountType !== "percentage" && discountType !== "fixed")
    || !Number.isFinite(discountPercentage) || discountPercentage < 0 || discountPercentage > 100
    || !Number.isFinite(discountAmount) || discountAmount < 0
    || (discountType === "percentage" && discountPercentage <= 0)
    || (discountType === "fixed" && (!promoCode || discountAmount <= 0))
    || !["USD", "UGX", "EUR", "GBP", "KES", "TZS", "RWF"].includes(currencyCode)
    || !Number.isFinite(minimumSpend) || minimumSpend < 0
    || !Number.isFinite(maximumDiscount) || maximumDiscount < 0
    || (maximumUses !== null && (!Number.isInteger(maximumUses) || maximumUses < 1 || !promoCode))
    || (promoCode !== null && !/^[A-Z0-9_-]{2,50}$/.test(promoCode))
    || !Number.isInteger(minimumNights) || minimumNights < 1
    || !Number.isInteger(displayOrder) || displayOrder < 0
    || typeof input.featured !== "boolean" || typeof input.is_active !== "boolean"
    || typeof input.limited_time !== "boolean"
    || !Array.isArray(terms) || terms.length > 12 || terms.some((term) => typeof term !== "string" || !term.trim() || term.length > 300)
    || (startsAt !== null && (typeof startsAt !== "string" || !Number.isFinite(startsAtTimestamp)))
    || (endsAt !== null && (typeof endsAt !== "string" || !Number.isFinite(endsAtTimestamp)))
    || (startsAtTimestamp !== null && endsAtTimestamp !== null && endsAtTimestamp <= startsAtTimestamp)) {
    throw new Error("Enter valid offer details and dates");
  }
  return {
    title,
    description,
    category: "accommodation",
    discount_type: discountType,
    discount_label: typeof input.discount_label === "string" ? input.discount_label.trim().slice(0, 40) : "",
    discount_percentage: discountPercentage,
    discount_amount: discountAmount,
    currency_code: currencyCode,
    minimum_nights: minimumNights,
    min_spend: minimumSpend,
    max_discount: maximumDiscount,
    max_uses: maximumUses,
    promo_code: promoCode,
    image: typeof input.image === "string" && input.image.trim() ? input.image.trim().slice(0, 8) : "🏨",
    popularity: Number.isInteger(Number(input.popularity)) ? Math.max(0, Math.min(100, Number(input.popularity))) : 0,
    limited_time: input.limited_time,
    display_order: displayOrder,
    featured: input.featured,
    terms: terms.map((term: string) => term.trim()),
    starts_at: startsAt,
    ends_at: endsAt,
    is_active: input.is_active,
  };
};

const callTenantRpc = async <T>(name: string, args: Record<string, unknown>): Promise<T> => {
  const { supabaseUrl } = configuration();
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: serviceHeaders(true),
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(10_000),
  });
  const payload = await response.json().catch(() => null) as T | { message?: string } | null;
  if (!response.ok) {
    throw new Error(payload && typeof payload === "object" && "message" in payload && typeof payload.message === "string"
      ? payload.message
      : "Hotel information could not be loaded");
  }
  return payload as T;
};

const getAuthenticatedUserId = async (authorization: string | undefined) => {
  if (!authorization?.startsWith("Bearer ")) throw new Error("Authentication is required");
  const { supabaseUrl, supabaseAnonKey } = configuration();
  const response = await fetch(`${supabaseUrl}/auth/v1/user`, {
    headers: { apikey: supabaseAnonKey, Authorization: authorization },
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error("Your sign-in session has expired");
  const user = await response.json() as { id?: string };
  if (!user.id) throw new Error("Your sign-in session could not be verified");
  return user.id;
};

const isUuid = (value: unknown): value is string => typeof value === "string"
  && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);

export const bindWorkerToHotelTenant: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const userId = await getAuthenticatedUserId(request.headers.authorization);
    await callTenantRpc("bind_worker_to_hotel", {
      target_organization_id: tenant.organizationId,
      target_user_id: userId,
    });
    response.json({ organizationId: tenant.organizationId });
  } catch (error) {
    response.status(400).json({ error: error instanceof Error ? error.message : "Unable to link worker to hotel" });
  }
};

export const submitHotelEventProposal: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const userId = await getAuthenticatedUserId(request.headers.authorization);
    const input = request.body as Record<string, unknown>;
    const planId = input.target_plan_id;
    if (planId !== null && planId !== undefined && !isUuid(planId)) {
      response.status(400).json({ error: "Event proposal is invalid" });
      return;
    }
    const result = await callTenantRpc<string>("submit_special_event_proposal_for_tenant", {
      target_organization_id: tenant.organizationId,
      target_user_id: userId,
      target_plan_id: planId ?? null,
      proposal_title: input.proposal_title,
      proposal_description: input.proposal_description ?? null,
      proposal_category: input.proposal_category,
      proposal_starts_at: input.proposal_starts_at,
      proposal_ends_at: input.proposal_ends_at,
      proposal_timezone: input.proposal_timezone,
      proposal_facility_id: input.proposal_facility_id,
      proposal_expected_guests: input.proposal_expected_guests,
      proposal_contact_name: input.proposal_contact_name,
      proposal_contact_email: input.proposal_contact_email,
      proposal_contact_phone: input.proposal_contact_phone ?? null,
      proposal_image_url: input.proposal_image_url ?? null,
      proposal_is_private: input.proposal_is_private,
      proposal_entry_type: input.proposal_entry_type,
      proposal_entry_fee: input.proposal_entry_fee,
      proposal_share_manager_operations: input.proposal_share_manager_operations ?? false,
    });
    response.json({ planId: result });
  } catch (error) {
    response.status(400).json({ error: error instanceof Error ? error.message : "Unable to submit event proposal" });
  }
};

export const reviewHotelEventProposal: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const userId = await getAuthenticatedUserId(request.headers.authorization);
    const input = request.body as { planId?: unknown; action?: unknown; suggestedValues?: unknown; reviewMessage?: unknown };
    if (!isUuid(input.planId) || !["approve", "decline", "suggest_changes"].includes(String(input.action))) {
      response.status(400).json({ error: "Event review details are invalid" });
      return;
    }
    await callTenantRpc("review_special_event_proposal_for_tenant", {
      target_organization_id: tenant.organizationId,
      target_user_id: userId,
      target_plan_id: input.planId,
      review_action: input.action,
      suggested_values: input.suggestedValues ?? null,
      review_message: input.reviewMessage ?? null,
    });
    response.json({ success: true });
  } catch (error) {
    response.status(400).json({ error: error instanceof Error ? error.message : "Unable to review event proposal" });
  }
};

export const respondHotelEventProposal: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const userId = await getAuthenticatedUserId(request.headers.authorization);
    const { planId, acceptSuggestions } = request.body as { planId?: unknown; acceptSuggestions?: unknown };
    if (!isUuid(planId) || typeof acceptSuggestions !== "boolean") {
      response.status(400).json({ error: "Event response details are invalid" });
      return;
    }
    await callTenantRpc("respond_to_special_event_proposal_for_tenant", {
      target_organization_id: tenant.organizationId,
      target_user_id: userId,
      target_plan_id: planId,
      accept_suggestions: acceptSuggestions,
    });
    response.json({ success: true });
  } catch (error) {
    response.status(400).json({ error: error instanceof Error ? error.message : "Unable to respond to event proposal" });
  }
};

export const publishHotelEventProposal: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const userId = await getAuthenticatedUserId(request.headers.authorization);
    const { planId } = request.body as { planId?: unknown };
    if (!isUuid(planId)) {
      response.status(400).json({ error: "Event proposal is invalid" });
      return;
    }
    await callTenantRpc("publish_special_event_proposal_for_tenant", {
      target_organization_id: tenant.organizationId,
      target_user_id: userId,
      target_plan_id: planId,
    });
    response.json({ success: true });
  } catch (error) {
    response.status(400).json({ error: error instanceof Error ? error.message : "Unable to publish event proposal" });
  }
};

export const deleteHotelEventProposal: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const userId = await getAuthenticatedUserId(request.headers.authorization);
    const { planId } = request.body as { planId?: unknown };
    if (!isUuid(planId)) {
      response.status(400).json({ error: "Event proposal is invalid" });
      return;
    }
    await callTenantRpc("delete_special_event_proposal_for_tenant", {
      target_organization_id: tenant.organizationId,
      target_user_id: userId,
      target_plan_id: planId,
    });
    response.json({ success: true });
  } catch (error) {
    response.status(400).json({ error: error instanceof Error ? error.message : "Unable to delete event proposal" });
  }
};

export const submitHotelComplaint: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const input = request.body as Record<string, unknown>;
    const requiredText = (value: unknown, maximumLength: number) => typeof value === "string"
      && value.trim().length > 0 && value.trim().length <= maximumLength;
    if (!requiredText(input.guestName, 160) || !requiredText(input.email, 320)
      || !requiredText(input.roomNumber, 64) || !requiredText(input.complaintType, 120)
      || !requiredText(input.description, 5000)
      || !["low", "medium", "high", "urgent"].includes(String(input.priority))) {
      response.status(400).json({ error: "Complete the required complaint details" });
      return;
    }
    const userId = request.headers.authorization
      ? await getAuthenticatedUserId(request.headers.authorization)
      : null;
    const { supabaseUrl, supabaseAnonKey, serviceRoleKey } = configuration();
    const insertResponse = await fetch(`${supabaseUrl}/rest/v1/complaints?select=id`, {
      method: "POST",
      headers: {
        apikey: supabaseAnonKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        "content-type": "application/json",
        Prefer: "return=representation",
      },
      body: JSON.stringify({
        user_id: userId,
        organization_id: tenant.organizationId,
        guest_name: String(input.guestName).trim(),
        email: String(input.email).trim().toLowerCase(),
        room_number: String(input.roomNumber).trim(),
        complaint_type: String(input.complaintType).trim(),
        description: String(input.description).trim(),
        priority: input.priority,
        status: "open",
        attachments: [],
      }),
      signal: AbortSignal.timeout(10_000),
    });
    const rows = await insertResponse.json().catch(() => null) as Array<{ id: string }> | null;
    if (!insertResponse.ok || !rows?.[0]?.id) throw new Error("Complaint could not be submitted");
    setPrivateTenantResponse(response);
    response.status(201).json({ complaintId: rows[0].id });
  } catch (error) {
    response.status(400).json({ error: error instanceof Error ? error.message : "Complaint could not be submitted" });
  }
};

export const getHotelTenant: RequestHandler = async (request, response) => {
  try {
    setPrivateTenantResponse(response);
    response.json(await resolveRequestHotelTenant(request));
  } catch (error) {
    response.status(404).json({ error: error instanceof Error ? error.message : "This hotel domain is not configured" });
  }
};

export const getHotelRewards: RequestHandler = async (request, response) => {
  setPrivateTenantResponse(response);
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const userId = await getAuthenticatedUserId(request.headers.authorization);
    const rewards = await callTenantRpc("get_hotel_loyalty_program_for_tenant", {
      target_organization_id: tenant.organizationId,
      target_user_id: userId,
    });
    setPrivateTenantResponse(response);
    response.json(rewards);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Hotel rewards could not be loaded";
    response.status(message.includes("Authentication") || message.includes("session has expired") ? 401 : 503).json({ error: message });
  }
};

export const updateHotelRewardsEnrollment: RequestHandler = async (request, response) => {
  setPrivateTenantResponse(response);
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const userId = await getAuthenticatedUserId(request.headers.authorization);
    const { enrolled } = request.body as { enrolled?: unknown };
    if (typeof enrolled !== "boolean") {
      response.status(400).json({ error: "Enrollment preference is invalid" });
      return;
    }
    const result = await callTenantRpc<boolean>("set_hotel_loyalty_enrollment_for_tenant", {
      target_organization_id: tenant.organizationId,
      target_user_id: userId,
      target_enrolled: enrolled,
    });
    setPrivateTenantResponse(response);
    response.json({ enrolled: result });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Rewards preference could not be saved";
    response.status(message.includes("Authentication") || message.includes("session has expired") ? 401 : 503).json({ error: message });
  }
};

export const getPublicHotelBookingData: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const organizationId = encodeURIComponent(tenant.organizationId);
    await callTenantRpc("release_expired_hotel_offer_holds_for_tenant", { target_organization_id: tenant.organizationId });
    const [settings, offers, rooms] = await Promise.all([
      readService<Array<{ booking_title: string; booking_subtitle: string }>>(`hotel_tenant_settings?organization_id=eq.${organizationId}&select=booking_title,booking_subtitle&is_active=eq.true&limit=1`),
      readService(`hotel_booking_offers?organization_id=eq.${organizationId}&category=eq.accommodation&is_active=eq.true&select=id,title,description,discount_percentage,discount_type,discount_label,discount_amount,currency_code,min_spend,max_discount,promo_code,image,popularity,limited_time,minimum_nights,starts_at,ends_at,max_uses,usage_count&order=display_order`),
      readService(`hotel_public_room_listings?organization_id=eq.${organizationId}&select=id,organization_id,name,room_type,description,image_url,size_sqm,max_guests,available_units,nightly_rate,original_nightly_rate,currency_code,amenities,status,hotel_name,hotel_city,hotel_country,hotel_classification&order=nightly_rate`),
    ]);
    if (settings.length !== 1) throw new Error("Hotel booking content is not configured");
    setPrivateTenantResponse(response);
    response.json({ tenant, settings: { title: settings[0].booking_title, subtitle: settings[0].booking_subtitle }, offers, rooms });
  } catch (error) {
    response.status(404).json({ error: error instanceof Error ? error.message : "Hotel information could not be loaded" });
  }
};

export const getPublicHotelOffers: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const organizationId = encodeURIComponent(tenant.organizationId);
    const now = new Date().toISOString();
    await callTenantRpc("release_expired_hotel_offer_holds_for_tenant", { target_organization_id: tenant.organizationId });
    const [roomOffers, menuItems, loyaltyPrograms, events, spaServices] = await Promise.all([
      readService<Array<Record<string, unknown>>>(`hotel_booking_offers?organization_id=eq.${organizationId}&category=eq.accommodation&is_active=eq.true&select=id,title,description,discount_percentage,discount_type,discount_label,discount_amount,currency_code,min_spend,max_discount,promo_code,image,popularity,limited_time,minimum_nights,starts_at,ends_at,display_order,featured,terms,max_uses,usage_count&order=display_order`),
      readService<Array<Record<string, unknown>>>(`menu_items?organization_id=eq.${organizationId}&is_published=eq.true&special_offer=not.is.null&select=id,name,short_description,price,original_price,currency,special_offer,availability,max_availability&order=created_at.asc`),
      readService<Array<{ program_name: string; points_per_1000_ugx: number }>>(`hotel_loyalty_programs?organization_id=eq.${organizationId}&program_enabled=eq.true&select=program_name,points_per_1000_ugx&limit=1`),
      readService<Array<Record<string, unknown>>>(`special_events?organization_id=eq.${organizationId}&status=eq.published&is_private=eq.false&starts_at=gte.${encodeURIComponent(now)}&select=id,title,description,starts_at,ends_at,location,price,currency,category,image_url,featured&order=featured.desc,starts_at.asc`),
      readService<Array<Record<string, unknown>>>(`hotel_spa_services?organization_id=eq.${organizationId}&is_active=eq.true&select=id,name,description,price,currency_code,duration_minutes&order=name.asc`),
    ]);
    const dateIsCurrent = (startsAt: unknown, endsAt: unknown) =>
      (typeof startsAt !== "string" || new Date(startsAt).getTime() <= Date.now())
      && (typeof endsAt !== "string" || new Date(endsAt).getTime() > Date.now());
    const offers = [
      ...roomOffers.filter((offer) => dateIsCurrent(offer.starts_at, offer.ends_at) && (offer.discount_type === "fixed" ? Boolean(offer.promo_code) && Number(offer.discount_amount) > 0 : Number(offer.discount_percentage) > 0)).map((offer) => ({ ...offer, discount: typeof offer.discount_label === "string" && offer.discount_label.trim() ? offer.discount_label : offer.discount_type === "fixed" ? `${offer.currency_code || ""} ${offer.discount_amount} OFF` : `${Number(offer.discount_percentage)}% OFF`, category: "accommodation", source: "booking" })),
      ...menuItems.filter((item) => typeof item.special_offer === "string" && item.special_offer.trim()).map((item) => ({ ...item, availability: item.availability === null ? null : Number(item.availability), title: item.name, description: `${item.special_offer}. ${item.short_description || ""}`.trim(), discount: item.original_price && Number(item.original_price) > Number(item.price) ? `${Math.round((1 - Number(item.price) / Number(item.original_price)) * 100)}% OFF` : "MENU SPECIAL", category: "dining", source: "menu" })),
      ...loyaltyPrograms.map((program) => ({ ...program, id: "hotel-rewards", title: program.program_name, description: `Earn ${program.points_per_1000_ugx} point${Number(program.points_per_1000_ugx) === 1 ? "" : "s"} for every UGX 1,000 spent on eligible purchases.`, discount: "REWARDS", category: "loyalty", source: "loyalty" })),
      ...events.filter((event) => typeof event.ends_at !== "string" || new Date(event.ends_at).getTime() > Date.now()).map((event) => ({ ...event, title: event.title, discount: event.price && Number(event.price) > 0 ? `FROM ${event.currency || ""} ${event.price}` : "UPCOMING EVENT", category: "seasonal", source: "event" })),
      ...spaServices.map((service) => ({ ...service, title: service.name, discount: `${service.currency_code} ${Number(service.price).toLocaleString()}`, category: "spa", image: "🧖", source: "spa" })),
    ];
    setPrivateTenantResponse(response);
    response.json({ tenant, offers });
  } catch (error) {
    response.status(404).json({ error: error instanceof Error ? error.message : "Offers could not be loaded" });
  }
};

export const checkHotelOfferManagementAccess: RequestHandler = async (request, response) => {
  try {
    await requireHotelManager(request);
    setPrivateTenantResponse(response);
    response.json({ authorized: true });
  } catch (error) {
    const status = (error as Error & { status?: number }).status
      ?? (error instanceof Error && error.message.includes("Authentication") ? 401 : 503);
    response.status(status).json({ authorized: false });
  }
};

export const getHotelOffersForManagement: RequestHandler = async (request, response) => {
  try {
    const tenant = await requireHotelManager(request);
    const organizationId = encodeURIComponent(tenant.organizationId);
    await callTenantRpc("release_expired_hotel_offer_holds_for_tenant", { target_organization_id: tenant.organizationId });
    const offers = await readService<Array<Record<string, unknown>>>(`hotel_booking_offers?organization_id=eq.${organizationId}&category=eq.accommodation&select=id,title,description,discount_percentage,discount_type,discount_label,discount_amount,currency_code,min_spend,max_discount,promo_code,image,popularity,limited_time,minimum_nights,starts_at,ends_at,display_order,featured,terms,max_uses,usage_count,is_active&order=display_order`);
    setPrivateTenantResponse(response);
    response.json({ offers });
  } catch (error) {
    const status = (error as Error & { status?: number }).status
      ?? (error instanceof Error && error.message.includes("Authentication") ? 401 : 503);
    response.status(status).json({ error: error instanceof Error ? error.message : "Hotel offers could not be loaded" });
  }
};

export const saveHotelOffer: RequestHandler = async (request, response) => {
  try {
    const tenant = await requireHotelManager(request);
    const body = request.body as Record<string, unknown>;
    const offerId = body.id;
    if (offerId !== undefined && (typeof offerId !== "string" || !isUuid(offerId))) {
      response.status(400).json({ error: "Offer identifier is invalid" });
      return;
    }
    const offer = validateHotelOffer(body);
    const organizationId = encodeURIComponent(tenant.organizationId);
    if (typeof offerId === "string") {
      const updated = await writeService<Array<{ id: string }>>(`hotel_booking_offers?id=eq.${encodeURIComponent(offerId)}&organization_id=eq.${organizationId}&select=id`, "PATCH", offer);
      if (!updated.length) {
        throw hotelOfferError("Offer was not found for this hotel", 404);
      }
    } else {
      await writeService("hotel_booking_offers?select=id", "POST", { ...offer, organization_id: tenant.organizationId });
    }
    setPrivateTenantResponse(response);
    response.json({ ok: true });
  } catch (error) {
    const status = (error as Error & { status?: number }).status
      ?? (error instanceof Error && error.message.includes("Authentication") ? 401 : 400);
    response.status(status).json({ error: error instanceof Error ? error.message : "Hotel offer could not be saved" });
  }
};

export const getPublicMenuItems: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const organizationId = encodeURIComponent(tenant.organizationId);
    const select = "id,organization_id,name,short_description,full_description,currency,media_type,media_url,media_attachment_id,media_aspect_ratio,price,original_price,category,icon,preparation_time,availability,max_availability,dietary_tags,spice_level,origin,calories,chef_note,special_offer,status_labels,is_trending,is_published,created_at";
    const legacySelect = select.replace(",media_aspect_ratio", "");
    let items: MenuItemRow[];
    try {
      items = await readService<MenuItemRow[]>(`menu_items?organization_id=eq.${organizationId}&is_published=eq.true&select=${select}&order=created_at.asc`);
    } catch {
      items = await readService<MenuItemRow[]>(`menu_items?organization_id=eq.${organizationId}&is_published=eq.true&select=${legacySelect}&order=created_at.asc`);
    }

    setPrivateTenantResponse(response);
    response.json({ tenant, items });
  } catch (error) {
    response.status(404).json({ error: error instanceof Error ? error.message : "Menu information could not be loaded" });
  }
};

export const requestHotelMenuAvailability: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const userId = await getAuthenticatedUserId(request.headers.authorization);
    const { menuItemId } = request.body as { menuItemId?: unknown };
    if (!isUuid(menuItemId)) {
      response.status(400).json({ error: "Select a valid menu item" });
      return;
    }

    const subscribed = await callTenantRpc<boolean>("request_menu_item_availability_for_tenant", {
      target_user_id: userId,
      target_organization_id: tenant.organizationId,
      target_menu_item_id: menuItemId,
    });
    setPrivateTenantResponse(response);
    response.json({ subscribed });
  } catch (error) {
    response.status(400).json({ error: error instanceof Error ? error.message : "Availability request could not be saved" });
  }
};

const muxAspectRatios = new Map<string, number>();

const getMuxAspectRatio = async (playbackId: string): Promise<number | null> => {
  const cachedRatio = muxAspectRatios.get(playbackId);
  if (cachedRatio) return cachedRatio;

  try {
    const manifestResponse = await fetch(`https://stream.mux.com/${encodeURIComponent(playbackId)}.m3u8`, {
      signal: AbortSignal.timeout(5000),
    });
    if (!manifestResponse.ok) return null;

    const manifest = await manifestResponse.text();
    const resolution = manifest.match(/RESOLUTION=(\d+)x(\d+)/);
    if (!resolution) return null;

    const aspectRatio = Number(resolution[1]) / Number(resolution[2]);
    muxAspectRatios.set(playbackId, aspectRatio);
    return aspectRatio;
  } catch {
    return null;
  }
};

export const getPublicMenuVideo: RequestHandler = async (request, response) => {
  try {
    const { attachmentId } = request.params;
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(attachmentId)) {
      response.status(400).json({ error: "Invalid menu media" });
      return;
    }

    const tenant = await resolveRequestHotelTenant(request);
    const organizationId = encodeURIComponent(tenant.organizationId);
    const encodedAttachmentId = encodeURIComponent(attachmentId);
    let menuItems: Array<{ id: string; media_aspect_ratio?: number | null }>;
    try {
      menuItems = await readService(
        `menu_items?organization_id=eq.${organizationId}&media_attachment_id=eq.${encodedAttachmentId}&media_type=eq.video&is_published=eq.true&select=id,media_aspect_ratio&limit=1`,
      );
    } catch {
      menuItems = await readService(
        `menu_items?organization_id=eq.${organizationId}&media_attachment_id=eq.${encodedAttachmentId}&media_type=eq.video&is_published=eq.true&select=id&limit=1`,
      );
    }
    if (menuItems.length === 0) {
      response.status(404).json({ error: "Menu video was not found" });
      return;
    }

    const attachments = await readService<Array<{ filename: string }>>(
      `attachments?id=eq.${encodedAttachmentId}&select=filename&limit=1`,
    );
    if (attachments.length === 0) {
      response.status(404).json({ error: "Menu video was not found" });
      return;
    }

    const filename = encodeURIComponent(attachments[0].filename);
    const videos = await readService<Array<{ playback_id: string | null; status: string }>>(
      `video_uploads?filename=eq.${filename}&select=playback_id,status&limit=1`,
    );
    const video = videos[0];
    const playbackId = video?.status === "ready" ? video.playback_id : null;
    const menuItem = menuItems[0];
    let aspectRatio = menuItem.media_aspect_ratio;
    if (playbackId && !(aspectRatio && Number.isFinite(aspectRatio) && aspectRatio > 0)) {
      aspectRatio = await getMuxAspectRatio(playbackId);
      if (aspectRatio) {
        try {
          await updateService(
            `menu_items?id=eq.${encodeURIComponent(menuItem.id)}&organization_id=eq.${organizationId}`,
            { media_aspect_ratio: aspectRatio },
          );
        } catch {
          // The menu media migration may not have been applied yet.
        }
      }
    }
    setPrivateTenantResponse(response);
    response.json({
      status: video?.status || "pending",
      playbackId,
      aspectRatio,
    });
  } catch (error) {
    response.status(404).json({ error: error instanceof Error ? error.message : "Menu video could not be loaded" });
  }
};

export const getPublicSpecialEvents: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const organizationId = encodeURIComponent(tenant.organizationId);
    const select = "id,title,description,starts_at,ends_at,timezone,location,facility_id,organization_id,is_private,share_token,price,currency,capacity,ticket_type_capacity,max_tickets_per_order,default_ticket_type_id,attendees_count,category,image_url,featured,rating,host_name,status,organizer_id,created_at,updated_at";
    const events = await readService(`special_events?organization_id=eq.${organizationId}&status=eq.published&is_private=eq.false&starts_at=gte.${encodeURIComponent(new Date().toISOString())}&select=${select}&order=featured.desc,starts_at.asc`);
    setPrivateTenantResponse(response);
    response.json({ events });
  } catch (error) {
    response.status(404).json({ error: error instanceof Error ? error.message : "Event information could not be loaded" });
  }
};

export const getTenantRoomAvailability: RequestHandler = async (request, response) => {
  try {
    const { checkIn, checkOut } = request.body as { checkIn?: string; checkOut?: string };
    if (!checkIn || !/^\d{4}-\d{2}-\d{2}$/.test(checkIn) || !checkOut || !/^\d{4}-\d{2}-\d{2}$/.test(checkOut)) {
      response.status(400).json({ error: "Select valid check-in and check-out dates" });
      return;
    }
    const tenant = await resolveRequestHotelTenant(request);
    const availability = await callTenantRpc<Array<{ room_id: string; remaining_units: number }>>(
      "get_hotel_room_availability_for_tenant",
      { target_organization_id: tenant.organizationId, target_check_in: checkIn, target_check_out: checkOut },
    );
    setPrivateTenantResponse(response);
    response.json({ availability });
  } catch (error) {
    response.status(404).json({ error: error instanceof Error ? error.message : "Hotel availability could not be loaded" });
  }
};

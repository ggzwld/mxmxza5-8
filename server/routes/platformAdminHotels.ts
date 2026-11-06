import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { resolveTxt } from "node:dns/promises";
import type { Request, RequestHandler } from "express";

type PlatformAdminError = Error & { status?: number };

type SupabaseConfig = {
  url: string;
  anonKey: string;
  serviceRoleKey: string;
};

const configuration = (): SupabaseConfig => {
  const url = process.env.VITE_SUPABASE_URL;
  const anonKey = process.env.VITE_SUPABASE_ANON_KEY;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !anonKey || !serviceRoleKey) throw new Error("Supabase server configuration is incomplete");
  return { url: url.replace(/\/$/, ""), anonKey, serviceRoleKey };
};

const serviceHeaders = (json = false) => {
  const { anonKey, serviceRoleKey } = configuration();
  return {
    apikey: anonKey,
    Authorization: `Bearer ${serviceRoleKey}`,
    ...(json ? { "content-type": "application/json" } : {}),
  };
};

const fail = (message: string, status: number): PlatformAdminError => Object.assign(new Error(message), { status });

const getAuthenticatedUserId = async (authorization: string | undefined) => {
  if (!authorization?.startsWith("Bearer ")) throw fail("Authentication is required", 401);
  const { url, anonKey } = configuration();
  const response = await fetch(`${url}/auth/v1/user`, {
    headers: { apikey: anonKey, Authorization: authorization },
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw fail("Your sign-in session has expired", 401);
  const user = await response.json() as { id?: string };
  if (!user.id) throw fail("Your sign-in session could not be verified", 401);
  return user.id;
};

const readService = async <T>(path: string): Promise<T> => {
  const { url } = configuration();
  const response = await fetch(`${url}/rest/v1/${path}`, {
    headers: serviceHeaders(),
    signal: AbortSignal.timeout(15_000),
  });
  const body = await response.json().catch(() => null) as T | { message?: string } | null;
  if (!response.ok) {
    throw fail(body && typeof body === "object" && "message" in body && body.message
      ? body.message
      : "Unable to load platform onboarding data", 500);
  }
  return body as T;
};

const callServiceRpc = async <T>(name: string, values: Record<string, unknown>): Promise<T> => {
  const { url } = configuration();
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: serviceHeaders(true),
    body: JSON.stringify(values),
    signal: AbortSignal.timeout(20_000),
  });
  const body = await response.json().catch(() => null) as T | { message?: string } | null;
  if (!response.ok) {
    throw fail(body && typeof body === "object" && "message" in body && body.message
      ? body.message
      : "Hotel onboarding could not be saved", response.status >= 500 ? 500 : 400);
  }
  return body as T;
};

const claimBootstrapAdmin = async (authorization: string) => {
  const { url, anonKey } = configuration();
  const response = await fetch(`${url}/rest/v1/rpc/claim_platform_admin_bootstrap`, {
    method: "POST",
    headers: { apikey: anonKey, Authorization: authorization, "content-type": "application/json" },
    body: "{}",
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw fail("Admin bootstrap could not be checked", 503);
};

const requirePlatformAdmin = async (request: Request) => {
  const userId = await getAuthenticatedUserId(request.headers.authorization);
  await claimBootstrapAdmin(request.headers.authorization!);
  const admins = await readService<Array<{ user_id: string }>>(
    `platform_admins?user_id=eq.${encodeURIComponent(userId)}&select=user_id&limit=1`,
  );
  if (admins.length !== 1) throw fail("Platform administrator access is required", 403);
  return userId;
};

const noStore = (response: { setHeader: (name: string, value: string) => unknown }) =>
  response.setHeader("Cache-Control", "private, no-store");

const sendError = (response: Parameters<RequestHandler>[1], error: unknown) => {
  const status = error && typeof error === "object" && "status" in error
    ? Number((error as PlatformAdminError).status) || 500
    : 500;
  response.status(status).json({ error: error instanceof Error ? error.message : "Hotel onboarding failed" });
};

const validDomain = (value: unknown): value is string => {
  if (typeof value !== "string") return false;
  const domain = value.trim().toLowerCase();
  if (domain !== value || domain.length > 253 || !domain.includes(".")) return false;
  return domain.split(".").every((label) =>
    label.length > 0 && label.length <= 63 && /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label),
  );
};

const isUuid = (value: unknown): value is string => typeof value === "string"
  && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);

const sha256 = (value: string) => createHash("sha256").update(value).digest("hex");

export const getPlatformAdminStatus: RequestHandler = async (request, response) => {
  noStore(response);
  if (!request.headers.authorization?.startsWith("Bearer ")) {
    response.json({ isPlatformAdmin: false });
    return;
  }
  try {
    const userId = await getAuthenticatedUserId(request.headers.authorization);
    await claimBootstrapAdmin(request.headers.authorization);
    const admins = await readService<Array<{ user_id: string }>>(
      `platform_admins?user_id=eq.${encodeURIComponent(userId)}&select=user_id&limit=1`,
    );
    response.json({ isPlatformAdmin: admins.length === 1 });
  } catch (error) {
    sendError(response, error);
  }
};

export const getPlatformHotels: RequestHandler = async (request, response) => {
  noStore(response);
  try {
    await requirePlatformAdmin(request);
    const [organizations, workerWorkspaces, settings, domains] = await Promise.all([
      readService<Array<{ id: string; name: string; country_code: string; base_currency: string; owner_id: string }>>(
        "books_organizations?select=id,name,country_code,base_currency,owner_id&order=name",
      ),
      readService<Array<{ organization_id: string }>>("books_worker_workspaces?select=organization_id"),
      readService<Array<{ organization_id: string; display_name: string; logo_url: string | null; primary_color: string | null; accent_color: string | null; booking_title: string; booking_subtitle: string; is_active: boolean }>>(
        "hotel_tenant_settings?select=organization_id,display_name,logo_url,primary_color,accent_color,booking_title,booking_subtitle,is_active",
      ),
      readService<Array<{ domain: string; organization_id: string; verification_status: string; verification_method: string | null; verified_at: string | null }>>(
        "hotel_tenant_domains?select=domain,organization_id,verification_status,verification_method,verified_at&order=domain",
      ),
    ]);
    const workerOrganizationIds = new Set(workerWorkspaces.map((workspace) => workspace.organization_id));
    response.json({
      organizations: organizations.filter((organization) => !workerOrganizationIds.has(organization.id)),
      hotels: settings.map((hotel) => ({
        ...hotel,
        domains: domains.filter((domain) => domain.organization_id === hotel.organization_id),
      })),
    });
  } catch (error) {
    sendError(response, error);
  }
};

export const onboardPlatformHotel: RequestHandler = async (request, response) => {
  noStore(response);
  try {
    const adminUserId = await requirePlatformAdmin(request);
    const input = request.body as Record<string, unknown>;
    const domain = typeof input.domain === "string" ? input.domain.trim().toLowerCase() : "";
    const verificationMethod = input.verificationMethod;
    if (!validDomain(domain)) throw fail("Enter a hostname without a scheme, path, or port", 400);
    if (verificationMethod !== "dns_txt" && verificationMethod !== "vercel_project") {
      throw fail("Choose DNS TXT or a reviewed Vercel hostname", 400);
    }
    if (domain.endsWith(".vercel.app") && verificationMethod !== "vercel_project") {
      throw fail("Vercel hostnames require platform-admin assignment review", 400);
    }
    if (!domain.endsWith(".vercel.app") && verificationMethod === "vercel_project") {
      throw fail("Vercel assignment review is only for .vercel.app hostnames", 400);
    }
    if (input.organizationId !== null && input.organizationId !== undefined && !isUuid(input.organizationId)) {
      throw fail("Choose a valid organization", 400);
    }
    const challenge = randomBytes(32).toString("base64url");
    const result = await callServiceRpc<Array<{ organization_id: string; domain: string; verification_status: string }>>(
      "platform_admin_onboard_hotel",
      {
        target_admin_user_id: adminUserId,
        target_organization_id: input.organizationId ?? null,
        target_organization_name: input.organizationName,
        target_owner_email: typeof input.ownerEmail === "string" ? input.ownerEmail.trim().toLowerCase() : null,
        target_country_code: input.countryCode,
        target_base_currency: input.baseCurrency,
        target_display_name: input.displayName,
        target_booking_title: input.bookingTitle,
        target_booking_subtitle: input.bookingSubtitle,
        target_logo_url: input.logoUrl ?? null,
        target_primary_color: input.primaryColor ?? null,
        target_accent_color: input.accentColor ?? null,
        target_domain: domain,
        target_challenge_hash: sha256(challenge),
        target_verification_method: verificationMethod,
      },
    );
    const hotel = Array.isArray(result) ? result[0] : null;
    if (!hotel) throw new Error("Hotel onboarding did not return a result");
    response.status(201).json({
      organizationId: hotel.organization_id,
      domain: hotel.domain,
      verificationStatus: hotel.verification_status,
      verificationMethod,
      dnsTxtName: verificationMethod === "dns_txt" ? `_hotel-verify.${hotel.domain}` : null,
      dnsTxtValue: verificationMethod === "dns_txt" && hotel.verification_status !== "verified"
        ? `hotel-domain-verification=${challenge}`
        : null,
    });
  } catch (error) {
    sendError(response, error);
  }
};

export const verifyPlatformHotelDomain: RequestHandler = async (request, response) => {
  noStore(response);
  try {
    const adminUserId = await requirePlatformAdmin(request);
    const input = request.body as { domain?: unknown; confirmVercelAssignment?: unknown };
    const domain = typeof input.domain === "string" ? input.domain.trim().toLowerCase() : "";
    if (!validDomain(domain)) throw fail("Enter a valid hostname", 400);
    const rows = await readService<Array<{
      domain: string;
      organization_id: string;
      verification_status: string;
      verification_method: string | null;
      verification_challenge_hash: string | null;
      verification_expires_at: string | null;
    }>>(
      `hotel_tenant_domains?domain=eq.${encodeURIComponent(domain)}&select=domain,organization_id,verification_status,verification_method,verification_challenge_hash,verification_expires_at&limit=1`,
    );
    const pendingDomain = rows[0];
    if (!pendingDomain) throw fail("This hostname has not been submitted for onboarding", 404);
    if (pendingDomain.verification_status === "verified") {
      response.json({ verified: true, domain });
      return;
    }
    if (!(["pending", "legacy"] as string[]).includes(pendingDomain.verification_status)
      || !pendingDomain.verification_expires_at
      || new Date(pendingDomain.verification_expires_at).getTime() <= Date.now()) {
      throw fail("This verification challenge has expired. Submit the hostname again to generate a new one.", 400);
    }

    if (domain.endsWith(".vercel.app") && pendingDomain.verification_method !== "vercel_project") {
      throw fail("Vercel hostnames require platform-admin assignment review", 400);
    }
    if (!domain.endsWith(".vercel.app") && pendingDomain.verification_method === "vercel_project") {
      throw fail("Vercel assignment review is only for .vercel.app hostnames", 400);
    }

    if (pendingDomain.verification_method === "dns_txt") {
      let records: string[][];
      try {
        records = await resolveTxt(`_hotel-verify.${domain}`);
      } catch {
        throw fail(`DNS TXT record not found yet. Add the record at _hotel-verify.${domain} and retry.`, 400);
      }
      const matches = records.flatMap((record) => record.join("")).some((record) => {
        const value = record.startsWith("hotel-domain-verification=")
          ? record.slice("hotel-domain-verification=".length)
          : "";
        if (!value || !pendingDomain.verification_challenge_hash) return false;
        const actual = Buffer.from(sha256(value), "hex");
        const expected = Buffer.from(pendingDomain.verification_challenge_hash, "hex");
        return actual.length === expected.length && timingSafeEqual(actual, expected);
      });
      if (!matches) throw fail("The DNS TXT record does not match the verification challenge yet", 400);
    } else if (pendingDomain.verification_method === "vercel_project") {
      const productionDomain = process.env.VERCEL_PROJECT_PRODUCTION_URL?.toLowerCase();
      if (!domain.endsWith(".vercel.app")
        || (domain !== productionDomain && input.confirmVercelAssignment !== true)) {
        throw fail("Confirm that this exact Vercel hostname is assigned to the project", 400);
      }
    } else {
      throw fail("This hostname has no supported verification method", 400);
    }

    const verified = await callServiceRpc<boolean>("platform_admin_record_domain_verification", {
      target_admin_user_id: adminUserId,
      target_domain: domain,
      target_organization_id: pendingDomain.organization_id,
      target_verification_method: pendingDomain.verification_method,
    });
    if (!verified) throw fail("The hostname could not be marked verified", 409);
    response.json({ verified: true, domain, organizationId: pendingDomain.organization_id });
  } catch (error) {
    sendError(response, error);
  }
};

export const activatePlatformHotel: RequestHandler = async (request, response) => {
  noStore(response);
  try {
    const adminUserId = await requirePlatformAdmin(request);
    const { organizationId } = request.body as { organizationId?: unknown };
    if (!isUuid(organizationId)) throw fail("Choose a valid hotel", 400);
    await callServiceRpc("platform_admin_activate_hotel", {
      target_admin_user_id: adminUserId,
      target_organization_id: organizationId,
    });
    response.json({ active: true });
  } catch (error) {
    sendError(response, error);
  }
};

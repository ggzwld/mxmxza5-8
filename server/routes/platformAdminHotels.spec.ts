import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  getPlatformAdminStatus,
  onboardPlatformHotel,
  verifyPlatformHotelDomain,
} from "./platformAdminHotels";

const adminId = "9aab5c78-3047-4a4c-9742-b2d09c783c8e";
const organizationId = "e40d63e6-c55b-4601-98b7-73a895a0b0d0";
const jsonResponse = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });

const invoke = async (handler: typeof getPlatformAdminStatus, headers: Record<string, string> = {}, body?: unknown) => {
  const result = { statusCode: 200, body: null as unknown };
  const response = {
    setHeader() { return this; },
    status(code: number) { result.statusCode = code; return this; },
    json(value: unknown) { result.body = value; return this; },
  };
  await handler({ headers, body } as unknown as Parameters<typeof handler>[0], response as unknown as Parameters<typeof handler>[1], (() => undefined) as Parameters<typeof handler>[2]);
  return result;
};

describe("platform admin hotel API", () => {
  beforeEach(() => {
    vi.stubEnv("VITE_SUPABASE_URL", "https://supabase.example.test");
    vi.stubEnv("VITE_SUPABASE_ANON_KEY", "anon-key");
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "service-role-key");
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  it("does not query the admin registry for an unauthenticated status check", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const result = await invoke(getPlatformAdminStatus);

    expect(result).toMatchObject({ statusCode: 200, body: { isPlatformAdmin: false } });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("rejects a signed-in non-admin before any onboarding write", async () => {
    const fetchMock = vi.fn(async (input: string | URL | Request) => {
      const url = String(input);
      if (url.endsWith("/auth/v1/user")) return jsonResponse({ id: adminId });
      if (url.endsWith("/rpc/claim_platform_admin_bootstrap")) return jsonResponse(false);
      if (url.includes("/rest/v1/platform_admins?")) return jsonResponse([]);
      throw new Error(`Unexpected request: ${url}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    const result = await invoke(onboardPlatformHotel, { authorization: "Bearer user-token" }, { domain: "hotel.example.com" });

    expect(result.statusCode).toBe(403);
    expect(result.body).toMatchObject({ error: "Platform administrator access is required" });
    expect(fetchMock.mock.calls.some(([input]) => String(input).includes("platform_admin_onboard_hotel"))).toBe(false);
  });

  it("verifies a legacy secondary Vercel hostname only after admin review", async () => {
    vi.stubEnv("VERCEL_PROJECT_PRODUCTION_URL", "yerger2.vercel.app");
    const fetchMock = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
      const url = String(input);
      if (url.endsWith("/auth/v1/user")) return jsonResponse({ id: adminId });
      if (url.endsWith("/rpc/claim_platform_admin_bootstrap")) return jsonResponse(true);
      if (url.includes("/rest/v1/platform_admins?")) return jsonResponse([{ user_id: adminId }]);
      if (url.includes("/rest/v1/hotel_tenant_domains?")) return jsonResponse([{
        domain: "hgrtxz00.vercel.app",
        organization_id: organizationId,
        verification_status: "legacy",
        verification_method: "vercel_project",
        verification_challenge_hash: "b".repeat(64),
        verification_expires_at: new Date(Date.now() + 60_000).toISOString(),
      }]);
      if (url.endsWith("/rpc/platform_admin_record_domain_verification")) {
        expect(JSON.parse(String(init?.body))).toMatchObject({
          target_admin_user_id: adminId,
          target_domain: "hgrtxz00.vercel.app",
          target_organization_id: organizationId,
          target_verification_method: "vercel_project",
        });
        return jsonResponse(true);
      }
      throw new Error(`Unexpected request: ${url}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    const unreviewed = await invoke(verifyPlatformHotelDomain, { authorization: "Bearer admin-token" }, {
      domain: "hgrtxz00.vercel.app",
    });
    expect(unreviewed.statusCode).toBe(400);
    expect(fetchMock.mock.calls.some(([input]) => String(input).endsWith("/rpc/platform_admin_record_domain_verification"))).toBe(false);

    fetchMock.mockClear();
    const result = await invoke(verifyPlatformHotelDomain, { authorization: "Bearer admin-token" }, {
      domain: "hgrtxz00.vercel.app",
      confirmVercelAssignment: true,
    });

    expect(result).toMatchObject({
      statusCode: 200,
      body: { verified: true, domain: "hgrtxz00.vercel.app", organizationId },
    });
  });

  it("does not allow DNS TXT verification for a Vercel hostname", async () => {
    const fetchMock = vi.fn(async (input: string | URL | Request) => {
      const url = String(input);
      if (url.endsWith("/auth/v1/user")) return jsonResponse({ id: adminId });
      if (url.endsWith("/rpc/claim_platform_admin_bootstrap")) return jsonResponse(true);
      if (url.includes("/rest/v1/platform_admins?")) return jsonResponse([{ user_id: adminId }]);
      throw new Error(`Unexpected request: ${url}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    const result = await invoke(onboardPlatformHotel, { authorization: "Bearer admin-token" }, {
      domain: "hgrtxz00.vercel.app",
      verificationMethod: "dns_txt",
    });

    expect(result.statusCode).toBe(400);
    expect(result.body).toMatchObject({ error: "Vercel hostnames require platform-admin assignment review" });
    expect(fetchMock.mock.calls.some(([input]) => String(input).includes("platform_admin_onboard_hotel"))).toBe(false);
  });
});

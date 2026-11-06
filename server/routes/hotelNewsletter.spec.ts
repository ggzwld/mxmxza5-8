import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { submitHotelNewsletter } from "./hotelNewsletter.js";

const organizationId = "1665de0b-1848-4862-940f-4dcc02b30a2b";
const otherOrganizationId = "36ec18aa-1fb4-48d6-ae37-6febd60c559c";
const jsonResponse = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });

describe("submitHotelNewsletter", () => {
  beforeEach(() => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("VITE_SUPABASE_URL", "https://supabase.example.test");
    vi.stubEnv("VITE_SUPABASE_ANON_KEY", "anon-key");
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "service-role-key");
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  it("allows an origin alias that resolves to the same hotel", async () => {
    const fetchMock = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
      const url = String(input);
      if (url.endsWith("/rpc/resolve_hotel_tenant")) {
        const hostname = JSON.parse(String(init?.body)).target_hostname;
        return jsonResponse([{ organization_id: hostname === "other.example.test" ? otherOrganizationId : organizationId, name: "Hotel", domain: hostname, logo_url: null, primary_color: null, accent_color: null }]);
      }
      if (url.includes("cloudfunctions.net/hotelOffersNewsletter")) return jsonResponse({ ok: true, unsubscribeToken: "token" });
      throw new Error(`Unexpected request: ${url}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    const result = { statusCode: 200, body: null as unknown };
    const response = {
      setHeader: vi.fn(),
      status(code: number) { result.statusCode = code; return this; },
      json(body: unknown) { result.body = body; return this; },
    };
    const request = {
      hostname: "hotel.example.test",
      headers: {},
      body: { email: "guest@example.test", consent: true },
      get: (name: string) => name.toLowerCase() === "origin" ? "https://deployment.example.test" : undefined,
    };

    await submitHotelNewsletter(request as never, response as never, (() => undefined) as never);

    expect(result.statusCode).toBe(200);
    expect(result.body).toEqual({ ok: true, unsubscribeToken: "token" });
    expect(fetchMock).toHaveBeenCalledWith(expect.stringContaining("cloudfunctions.net/hotelOffersNewsletter"), expect.any(Object));
  });

  it("rejects an origin that resolves to a different hotel", async () => {
    const fetchMock = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
      const url = String(input);
      if (!url.endsWith("/rpc/resolve_hotel_tenant")) throw new Error(`Unexpected request: ${url}`);
      const hostname = JSON.parse(String(init?.body)).target_hostname;
      return jsonResponse([{ organization_id: hostname === "other.example.test" ? otherOrganizationId : organizationId, name: "Hotel", domain: hostname, logo_url: null, primary_color: null, accent_color: null }]);
    });
    vi.stubGlobal("fetch", fetchMock);

    const result = { statusCode: 200, body: null as unknown };
    const response = {
      status(code: number) { result.statusCode = code; return this; },
      json(body: unknown) { result.body = body; return this; },
    };
    const request = {
      hostname: "hotel.example.test",
      headers: {},
      body: { email: "guest@example.test", consent: true },
      get: (name: string) => name.toLowerCase() === "origin" ? "https://other.example.test" : undefined,
    };

    await submitHotelNewsletter(request as never, response as never, (() => undefined) as never);

    expect(result.statusCode).toBe(403);
    expect(result.body).toEqual({ error: "This site address is not registered to the same hotel as its newsletter." });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});

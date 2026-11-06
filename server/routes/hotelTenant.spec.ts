import { afterEach, describe, expect, it, vi } from "vitest";
import { getHotelOffersForManagement, getHotelRewards, getPublicHotelOffers, resolveRequestHotelTenant } from "./hotelTenant.js";

const organizationId = "1665de0b-1848-4862-940f-4dcc02b30a2b";
const request = { hostname: "abc123.projects.builder.my" } as Parameters<typeof resolveRequestHotelTenant>[0];

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

describe("getHotelRewards", () => {
  it("loads only the authenticated user's rewards for the resolved hotel", async () => {
    vi.stubEnv("NODE_ENV", "development");
    vi.stubEnv("VITE_SUPABASE_URL", "https://example.supabase.co");
    vi.stubEnv("VITE_SUPABASE_ANON_KEY", "anon-key");
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "service-role-key");
    vi.stubEnv("BUILDER_PREVIEW_TENANT_ORGANIZATION_ID", organizationId);
    const userId = "bd15af7a-93a0-4618-bd1f-4dc72c7f88c6";
    const fetchMock = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
      const url = String(input);
      if (url.endsWith("/auth/v1/user")) return new Response(JSON.stringify({ id: userId }), { status: 200 });
      if (url.includes("hotel_tenant_settings?")) return new Response(JSON.stringify([{
        organization_id: organizationId,
        display_name: "MisuriStay",
        logo_url: null,
        primary_color: null,
        accent_color: null,
      }]), { status: 200 });
      if (url.endsWith("/rpc/get_hotel_loyalty_program_for_tenant")) {
        expect(JSON.parse(String(init?.body))).toEqual({ target_organization_id: organizationId, target_user_id: userId });
        return new Response(JSON.stringify({ organizationId, availablePoints: 20 }), { status: 200 });
      }
      throw new Error(`Unexpected request: ${url}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    const result = { statusCode: 200, body: null as unknown };
    const response = {
      setHeader: vi.fn(),
      status(code: number) { result.statusCode = code; return this; },
      json(body: unknown) { result.body = body; return this; },
    };
    await getHotelRewards({
      headers: { authorization: "Bearer user-token", host: "abc123.projects.builder.my" },
      hostname: "abc123.projects.builder.my",
    } as unknown as Parameters<typeof getHotelRewards>[0], response as unknown as Parameters<typeof getHotelRewards>[1], (() => undefined) as Parameters<typeof getHotelRewards>[2]);

    expect(result.statusCode).toBe(200);
    expect(result.body).toEqual({ organizationId, availablePoints: 20 });
    expect(response.setHeader).toHaveBeenCalledWith("Cache-Control", "private, no-store");
  });
});

describe("getPublicHotelOffers", () => {
  it("returns published booking, menu, rewards, and event data for the resolved hotel", async () => {
    vi.stubEnv("NODE_ENV", "development");
    vi.stubEnv("VITE_SUPABASE_URL", "https://example.supabase.co");
    vi.stubEnv("VITE_SUPABASE_ANON_KEY", "anon-key");
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "service-role-key");
    vi.stubEnv("BUILDER_PREVIEW_TENANT_ORGANIZATION_ID", organizationId);
    const fetchMock = vi.fn(async (input: string | URL | Request) => {
      const url = String(input);
      if (url.includes("hotel_tenant_settings?")) return new Response(JSON.stringify([{
        organization_id: organizationId,
        display_name: "MisuriStay",
        logo_url: null,
        primary_color: null,
        accent_color: null,
      }]), { status: 200 });
      if (url.endsWith("/rpc/release_expired_hotel_offer_holds_for_tenant")) return new Response("0", { status: 200 });
      if (url.includes("hotel_booking_offers?")) return new Response(JSON.stringify([{
        id: "stay-offer",
        title: "Extended Stay",
        description: "Save on longer stays.",
        discount_percentage: 15,
        minimum_nights: 3,
        starts_at: null,
        ends_at: null,
        display_order: 1,
        featured: true,
        terms: [],
      }]), { status: 200 });
      if (url.includes("hotel_spa_services?")) return new Response(JSON.stringify([]), { status: 200 });
      if (url.includes("menu_items?")) return new Response(JSON.stringify([{
        id: "menu-special",
        name: "Local platter",
        short_description: "Seasonal ingredients",
        price: 20,
        original_price: null,
        currency: "USD",
        special_offer: "Chef's special",
        availability: 4,
        max_availability: 10,
      }]), { status: 200 });
      if (url.includes("hotel_loyalty_programs?")) return new Response(JSON.stringify([{ program_name: "Guest Rewards", points_per_1000_ugx: 1 }]), { status: 200 });
      if (url.includes("special_events?")) return new Response(JSON.stringify([{ id: "event", title: "Jazz Night", description: "Live music", starts_at: new Date(Date.now() + 86400000).toISOString(), ends_at: null, location: "Hotel lounge", price: 0, currency: "USD", featured: false }]), { status: 200 });
      throw new Error(`Unexpected request: ${url}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    const result = { statusCode: 200, body: null as unknown };
    const response = {
      setHeader: vi.fn(),
      status(code: number) { result.statusCode = code; return this; },
      json(body: unknown) { result.body = body; return this; },
    };
    await getPublicHotelOffers({ hostname: request.hostname, headers: {} } as Parameters<typeof getPublicHotelOffers>[0], response as unknown as Parameters<typeof getPublicHotelOffers>[1], (() => undefined) as Parameters<typeof getPublicHotelOffers>[2]);

    expect(result.statusCode).toBe(200);
    expect(response.setHeader).toHaveBeenCalledWith("Cache-Control", "private, no-store");
    const body = result.body as { tenant: { organizationId: string }; offers: Array<{ category: string; title: string; discount: string }> };
    expect(body.tenant.organizationId).toBe(organizationId);
    expect(body.offers.map(({ category }) => category)).toEqual(["accommodation", "dining", "loyalty", "seasonal"]);
    expect(body.offers[0]).toMatchObject({ title: "Extended Stay", discount: "15% OFF" });
    expect(body.offers[1]).toMatchObject({ title: "Local platter", category: "dining" });
    expect(fetchMock.mock.calls.some(([input]) => String(input).includes(`organization_id=eq.${organizationId}`))).toBe(true);
  });
});

describe("getHotelOffersForManagement", () => {
  it("does not expose offers without membership in the resolved hotel", async () => {
    vi.stubEnv("NODE_ENV", "development");
    vi.stubEnv("VITE_SUPABASE_URL", "https://example.supabase.co");
    vi.stubEnv("VITE_SUPABASE_ANON_KEY", "anon-key");
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "service-role-key");
    vi.stubEnv("BUILDER_PREVIEW_TENANT_ORGANIZATION_ID", organizationId);
    const userId = "bd15af7a-93a0-4618-bd1f-4dc72c7f88c6";
    vi.stubGlobal("fetch", vi.fn(async (input: string | URL | Request) => {
      const url = String(input);
      if (url.includes("hotel_tenant_settings?")) return new Response(JSON.stringify([{
        organization_id: organizationId,
        display_name: "MisuriStay",
        logo_url: null,
        primary_color: null,
        accent_color: null,
      }]), { status: 200 });
      if (url.endsWith("/auth/v1/user")) return new Response(JSON.stringify({ id: userId }), { status: 200 });
      if (url.includes("user_profiles?")) return new Response(JSON.stringify([{ role: "manager" }]), { status: 200 });
      if (url.includes("books_memberships?")) return new Response(JSON.stringify([]), { status: 200 });
      throw new Error(`Unexpected request: ${url}`);
    }));

    const result = { statusCode: 200, body: null as unknown };
    const response = {
      setHeader: vi.fn(),
      status(code: number) { result.statusCode = code; return this; },
      json(body: unknown) { result.body = body; return this; },
    };
    await getHotelOffersForManagement({ hostname: request.hostname, headers: { authorization: "Bearer user-token" } } as Parameters<typeof getHotelOffersForManagement>[0], response as unknown as Parameters<typeof getHotelOffersForManagement>[1], (() => undefined) as Parameters<typeof getHotelOffersForManagement>[2]);

    expect(result.statusCode).toBe(403);
    expect(result.body).toEqual({ error: "Only a hotel manager can manage offers" });
  });
});

describe("resolveRequestHotelTenant", () => {
  it("uses the configured hotel only outside production", async () => {
    vi.stubEnv("NODE_ENV", "development");
    vi.stubEnv("VITE_SUPABASE_URL", "https://example.supabase.co");
    vi.stubEnv("VITE_SUPABASE_ANON_KEY", "anon-key");
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "service-role-key");
    vi.stubEnv("BUILDER_PREVIEW_TENANT_ORGANIZATION_ID", organizationId);
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(JSON.stringify([{
      organization_id: organizationId,
      display_name: "MisuriStay",
      logo_url: null,
      primary_color: "#123456",
      accent_color: "#abcdef",
    }]), { status: 200 })));

    await expect(resolveRequestHotelTenant(request)).resolves.toEqual({
      organizationId,
      domain: "abc123.projects.builder.my",
      name: "MisuriStay",
      logoUrl: null,
      primaryColor: "#123456",
      accentColor: "#abcdef",
    });
    expect(fetch).toHaveBeenCalledWith(
      `https://example.supabase.co/rest/v1/hotel_tenant_settings?organization_id=eq.${organizationId}&is_active=eq.true&select=organization_id,display_name,logo_url,primary_color,accent_color&limit=1`,
      expect.objectContaining({ headers: expect.objectContaining({ Authorization: "Bearer service-role-key" }) }),
    );
  });

  it("uses a forwarded Builder host when the dev proxy exposes localhost", async () => {
    vi.stubEnv("NODE_ENV", "development");
    vi.stubEnv("VITE_SUPABASE_URL", "https://example.supabase.co");
    vi.stubEnv("VITE_SUPABASE_ANON_KEY", "anon-key");
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "service-role-key");
    vi.stubEnv("BUILDER_PREVIEW_TENANT_ORGANIZATION_ID", organizationId);
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(JSON.stringify([{
      organization_id: organizationId,
      display_name: "MisuriStay",
      logo_url: null,
      primary_color: null,
      accent_color: null,
    }]), { status: 200 })));

    const proxiedRequest = {
      hostname: "localhost",
      headers: { "x-forwarded-host": "abc123.projects.builder.my:8080" },
    } as unknown as Parameters<typeof resolveRequestHotelTenant>[0];

    await expect(resolveRequestHotelTenant(proxiedRequest)).resolves.toMatchObject({
      organizationId,
      domain: "abc123.projects.builder.my",
      name: "MisuriStay",
    });
  });

  it("keeps production tenant resolution tied to the requested verified domain", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("VITE_SUPABASE_URL", "https://example.supabase.co");
    vi.stubEnv("VITE_SUPABASE_ANON_KEY", "anon-key");
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "service-role-key");
    vi.stubEnv("BUILDER_PREVIEW_TENANT_ORGANIZATION_ID", organizationId);
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(JSON.stringify([{
      organization_id: "36ec18aa-1fb4-48d6-ae37-6febd60c559c",
      name: "Another Hotel",
      domain: "abc123.projects.builder.my",
      logo_url: null,
      primary_color: null,
      accent_color: null,
    }]), { status: 200 })));

    await expect(resolveRequestHotelTenant(request)).resolves.toMatchObject({
      organizationId: "36ec18aa-1fb4-48d6-ae37-6febd60c559c",
      domain: "abc123.projects.builder.my",
      name: "Another Hotel",
    });
    expect(fetch).toHaveBeenCalledWith(
      "https://example.supabase.co/rest/v1/rpc/resolve_hotel_tenant",
      expect.any(Object),
    );
  });
});

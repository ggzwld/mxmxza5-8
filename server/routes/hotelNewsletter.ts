import { createHmac } from "node:crypto";
import type { RequestHandler } from "express";
import { resolveRequestHotelTenant } from "./hotelTenant.js";

const getConfiguration = () => {
  const supabaseUrl = process.env.VITE_SUPABASE_URL;
  const supabaseAnonKey = process.env.VITE_SUPABASE_ANON_KEY;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !supabaseAnonKey || !serviceRoleKey) throw new Error("Hotel newsletter configuration is incomplete");
  return { supabaseUrl: supabaseUrl.replace(/\/$/, ""), supabaseAnonKey, serviceRoleKey };
};

export const submitHotelNewsletter: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const body = request.body as { operation?: unknown; email?: unknown; consent?: unknown; token?: unknown };
    if (body.operation !== "unsubscribe" && (typeof body.email !== "string" || body.consent !== true)) {
      return response.status(400).json({ error: "Enter your email and confirm consent to receive hotel offers" });
    }
    if (body.operation === "unsubscribe" && typeof body.token !== "string") {
      return response.status(400).json({ error: "Unsubscribe link is invalid" });
    }
    const { serviceRoleKey } = getConfiguration();
    const origin = new URL(request.get("origin") || `https://${request.hostname}`);
    const originTenant = await resolveRequestHotelTenant({ hostname: origin.hostname, headers: request.headers } as typeof request);
    if (originTenant.organizationId !== tenant.organizationId) {
      console.warn("Hotel newsletter origin resolved to a different tenant", { requestOrganizationId: tenant.organizationId, originOrganizationId: originTenant.organizationId, origin: origin.hostname });
      return response.status(403).json({ error: "This site address is not registered to the same hotel as its newsletter." });
    }
    const unsubscribeUrl = new URL("/offers", origin);
    const payload = { ...body, organizationId: tenant.organizationId, unsubscribeUrl: unsubscribeUrl.toString() };
    const timestamp = String(Date.now());
    const signature = createHmac("sha256", serviceRoleKey).update(`${timestamp}.${JSON.stringify(payload)}`).digest("hex");
    const functionUrl = process.env.HOTEL_NEWSLETTER_FUNCTION_URL || "https://us-central1-speshio.cloudfunctions.net/hotelOffersNewsletter";
    const result = await fetch(functionUrl, {
      method: "POST",
      headers: { "content-type": "application/json", "x-hotel-newsletter-timestamp": timestamp, "x-hotel-newsletter-signature": signature },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(45_000),
    });
    const resultBody = await result.json().catch(() => null) as { error?: string; ok?: boolean; unsubscribeToken?: string; unsubscribed?: boolean } | null;
    if (!result.ok || !resultBody?.ok) return response.status(result.status >= 400 && result.status < 500 ? result.status : 503).json({ error: resultBody?.error || "Newsletter service is temporarily unavailable" });
    response.setHeader("Cache-Control", "private, no-store");
    return response.json(resultBody);
  } catch (error) {
    return response.status(503).json({ error: error instanceof Error ? error.message : "Newsletter service is temporarily unavailable" });
  }
};

import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import type { Request, RequestHandler } from "express";
import { resolveRequestHotelTenant } from "./hotelTenant.js";

const paymentBaseUrl = "https://api.flutterwave.com/v3";
const supportedCurrencies = new Set(["USD", "UGX", "EUR", "GBP", "KES", "TZS", "RWF"]);

const configuration = () => {
  const supabaseUrl = process.env.VITE_SUPABASE_URL;
  const supabaseAnonKey = process.env.VITE_SUPABASE_ANON_KEY;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !supabaseAnonKey || !serviceRoleKey) throw new Error("Hotel spa database configuration is incomplete");
  return { supabaseUrl: supabaseUrl.replace(/\/$/, ""), supabaseAnonKey, serviceRoleKey };
};

const serviceHeaders = (json = false) => {
  const { supabaseAnonKey, serviceRoleKey } = configuration();
  return { apikey: supabaseAnonKey, Authorization: `Bearer ${serviceRoleKey}`, ...(json ? { "content-type": "application/json" } : {}) };
};

const readService = async <T>(path: string): Promise<T> => {
  const { supabaseUrl } = configuration();
  const response = await fetch(`${supabaseUrl}/rest/v1/${path}`, { headers: serviceHeaders(), signal: AbortSignal.timeout(10_000) });
  if (!response.ok) throw new Error("Hotel spa data could not be loaded");
  return response.json() as Promise<T>;
};

const writeService = async <T>(path: string, method: "POST" | "PATCH" | "DELETE", body?: Record<string, unknown>): Promise<T> => {
  const { supabaseUrl } = configuration();
  const response = await fetch(`${supabaseUrl}/rest/v1/${path}`, {
    method,
    headers: { ...serviceHeaders(true), Prefer: "return=representation" },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error("Spa service could not be saved");
  if (response.status === 204) return [] as T;
  return response.json() as Promise<T>;
};

const callRpc = async <T>(name: string, args: Record<string, unknown>): Promise<T> => {
  const { supabaseUrl } = configuration();
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: serviceHeaders(true),
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(15_000),
  });
  const result = await response.json().catch(() => null) as T | { message?: string } | null;
  if (!response.ok) throw Object.assign(new Error(typeof result === "object" && result && "message" in result ? result.message : "Spa request could not be completed"), { status: 400 });
  return result as T;
};

const getUserId = async (authorization: string | undefined) => {
  if (!authorization?.startsWith("Bearer ")) throw Object.assign(new Error("Authentication is required"), { status: 401 });
  const { supabaseUrl, supabaseAnonKey } = configuration();
  const response = await fetch(`${supabaseUrl}/auth/v1/user`, { headers: { apikey: supabaseAnonKey, Authorization: authorization }, signal: AbortSignal.timeout(10_000) });
  if (!response.ok) throw Object.assign(new Error("Your sign-in session has expired"), { status: 401 });
  const user = await response.json() as { id?: string };
  if (!user.id) throw Object.assign(new Error("Your sign-in session could not be verified"), { status: 401 });
  return user.id;
};

const requireHotelManager = async (request: Request) => {
  const tenant = await resolveRequestHotelTenant(request);
  const userId = await getUserId(request.headers.authorization);
  const organizationId = encodeURIComponent(tenant.organizationId);
  const encodedUserId = encodeURIComponent(userId);
  const [profiles, memberships] = await Promise.all([
    readService<Array<{ role: string }>>(`user_profiles?user_id=eq.${encodedUserId}&select=role&limit=1`),
    readService<Array<{ role: string }>>(`books_memberships?organization_id=eq.${organizationId}&user_id=eq.${encodedUserId}&role=in.(owner,admin)&select=role&limit=1`),
  ]);
  if (profiles[0]?.role !== "manager" || !memberships[0]) throw Object.assign(new Error("Only a hotel manager can manage spa services"), { status: 403 });
  return tenant;
};

const validEmail = (value: unknown): value is string => typeof value === "string" && value.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
const parseWeeklyHours = (value: unknown) => {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Set valid weekly opening hours");
  const output: Record<string, { open: string; close: string }[]> = {};
  for (let day = 0; day < 7; day += 1) {
    const ranges = (value as Record<string, unknown>)[String(day)];
    if (!Array.isArray(ranges) || ranges.length > 8) throw new Error("Set valid weekly opening hours");
    const parsed = ranges.map((range) => {
      if (!range || typeof range !== "object") throw new Error("Set valid weekly opening hours");
      const { open, close } = range as Record<string, unknown>;
      if (typeof open !== "string" || typeof close !== "string" || !/^([01]\d|2[0-3]):[0-5]\d$/.test(open) || !/^([01]\d|2[0-3]):[0-5]\d$/.test(close) || close <= open) {
        throw new Error("Opening ranges must have a start and a later closing time on the same day");
      }
      return { open, close };
    }).sort((a, b) => a.open.localeCompare(b.open));
    if (parsed.some((range, index) => index > 0 && range.open < parsed[index - 1].close)) throw new Error("Opening ranges cannot overlap");
    output[String(day)] = parsed;
  }
  return output;
};

const validateService = (input: Record<string, unknown>) => {
  const name = typeof input.name === "string" ? input.name.trim() : "";
  const description = typeof input.description === "string" ? input.description.trim() : "";
  const price = Number(input.price);
  const currencyCode = typeof input.currency_code === "string" ? input.currency_code.trim().toUpperCase() : "";
  const durationMinutes = Number(input.duration_minutes);
  const slotIntervalMinutes = Number(input.slot_interval_minutes);
  const capacity = Number(input.capacity);
  const depositType = input.deposit_type;
  const depositValue = Number(input.deposit_value);
  const timezone = typeof input.timezone === "string" ? input.timezone.trim() : "Africa/Kampala";
  try { new Intl.DateTimeFormat("en", { timeZone: timezone }); } catch { throw new Error("Enter a valid hotel timezone"); }
  if (!name || name.length > 120 || description.length > 2000 || !Number.isFinite(price) || price <= 0
    || !supportedCurrencies.has(currencyCode) || !Number.isInteger(durationMinutes) || durationMinutes < 10 || durationMinutes > 480
    || !Number.isInteger(slotIntervalMinutes) || slotIntervalMinutes < 5 || slotIntervalMinutes > 240
    || !Number.isInteger(capacity) || capacity < 1 || capacity > 100
    || (depositType !== "fixed" && depositType !== "percentage") || !Number.isFinite(depositValue) || depositValue < 0
    || depositValue <= 0 || (depositType === "percentage" && depositValue > 100) || (depositType === "fixed" && depositValue > price)) {
    throw new Error("Enter valid spa service details");
  }
  return { name, description, price, currency_code: currencyCode, duration_minutes: durationMinutes, slot_interval_minutes: slotIntervalMinutes, capacity, weekly_hours: parseWeeklyHours(input.weekly_hours), deposit_type: depositType, deposit_value: depositValue, is_active: input.is_active === true };
};

const hashToken = (token: string) => createHash("sha256").update(token).digest("hex");
const safeText = (value: unknown, max: number) => typeof value === "string" ? value.trim().slice(0, max) : "";
const getIp = (request: Request) => {
  const forwarded = request.headers["x-vercel-forwarded-for"] || request.headers["x-nf-client-connection-ip"];
  return (Array.isArray(forwarded) ? forwarded[0] : forwarded)?.split(",")[0]?.trim() || request.ip || request.socket.remoteAddress || "unknown";
};
const returnUrl = (domain: string) => {
  const value = process.env.NODE_ENV === "production" ? process.env.FLUTTERWAVE_RETURN_URL : process.env.FLUTTERWAVE_LOCAL_RETURN_URL;
  if (!value) throw new Error("Flutterwave return URL is not configured");
  const parsed = new URL(value);
  if (parsed.protocol !== "https:" || parsed.pathname !== "/checkout/flutterwave-return") throw new Error("Flutterwave return URL must use HTTPS and target the payment return route");
  parsed.hostname = domain;
  return parsed.toString();
};

export const getHotelSpaServices: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const organizationId = encodeURIComponent(tenant.organizationId);
    const [settings, services] = await Promise.all([
      readService<Array<{ timezone: string }>>(`hotel_tenant_settings?organization_id=eq.${organizationId}&is_active=eq.true&select=timezone&limit=1`),
      readService<Array<Record<string, unknown>>>(`hotel_spa_services?organization_id=eq.${organizationId}&is_active=eq.true&select=id,name,description,price,currency_code,duration_minutes,slot_interval_minutes,capacity,weekly_hours,deposit_type,deposit_value&order=name.asc`),
    ]);
    response.setHeader("Cache-Control", "private, no-store");
    response.json({ tenant: { name: tenant.name, timezone: settings[0]?.timezone || "Africa/Kampala" }, services });
  } catch (error) {
    response.status((error as Error & { status?: number }).status || 404).json({ error: error instanceof Error ? error.message : "Spa services could not be loaded" });
  }
};

export const getHotelSpaAvailability: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const serviceId = request.query.serviceId;
    const date = request.query.date;
    if (typeof serviceId !== "string" || !/^[0-9a-f-]{36}$/i.test(serviceId) || typeof date !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      return response.status(400).json({ error: "Choose a spa service and appointment date" });
    }
    const slots = await callRpc<Array<{ slot_start: string; slot_end: string; remaining_capacity: number }>>("get_hotel_spa_availability", {
      target_organization_id: tenant.organizationId,
      target_service_id: serviceId,
      target_date: date,
    });
    response.setHeader("Cache-Control", "private, no-store");
    response.json({ slots });
  } catch (error) {
    response.status((error as Error & { status?: number }).status || 503).json({ error: error instanceof Error ? error.message : "Spa availability could not be loaded" });
  }
};

export const getHotelSpaServicesForManagement: RequestHandler = async (request, response) => {
  try {
    const tenant = await requireHotelManager(request);
    const [services, settings] = await Promise.all([
      readService<Array<Record<string, unknown>>>(`hotel_spa_services?organization_id=eq.${encodeURIComponent(tenant.organizationId)}&select=*&order=name.asc`),
      readService<Array<{ timezone: string }>>(`hotel_tenant_settings?organization_id=eq.${encodeURIComponent(tenant.organizationId)}&select=timezone&limit=1`),
    ]);
    response.setHeader("Cache-Control", "private, no-store");
    response.json({ services, timezone: settings[0]?.timezone || "Africa/Kampala" });
  } catch (error) {
    response.status((error as Error & { status?: number }).status || 503).json({ error: error instanceof Error ? error.message : "Spa services could not be loaded" });
  }
};

export const saveHotelSpaService: RequestHandler = async (request, response) => {
  try {
    const tenant = await requireHotelManager(request);
    const body = request.body as Record<string, unknown>;
    const values = validateService(body);
    const timezone = typeof body.timezone === "string" ? body.timezone.trim() : "Africa/Kampala";
    await writeService(`hotel_tenant_settings?organization_id=eq.${encodeURIComponent(tenant.organizationId)}`, "PATCH", { timezone, updated_at: new Date().toISOString() });
    if (typeof body.id === "string") {
      const rows = await writeService<Array<{ id: string }>>(`hotel_spa_services?id=eq.${encodeURIComponent(body.id)}&organization_id=eq.${encodeURIComponent(tenant.organizationId)}&select=id`, "PATCH", values);
      if (!rows.length) return response.status(404).json({ error: "Spa service was not found for this hotel" });
    } else {
      await writeService("hotel_spa_services?select=id", "POST", { ...values, organization_id: tenant.organizationId });
    }
    return response.json({ ok: true });
  } catch (error) {
    return response.status((error as Error & { status?: number }).status || 400).json({ error: error instanceof Error ? error.message : "Spa service could not be saved" });
  }
};

export const deleteHotelSpaService: RequestHandler = async (request, response) => {
  try {
    const tenant = await requireHotelManager(request);
    const id = (request.body as { id?: unknown }).id;
    if (typeof id !== "string" || !/^[0-9a-f-]{36}$/i.test(id)) return response.status(400).json({ error: "Spa service identifier is invalid" });
    const rows = await writeService<Array<{ id: string }>>(`hotel_spa_services?id=eq.${encodeURIComponent(id)}&organization_id=eq.${encodeURIComponent(tenant.organizationId)}&select=id`, "DELETE");
    if (!rows.length) return response.status(404).json({ error: "Spa service was not found for this hotel" });
    return response.json({ ok: true });
  } catch (error) {
    return response.status((error as Error & { status?: number }).status || 503).json({ error: error instanceof Error ? error.message : "Spa service could not be deleted" });
  }
};

export const createHotelSpaBooking: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const body = request.body as Record<string, unknown>;
    const guest = body.guest && typeof body.guest === "object" ? body.guest as Record<string, unknown> : {};
    const firstName = safeText(guest.firstName, 100);
    const lastName = safeText(guest.lastName, 100);
    const email = safeText(guest.email, 254).toLowerCase();
    const phone = safeText(guest.phone, 40);
    if (!firstName || !lastName || !validEmail(email) || !phone || typeof body.serviceId !== "string" || !/^[0-9a-f-]{36}$/i.test(body.serviceId)
      || typeof body.slotStart !== "string" || Number.isNaN(Date.parse(body.slotStart))
      || !["pay_at_spa", "full", "deposit"].includes(String(body.paymentChoice))) {
      return response.status(400).json({ error: "Enter your contact details and choose a spa service, time, and payment option" });
    }
    const forwardedAddress = getIp(request);
    const { supabaseUrl } = configuration();
    const rateKey = createHash("sha256").update(`spa:${tenant.organizationId}:${forwardedAddress}`).digest("hex");
    const limitResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/consume_hotel_booking_rate_limit`, {
      method: "POST", headers: serviceHeaders(true), body: JSON.stringify({ target_rate_limit_key: rateKey }), signal: AbortSignal.timeout(10_000),
    });
    if (!limitResponse.ok || !(await limitResponse.json())) return response.status(429).json({ error: "Too many appointment attempts. Please try again later." });
    const accessToken = randomBytes(32).toString("hex");
    const booking = await callRpc<Array<{ booking_id: string; confirmation_number: string; amount_due: number; service_price: number; currency_code: string; booking_status: string; payment_status: string; starts_at: string; expires_at: string | null; timezone: string }>>("create_hotel_spa_booking", {
      target_organization_id: tenant.organizationId,
      target_service_id: body.serviceId,
      target_guest: { first_name: firstName, last_name: lastName, email, phone },
      target_slot_start: new Date(body.slotStart).toISOString(),
      target_payment_choice: body.paymentChoice,
      target_access_token_hash: hashToken(accessToken),
    });
    const result = booking[0];
    if (!result) throw new Error("Spa booking was not created");
    response.status(201).json({ ...result, accessToken });
  } catch (error) {
    response.status((error as Error & { status?: number }).status || 400).json({ error: error instanceof Error ? error.message : "Spa booking could not be created" });
  }
};

const getSpaBooking = async (bookingId: string, accessToken: string) => {
  const rows = await readService<Array<Record<string, unknown>>>(`hotel_spa_bookings?id=eq.${encodeURIComponent(bookingId)}&access_token_hash=eq.${hashToken(accessToken)}&select=*`);
  if (!rows[0]) throw Object.assign(new Error("Spa booking could not be verified"), { status: 404 });
  return rows[0];
};

const verifyFlutterwaveTransaction = async (transactionId: string) => {
  const secretKey = process.env.FLUTTERWAVE_SECRET_KEY;
  if (!secretKey) throw new Error("Flutterwave payment configuration is incomplete");
  const response = await fetch(`${paymentBaseUrl}/transactions/${encodeURIComponent(transactionId)}/verify`, { headers: { Authorization: `Bearer ${secretKey}` }, signal: AbortSignal.timeout(15_000) });
  const payload = await response.json() as { status?: string; data?: { id?: string | number; tx_ref?: string; status?: string; amount?: number; currency?: string } };
  if (!response.ok || payload.status !== "success" || !payload.data) throw new Error("Spa payment could not be verified");
  return payload.data;
};

const confirmSpaPayment = async (transactionId: string, txRef: string, booking: Record<string, unknown>) => {
  const transaction = await verifyFlutterwaveTransaction(transactionId);
  const { supabaseUrl } = configuration();
  const attempts = await readService<Array<Record<string, unknown>>>(`hotel_spa_payment_attempts?tx_ref=eq.${encodeURIComponent(txRef)}&booking_id=eq.${encodeURIComponent(String(booking.id))}&select=*`);
  const attempt = attempts[0];
  if (!attempt || transaction.status !== "successful" || transaction.tx_ref !== txRef
    || Number(transaction.amount) !== Number(attempt.amount) || Number(transaction.amount) !== Number(booking.amount_due)
    || transaction.currency?.toUpperCase() !== String(booking.currency_code).trim().toUpperCase()) {
    throw new Error("Spa payment details do not match the booking");
  }
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/confirm_hotel_spa_booking_payment`, {
    method: "POST",
    headers: serviceHeaders(true),
    body: JSON.stringify({ target_booking_id: booking.id, target_access_token_hash: booking.access_token_hash, target_tx_ref: txRef, target_transaction_id: String(transaction.id) }),
    signal: AbortSignal.timeout(15_000),
  });
  const result = await response.json().catch(() => null) as { message?: string } | null;
  if (!response.ok) {
    console.error("Hotel spa payment confirmation RPC failed", { bookingId: booking.id, txRef, error: result?.message || response.status });
    throw new Error("Spa payment could not be confirmed");
  }
  return Array.isArray(result) ? result[0] : result;
};

export const createHotelSpaPaymentSession: RequestHandler = async (request, response) => {
  let txRef: string | undefined;
  try {
    const { bookingId, accessToken } = request.body as { bookingId?: unknown; accessToken?: unknown };
    if (typeof bookingId !== "string" || typeof accessToken !== "string" || !/^[a-f0-9]{64}$/i.test(accessToken)) return response.status(400).json({ error: "Spa booking access is invalid" });
    const booking = await getSpaBooking(bookingId, accessToken);
    const tenant = await resolveRequestHotelTenant(request);
    if (booking.organization_id !== tenant.organizationId) return response.status(404).json({ error: "Spa booking could not be verified" });
    if (booking.booking_status !== "pending_payment" || new Date(String(booking.expires_at)).getTime() <= Date.now()) return response.status(409).json({ error: "Spa booking hold has expired" });
    const paymentOptions = String(booking.currency_code).trim().toUpperCase() === "UGX" ? "card, mobilemoneyuganda" : "card";
    txRef = `hotel-spa-${String(booking.confirmation_number)}-${randomUUID()}`;
    const attemptRows = await callRpc<Array<{ attempt_id: string; attempt_tx_ref: string; attempt_status: string; attempt_payment_url: string | null; amount: number; currency_code: string }>>("create_hotel_spa_payment_attempt", {
      target_booking_id: booking.id,
      target_access_token_hash: hashToken(accessToken),
      target_tx_ref: txRef,
    });
    const attempt = attemptRows[0];
    if (attempt?.attempt_status === "redirected" && attempt.attempt_payment_url) return response.json({ paymentUrl: attempt.attempt_payment_url, txRef: attempt.attempt_tx_ref, bookingId });
    txRef = attempt?.attempt_tx_ref;
    const secretKey = process.env.FLUTTERWAVE_SECRET_KEY;
    if (!secretKey || !txRef) throw new Error("Spa payment configuration is incomplete");
    const paymentResponse = await fetch(`${paymentBaseUrl}/payments`, {
      method: "POST",
      headers: { Authorization: `Bearer ${secretKey}`, "content-type": "application/json" },
      body: JSON.stringify({
        tx_ref: txRef,
        amount: Number(attempt.amount),
        currency: String(attempt.currency_code).trim().toUpperCase(),
        payment_options: paymentOptions,
        redirect_url: returnUrl(request.hostname),
        customer: { email: booking.guest_email, name: `${booking.guest_first_name} ${booking.guest_last_name}`.trim(), phonenumber: booking.guest_phone },
        meta: { booking_id: booking.id, confirmation_number: booking.confirmation_number, flow: "hotel-spa" },
        customizations: { title: `${tenant.name} Spa`, description: `Spa appointment ${booking.confirmation_number}` },
      }),
      signal: AbortSignal.timeout(15_000),
    });
    const payment = await paymentResponse.json() as { status?: string; data?: { link?: string } };
    if (!paymentResponse.ok || payment.status !== "success" || !payment.data?.link) throw new Error("Flutterwave could not prepare spa checkout");
    await writeService(`hotel_spa_payment_attempts?tx_ref=eq.${encodeURIComponent(txRef)}`, "PATCH", { status: "redirected", payment_url: payment.data.link, updated_at: new Date().toISOString() });
    return response.json({ paymentUrl: payment.data.link, txRef, bookingId });
  } catch (error) {
    if (txRef) await writeService(`hotel_spa_payment_attempts?tx_ref=eq.${encodeURIComponent(txRef)}`, "PATCH", { status: "failed", updated_at: new Date().toISOString() }).catch(() => undefined);
    return response.status((error as Error & { status?: number }).status || 502).json({ error: error instanceof Error ? error.message : "Spa payment could not be prepared" });
  }
};

export const verifyHotelSpaPayment: RequestHandler = async (request, response) => {
  try {
    const { transactionId, txRef, accessToken, bookingId } = request.body as { transactionId?: unknown; txRef?: unknown; accessToken?: unknown; bookingId?: unknown };
    if (!transactionId || typeof txRef !== "string" || typeof accessToken !== "string" || typeof bookingId !== "string") return response.status(400).json({ error: "Spa payment verification details are required" });
    const booking = await getSpaBooking(bookingId, accessToken);
    const tenant = await resolveRequestHotelTenant(request);
    if (booking.organization_id !== tenant.organizationId) return response.status(404).json({ error: "Spa booking could not be verified" });
    const confirmation = await confirmSpaPayment(String(transactionId), txRef, booking);
    return response.json(confirmation);
  } catch (error) {
    console.error("Hotel spa payment verification failed", { txRef: (request.body as { txRef?: unknown }).txRef, error: error instanceof Error ? error.message : "unknown error" });
    return response.status((error as Error & { status?: number }).status || 400).json({ error: error instanceof Error ? error.message : "Spa payment could not be verified" });
  }
};

export const cancelHotelSpaPayment: RequestHandler = async (request, response) => {
  try {
    const { txRef, status, accessToken } = request.body as { txRef?: unknown; status?: unknown; accessToken?: unknown };
    if (typeof txRef !== "string" || !["cancelled", "failed"].includes(String(status)) || typeof accessToken !== "string") return response.status(400).json({ error: "Spa payment status is invalid" });
    const attempts = await readService<Array<Record<string, unknown>>>(`hotel_spa_payment_attempts?tx_ref=eq.${encodeURIComponent(txRef)}&select=*`);
    const attempt = attempts[0];
    if (!attempt) return response.status(404).json({ error: "Spa payment attempt was not found" });
    const booking = await getSpaBooking(String(attempt.booking_id), accessToken);
    const tenant = await resolveRequestHotelTenant(request);
    if (booking.organization_id !== tenant.organizationId) return response.status(404).json({ error: "Spa payment attempt was not found" });
    if (["initiated", "redirected"].includes(String(attempt.status))) await writeService(`hotel_spa_payment_attempts?tx_ref=eq.${encodeURIComponent(txRef)}`, "PATCH", { status, updated_at: new Date().toISOString() });
    return response.json({ ok: true });
  } catch (error) {
    return response.status((error as Error & { status?: number }).status || 400).json({ error: error instanceof Error ? error.message : "Spa payment status could not be saved" });
  }
};

export const verifyHotelSpaPaymentForWebhook = async (transactionId: string, txRef: string) => {
  const attempts = await readService<Array<Record<string, unknown>>>(`hotel_spa_payment_attempts?tx_ref=eq.${encodeURIComponent(txRef)}&select=booking_id`);
  if (!attempts[0]) throw new Error("Spa payment attempt was not found");
  const bookings = await readService<Array<Record<string, unknown>>>(`hotel_spa_bookings?id=eq.${encodeURIComponent(String(attempts[0].booking_id))}&select=*`);
  if (!bookings[0]) throw new Error("Spa booking was not found");
  return confirmSpaPayment(transactionId, txRef, bookings[0]);
};

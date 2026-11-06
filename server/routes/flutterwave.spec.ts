import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { prepareFlutterwaveHostedSession, verifyFlutterwavePayment } from "./flutterwave";

const orderId = "f4d77e69-3a94-4c6f-b311-3c832206c0fd";
const organizationId = "cd4d5b85-0559-4ee0-8fcf-c2b3454d0811";
const transactionId = "9001001";
const txRef = "sheraton-SH0123456789AB-abc123";

const jsonResponse = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });

describe("verifyFlutterwavePayment", () => {
  beforeEach(() => {
    vi.stubEnv("VITE_SUPABASE_URL", "https://supabase.example.test");
    vi.stubEnv("VITE_SUPABASE_ANON_KEY", "anon-key");
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "service-role-key");
    vi.stubEnv("FLUTTERWAVE_SECRET_KEY", "flutterwave-secret");
    vi.stubEnv("FLUTTERWAVE_SECRET_HASH", "flutterwave-hash");
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  it.each([
    { label: "pending", paymentStatus: "pending", flutterwaveTransactionId: null },
    { label: "already paid on retry", paymentStatus: "paid", flutterwaveTransactionId: transactionId },
  ])("confirms the attempt atomically for an order $label", async ({ paymentStatus, flutterwaveTransactionId }) => {
    const order = {
      id: orderId,
      organization_id: organizationId,
      user_id: "6f4753fc-ab48-4f03-af42-c34ae0d2f3a9",
      order_number: "SH0123456789AB",
      payment_method: "card",
      payment_status: paymentStatus,
      pricing_version: 1,
      currency: "UGX",
      payment_reference: txRef,
      flutterwave_transaction_id: flutterwaveTransactionId,
      total_amount: 1200,
      email: "guest@example.test",
      first_name: "Test",
      last_name: "Guest",
      phone: "+256700000000",
    };
    const attempt = {
      id: "1c46c79a-3e19-4c18-8f73-dfe6e4bfc1d1",
      order_id: orderId,
      tx_ref: txRef,
      transaction_id: null,
      amount: 1200,
      currency: "UGX",
      status: "redirected",
    };
    const confirmRpc = vi.fn();
    const fetchMock = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
      const url = String(input);
      if (url.endsWith("/rpc/resolve_hotel_tenant")) {
        return jsonResponse([{ organization_id: organizationId, name: "Ricanspace", domain: "rphw-zved.vercel.app", logo_url: null, primary_color: null, accent_color: null }]);
      }
      if (url.includes("/rest/v1/menu_payment_attempts?tx_ref=")) return jsonResponse([attempt]);
      if (url.includes(`/rest/v1/menu_orders?id=eq.${orderId}`)) return jsonResponse([order]);
      if (url.includes(`/transactions/${transactionId}/verify`)) {
        return jsonResponse({
          status: "success",
          data: {
            id: transactionId,
            tx_ref: txRef,
            status: "successful",
            amount: 1200,
            currency: "UGX",
            meta: { order_id: orderId },
          },
        });
      }
      if (url.endsWith("/rpc/confirm_menu_flutterwave_payment")) {
        expect(JSON.parse(String(init?.body))).toEqual({
          target_order_id: orderId,
          target_tx_ref: txRef,
          target_transaction_id: transactionId,
        });
        confirmRpc();
        return jsonResponse({ orderId, orderNumber: order.order_number, paymentStatus: "paid" });
      }
      throw new Error(`Unexpected request: ${url}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    const result = { statusCode: 200, body: null as unknown };
    const response = {
      status(code: number) {
        result.statusCode = code;
        return this;
      },
      json(body: unknown) {
        result.body = body;
        return this;
      },
    };

    await verifyFlutterwavePayment({
      headers: { authorization: "Bearer user-token" },
      hostname: "rphw-zved.vercel.app",
      body: { transactionId, txRef },
    } as Parameters<typeof verifyFlutterwavePayment>[0], response as Parameters<typeof verifyFlutterwavePayment>[1], (() => undefined) as Parameters<typeof verifyFlutterwavePayment>[2]);

    expect(result.statusCode).toBe(200);
    expect(result.body).toMatchObject({ orderId, orderNumber: "SH0123456789AB", paymentStatus: "paid" });
    expect(confirmRpc).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls.filter(([, init]) => init?.method === "PATCH")).toHaveLength(0);
  });
});

describe("prepareFlutterwaveHostedSession", () => {
  beforeEach(() => {
    vi.stubEnv("VITE_SUPABASE_URL", "https://supabase.example.test");
    vi.stubEnv("VITE_SUPABASE_ANON_KEY", "anon-key");
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "service-role-key");
    vi.stubEnv("FLUTTERWAVE_SECRET_KEY", "flutterwave-secret");
    vi.stubEnv("FLUTTERWAVE_SECRET_HASH", "flutterwave-hash");
    vi.stubEnv("FLUTTERWAVE_LOCAL_RETURN_URL", "https://hotel.example.test/checkout/flutterwave-return");
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  it("creates a new provider session when a saved redirect amount is stale", async () => {
    const userId = "6f4753fc-ab48-4f03-af42-c34ae0d2f3a9";
    const currentAmount = 24000;
    const currentOrder = {
      id: orderId,
      organization_id: organizationId,
      user_id: userId,
      order_number: "SH0123456789AB",
      payment_method: "card",
      payment_status: "pending",
      pricing_version: 1,
      currency: "UGX",
      total_amount: currentAmount,
      email: "guest@example.test",
      first_name: "Test",
      last_name: "Guest",
      phone: "+256700000000",
    };
    const staleTxRef = "sheraton-SH0123456789AB-00000000-0000-4000-8000-000000000001";
    const currentTxRef = "sheraton-SH0123456789AB-00000000-0000-4000-8000-000000000002";
    const fetchMock = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
      const url = String(input);
      if (url.includes(`/rest/v1/menu_orders?id=eq.${orderId}`)) return jsonResponse([currentOrder]);
      if (url.endsWith("/rpc/create_menu_payment_attempt")) {
        const body = JSON.parse(String(init?.body));
        expect(body).toMatchObject({ target_order_id: orderId, target_user_id: userId });
        return jsonResponse([body.target_tx_ref === currentTxRef
          ? { attempt_id: "attempt-current", attempt_tx_ref: currentTxRef, attempt_status: "initiated", attempt_payment_url: null }
          : { attempt_id: "attempt-stale", attempt_tx_ref: staleTxRef, attempt_status: "redirected", attempt_payment_url: "https://checkout.flutterwave.com/stale" }]);
      }
      if (url.includes(`/rest/v1/menu_payment_attempts?tx_ref=eq.${staleTxRef}`) && init?.method === "PATCH") {
        expect(JSON.parse(String(init.body))).toMatchObject({ status: "failed" });
        return jsonResponse(null);
      }
      if (url.includes(`/rest/v1/menu_payment_attempts?tx_ref=eq.${staleTxRef}`)) {
        return jsonResponse([{ id: "attempt-stale", order_id: orderId, tx_ref: staleTxRef, transaction_id: null, amount: 12000, currency: "UGX", status: "redirected" }]);
      }
      if (url.includes(`/rest/v1/menu_payment_attempts?tx_ref=eq.${currentTxRef}`)) {
        return jsonResponse([{ id: "attempt-current", order_id: orderId, tx_ref: currentTxRef, transaction_id: null, amount: currentAmount, currency: "UGX", status: "initiated" }]);
      }
      if (url.endsWith("/payments") && init?.method === "POST") {
        const body = JSON.parse(String(init.body));
        expect(body.amount).toBe(currentAmount);
        expect(body.currency).toBe("UGX");
        expect(body.tx_ref).toBe(currentTxRef);
        return jsonResponse({ status: "success", data: { link: "https://checkout.flutterwave.com/current" } });
      }
      if (url.includes(`/rest/v1/menu_payment_attempts?tx_ref=eq.${currentTxRef}`) && init?.method === "PATCH") return jsonResponse(null);
      throw new Error(`Unexpected request: ${url}`);
    });
    vi.stubGlobal("fetch", fetchMock);
    vi.spyOn(crypto, "randomUUID").mockReturnValueOnce("00000000-0000-4000-8000-000000000001").mockReturnValueOnce("00000000-0000-4000-8000-000000000002");

    const result = await prepareFlutterwaveHostedSession({ orderId }, organizationId, "hotel.example.test", "Bearer user-token");

    expect(result).toEqual({ paymentUrl: "https://checkout.flutterwave.com/current", txRef: currentTxRef, orderId });
    expect(fetchMock.mock.calls.filter(([input]) => String(input).endsWith("/rpc/create_menu_payment_attempt"))).toHaveLength(2);
  });
});

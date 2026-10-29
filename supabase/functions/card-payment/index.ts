// Online card payments for QAVERA through Noqoody (API v2).
// Called from the website (checkout, payment-result, account, admin).
//
//   { action: "config" }              -> is "Pay online by card" shown to this visitor?
//   { action: "start", order_id }     -> creates a Noqoody payment link for the
//                                        signed-in customer's order, returns its URL
//   { action: "check", order_id }     -> asks Noqoody if the order is paid and, if
//                                        so, marks it paid in the database
//
// Secrets: NOQOODY_API_KEY (nq_test_… = sandbox, anything else = live).
// Optional: NOQOODY_PROJECT_CODE + NOQOODY_CLIENT_SECRET (otherwise read from
//   the account), NOQOODY_BASE_URL (otherwise picked from the key).
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.
// In the Supabase dashboard, turn OFF "Verify JWT" for this function: it checks
// the signed-in customer itself.

const SITE_URL = "https://www.qavera.qa";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const apiKey = () => Deno.env.get("NOQOODY_API_KEY") || "";
const isTestKey = () => apiKey().startsWith("nq_test_");
const baseUrl = () =>
  (Deno.env.get("NOQOODY_BASE_URL") || (isTestKey() ? "https://api-sandbox.noqoody.qa" : "https://api.noqoody.qa"))
    .replace(/\/+$/, "");

// ---- Supabase (service role) ----
const SB_URL = () => Deno.env.get("SUPABASE_URL")!;
const serviceHeaders = () => {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  return { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" };
};

type Order = {
  id: string;
  order_number: string;
  user_id: string | null;
  customer_name: string;
  customer_email: string | null;
  customer_phone: string;
  total: number;
  status: string;
  payment_method: string;
  payment_status: string;
  online_payment_refs: string[] | null;
};

async function loadOrder(id: string): Promise<Order | null> {
  if (!/^[0-9a-f-]{36}$/i.test(id || "")) return null;
  const response = await fetch(
    `${SB_URL()}/rest/v1/orders?id=eq.${id}&select=id,order_number,user_id,customer_name,customer_email,customer_phone,total,status,payment_method,payment_status,online_payment_refs`,
    { headers: serviceHeaders() },
  );
  if (!response.ok) throw new Error(`Could not load the order: ${await response.text()}`);
  return (await response.json())[0] || null;
}

async function updateOrder(id: string, fields: Record<string, unknown>) {
  const response = await fetch(`${SB_URL()}/rest/v1/orders?id=eq.${id}`, {
    method: "PATCH",
    headers: { ...serviceHeaders(), Prefer: "return=minimal" },
    body: JSON.stringify(fields),
  });
  if (!response.ok) throw new Error(`Could not update the order: ${await response.text()}`);
}

// The signed-in visitor, from the token the website sends.
async function currentUser(req: Request): Promise<{ id: string; admin: boolean } | null> {
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token || !token.includes(".")) return null;  // the public key is not a user
  const gateway = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;  // passes the gateway; the token decides who
  const userResponse = await fetch(`${SB_URL()}/auth/v1/user`, {
    headers: { apikey: gateway, Authorization: `Bearer ${token}` },
  });
  if (!userResponse.ok) return null;
  const user = await userResponse.json();
  const adminResponse = await fetch(`${SB_URL()}/rest/v1/rpc/is_admin`, {
    method: "POST",
    headers: { apikey: gateway, Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: "{}",
  });
  const admin = adminResponse.ok && (await adminResponse.json()) === true;
  return user?.id ? { id: user.id, admin } : null;
}

// ---- Noqoody ----
async function noqoody(path: string, init: RequestInit = {}) {
  const response = await fetch(`${baseUrl()}${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${apiKey()}`, "Content-Type": "application/json", ...(init.headers || {}) },
    signal: AbortSignal.timeout(20000),
  });
  const body = await response.json().catch(() => null);
  return { status: response.status, body };
}

let project: { code: string; secret: string } | null = null;
async function projectCredentials() {
  const code = Deno.env.get("NOQOODY_PROJECT_CODE");
  const secret = Deno.env.get("NOQOODY_CLIENT_SECRET");
  if (code && secret) return { code, secret };
  if (project) return project;
  const { status, body } = await noqoody("/api/v2/account/projects");
  const active = (body?.data?.UserProjects || []).find((p: any) => p.IsActive && p.ProjectCode && p.ClientSecret);
  if (status !== 200 || !active) throw new Error(`Could not read the Noqoody project (HTTP ${status})`);
  project = { code: active.ProjectCode, secret: active.ClientSecret };
  return project;
}

// Amount with 2 decimals, truncated (10.999 -> "10.99"), using string maths.
function amountString(value: number | string): string {
  const [whole, frac = ""] = Number(value).toFixed(6).split(".");
  return `${whole}.${(frac + "00").slice(0, 2)}`;
}

async function secureHash(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message)));
  return btoa(String.fromCharCode(...signature));
}

// Asks Noqoody about every payment attempt of the order; marks it paid on success.
async function checkOrder(order: Order): Promise<"paid" | "failed" | "pending" | "none"> {
  if (order.payment_status === "paid") return "paid";
  let seen: "failed" | "none" = "none";
  for (const ref of [...(order.online_payment_refs || [])].reverse()) {
    const { status, body } = await noqoody(`/api/v2/transactions/${encodeURIComponent(ref)}`);
    if (status === 200 && body?.success === true) {
      await updateOrder(order.id, { payment_status: "paid", online_paid_at: new Date().toISOString() });
      return "paid";
    }
    if (status === 200) seen = "failed";
    else if (status !== 404) throw new Error(`Noqoody status check failed (HTTP ${status})`);
  }
  return seen === "failed" ? "failed" : order.online_payment_refs?.length ? "pending" : "none";
}

async function startPayment(order: Order): Promise<string> {
  const { code, secret } = await projectCredentials();
  // A new reference for every attempt, saved before the link is created.
  const reference = `${order.order_number}-${Date.now().toString(36).toUpperCase()}`;
  await updateOrder(order.id, { online_payment_refs: [...(order.online_payment_refs || []), reference] });

  const fields = {
    CustomerEmail: order.customer_email || "info@qavera.qa",
    CustomerName: (order.customer_name || "QAVERA customer").trim(),
    CustomerMobile: String(order.customer_phone || "").replace(/\D/g, ""),
    Description: `QAVERA order ${order.order_number}`,
    ProjectCode: code,
    Reference: reference,
    Amount: amountString(order.total),
  };
  const hash = await secureHash(secret,
    fields.CustomerEmail + fields.CustomerName + fields.CustomerMobile + fields.Description +
    fields.ProjectCode + fields.Reference + fields.Amount);

  const { status, body } = await noqoody("/api/v2/payment-links", {
    method: "POST",
    body: JSON.stringify({
      ...fields,
      Amount: Number(fields.Amount),
      SecureHash: hash,
      RedirectURL: `${SITE_URL}/payment-result?order=${order.id}`,
    }),
  });
  const url = body?.data?.PaymentUrl;
  if ((status !== 201 && status !== 200 && status !== 409) || !url) {
    console.error("Noqoody payment link failed", status, JSON.stringify(body?.errors || body?.message || ""));
    throw new Error(`The payment page could not be opened (HTTP ${status})`);
  }
  return url;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const { action, order_id } = await req.json().catch(() => ({}));
    const configured = !!apiKey();

    if (action === "config") {
      // A test key only shows the card option to admins, so customers can't
      // "pay" with test cards on the live site.
      if (!configured) return json({ enabled: false });
      if (!isTestKey()) return json({ enabled: true, test: false });
      const user = await currentUser(req);
      return json({ enabled: !!user?.admin, test: true });
    }

    if (!configured) return json({ error: "Card payments are not set up yet." }, 503);
    const order = await loadOrder(order_id);
    if (!order || order.payment_method !== "card_online") return json({ error: "Order not found." }, 404);

    if (action === "check") {
      const result = await checkOrder(order);
      return json({ status: result, order_number: order.order_number, total: Number(order.total) });
    }

    if (action === "start") {
      const user = await currentUser(req);
      if (!user || (user.id !== order.user_id && !user.admin)) {
        return json({ error: "Please sign in to the account that placed this order." }, 401);
      }
      if (isTestKey() && !user.admin) return json({ error: "Card payments are not available yet." }, 403);
      if (order.status === "cancelled") return json({ error: "This order was cancelled." }, 409);
      if (await checkOrder(order) === "paid") return json({ status: "paid" });
      return json({ url: await startPayment(order) });
    }

    return json({ error: "Unknown action" }, 400);
  } catch (error) {
    console.error(error);
    return json({ error: "Something went wrong with the card payment. Please try again or contact us." }, 502);
  }
});

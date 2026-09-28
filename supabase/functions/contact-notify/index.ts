// Emails QAVERA whenever a row is added to public.contact_messages.
// Called by a Supabase Database Webhook (INSERT on contact_messages).
//
// Secrets (Edge Functions → Secrets):
//   RESEND_API_KEY         API key from resend.com
//   CONTACT_TO_EMAIL       where messages are sent (e.g. your Gmail)
//   CONTACT_WEBHOOK_SECRET any long random string; the webhook sends it in the
//                          x-webhook-secret header so nobody else can call this
//   CONTACT_FROM_EMAIL     optional; defaults to Resend's test sender, which can
//                          only deliver to the email you signed up to Resend with

const REASONS: Record<string, string> = {
  general: "General",
  support: "Customer Support",
  corporate: "Corporate & Wholesale",
};

Deno.serve(async (req) => {
  const secret = Deno.env.get("CONTACT_WEBHOOK_SECRET");
  if (!secret || req.headers.get("x-webhook-secret") !== secret) {
    return new Response("Unauthorized", { status: 401 });
  }

  const payload = await req.json().catch(() => null);
  const record = payload?.record;
  if (payload?.type !== "INSERT" || payload?.table !== "contact_messages" || !record) {
    return new Response("Ignored", { status: 200 });
  }

  const reason = REASONS[record.reason] ?? record.reason;
  const text = [
    `New ${reason} message from the QAVERA website`,
    "",
    `Name:    ${record.name}`,
    `Email:   ${record.email}`,
    `Phone:   ${record.phone || "—"}`,
    `Inquiry: ${reason}`,
    `Sent:    ${new Date(record.created_at).toLocaleString("en-GB", { timeZone: "Asia/Qatar" })}`,
    "",
    record.message,
  ].join("\n");

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: Deno.env.get("CONTACT_FROM_EMAIL") || "QAVERA Website <onboarding@resend.dev>",
      to: [Deno.env.get("CONTACT_TO_EMAIL")],
      reply_to: record.email,
      subject: `QAVERA contact: ${reason} — ${record.name}`,
      text,
    }),
  });

  if (!response.ok) {
    const error = await response.text();
    console.error("Resend error:", response.status, error);
    return new Response("Email failed", { status: 502 });
  }

  return new Response("Sent", { status: 200 });
});

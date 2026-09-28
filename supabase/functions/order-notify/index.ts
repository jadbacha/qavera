// Order emails for QAVERA. Called by a Supabase Database Webhook on the
// orders table (events: Insert + Update).
//
//   New order                 -> confirmation to the customer + notice to QAVERA
//   status -> out_for_delivery -> "on its way" email to the customer
//   status -> delivered        -> "delivered" email to the customer (with points earned)
//
// Uses the same secrets as contact-notify:
//   RESEND_API_KEY, CONTACT_TO_EMAIL (QAVERA inbox), CONTACT_WEBHOOK_SECRET
// Optional: ORDERS_FROM_EMAIL (default "QAVERA <orders@qavera.qa>")
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.

type OrderItem = {
  product_name: string;
  variant_name: string;
  quantity: number;
  total_price: number;
  customization: { name: string; quantity: number }[] | null;
};

const SITE_URL = "https://qavera.qa";

const PAYMENT_LABELS: Record<string, string> = {
  cash_on_delivery: "Cash on Delivery",
  card_on_delivery: "Card on Delivery",
};

function escapeHtml(value: unknown): string {
  return String(value ?? "").replace(/[&<>"']/g, (ch) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[ch]!);
}

function qar(value: unknown): string {
  const amount = Number(value || 0);
  return `QAR ${Number.isInteger(amount) ? amount : amount.toFixed(2)}`;
}

function firstName(fullName: string): string {
  return String(fullName || "").trim().split(/\s+/)[0] || "there";
}

async function loadItems(orderId: string): Promise<OrderItem[]> {
  const url = `${Deno.env.get("SUPABASE_URL")}/rest/v1/order_items` +
    `?order_id=eq.${orderId}&select=product_name,variant_name,quantity,total_price,customization&order=created_at`;
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Items are saved in the same transaction as the order; retry once just in case.
  for (let attempt = 0; attempt < 2; attempt++) {
    const response = await fetch(url, { headers: { apikey: key, Authorization: `Bearer ${key}` } });
    if (!response.ok) throw new Error(`Could not load order items: ${await response.text()}`);
    const items = await response.json();
    if (items.length || attempt === 1) return items;
    await new Promise((resolve) => setTimeout(resolve, 1500));
  }
  return [];
}

function itemsText(items: OrderItem[]): string {
  return items.map((item) => {
    const flavors = (item.customization || []).filter((f) => Number(f.quantity) > 0);
    return `- ${item.product_name} (${item.variant_name}) x${item.quantity}  ${qar(item.total_price)}` +
      (flavors.length
        ? "\n    CUSTOMIZED - flavours per box:\n" +
          flavors.map((f) => `      ${f.name}: ${f.quantity}`).join("\n")
        : "");
  }).join("\n");
}

function itemsHtml(items: OrderItem[]): string {
  return items.map((item) => {
    const flavors = (item.customization || [])
      .filter((f) => Number(f.quantity) > 0)
      .map((f) => `${escapeHtml(f.name)} × ${Number(f.quantity)}`)
      .join(", ");
    return `
      <tr>
        <td style="padding:10px 0;border-bottom:1px solid #EBE0C4;">
          ${escapeHtml(item.product_name)} — ${escapeHtml(item.variant_name)} × ${Number(item.quantity)}
          ${flavors ? `<div style="color:#6B5F45;font-size:12px;margin-top:3px;">${flavors}</div>` : ""}
        </td>
        <td style="padding:10px 0;border-bottom:1px solid #EBE0C4;text-align:right;white-space:nowrap;">${qar(item.total_price)}</td>
      </tr>`;
  }).join("");
}

function row(label: string, value: string, strong = false): string {
  return `
    <tr>
      <td style="padding:6px 0;color:#6B5F45;">${label}</td>
      <td style="padding:6px 0;text-align:right;${strong ? "font-weight:600;color:#1A1713;" : ""}">${value}</td>
    </tr>`;
}

// Shared email layout in the site's colours.
function layout(label: string, title: string, bodyHtml: string): string {
  return `<!doctype html>
<html><body style="margin:0;padding:0;background:#F5EDD9;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F5EDD9;padding:32px 12px;">
    <tr><td align="center">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
             style="max-width:560px;background:#FAF5EA;border:1px solid rgba(26,23,19,.12);font-family:Helvetica,Arial,sans-serif;font-size:14px;line-height:1.6;color:#1A1713;">
        <tr><td style="background:#0D0B08;padding:26px 32px;text-align:center;">
          <div style="font-family:Georgia,serif;font-size:26px;letter-spacing:.3em;color:#C9A84C;">QAVERA</div>
        </td></tr>
        <tr><td style="padding:34px 32px 10px;text-align:center;">
          <div style="color:#9A7A2E;font-size:11px;letter-spacing:.25em;text-transform:uppercase;">${label}</div>
          <h1 style="font-family:Georgia,serif;font-weight:400;font-size:28px;margin:10px 0 0;">${title}</h1>
        </td></tr>
        <tr><td style="padding:14px 32px 34px;">${bodyHtml}</td></tr>
        <tr><td style="padding:18px 32px;border-top:1px solid rgba(26,23,19,.12);text-align:center;color:#6B5F45;font-size:12px;">
          Questions? Just reply to this email.<br>
          <a href="${SITE_URL}" style="color:#9A7A2E;text-decoration:none;">qavera.qa</a>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>`;
}

function orderSummaryHtml(order: Record<string, any>, items: OrderItem[]): string {
  return `
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:18px;">
      ${itemsHtml(items)}
    </table>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:12px;">
      ${row("Subtotal", qar(order.subtotal))}
      ${Number(order.points_discount) > 0 ? row(`Points (${Number(order.points_used)})`, `− ${qar(order.points_discount)}`) : ""}
      ${row("Delivery", qar(order.delivery_fee))}
      ${row("Total", qar(order.total), true)}
      ${row("Payment", escapeHtml(PAYMENT_LABELS[order.payment_method] || order.payment_method))}
    </table>
    <div style="margin-top:22px;padding:16px 18px;background:#F5EDD9;">
      <div style="color:#9A7A2E;font-size:11px;letter-spacing:.2em;text-transform:uppercase;margin-bottom:6px;">Delivery address</div>
      <div style="white-space:pre-line;">${escapeHtml(order.delivery_area)}\n${escapeHtml(order.delivery_address)}</div>
      ${order.notes ? `<div style="margin-top:8px;color:#6B5F45;">Notes: ${escapeHtml(order.notes)}</div>` : ""}
    </div>`;
}

async function sendEmail(to: string, subject: string, text: string, html: string | null, replyTo?: string) {
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: Deno.env.get("ORDERS_FROM_EMAIL") || "QAVERA <orders@qavera.qa>",
      to: [to],
      subject,
      text,
      ...(html ? { html } : {}),
      ...(replyTo ? { reply_to: replyTo } : {}),
    }),
  });
  if (!response.ok) {
    throw new Error(`Resend error ${response.status}: ${await response.text()}`);
  }
}

async function handleNewOrder(order: Record<string, any>) {
  const items = await loadItems(order.id);
  const shopInbox = Deno.env.get("CONTACT_TO_EMAIL")!;
  const payment = PAYMENT_LABELS[order.payment_method] || order.payment_method;
  const tasks: Promise<void>[] = [];

  // 1. Notice to QAVERA (plain text, easy to read on a phone).
  const shopText = [
    `New order ${order.order_number}`,
    "",
    `Customer: ${order.customer_name}`,
    `Phone:    ${order.customer_phone}`,
    `Email:    ${order.customer_email || "—"}`,
    "",
    "Items:",
    itemsText(items),
    "",
    `Subtotal: ${qar(order.subtotal)}`,
    Number(order.points_discount) > 0 ? `Points:   -${qar(order.points_discount)} (${order.points_used} points)` : null,
    `Delivery: ${qar(order.delivery_fee)}`,
    `TOTAL:    ${qar(order.total)}`,
    `Payment:  ${payment}`,
    "",
    "Deliver to:",
    order.delivery_area,
    order.delivery_address,
    order.notes ? `\nNotes: ${order.notes}` : null,
    "",
    `Manage orders: ${SITE_URL}/admin.html`,
  ].filter((line) => line !== null).join("\n");

  tasks.push(sendEmail(
    shopInbox,
    `New order ${order.order_number} — ${order.customer_name} — ${qar(order.total)}`,
    shopText,
    null,
    order.customer_email || undefined,
  ));

  // 2. Confirmation to the customer.
  if (order.customer_email) {
    const html = layout(
      "Order received",
      "Thank you for your order",
      `<p style="margin:0;text-align:center;">Hello ${escapeHtml(firstName(order.customer_name))}, we have received your order
        <strong>${escapeHtml(order.order_number)}</strong>. We will contact you shortly to confirm your delivery.</p>
       ${orderSummaryHtml(order, items)}`,
    );
    const text = [
      `Hello ${firstName(order.customer_name)},`,
      "",
      `Thank you for your order ${order.order_number}. We will contact you shortly to confirm your delivery.`,
      "",
      itemsText(items),
      "",
      `Total: ${qar(order.total)} (${payment})`,
      "",
      "Deliver to:",
      order.delivery_area,
      order.delivery_address,
      "",
      "QAVERA",
    ].join("\n");
    tasks.push(sendEmail(order.customer_email, `Your QAVERA order ${order.order_number}`, text, html, shopInbox));
  }

  await Promise.all(tasks);
}

async function handleStatusChange(order: Record<string, any>) {
  if (!order.customer_email) return;
  const shopInbox = Deno.env.get("CONTACT_TO_EMAIL")!;
  const name = firstName(order.customer_name);

  if (order.status === "out_for_delivery") {
    const html = layout(
      "On its way",
      "Your order is on its way",
      `<p style="margin:0;text-align:center;">Hello ${escapeHtml(name)}, your order
        <strong>${escapeHtml(order.order_number)}</strong> is out for delivery and will reach you soon.</p>
       <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:18px;">
         ${row("Total", qar(order.total), true)}
         ${row("Payment", escapeHtml(PAYMENT_LABELS[order.payment_method] || order.payment_method))}
       </table>`,
    );
    const text = `Hello ${name},\n\nYour order ${order.order_number} is out for delivery and will reach you soon.\n\n` +
      `Total: ${qar(order.total)}\n\nQAVERA`;
    await sendEmail(order.customer_email, `Your QAVERA order ${order.order_number} is on its way`, text, html, shopInbox);
  }

  if (order.status === "delivered") {
    const points = Number(order.points_earned || 0);
    const pointsLine = points > 0
      ? `You earned <strong>${points} QAVERA points</strong> with this order.`
      : "";
    const html = layout(
      "Delivered",
      "Enjoy your QAVERA",
      `<p style="margin:0;text-align:center;">Hello ${escapeHtml(name)}, your order
        <strong>${escapeHtml(order.order_number)}</strong> has been delivered. Thank you for choosing QAVERA.</p>
       ${pointsLine ? `<p style="margin:16px 0 0;text-align:center;">${pointsLine}<br>
         <a href="${SITE_URL}/account.html" style="color:#9A7A2E;">See your points</a></p>` : ""}`,
    );
    const text = `Hello ${name},\n\nYour order ${order.order_number} has been delivered. Thank you for choosing QAVERA.\n` +
      (points > 0 ? `\nYou earned ${points} QAVERA points with this order.\n` : "") + "\nQAVERA";
    await sendEmail(order.customer_email, `Your QAVERA order ${order.order_number} has been delivered`, text, html, shopInbox);
  }
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("CONTACT_WEBHOOK_SECRET");
  if (!secret || req.headers.get("x-webhook-secret") !== secret) {
    return new Response("Unauthorized", { status: 401 });
  }

  const payload = await req.json().catch(() => null);
  if (payload?.table !== "orders" || !payload?.record) {
    return new Response("Ignored", { status: 200 });
  }

  try {
    if (payload.type === "INSERT") {
      await handleNewOrder(payload.record);
    } else if (payload.type === "UPDATE" && payload.old_record?.status !== payload.record.status) {
      await handleStatusChange(payload.record);
    }
  } catch (error) {
    console.error(error);
    return new Response("Email failed", { status: 502 });
  }

  return new Response("OK", { status: 200 });
});

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const allowedOrigin = Deno.env.get("STORE_ORIGIN") ?? "";
const corsHeaders = {
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Origin": allowedOrigin,
  "Vary": "Origin",
};

function jsonResponse(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function normalizeEgyptianMobile(value: unknown): string | null {
  let digits = String(value ?? "").replace(/\D/g, "");
  if (digits.startsWith("0020")) digits = digits.slice(2);
  if (digits.startsWith("0")) digits = `20${digits.slice(1)}`;
  if (digits.length === 10 && digits.startsWith("1")) digits = `20${digits}`;
  return /^201[0125]\d{8}$/.test(digits) ? digits : null;
}

Deno.serve(async (request) => {
  const origin = request.headers.get("origin") ?? "";
  if (request.method === "OPTIONS") {
    return origin === allowedOrigin && allowedOrigin
      ? new Response("ok", { headers: corsHeaders })
      : new Response("forbidden", { status: 403 });
  }

  if (request.method !== "POST") {
    return jsonResponse(405, { error: "Method not allowed" });
  }

  if (!allowedOrigin || origin !== allowedOrigin) {
    return jsonResponse(403, { error: "Origin is not allowed" });
  }

  let body: { order_number?: unknown };
  try {
    body = await request.json();
  } catch {
    return jsonResponse(400, { error: "Invalid JSON" });
  }

  const orderNumber = String(body.order_number ?? "").trim();
  if (!/^BKH-\d{10,}-[A-Z0-9]{5}$/.test(orderNumber)) {
    return jsonResponse(400, { error: "Invalid order reference" });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const webhookUrlValue = Deno.env.get("N8N_WEBHOOK_URL");
  const webhookToken = Deno.env.get("N8N_WEBHOOK_TOKEN");
  if (!supabaseUrl || !serviceRoleKey || !webhookUrlValue || !webhookToken) {
    return jsonResponse(503, { error: "Notification service is not configured" });
  }

  let webhookUrl: URL;
  try {
    webhookUrl = new URL(webhookUrlValue);
  } catch {
    return jsonResponse(503, { error: "Notification service URL is invalid" });
  }
  if (webhookUrl.protocol !== "https:" || !webhookUrl.pathname.endsWith("/webhook/bakhoor-order")) {
    return jsonResponse(503, { error: "Notification service URL is not allowed" });
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select("order_number, customer_name, customer_phone, items, total_amount, created_at")
    .eq("order_number", orderNumber)
    .maybeSingle();

  if (orderError) {
    console.error("Order lookup failed:", orderError.message);
    return jsonResponse(503, { error: "Unable to verify the order" });
  }
  if (!order) {
    return jsonResponse(404, { error: "Order not found" });
  }

  const createdAt = Date.parse(order.created_at);
  if (!Number.isFinite(createdAt) || Date.now() - createdAt > 15 * 60 * 1000 || createdAt > Date.now() + 60_000) {
    return jsonResponse(403, { error: "Order is outside the notification window" });
  }

  const name = String(order.customer_name ?? "").trim();
  const phone = normalizeEgyptianMobile(order.customer_phone);
  const total = Number(order.total_amount);
  if (
    !name ||
    name.length > 100 ||
    !phone ||
    !Array.isArray(order.items) ||
    order.items.length === 0 ||
    order.items.length > 50 ||
    !Number.isFinite(total) ||
    total <= 0
  ) {
    return jsonResponse(422, { error: "Order data is invalid" });
  }

  const { data: claimed, error: claimError } = await supabase.rpc(
    "claim_whatsapp_notification",
    { p_order_number: orderNumber, p_phone: phone },
  );
  if (claimError) {
    console.error("Notification claim failed:", claimError.message);
    return jsonResponse(503, { error: "Unable to claim notification" });
  }
  if (claimed !== true) {
    return jsonResponse(409, { error: "Duplicate or rate-limited notification" });
  }

  try {
    const response = await fetch(webhookUrl, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${webhookToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        order_number: orderNumber,
        customer_name: name,
        customer_phone: phone,
        items: order.items,
        total_amount: total,
        created_at: order.created_at,
      }),
      signal: AbortSignal.timeout(45_000),
    });

    if (!response.ok) {
      const { error: updateError } = await supabase
        .from("whatsapp_notification_dispatches")
        .update({ status: "failed" })
        .eq("order_number", orderNumber);
      if (updateError) console.error("Failed to record notification failure:", updateError.message);
      console.error("n8n rejected notification:", response.status);
      return jsonResponse(502, { error: "Notification delivery failed" });
    }

    const { error: updateError } = await supabase
      .from("whatsapp_notification_dispatches")
      .update({ status: "sent" })
      .eq("order_number", orderNumber);
    if (updateError) {
      console.error("Failed to record notification success:", updateError.message);
      return jsonResponse(503, { error: "Unable to record notification status" });
    }

    return jsonResponse(202, { accepted: true });
  } catch (error) {
    const { error: updateError } = await supabase
      .from("whatsapp_notification_dispatches")
      .update({ status: "failed" })
      .eq("order_number", orderNumber);
    if (updateError) console.error("Failed to record notification failure:", updateError.message);
    console.error("n8n request failed:", error instanceof Error ? error.message : "unknown error");
    return jsonResponse(502, { error: "Notification delivery failed" });
  }
});

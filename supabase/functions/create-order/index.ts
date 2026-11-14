import { createClient } from 'npm:@supabase/supabase-js@2';
import { normalizeEgyptianMobile } from '../_shared/phone.ts';
import { sendUltramsg } from '../_shared/ultramsg.ts';

const ADMIN_WHATSAPP_NUMBER = '201278771472';
const ORDER_FIELDS = 'id, client_request_id, created_at, customer_name, customer_phone, customer_address, order_details, order_items, total_amount, total_items_count';

function json(data: unknown, status = 200, headers: HeadersInit = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', ...headers },
  });
}

function corsHeaders(origin: string | null): HeadersInit {
  const allowed = (Deno.env.get('CORS_ALLOWED_ORIGINS') ?? '')
    .split(',').map((value) => value.trim()).filter(Boolean);
  if (!origin || !allowed.includes(origin)) return {};
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  };
}

function validText(value: unknown, maxLength: number): value is string {
  return typeof value === 'string' && value.trim().length > 0 && value.trim().length <= maxLength;
}

Deno.serve(async (request) => {
  const origin = request.headers.get('origin');
  const cors = corsHeaders(origin);
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405, cors);
  if (origin && !('Access-Control-Allow-Origin' in cors)) return json({ error: 'Origin not allowed' }, 403);

  let input: Record<string, unknown>;
  try {
    input = await request.json();
  } catch {
    return json({ error: 'Invalid JSON' }, 400, cors);
  }

  const requestId = String(input.client_request_id ?? '');
  const name = typeof input.customer_name === 'string' ? input.customer_name.trim() : '';
  const address = typeof input.customer_address === 'string' ? input.customer_address.trim() : '';
  const phone = normalizeEgyptianMobile(input.customer_phone);
  const items = input.items;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(requestId) ||
      !validText(name, 200) || !validText(address, 1000) || !phone ||
      !Array.isArray(items) || items.length < 1 || items.length > 30) {
    return json({ error: 'Invalid order data' }, 400, cors);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceKey) {
    return json({ error: 'Order service is not configured' }, 503, cors);
  }
  const db = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });

  // A browser retry reuses the same request UUID, so it resolves to the original order.
  let { data: order, error: lookupError } = await db.from('orders').select(ORDER_FIELDS)
    .eq('client_request_id', requestId).maybeSingle();
  if (lookupError) return json({ error: 'Could not check duplicate order' }, 500, cors);

  let duplicateOrder = Boolean(order);
  let productsPayload: Array<Record<string, unknown>> = [];
  if (!order) {
    const normalizedItems: Array<{ product_id: string; quantity: number; variant: string }> = [];
    const seen = new Set<string>();
    for (const item of items) {
      const productId = item && (typeof item.product_id === 'string' || typeof item.product_id === 'number')
        ? String(item.product_id).trim() : '';
      if (!productId || productId.length > 128 || seen.has(productId) ||
          !Number.isInteger(item.quantity) || item.quantity < 1 || item.quantity > 99 ||
          !validText(item.variant, 120)) {
        return json({ error: 'Invalid order item' }, 400, cors);
      }
      seen.add(productId);
      normalizedItems.push({ product_id: productId, quantity: item.quantity, variant: item.variant.trim() });
    }

    const { data: catalog, error: catalogError } = await db.from('products')
      .select('id, title, price, stock_quantity, variants').in('id', [...seen]);
    if (catalogError || !catalog || catalog.length !== normalizedItems.length) {
      return json({ error: 'One or more products are unavailable' }, 422, cors);
    }

    let total = 0;
    let totalItems = 0;
    const detailLines: string[] = [];
    for (const item of normalizedItems) {
      const product = catalog.find((candidate) => String(candidate.id) === item.product_id);
      if (!product) return json({ error: 'Product not found' }, 422, cors);
      const price = Number(product.price);
      if (!Number.isFinite(price) || price < 0) return json({ error: 'Product price is invalid' }, 422, cors);
      if (Array.isArray(product.variants) && product.variants.length > 0 &&
          !product.variants.some((variant: { name?: string } | string) =>
            (typeof variant === 'string' ? variant : variant?.name) === item.variant)) {
        return json({ error: 'Product variant is unavailable' }, 422, cors);
      }
      const stock = Number(product.stock_quantity);
      if (Number.isFinite(stock) && stock >= 0 && stock < item.quantity) {
        return json({ error: 'Requested quantity is unavailable' }, 422, cors);
      }
      const subtotal = price * item.quantity;
      total += subtotal;
      totalItems += item.quantity;
      const title = String(product.title ?? 'منتج').slice(0, 200);
      detailLines.push(`- ${title} (${item.variant}) | الكمية: ${item.quantity} | سعر الوحدة: ${price} ج.م | الإجمالي: ${subtotal} ج.م`);
      productsPayload.push({
        productId: product.id,
        name: title,
        variant: item.variant,
        quantity: item.quantity,
        unitPrice: price,
        subtotal,
      });
    }
    const details = detailLines.join('\n');
    const { data: inserted, error: insertError } = await db.from('orders').insert({
      client_request_id: requestId,
      customer_name: name,
      customer_phone: phone,
      customer_address: address,
      total_amount: total,
      order_details: details,
      order_items: productsPayload,
      total_items_count: totalItems,
    }).select(ORDER_FIELDS).single();

    if (insertError?.code === '23505') {
      const duplicate = await db.from('orders').select(ORDER_FIELDS)
        .eq('client_request_id', requestId).maybeSingle();
      if (duplicate.error || !duplicate.data) return json({ error: 'Could not resolve duplicate order' }, 500, cors);
      order = duplicate.data;
      duplicateOrder = true;
    } else if (insertError || !inserted) {
      return json({ error: 'Could not save order' }, 500, cors);
    } else {
      order = inserted;
    }
  }

  if (order && productsPayload.length === 0 && Array.isArray(order.order_items)) {
    productsPayload = order.order_items as Array<Record<string, unknown>>;
  }

  const customerPhone = normalizeEgyptianMobile(order.customer_phone);
  if (!customerPhone) return json({ error: 'Saved order has an invalid Egyptian mobile number' }, 422, cors);
  const orderId = String(order.id);
  const idempotencyKey = `order.created:${orderId}`;
  const details = String(order.order_details ?? '').slice(0, 5000);
  const createdAt = new Date(String(order.created_at ?? Date.now()))
    .toLocaleString('ar-EG', { timeZone: 'Africa/Cairo' });
  const adminMessage = `✨ طلب جديد من متجر بخور الشيخ ✨\n` +
    `رقم الطلب: #${orderId}\n` +
    `التاريخ والوقت: ${createdAt}\n\n` +
    `👤 الاسم: ${String(order.customer_name ?? '').slice(0, 200)}\n` +
    `📱 الهاتف: ${customerPhone}\n` +
    `📍 العنوان: ${String(order.customer_address ?? '').slice(0, 1000)}\n\n` +
    `الطلبات:\n${details}\n` +
    `📦 إجمالي القطع المطلوبة: ${Number(order.total_items_count) || 0}\n` +
    `💰 الإجمالي الكلي: ${Number(order.total_amount) || 0} جنيه مصري`;
  const customerMessage = `أهلاً بك في بخور الشيخ 🌿\n\n` +
    `تم استلام طلبك بنجاح!\nرقم الطلب: ${orderId}\n\n` +
    `نعمل حالياً على مراجعة طلبك وتجهيزه، وسنتواصل معك قريباً لتأكيد التفاصيل.\n\n` +
    `شكراً لثقتك بنا ❤️\nبخور الشيخ`;
  const whatsappDraft = `مرحبًا، أريد تأكيد طلبي من متجر بخور الشيخ 🌿\n\n` +
    `رقم الطلب: #${orderId}\n\n` +
    `الاسم: ${String(order.customer_name ?? '').slice(0, 200)}\n` +
    `رقم الهاتف: ${customerPhone}\n` +
    `العنوان: ${String(order.customer_address ?? '').slice(0, 1000)}\n\n` +
    `المنتجات:\n${details}\n\n` +
    `الإجمالي: ${Number(order.total_amount) || 0} جنيه مصري\n\n` +
    `شكرًا لكم ❤️`;
  const notificationClaims = (['admin', 'customer'] as const).map((notificationType) => ({
    order_id: orderId,
    notification_type: notificationType,
    idempotency_key: `${idempotencyKey}:${notificationType}`,
    whatsapp_notification_status: 'processing',
    attempt_count: 1,
    last_attempt_at: new Date().toISOString(),
  }));
  const { error: claimError } = await db.from('whatsapp_notifications').insert(notificationClaims);
  if (claimError?.code === '23505') {
    const { data: prior } = await db.from('whatsapp_notifications')
      .select('notification_type, whatsapp_notification_status').eq('order_id', orderId);
    const statusByType = Object.fromEntries((prior ?? []).map((row) => [row.notification_type, row.whatsapp_notification_status]));
    return json({
      ok: true,
      order_id: orderId,
      duplicate_order: duplicateOrder,
      duplicate_notification: true,
      idempotency_key: idempotencyKey,
      notification_status: statusByType,
      whatsapp_draft: whatsappDraft,
    }, 200, cors);
  }
  if (claimError) return json({ error: 'Order saved but notification could not be claimed', order_id: orderId }, 500, cors);

  const messages = [
    { type: 'admin', to: ADMIN_WHATSAPP_NUMBER, body: adminMessage, key: `${idempotencyKey}:admin` },
    { type: 'customer', to: customerPhone, body: customerMessage, key: `${idempotencyKey}:customer` },
  ] as const;
  const outcomes = await Promise.all(messages.map(async (message) => {
    const result = await sendUltramsg(message.to, message.body);
    const { error: updateError } = await db.from('whatsapp_notifications').update({
      whatsapp_notification_status: result.status,
      whatsapp_message_id: result.messageId,
      whatsapp_retryable: result.retryable,
      whatsapp_error: result.error,
      updated_at: new Date().toISOString(),
    }).eq('idempotency_key', message.key);
    return { [message.type]: updateError ? 'tracking_update_failed' : result.status };
  }));

  return json({
    ok: true,
    order_id: orderId,
    duplicate_order: duplicateOrder,
    idempotency_key: idempotencyKey,
    notification_status: Object.assign({}, ...outcomes),
    whatsapp_draft: whatsappDraft,
  }, 200, cors);
});

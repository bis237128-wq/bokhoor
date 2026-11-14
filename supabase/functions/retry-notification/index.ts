import { createClient } from 'npm:@supabase/supabase-js@2';
import { normalizeEgyptianMobile } from '../_shared/phone.ts';
import { sendUltramsg } from '../_shared/ultramsg.ts';

const ADMIN_WHATSAPP_NUMBER = '201278771472';
const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), {
  status, headers: { 'Content-Type': 'application/json' },
});

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  const bearer = request.headers.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? '';
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceKey || !bearer) return json({ error: 'Unauthorized' }, 401);

  const db = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
  const { data: authData, error: authError } = await db.auth.getUser(bearer);
  if (authError || authData.user?.app_metadata?.role !== 'admin') return json({ error: 'Forbidden' }, 403);

  let input: Record<string, unknown>;
  try { input = await request.json(); } catch { return json({ error: 'Invalid JSON' }, 400); }
  const key = String(input.idempotency_key ?? '');
  if (!/^order\.created:.{1,128}:(admin|customer)$/.test(key)) return json({ error: 'Invalid idempotency key' }, 400);

  const { data: claimed, error: claimError } = await db.rpc('claim_whatsapp_retry', { p_idempotency_key: key });
  if (claimError) return json({ error: 'Retry could not be claimed' }, 500);
  if (!claimed) return json({ error: 'Notification is not safely retryable' }, 409);

  const { data: notification, error: notificationError } = await db.from('whatsapp_notifications')
    .select('order_id, notification_type').eq('idempotency_key', key).single();
  if (notificationError || !notification) return json({ error: 'Notification not found' }, 404);
  const { data: order, error: orderError } = await db.from('orders')
    .select('id, created_at, customer_name, customer_phone, customer_address, order_details, total_amount, total_items_count')
    .eq('id', notification.order_id).single();
  if (orderError || !order) return json({ error: 'Order not found' }, 404);

  const customerPhone = normalizeEgyptianMobile(order.customer_phone);
  if (!customerPhone) return json({ error: 'Order has invalid customer phone' }, 422);
  const createdAt = new Date(String(order.created_at)).toLocaleString('ar-EG', { timeZone: 'Africa/Cairo' });
  const adminMessage = `✨ طلب جديد من متجر بخور الشيخ ✨\nرقم الطلب: #${order.id}\nالتاريخ والوقت: ${createdAt}\n\n👤 الاسم: ${order.customer_name ?? ''}\n📱 الهاتف: ${customerPhone}\n📍 العنوان: ${order.customer_address ?? ''}\n\nالطلبات:\n${order.order_details ?? ''}\n📦 إجمالي القطع: ${Number(order.total_items_count) || 0}\n💰 الإجمالي: ${Number(order.total_amount) || 0} جنيه مصري`;
  const customerMessage = `أهلاً بك في بخور الشيخ 🌿\n\nتم استلام طلبك بنجاح!\nرقم الطلب: ${order.id}\n\nنعمل حالياً على مراجعة طلبك وتجهيزه، وسنتواصل معك قريباً لتأكيد التفاصيل.\n\nشكراً لثقتك بنا ❤️\nبخور الشيخ`;
  const isAdmin = notification.notification_type === 'admin';
  const result = await sendUltramsg(isAdmin ? ADMIN_WHATSAPP_NUMBER : customerPhone, isAdmin ? adminMessage : customerMessage);
  const { error: updateError } = await db.from('whatsapp_notifications').update({
    whatsapp_notification_status: result.status,
    whatsapp_message_id: result.messageId,
    whatsapp_retryable: result.retryable,
    whatsapp_error: result.error,
    updated_at: new Date().toISOString(),
  }).eq('idempotency_key', key).eq('whatsapp_notification_status', 'processing');
  if (updateError) return json({ error: 'Message attempted; status update failed' }, 500);
  return json({ ok: true, status: result.status, message_id: result.messageId });
});

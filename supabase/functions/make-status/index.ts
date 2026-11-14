import { createClient } from 'npm:@supabase/supabase-js@2';

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } });
}

function constantTimeEqual(a: string, b: string): boolean {
  const encoder = new TextEncoder();
  const left = encoder.encode(a);
  const right = encoder.encode(b);
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i++) diff |= left[i] ^ right[i];
  return diff === 0;
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  const expectedSecret = Deno.env.get('MAKE_CALLBACK_SECRET');
  const suppliedSecret = request.headers.get('x-make-callback-secret') ?? '';
  if (!expectedSecret || !constantTimeEqual(expectedSecret, suppliedSecret)) {
    return json({ error: 'Unauthorized' }, 401);
  }

  let input: Record<string, unknown>;
  try {
    input = await request.json();
  } catch {
    return json({ error: 'Invalid JSON' }, 400);
  }
  const idempotencyKey = String(input.idempotency_key ?? '');
  const notificationType = String(input.notification_type ?? '');
  const status = String(input.status ?? '');
  if (!/^order\.created:.{1,128}:(admin|customer)$/.test(idempotencyKey) ||
      !['admin', 'customer'].includes(notificationType) || !idempotencyKey.endsWith(`:${notificationType}`) ||
      !['accepted', 'sent', 'delivered', 'failed'].includes(status)) {
    return json({ error: 'Invalid status update' }, 400);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceKey) return json({ error: 'Status service is not configured' }, 503);
  const db = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
  const now = new Date().toISOString();
  const update: Record<string, unknown> = {
    whatsapp_notification_status: status,
    whatsapp_retryable: false,
    whatsapp_message_id: String(input.message_id ?? '').slice(0, 200) || null,
    whatsapp_error: status === 'failed' ? String(input.error ?? 'UltraMsg request failed').slice(0, 1000) : null,
    updated_at: now,
  };
  if (status === 'accepted' || status === 'sent' || status === 'delivered') update.whatsapp_sent_at = now;
  if (status === 'delivered') update.whatsapp_delivered_at = now;

  const { data: current, error: readError } = await db.from('whatsapp_notifications')
    .select('whatsapp_notification_status').eq('idempotency_key', idempotencyKey)
    .eq('notification_type', notificationType).maybeSingle();
  if (readError) return json({ error: 'Could not read notification status' }, 500);
  if (!current) return json({ error: 'Notification key not found' }, 404);
  const rank: Record<string, number> = { processing: 0, unknown: 0, failed: 0, webhook_accepted: 1, accepted: 1, sent: 2, delivered: 3 };
  if (status !== 'failed' && (rank[status] ?? 0) <= (rank[current.whatsapp_notification_status] ?? 0)) {
    return json({ ok: true, unchanged: true });
  }

  const { data, error } = await db.from('whatsapp_notifications').update(update)
    .eq('idempotency_key', idempotencyKey).eq('notification_type', notificationType)
    .eq('whatsapp_notification_status', current.whatsapp_notification_status)
    .select('order_id').maybeSingle();
  if (error) return json({ error: 'Could not update notification status' }, 500);
  if (!data) return json({ error: 'Notification key not found' }, 404);
  return json({ ok: true });
});

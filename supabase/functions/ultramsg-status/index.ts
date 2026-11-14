import { createClient } from 'npm:@supabase/supabase-js@2';

const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), {
  status, headers: { 'Content-Type': 'application/json' },
});
function constantTimeEqual(a: string, b: string): boolean {
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i++) diff |= left[i] ^ right[i];
  return diff === 0;
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  const expected = Deno.env.get('ULTRAMSG_CALLBACK_SECRET') ?? '';
  const supplied = new URL(request.url).searchParams.get('key') ?? '';
  if (!expected || !constantTimeEqual(expected, supplied)) return json({ error: 'Unauthorized' }, 401);

  let payload: Record<string, any>;
  try { payload = await request.json(); } catch { return json({ error: 'Invalid JSON' }, 400); }
  const data = payload.data && typeof payload.data === 'object' ? payload.data : payload;
  const messageId = String(data.id ?? data.msgId ?? data.message_id ?? '').slice(0, 200);
  const ack = String(data.ack ?? data.status ?? '').toLowerCase();
  if (!messageId || !['pending', 'server', 'device', 'read', 'played'].includes(ack)) {
    return json({ error: 'Unsupported UltraMsg acknowledgement payload' }, 400);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceKey) return json({ error: 'Status service is not configured' }, 503);
  const db = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
  const { data: row, error } = await db.from('whatsapp_notifications')
    .select('idempotency_key, whatsapp_notification_status').eq('whatsapp_message_id', messageId).maybeSingle();
  if (error) return json({ error: 'Could not locate message status' }, 500);
  if (!row) return json({ error: 'Message ID not found' }, 404);

  const next = ack === 'pending' ? 'accepted' : ack === 'server' ? 'sent' : 'delivered';
  const rank: Record<string, number> = { processing: 0, unknown: 0, failed: 0, accepted: 1, webhook_accepted: 1, sent: 2, delivered: 3 };
  if ((rank[next] ?? 0) <= (rank[row.whatsapp_notification_status] ?? 0)) return json({ ok: true, unchanged: true });
  const update: Record<string, unknown> = {
    whatsapp_notification_status: next,
    whatsapp_retryable: false,
    whatsapp_error: null,
    updated_at: new Date().toISOString(),
  };
  if (next === 'sent' || next === 'delivered') update.whatsapp_sent_at = new Date().toISOString();
  if (next === 'delivered') update.whatsapp_delivered_at = new Date().toISOString();
  const { error: updateError } = await db.from('whatsapp_notifications').update(update)
    .eq('idempotency_key', row.idempotency_key)
    .eq('whatsapp_notification_status', row.whatsapp_notification_status);
  if (updateError) return json({ error: 'Could not update message status' }, 500);
  return json({ ok: true, status: next });
});

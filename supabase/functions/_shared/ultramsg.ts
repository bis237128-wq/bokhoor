export type SendResult = {
  status: 'accepted' | 'failed' | 'unknown';
  messageId: string | null;
  retryable: boolean;
  error: string | null;
};

export async function sendUltramsg(to: string, body: string): Promise<SendResult> {
  const instanceId = Deno.env.get('ULTRAMSG_INSTANCE_ID');
  const token = Deno.env.get('ULTRAMSG_TOKEN');
  if (!instanceId || !token) {
    return { status: 'failed', messageId: null, retryable: true, error: 'UltraMsg is not configured' };
  }
  if (!/^\d{10,15}$/.test(to) || !body.trim() || body.length > 4096) {
    return { status: 'failed', messageId: null, retryable: false, error: 'Invalid recipient or message' };
  }

  try {
    const response = await fetch(`https://api.ultramsg.com/${encodeURIComponent(instanceId)}/messages/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ token, to, body }),
      signal: AbortSignal.timeout(15000),
    });
    const raw = await response.text();
    let parsed: Record<string, unknown> = {};
    try { parsed = JSON.parse(raw); } catch { /* provider may return plain text */ }
    const messageId = String(parsed.id ?? parsed.message_id ?? parsed.msgId ?? '').slice(0, 200) || null;
    if (response.ok) {
      return { status: 'accepted', messageId, retryable: false, error: null };
    }
    // A non-success client response is an explicit rejection. Server errors and
    // timeouts remain ambiguous because UltraMsg may have queued the message.
    if (response.status >= 400 && response.status < 500 && response.status !== 408) {
      return { status: 'failed', messageId, retryable: true, error: `UltraMsg rejected request (HTTP ${response.status})` };
    }
    return { status: 'unknown', messageId, retryable: false, error: `Ambiguous UltraMsg response (HTTP ${response.status})` };
  } catch (error) {
    return {
      status: 'unknown', messageId: null, retryable: false,
      error: error instanceof Error ? `Ambiguous UltraMsg transport result (${error.name})` : 'Ambiguous UltraMsg transport result',
    };
  }
}

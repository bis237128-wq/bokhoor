-- Additive fields and an atomic retry claim for direct server-side UltraMsg sends.
-- Existing order and notification rows are preserved.
alter table public.whatsapp_notifications
  add column if not exists attempt_count integer not null default 0,
  add column if not exists last_attempt_at timestamptz,
  add column if not exists whatsapp_retryable boolean not null default false;

alter table public.whatsapp_notifications
  drop constraint if exists whatsapp_notifications_whatsapp_notification_status_check;
alter table public.whatsapp_notifications
  add constraint whatsapp_notifications_whatsapp_notification_status_check
  check (whatsapp_notification_status in (
    'processing', 'webhook_accepted', 'accepted', 'sent', 'delivered', 'failed', 'unknown'
  ));

create unique index if not exists whatsapp_notifications_message_id_uidx
  on public.whatsapp_notifications (whatsapp_message_id)
  where whatsapp_message_id is not null;

create or replace function public.claim_whatsapp_retry(p_idempotency_key text)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  claimed boolean := false;
begin
  update public.whatsapp_notifications
     set whatsapp_notification_status = 'processing',
         whatsapp_retryable = false,
         attempt_count = attempt_count + 1,
         last_attempt_at = now(),
         updated_at = now(),
         whatsapp_error = null
   where idempotency_key = p_idempotency_key
     and whatsapp_notification_status = 'failed'
     and whatsapp_retryable = true
     and attempt_count < 5;
  claimed := found;
  return claimed;
end;
$$;

revoke all on function public.claim_whatsapp_retry(text) from public, anon, authenticated;
grant execute on function public.claim_whatsapp_retry(text) to service_role;

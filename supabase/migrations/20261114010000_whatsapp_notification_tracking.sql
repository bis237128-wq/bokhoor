-- Additive notification ledger. Existing orders and customer records are untouched.
-- order_id is stored as text because the existing orders.id type is not declared in
-- repository files; the Edge Function verifies the referenced order before use.
alter table public.orders add column if not exists client_request_id uuid;
create unique index if not exists orders_client_request_id_uidx
    on public.orders (client_request_id)
    where client_request_id is not null;

create table if not exists public.whatsapp_notifications (
    order_id text primary key,
    idempotency_key text not null unique,
    whatsapp_notification_status text not null default 'processing'
        check (whatsapp_notification_status in (
            'processing', 'webhook_accepted', 'accepted', 'sent', 'delivered', 'failed'
        )),
    whatsapp_message_id text,
    whatsapp_sent_at timestamptz,
    whatsapp_delivered_at timestamptz,
    whatsapp_error text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists whatsapp_notifications_status_idx
    on public.whatsapp_notifications (whatsapp_notification_status);

alter table public.whatsapp_notifications enable row level security;
revoke all on table public.whatsapp_notifications from public, anon, authenticated;
grant all on table public.whatsapp_notifications to service_role;

comment on table public.whatsapp_notifications is
    'Server-only WhatsApp notification state, deduplicated by order and idempotency key.';

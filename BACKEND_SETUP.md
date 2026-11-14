# Backend and WhatsApp setup status

## Current architecture

The production storefront is static HTML and reads products from the existing Supabase project. Checkout now calls the `create-order` Edge Function. That function validates the Egyptian phone number, catalog items and server-side prices, then inserts the order with a stable `client_request_id`. A unique partial index on that key makes retries resolve to the original order.

The Edge Function does not send WhatsApp. The existing production `trigger_notify_make` trigger on `public.orders` is the only notification sender: each new order insert invokes `notify_make_on_new_order`, which POSTs the inserted order record to the existing Make webhook. The Edge Function must be deployed only after the additive idempotency migration is reviewed and approved. The old trigger is not stopped or filtered.

The storefront no longer opens WhatsApp or changes `stock_quantity`. Inventory is not recorded; the customer is told that the store will confirm availability. Prices and product records are not changed.

## What is verified in production

Read-only inspection of project `zhppvfabbjffmjgsiaza` confirmed 4 product rows and 53 order rows. The products table has no `is_published` column and all four current `stock_quantity` values are zero. The live database has no recorded migrations and no deployed Edge Functions. `trigger_notify_make` is currently attached to `orders` for every insert and calls `notify_make_on_new_order`.

The trigger's Make webhook URL remains embedded in the database function. Rotate that webhook before a future cutover. The Make scenario itself and delivery history were not accessible, so neither the scenario configuration nor message delivery is verified. No order was inserted and no WhatsApp message was sent during this work.

## Local migrations and deployment guard

`20261114010000_whatsapp_notification_tracking.sql` is additive: it adds `client_request_id`, `order_items`, a unique index for request keys, and a private notification ledger. It does not delete or rewrite existing orders. `20261114015000_dual_order_notification_path.sql` now preserves the existing trigger for every new order insert and hardens its function search path/execute grants. Neither migration has been applied.

The Edge Function requires those columns to exist. Apply the migration only after reviewing it against the live schema and verifying a restorable backup. Deploying only the storefront cannot make checkout work while `create-order` is absent; applying the migration and deploying the function are production changes and remain pending approval.

No UltraMsg token or Make webhook URL belongs in frontend files. The direct UltraMsg sender and its retry/status migrations were removed from the active local source so it cannot create a second send path. The Make callback/status flow is not connected, and delivery status tracking is not currently active. Do not claim WhatsApp delivery based on a database trigger or HTTP acceptance alone.

## Rollback

Before cutover, keep the current production deployment and trigger active. For a failed rollout after approval, revert the storefront to a validated version and redeploy the previous Edge Function version; keep additive database columns and rows. Do not drop data, reset the database, or disable the existing trigger as a rollback step.

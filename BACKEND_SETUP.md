# Backend and WhatsApp notification setup

> **Production cutover guard:** Review [SECURITY_REVIEW.md](SECURITY_REVIEW.md) before any migration or deployment. The existing database trigger must continue serving legacy inserts until the replacement Make route is verified. The local bridge and RLS migrations are proposals only. This checkout now contains the RLS migration, so do not run `supabase db push` wholesale before verifying backup restoreability, Make credentials, server-side inventory handling, and notification retry behavior.

## Architecture in this repository

The storefront remains static HTML and uses the existing Supabase project. Checkout calls `create-order`, which validates the request and product prices server-side, inserts the order with a browser retry key, claims separate admin/customer notification rows, and sends through UltraMsg from the Edge Function. The service returns a WhatsApp draft built from the saved order; the browser opens `wa.me/201278771472` only after the save succeeds, and the customer must press Send. The UltraMsg token and Supabase service-role key stay server-side.

The root storefront admin login uses Supabase Auth and requires `app_metadata.role = admin`. There is no fixed owner email or password in the HTML. Do not replace it with a JavaScript password such as `147852`: browser code is public, and a local gate would not grant a valid Supabase admin session or protect database operations. The existing owner account must be identified in Supabase Auth and retain its current password; do not reset it without authorization. Verify RLS for every dashboard operation because a UI role check alone is not database authorization. The nested `bokhoor/index.html` page is a legacy static variant; its demo admin login is disabled.

The migration is additive: it adds nullable `client_request_id` and `order_items` columns plus a unique partial index to `orders`, and creates a private notification ledger with separate admin and customer rows. Existing orders are unchanged. The order ID is stored as text in the ledger because this repository does not declare the type of `orders.id`.

## Supabase setup

The following are preparation instructions only; no migration or function deployment has been applied to production from this checkout.

1. Inspect the live schema and backup restoreability. The expected `orders` and `products` columns must match the queries in `create-order`.
2. Review and apply migrations individually in an isolated project first: `20261114010000_whatsapp_notification_tracking.sql`, then `20261114015000_dual_order_notification_path.sql`, then `20261114030000_direct_ultramsg_retry.sql`. The bridge is required to keep the existing Trigger for legacy inserts while skipping Edge Function inserts. Do not apply the local RLS proposal until browser-side stock updates are moved server-side.
3. Set these secrets in Supabase Function Secrets (Dashboard) or an already-authorized CLI session; never put values in this repository:
   - `ULTRAMSG_INSTANCE_ID`
   - `ULTRAMSG_TOKEN`
   - `ULTRAMSG_CALLBACK_SECRET` (high-entropy value used as the `key` query parameter on the UltraMsg callback URL)
   - `CORS_ALLOWED_ORIGINS`

   Supabase supplies `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` to Edge Functions. The previously exposed Make URL and any exposed UltraMsg token must be rotated before production activation.
4. After staging verification and approved cutover, deploy `create-order`, `retry-notification` (JWT enabled), `ultramsg-status` (callback key required), and `make-status` only if the existing Make route still needs its callback. Do not deploy against production before the migration and recipient routing have been reviewed.
5. Add only the exact storefront origins to `CORS_ALLOWED_ORIGINS`.
6. Retries are separate from order creation. Only explicitly rejected requests marked retryable can be retried, up to five attempts. Timeouts and ambiguous provider responses become `unknown` and must be reconciled against UltraMsg before any resend.

## Make and WhatsApp routes

The existing production Trigger still sends legacy direct inserts to Make. It must remain active until the migration bridge and replacement route have passed staging verification. The Edge Function route in this checkout uses UltraMsg directly; Make was not configured or inspected from the connected tools. Do not activate both send paths for the same order. UltraMsg ACKs are received by `ultramsg-status` and matched using the provider message ID; inspect a real provider sample before relying on the webhook mapping.

The site opens a prepared customer-to-admin WhatsApp draft after the order save succeeds. Opening the draft does not send it; the customer must press Send. The site must not display “confirmed through WhatsApp” based only on opening the link.

## Verification and rollback

Before deployment, run the repository checks and test in staging: invalid phones, malformed requests, nonexistent products/orders, duplicate `client_request_id`, separate recipient outcomes, explicit rejection retry, ambiguous timeout protection, and UltraMsg ACK callbacks. Use an authorized test number only. Verify each ledger status and provider message ID; an API acceptance response is not proof of delivery.

No deployment has been made from this checkout. For a future rollout, keep the additive migration and notification rows during rollback; do not drop or rewrite existing order data. Roll back only to a previously validated storefront artifact that calls a secured server endpoint. Earlier repository revisions contain the client-side Make webhook URL and a fixed admin password, so do not redeploy those revisions as a rollback. If the new checkout fails after release and no secure prior artifact exists, keep the current production deployment in place and ship a corrective frontend/backend release instead of restoring the exposed webhook flow.

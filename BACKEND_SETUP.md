# Backend and WhatsApp notification setup

## Architecture in this repository

The storefront is static HTML and already uses Supabase for products, reviews, analytics, and orders. This change keeps Supabase and adds Edge Functions; it does not add a database or hosting framework. The checkout calls `create-order`, which validates the request, reads product prices and variants from Supabase, inserts an order with a browser retry key, claims one notification row per order, and posts the verified order to Make. The Make URL and Supabase service-role key stay in Supabase's server-side function secrets.

The root storefront admin login now uses Supabase Auth and requires `app_metadata.role = admin`. Configure an existing admin account through a trusted Supabase Admin API path, then inspect and verify RLS policies on all tables the dashboard can modify. Those live policies are not present in this repository, so the UI role check alone is not a substitute for RLS. The nested `bokhoor/index.html` page is a legacy static variant with no Supabase integration; its demo admin login is disabled.

The migration is additive: it adds a nullable `client_request_id` and unique partial index to `orders`, and creates a private notification ledger. Existing orders are unchanged. The order ID is stored as text in the ledger because this repository does not declare the type of `orders.id`.

## Supabase setup

1. Install the Supabase CLI, authenticate, and link this checkout to the existing project with `supabase login` and `supabase link --project-ref <project-ref>`.
2. Confirm the linked project has the `public.orders` and `public.products` columns queried by `create-order`. In particular, verify `orders.id`, the existing customer/order columns, and `products.id`, `title`, `price`, `stock_quantity`, and `variants`. Review the generated migration against the live schema before applying it.
3. Set function secrets without putting values in this repository:

   ```powershell
   supabase secrets set 'MAKE_WEBHOOK_URL=<Make-custom-webhook-url>' 'CORS_ALLOWED_ORIGINS=https://your-store-domain'
   ```

   `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are supplied to deployed Edge Functions by Supabase. Never put the service-role key or Make URL in storefront JavaScript.
   The previous Make URL was present in client code and repository history; rotate the Make custom webhook before setting `MAKE_WEBHOOK_URL`.
4. Apply the additive migration with `supabase db push` after reviewing the migration plan.
5. Deploy the functions:

   ```powershell
   supabase functions deploy create-order
   supabase secrets set 'MAKE_CALLBACK_SECRET=<long-random-secret>'
   supabase functions deploy make-status --no-verify-jwt
   ```

   `make-status` has `verify_jwt = false` because Make cannot use a Supabase user JWT; it requires the separate `x-make-callback-secret` header.
6. Add the storefront origin exactly as served, including scheme and any `www` subdomain, to `CORS_ALLOWED_ORIGINS`. Include a comma-separated list only when multiple known origins are required.

## Make scenario

Keep the existing admin notification module and its route unchanged. The new server event retains `notifications.admin.whatsapp_number` and `notifications.admin.message`, and includes `notifications.customer.whatsapp_number`, `notifications.customer.message`, `order_id`, and `idempotency_key`.

Configure the customer HTTP module as follows:

- Method: `POST`
- URL: `https://api.ultramsg.com/{INSTANCE_ID}/messages/chat`
- Body type: `application/x-www-form-urlencoded`
- `token`: UltraMsg token stored in Make's secured field/connection
- `to`: map `notifications.customer.whatsapp_number`
- `body`: map `notifications.customer.message`
- Capture the HTTP status and response body; map the returned message ID when present. A 2xx response means UltraMsg accepted/queued the request, not that WhatsApp delivered it.

Use a Make Data Store keyed by `idempotency_key` before the customer HTTP module. Enable sequential processing for this scenario, skip an existing key, and record the key before sending. This protects against scenario retries in addition to the Supabase unique notification claim. Do not automatically retry an ambiguous timeout unless the idempotency record is checked first.

After the UltraMsg module, call the Supabase `make-status` function at:

```text
https://<project-ref>.supabase.co/functions/v1/make-status
```

Send JSON fields `idempotency_key`, `status`, `message_id`, and `error`; set status to `accepted` for an UltraMsg 2xx response and `failed` otherwise. Add header `x-make-callback-secret` using the same secret as `MAKE_CALLBACK_SECRET`. If the UltraMsg instance can emit later delivery receipts, configure its status webhook to update the same function with `delivered` or `failed`; until then, the database can report API acceptance but not actual device delivery.

## Verification and rollback

Before deployment, run the repository checks listed in the change report. In a Supabase staging project, test invalid phones, malformed requests, nonexistent products/orders, duplicate `client_request_id`, duplicate Make events, webhook errors, and callback status updates. Use an authorized test WhatsApp number only. Verify `whatsapp_notifications` status and message ID after each test; do not equate Make's success response with delivery.

Rollback the application by redeploying the previous static-site commit. The migration is additive and does not delete or rewrite existing order rows. If rolling back Edge Functions, redeploy the previous function versions or disable the checkout call to `create-order`; retain the migration and notification rows until you confirm no function or Make scenario depends on them. Do not drop the new column/table as part of rollback.

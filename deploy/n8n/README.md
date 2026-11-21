# Always-on n8n deployment

This deployment runs n8n behind Caddy with automatic HTTPS and a persistent PostgreSQL database. The VPS, not the store laptop, runs the services. n8n is not published directly on port 5678; only ports 80 and 443 are exposed.

## 1. Prepare a VPS and DNS

1. For a no-cost trial, Oracle Cloud Always Free A1 Flex is a possible fit: its published allowance is up to 2 OCPUs and 12 GB RAM in the home region. Use an ARM64 Ubuntu image and allocate at least 2 vCPU and 2 GB RAM; the pinned n8n image publishes both amd64 and arm64 variants. The 1 GB E2.1.Micro shape is below this deployment's recommended memory.
2. Always Free is not an uptime guarantee. OCI can reclaim an idle VM when, over seven days, CPU p95 and network utilization are below 20% (and memory utilization is also below 20% for A1). A quiet order-notification workflow may not generate enough activity to avoid this policy. Capacity can also be unavailable in the selected region. Use a paid VPS if uninterrupted production availability is essential, and monitor OCI billing/usage.
3. Create a free DuckDNS subdomain and point its A record to the VPS public IPv4 address. Leave AAAA unset unless IPv6 is configured end to end. Keep the record DNS-only. DuckDNS account credentials/tokens are not part of this deployment and must never be committed.
4. In the OCI network security list or NSG and the VM firewall, allow TCP 22 only from trusted source IPs, TCP 80 and 443 from the internet, and optionally UDP 443 for HTTP/3. Caddy needs public DNS resolution and inbound TCP 80/443 for automatic certificate issuance and renewal.
5. Install Docker Engine and the Docker Compose plugin on the VPS.

## 2. Generate local secrets and deploy

On the Windows project machine, generate three independent 256-bit secrets in a local `.env` file with restricted Windows ACLs:

```sh
.\deploy\n8n\initialize.ps1
```

The script does not display the secret values. `.env` is ignored by Git and must never be committed. Back up the encryption key securely: without it, n8n cannot decrypt stored credentials after a restore.

Provision the VPS, install Docker Engine and Compose, point the domain's DNS A record to it, and verify SSH host keys normally. Then run the deployment script with the server SSH target, public n8n domain, and certificate email:

```sh
.\deploy\n8n\deploy.ps1 -SshTarget user@server -Domain n8n.example.com -LetsEncryptEmail ops@example.com
```

The script sends only the Compose/Caddy/bootstrap files and a temporary, filtered environment file over SSH/SCP. It excludes `N8N_WEBHOOK_TOKEN` from the server file, restricts file permissions, validates the configuration, then pulls and starts the services. It does not install Docker on an unknown server OS or configure its firewall.

Open `https://<N8N_DOMAIN>` and create the n8n owner account. Use a unique password, enable MFA if available, and do not expose the owner credentials. Caddy obtains and renews the HTTPS certificate automatically.

The Compose file pins n8n to the same version as the currently tested local installation. Upgrade deliberately: back up PostgreSQL and the encryption key first, review n8n release notes, then change the image tag and redeploy. Task runners are built in for n8n 2.x; the old `N8N_RUNNERS_ENABLED` toggle is intentionally omitted.

## 3. Import the WhatsApp workflow and recreate credentials

Import `n8n-whatsapp-workflow.json` through the n8n editor, then assign credentials to the nodes. Credential IDs in an exported workflow belong to the source n8n instance; do not assume they resolve to the new instance.

Create these credentials in the cloud n8n instance:

1. **Bakhoor Edge Function Authorization** — Header Auth. Set the header name to `Authorization` and the value to `Bearer <N8N_WEBHOOK_TOKEN>`. Generate a fresh random token and use the same token in Supabase. Do not put it in the workflow JSON.
2. **UltraMsg API Token** — Custom Auth with JSON body field `token` set to the newly rotated UltraMsg API token. Do not put that token in the workflow JSON, this repository, or Supabase.

Select the newly created credentials on their corresponding nodes, save, and activate/publish the workflow. The production webhook path must remain `/webhook/bakhoor-order` (not `/webhook-test/...`).

## 4. Point Supabase to the cloud instance

In the existing Supabase project's Edge Function secrets, set:

- `N8N_WEBHOOK_URL=https://<N8N_DOMAIN>/webhook/bakhoor-order`
- `N8N_WEBHOOK_TOKEN=<the same random token used in the n8n Header Auth credential>`
- `STORE_ORIGIN=https://<the exact public store origin>`

The Edge Function sends `Authorization: Bearer <N8N_WEBHOOK_TOKEN>`, which must exactly match the n8n Header Auth credential. Keep `ULTRAMSG_TOKEN` only in the n8n credential. Supabase's `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` belong only to the Edge Function environment; never copy them to the browser or VPS deployment files.

The generated webhook token is in the local `.env` and is not copied to the VPS by the deploy script. Enter it into the n8n Header Auth credential and Supabase secrets through their trusted interfaces. Do not send it in chat, add it to this repository, or pass it as a command-line argument.

If Supabase CLI is installed and authenticated, secrets can instead be set without printing the token:

```powershell
.\deploy\n8n\configure-supabase.ps1 -ProjectRef <project-ref> -N8nDomain n8n.example.com -StoreOrigin https://store.example.com
```

The script writes only the three required Edge Function secrets through a restricted temporary file, then removes that file. `ProjectRef` is the project's reference ID from Supabase; it is not an access token.

The database migrations and `notify-order` function are maintained separately under `supabase/`. If they are already deployed and unchanged, they do not need to be redeployed for this host migration.

## 5. Stage and publish only deployment files

If Git is installed outside `PATH`, provide its full executable path:

```powershell
.\deploy\n8n\publish.ps1 -GitExePath "C:\Program Files\Git\cmd\git.exe"
```

The publisher verifies the `origin` repository, ignores and excludes the local `.env`, scans only the deployment files for temporary tunnel URLs and obvious secret literals, commits only the explicit deployment file list, and pushes the current branch. It does not include unrelated staged changes.

## 6. Verify the migration

1. In n8n, confirm the workflow is active and its production webhook URL is `https://<N8N_DOMAIN>/webhook/bakhoor-order`.
2. Submit one real, low-risk test order using an authorized test phone. Check that the Edge Function returns successfully, n8n records a successful execution, and UltraMsg delivers the greeting.
3. Stop the local n8n and Cloudflare Tunnel, then shut down the laptop and submit a second authorized test order. Confirm that the cloud n8n execution and WhatsApp delivery still succeed.
4. Back up PostgreSQL and the n8n volume regularly. Do not migrate the local SQLite database wholesale: it can contain customer execution data and is not required to import the workflow.

Execution payload saving is disabled in this deployment to reduce retention of customer names, phone numbers, and order contents. Use status metadata and Supabase's notification dispatch status for routine monitoring.

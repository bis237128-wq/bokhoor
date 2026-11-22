---
title: n8n on Hugging Face Spaces
emoji: 🐳
colorFrom: yellow
colorTo: red
sdk: docker
app_port: 7860
pinned: false
---

# n8n with Supabase PostgreSQL

Create a Docker Space, then add the settings from `huggingface.env.example` under **Settings > Variables and secrets**. Replace every example value with the values from your Space and Supabase project; never commit real credentials or keys.

Add database connection details and public URL settings as **Variables**. Add `DB_POSTGRESDB_PASSWORD` and a newly generated, strong `N8N_ENCRYPTION_KEY` as **Secrets**. Keep the encryption key unchanged and backed up: n8n needs it to decrypt saved credentials after a restart.

Use the Supabase PostgreSQL host, database, user, and port shown in your project's connection details. SSL is enabled in the example. Workflows and credentials are stored in PostgreSQL, not the Space's temporary filesystem.

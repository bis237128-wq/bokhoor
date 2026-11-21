#!/usr/bin/env bash
set -euo pipefail

app_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$app_dir"

if [[ ! -f .env || ! -f compose.yaml || ! -f Caddyfile ]]; then
  echo "Deployment files are incomplete." >&2
  exit 1
fi

chmod 700 "$app_dir"
chmod 600 .env

for key in POSTGRES_PASSWORD N8N_ENCRYPTION_KEY; do
  value="$(sed -n "s/^${key}=//p" .env | head -n 1)"
  if [[ ! "$value" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "A required secret is missing or invalid." >&2
    exit 1
  fi
  unset value
done

for key in N8N_DOMAIN LETSENCRYPT_EMAIL; do
  value="$(sed -n "s/^${key}=//p" .env | head -n 1)"
  if [[ -z "$value" || "$value" == replace-before-deployment ]]; then
    echo "Domain and certificate email must be configured before deployment." >&2
    exit 1
  fi
  unset value
done

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "Docker Engine and the Docker Compose plugin are required on the VPS." >&2
  exit 1
fi

docker compose --env-file .env -f compose.yaml config -q
docker compose --env-file .env -f compose.yaml pull
docker compose --env-file .env -f compose.yaml up -d
docker compose --env-file .env -f compose.yaml ps

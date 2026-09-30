#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || die "Docker is required. Install Docker Engine and the Compose plugin, then rerun this script."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose)."
command -v openssl >/dev/null 2>&1 || die "OpenSSL is required to generate instance secrets."
command -v git >/dev/null 2>&1 || die "Git is required to identify the deployed fork revision."

SOURCE_ROOT="$(cd -- "$ROOT_DIR/../.." && pwd)"
[[ -f "$SOURCE_ROOT/Dockerfile" && -f "$SOURCE_ROOT/package.json" ]] || die "Run this script from deploy/vps inside a Paperclip source checkout."
git -C "$SOURCE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "The Paperclip source must be a Git checkout."
[[ -z "$(git -C "$SOURCE_ROOT" status --porcelain)" ]] || die "Commit or stash source changes before deploying; deployments are recorded by commit."
source_commit="$(git -C "$SOURCE_ROOT" rev-parse HEAD)"

if [[ -e .env ]]; then
  die "deploy/vps/.env already exists. This installer will not overwrite an existing deployment."
fi

read -r -p "Public domain for Paperclip (for example agents.example.com): " domain
[[ "$domain" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] || die "Enter a hostname without a scheme, path, or port."
[[ "$domain" != *..* ]] || die "The hostname cannot contain consecutive dots."

umask 077
mkdir -p data backups
cat >.env <<EOF
PAPERCLIP_DOMAIN=${domain}
PAPERCLIP_SOURCE_COMMIT=${source_commit}
PAPERCLIP_USER_UID=$(id -u)
PAPERCLIP_USER_GID=$(id -g)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
BETTER_AUTH_SECRET=$(openssl rand -hex 32)
PAPERCLIP_TOOL_ACTION_SIGNING_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 .env

printf '\nBuilding Paperclip from source commit %s...\n' "$source_commit"
if ! docker compose -f compose.yaml build --pull paperclip; then
  rm -f .env
  die "Paperclip source build failed. Fix the build issue and rerun this installer."
fi
printf '\nStarting Paperclip, PostgreSQL, and Caddy...\n'
docker compose -f compose.yaml up -d

printf 'Waiting for Paperclip health check...'
for _ in $(seq 1 60); do
  container_id="$(docker compose -f compose.yaml ps -q paperclip)"
  if [[ -n "$container_id" ]]; then
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
    if [[ "$health" == healthy ]]; then
      printf ' ready\n'
      break
    fi
    if [[ "$health" == exited || "$health" == dead ]]; then
      printf '\nPaperclip failed to start. Recent logs:\n' >&2
      docker compose -f compose.yaml logs --tail=80 paperclip >&2 || true
      die "Review the logs above, fix the issue, then run docker compose -f compose.yaml up -d."
    fi
  fi
  sleep 5
done

container_id="$(docker compose -f compose.yaml ps -q paperclip)"
health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
if [[ "$health" != healthy ]]; then
  docker compose -f compose.yaml logs --tail=80 paperclip >&2 || true
  die "Paperclip did not become healthy within five minutes. The services remain available for diagnosis."
fi

printf '\nDeployment started.\n'
printf 'URL: https://%s\n' "$domain"
printf '\nBefore signing in, point the domain DNS A/AAAA record at this VPS and allow inbound TCP ports 80 and 443 (plus UDP 443 for HTTP/3).\n'
printf 'Check startup with: docker compose -f compose.yaml ps\n'
printf 'Follow logs with:   docker compose -f compose.yaml logs -f paperclip caddy\n'
printf 'Keep %s/.env private; it contains database and authentication secrets.\n' "$ROOT_DIR"

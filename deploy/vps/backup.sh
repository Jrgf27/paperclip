#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

[[ -f .env ]] || { printf 'No deployment found. Run ./install.sh first.\n' >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { printf 'Docker is required.\n' >&2; exit 1; }

timestamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
backup_dir="./backups/$timestamp"
mkdir -p "$backup_dir"
chmod 700 ./backups "$backup_dir"

# Stop writes while capturing both PostgreSQL and instance files so the pair is
# a consistent recovery point. Always restart the app, including on failure.
restart_app() {
  docker compose -f compose.yaml start paperclip >/dev/null
}
trap restart_app EXIT
docker compose -f compose.yaml stop paperclip

docker compose -f compose.yaml exec -T db pg_dump -U paperclip -Fc paperclip >"$backup_dir/database.dump"
tar -czf "$backup_dir/instance-data.tar.gz" -C . data
cp .env "$backup_dir/deployment.env"
chmod 600 "$backup_dir/database.dump" "$backup_dir/instance-data.tar.gz" "$backup_dir/deployment.env"

restart_app
trap - EXIT
printf 'Backup created: %s (database, Paperclip instance data, and deployment secrets).\n' "$backup_dir"

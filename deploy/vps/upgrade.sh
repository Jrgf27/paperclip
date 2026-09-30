#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

[[ -f .env ]] || die "No deployment found. Run ./install.sh first."
command -v docker >/dev/null 2>&1 || die "Docker is required."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
command -v git >/dev/null 2>&1 || die "Git is required."

SOURCE_ROOT="$(cd -- "$ROOT_DIR/../.." && pwd)"
[[ -f "$SOURCE_ROOT/Dockerfile" ]] || die "Run this script from deploy/vps inside the deployed Paperclip checkout."
[[ -z "$(git -C "$SOURCE_ROOT" status --porcelain)" ]] || die "Commit or stash source changes before upgrading."
previous_commit="$(sed -n 's/^PAPERCLIP_SOURCE_COMMIT=//p' .env | head -n 1)"
[[ "$previous_commit" =~ ^[0-9a-f]{40}$ ]] || die "The current .env does not contain a full deployed Git commit."
requested_ref="${1:-}"
[[ -n "$requested_ref" ]] || die "Usage: ./upgrade.sh <git-commit-or-ref-from-your-fork>"

backup_file="./backup.sh"
[[ -x "$backup_file" ]] || die "Backup helper is missing. Run ./backup.sh manually before upgrading."
"$backup_file"

git -C "$SOURCE_ROOT" fetch --all --tags
target_commit="$(git -C "$SOURCE_ROOT" rev-parse --verify "${requested_ref}^{commit}" 2>/dev/null || true)"
[[ "$target_commit" =~ ^[0-9a-f]{40}$ ]] || die "Could not resolve '$requested_ref' to a commit in this checkout."
[[ "$target_commit" != "$previous_commit" ]] || { printf 'Paperclip is already deployed from %s\n' "$target_commit"; exit 0; }

git -C "$SOURCE_ROOT" checkout --detach "$target_commit"
if ! PAPERCLIP_SOURCE_COMMIT="$target_commit" docker compose -f compose.yaml build --pull paperclip; then
  git -C "$SOURCE_ROOT" checkout --detach "$previous_commit"
  die "Build failed; the source checkout was returned to the previously deployed commit."
fi

temporary_env="$(mktemp .env.upgrade.XXXXXX)"
trap 'rm -f "$temporary_env"' EXIT
sed -E "s|^PAPERCLIP_SOURCE_COMMIT=.*$|PAPERCLIP_SOURCE_COMMIT=${target_commit}|" .env >"$temporary_env"
chmod 600 "$temporary_env"
mv "$temporary_env" .env
trap - EXIT

docker compose -f compose.yaml up -d --remove-orphans

container_id="$(docker compose -f compose.yaml ps -q paperclip)"
healthy=false
for _ in $(seq 1 60); do
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
  if [[ "$health" == healthy ]]; then healthy=true; break; fi
  if [[ "$health" == exited || "$health" == dead ]]; then break; fi
  sleep 5
done

if [[ "$healthy" != true ]]; then
  docker compose -f compose.yaml logs --tail=80 paperclip >&2 || true
  die "The new Paperclip source did not become healthy. The backup is available in deploy/vps/backups/. Do not downgrade across a database migration without following the restore procedure."
fi

printf 'Updated Paperclip to source commit %s and confirmed it is healthy.\n' "$target_commit"

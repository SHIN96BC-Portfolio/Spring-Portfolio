#!/usr/bin/env bash
# 볼륨 삭제 후 재기동 → V1__init.sql / V1__init_mongodb.js 가 다시 적용됩니다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMPOSE=(docker compose)

echo "WARNING: 모든 로컬 DB 볼륨을 삭제합니다."
read -r -p "Continue? [y/N] " ans
if [[ "${ans:-}" != "y" && "${ans:-}" != "Y" ]]; then
  echo "Cancelled."
  exit 0
fi

(cd "$ROOT/msa-platform/docker" && "${COMPOSE[@]}" down -v)
(cd "$ROOT/msa-auth/docker" && "${COMPOSE[@]}" down -v)

echo "Volumes removed. Starting fresh..."
exec "$ROOT/scripts/unix/up.sh"

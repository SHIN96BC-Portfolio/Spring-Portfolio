#!/usr/bin/env bash
# DB 컨테이너 중지 (볼륨 유지)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMPOSE=(docker compose)

echo "==> Stopping msa-platform DBs"
(cd "$ROOT/msa-platform/docker" && "${COMPOSE[@]}" down)

echo "==> Stopping msa-auth postgres"
(cd "$ROOT/msa-auth/docker" && "${COMPOSE[@]}" down)

echo "==> Stopping msa-infra"
(cd "$ROOT/msa-infra/docker" && "${COMPOSE[@]}" down)

echo "Done."

#!/usr/bin/env bash
# DB 컨테이너 일괄 기동 (Kafka + PostgreSQL × 10 + MongoDB × 1)
# V1 스키마는 각 DB 볼륨 "최초 생성" 시 docker-entrypoint-initdb.d 로 자동 적용됩니다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMPOSE=(docker compose)

wait_pg() {
  local container="$1" user="$2" db="$3"
  local i
  for i in $(seq 1 60); do
    if docker exec "$container" pg_isready -U "$user" -d "$db" -q 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "timeout waiting for $container" >&2
  return 1
}

echo "==> 1/3 msa-infra (Kafka, Redis, msa-network)"
if ! (cd "$ROOT/msa-infra/docker" && "${COMPOSE[@]}" up -d); then
  echo "WARN: msa-infra start failed (Kafka image/port 등). DB만 계속합니다."
  docker network create msa-network 2>/dev/null || true
fi

echo "==> 2/3 msa-auth postgres-auth"
if ! (cd "$ROOT/msa-auth/docker" && "${COMPOSE[@]}" up -d); then
  echo "WARN: msa-postgres-auth failed (5432 포트 충돌?). 나머지 DB는 계속합니다." >&2
else
  wait_pg msa-postgres-auth auth authdb
fi

echo "==> 3/3 msa-platform (PostgreSQL × 9, MongoDB)"
(cd "$ROOT/msa-platform/docker" && "${COMPOSE[@]}" up -d)

for spec in \
  "msa-postgres-user:userapp:userdb" \
  "msa-postgres-commerce:commerce:commercedb" \
  "msa-postgres-point:pointapp:pointdb" \
  "msa-postgres-fashion:fashion:fashiondb" \
  "msa-postgres-social:social:socialdb" \
  "msa-postgres-recommendation:recommendation:recommendationdb" \
  "msa-postgres-notification:notification:notificationdb" \
  "msa-postgres-media:media:mediadb" \
  "msa-postgres-content:content:contentdb"
do
  IFS=: read -r c u d <<<"$spec"
  wait_pg "$c" "$u" "$d"
done

echo ""
echo "Done. Containers:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' \
  | grep -E 'NAMES|msa-postgres|msa-mongodb|msa-kafka|msa-redis' || true

echo ""
echo "Schema check (userdb):"
count="$(docker exec msa-postgres-user psql -U userapp -d userdb -tAc \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';")"
echo "  public tables: ${count}"

echo ""
echo "Tip: V1 변경 후 재적용 → ./db reset"

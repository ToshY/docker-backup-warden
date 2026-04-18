#!/usr/bin/env bash
# Multi-tier retention smoke test: seed a mix of daily/weekly/monthly/yearly-
# eligible backups, apply --daily=4 --weekly=7 --monthly=4 --yearly=always,
# assert the exact set of surviving keys.
set -euo pipefail
BUCKET="multi-bucket"
PREFIX="db/prod"
# 20 seeded dates; see EXPECTED below for which backup-warden keeps and why.
DATES=(
  2022-01-15 2023-01-15 2024-01-15 2025-01-15                # yearly anchors
  2025-06-15 2025-09-15 2025-12-15                           # stale 2025 months (deleted)
  2026-01-15 2026-02-15 2026-03-15                           # recent monthlies
  2026-03-08 2026-03-22 2026-03-29 2026-04-05 2026-04-12     # weekly candidates
  2026-04-10 2026-04-14 2026-04-15 2026-04-16 2026-04-17     # daily candidates
)
# Expected survivors: 4 yearly + 4 monthly (1 overlaps yearly) + 7 weekly
# (2 overlap monthly) + 4 daily (1 overlaps weekly) = 16 distinct keys.
EXPECTED_SURVIVORS=(
  2022-01-15 2023-01-15 2024-01-15 2025-01-15
  2026-01-15 2026-02-15
  2026-03-08 2026-03-15 2026-03-22 2026-03-29 2026-04-05 2026-04-10 2026-04-14
  2026-04-15 2026-04-16 2026-04-17
)
mc_cmd() {
  docker compose run --rm --entrypoint /bin/sh mc -c "$1"
}
cleanup() { docker compose down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT
echo "==> starting rustfs"
docker compose up -d rustfs >/dev/null
echo "==> creating bucket + seeding ${#DATES[@]} dated backups under $PREFIX/"
# Batch bucket create + all seeds into one `mc` container to avoid paying
# docker-run overhead per key. `set -eu` inside keeps the first failure fatal.
seed_script="set -eu
mc mb --ignore-existing rustfs/$BUCKET
"
for d in "${DATES[@]}"; do
  seed_script+="echo -n x | mc pipe rustfs/$BUCKET/$PREFIX/$d.sql
"
done
mc_cmd "$seed_script"
echo "==> running backup-warden (multi-tier retention)"
docker compose run --rm backup-warden \
  -s s3 \
  -b "$BUCKET" \
  -p "${PREFIX%%/*}/" \
  -t '(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})' \
  --hourly=0 \
  --daily=4 \
  --weekly=7 \
  --monthly=4 \
  --yearly=always \
  --no-recency-check \
  --delete
echo "==> comparing survivors to expected set"
ACTUAL=$(mc_cmd "mc ls --recursive rustfs/$BUCKET" \
  | awk '{print $NF}' \
  | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}\.sql$' \
  | sed 's/\.sql$//' \
  | sort -u)
EXPECTED=$(printf '%s\n' "${EXPECTED_SURVIVORS[@]}" | sort -u)
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "FAIL: survivor set mismatch"
  diff <(echo "$EXPECTED") <(echo "$ACTUAL") || true
  exit 1
fi
echo "PASS: ${#EXPECTED_SURVIVORS[@]} expected survivors, all present"

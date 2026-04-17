#!/usr/bin/env bash
# Smoke test: seed 8 dated backups in rustfs, run backup-warden with
# --daily=3 --delete, assert exactly 3 remain.
set -euo pipefail
BUCKET="test-bucket"
PREFIX="db/prod"
EXPECTED=3
DATES=(2026-04-10 2026-04-11 2026-04-12 2026-04-13 2026-04-14 2026-04-15 2026-04-16 2026-04-17)
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
seed_script+="mc ls --recursive rustfs/$BUCKET | wc -l
"
mc_cmd "$seed_script"
echo "==> running backup-warden (--daily=$EXPECTED --delete)"
docker compose run --rm backup-warden \
  -s s3 \
  -b "$BUCKET" \
  -p "${PREFIX%%/*}/" \
  -t '(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})' \
  --hourly=0 --weekly=0 --monthly=0 --yearly=0 \
  --daily="$EXPECTED" \
  --no-recency-check \
  --delete
echo "==> counting remaining objects"
COUNT=$(mc_cmd "mc ls --recursive rustfs/$BUCKET | wc -l" | tr -d '[:space:]')
echo "remaining: $COUNT (expected: $EXPECTED)"
if [ "$COUNT" -ne "$EXPECTED" ]; then
  echo "FAIL: rotation kept $COUNT objects, expected exactly $EXPECTED"
  mc_cmd "mc ls --recursive rustfs/$BUCKET"
  exit 1
fi
echo "PASS: rotation kept exactly $EXPECTED most-recent backups"

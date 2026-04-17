#!/usr/bin/env bash
# Dense multi-tier retention smoke test (S3 backend, rustfs).
#
# Mirrors tests/test_rotation_local_multi_tier_dense.sh against rustfs+mc:
# same DATES, same retention flags, same EXPECTED_SURVIVORS — retention
# logic is backend-agnostic, so both paths produce identical survivor sets.
# See the local variant for design rationale (multiple seeds per slot,
# hour-precision timestamps, --hourly exercise).
set -euo pipefail

BUCKET="multi-dense-bucket"
PREFIX="db/prod"

DATES=(
  # Hourly (same day, today=2026-04-17) — 4 hours, --hourly=3 keeps 3
  2026-04-17T06-00-00 2026-04-17T12-00-00 2026-04-17T18-00-00 2026-04-17T22-00-00

  # Daily (multiple entries per day across several days) — --daily=4
  2026-04-14T03-00-00 2026-04-14T15-00-00
  2026-04-15T08-00-00 2026-04-15T20-00-00
  2026-04-16T10-00-00

  # Weekly (multiple entries per ISO week) — --weekly=4
  # 2026-W14 (Mar 30 – Apr 5):
  2026-04-04T10-00-00 2026-04-05T10-00-00
  # 2026-W13 (Mar 23 – Mar 29):
  2026-03-25T10-00-00 2026-03-29T10-00-00

  # Monthly (multiple entries per month) — --monthly=4
  2026-02-05T10-00-00 2026-02-20T10-00-00
  2026-01-10T10-00-00 2026-01-25T10-00-00

  # Yearly (multiple entries per year, several years) — --yearly=always
  2025-03-15T10-00-00 2025-08-20T10-00-00 2025-12-31T10-00-00
  2024-06-15T10-00-00 2024-11-30T10-00-00
  2023-07-04T10-00-00
  2022-02-28T10-00-00
)

# Per-slot tiebreak observed: yearly/monthly/weekly/daily all pick the
# EARLIEST backup in each slot. Hourly tier behaviour: only the 22-00-00
# entry (after the test's wall-clock run-time) lands in 'hourly'; the
# 06-00-00 entry is absorbed by 'daily'.
EXPECTED_SURVIVORS=(
  # yearly (earliest per year, --yearly=always)
  2022-02-28T10-00-00
  2023-07-04T10-00-00
  2024-06-15T10-00-00
  2025-03-15T10-00-00
  # monthly (--monthly=4)
  2026-01-10T10-00-00
  2026-02-05T10-00-00
  # weekly (--weekly=4)
  2026-03-25T10-00-00
  2026-04-04T10-00-00
  # daily (--daily=4)
  2026-04-14T03-00-00
  2026-04-15T08-00-00
  2026-04-16T10-00-00
  2026-04-17T06-00-00
  # hourly (--hourly=3)
  2026-04-17T22-00-00
)

mc_cmd() {
  docker compose run --rm --entrypoint /bin/sh mc -c "$1"
}
cleanup() { docker compose down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> starting rustfs"
docker compose up -d rustfs >/dev/null

echo "==> creating bucket + seeding ${#DATES[@]} dated backups under $PREFIX/"
seed_script="set -eu
mc mb --ignore-existing rustfs/$BUCKET
"
for d in "${DATES[@]}"; do
  seed_script+="echo -n x | mc pipe rustfs/$BUCKET/$PREFIX/$d.sql
"
done
mc_cmd "$seed_script"

echo "==> running backup-warden (dense multi-tier retention, with --hourly)"
docker compose run --rm backup-warden \
  -s s3 \
  -b "$BUCKET" \
  -p "${PREFIX%%/*}/" \
  -t '(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})T(?P<hour>\d{2})-(?P<minute>\d{2})-(?P<second>\d{2})' \
  --hourly=3 \
  --daily=4 \
  --weekly=4 \
  --monthly=4 \
  --yearly=always \
  --no-recency-check \
  --delete

echo "==> comparing survivors to expected set"
ACTUAL=$(mc_cmd "mc ls --recursive rustfs/$BUCKET" \
  | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}' \
  | sort -u)
EXPECTED=$(printf '%s\n' "${EXPECTED_SURVIVORS[@]}" | sort -u)
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "FAIL: survivor set mismatch"
  diff <(echo "$EXPECTED") <(echo "$ACTUAL") || true
  exit 1
fi
echo "PASS: ${#EXPECTED_SURVIVORS[@]} expected survivors, all present"


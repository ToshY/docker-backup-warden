#!/usr/bin/env bash
# Local-filesystem multi-tier smoke test: mirrors tests/test_rotation_s3_multi_tier.sh
# but against a bind-mounted host directory. Seeds 20 dated files covering
# yearly/monthly/weekly/daily tiers, applies --daily=4 --weekly=7 --monthly=4
# --yearly=always, asserts the exact set of 16 surviving filenames.
set -euo pipefail

# 20 seeded dates; same set as the S3 multi-tier test — retention logic is
# backend-agnostic, so the expected survivors are identical. See that file
# for which tier each date falls into.
DATES=(
  2022-01-15 2023-01-15 2024-01-15 2025-01-15                # yearly anchors
  2025-06-15 2025-09-15 2025-12-15                           # stale 2025 months (deleted)
  2026-01-15 2026-02-15 2026-03-15                           # recent monthlies
  2026-03-08 2026-03-22 2026-03-29 2026-04-05 2026-04-12     # weekly candidates
  2026-04-10 2026-04-14 2026-04-15 2026-04-16 2026-04-17     # daily candidates
)
EXPECTED_SURVIVORS=(
  2022-01-15 2023-01-15 2024-01-15 2025-01-15
  2026-01-15 2026-02-15
  2026-03-08 2026-03-15 2026-03-22 2026-03-29 2026-04-05 2026-04-10 2026-04-14
  2026-04-15 2026-04-16 2026-04-17
)

TMPDIR="$(mktemp -d -t backup-warden-local-multi.XXXXXX)"
cleanup() { rm -rf "$TMPDIR" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> preparing $TMPDIR (chmod 777 so uid 65532 in the container can delete)"
chmod 777 "$TMPDIR"

echo "==> seeding ${#DATES[@]} dated files"
for d in "${DATES[@]}"; do
  : > "$TMPDIR/db-$d.sql"
done

echo "==> running backup-warden (multi-tier retention)"
docker compose run --rm --no-deps \
  -v "$TMPDIR:/data" \
  backup-warden \
    -s local \
    -p /data \
    -t '(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})' \
    --hourly=0 \
    --daily=4 \
    --weekly=7 \
    --monthly=4 \
    --yearly=always \
    --no-recency-check \
    --delete

echo "==> comparing survivors to expected set"
ACTUAL=$(find "$TMPDIR" -maxdepth 1 -type f -name '*.sql' \
  | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}' \
  | sort -u)
EXPECTED=$(printf '%s\n' "${EXPECTED_SURVIVORS[@]}" | sort -u)
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "FAIL: survivor set mismatch"
  diff <(echo "$EXPECTED") <(echo "$ACTUAL") || true
  exit 1
fi
echo "PASS: ${#EXPECTED_SURVIVORS[@]} expected survivors, all present"


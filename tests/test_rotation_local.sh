#!/usr/bin/env bash
# Local-filesystem smoke test: seed 5 dated files in a bind-mounted host dir,
# run backup-warden with `-s local --daily=3 --delete`, assert the 3 most-
# recent survive. No rustfs / mc involved — exercises the `-s local` code
# path end-to-end against the prod image.
set -euo pipefail

EXPECTED=3
DATES=(2026-04-10 2026-04-11 2026-04-12 2026-04-13 2026-04-14)
SURVIVORS=(2026-04-12 2026-04-13 2026-04-14)

# mktemp -d honours $TMPDIR; on Linux hosts that's /tmp (world-writable), which
# is what we need to then chmod 777 a subdir into so uid 65532 inside the
# container can unlink files during --delete.
TMPDIR="$(mktemp -d -t backup-warden-local.XXXXXX)"
cleanup() {
  # Files created/modified by uid 65532 in the container still live in a dir
  # owned by the host user; rm -rf from the host removes them cleanly.
  rm -rf "$TMPDIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> preparing $TMPDIR (chmod 777 so uid 65532 in the container can delete)"
chmod 777 "$TMPDIR"

echo "==> seeding ${#DATES[@]} dated files"
for d in "${DATES[@]}"; do
  : > "$TMPDIR/db-$d.sql"
done
ls -1 "$TMPDIR"

echo "==> running backup-warden (-s local --daily=$EXPECTED --delete)"
# --no-deps: skip the rustfs healthcheck wait; this test doesn't need S3.
# The compose service's AWS_* env vars are harmless no-ops in -s local mode.
docker compose run --rm --no-deps \
  -v "$TMPDIR:/data" \
  backup-warden \
    -s local \
    -p /data \
    -t '(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})' \
    --hourly=0 --weekly=0 --monthly=0 --yearly=0 \
    --daily="$EXPECTED" \
    --no-recency-check \
    --delete

echo "==> counting remaining files"
COUNT=$(find "$TMPDIR" -maxdepth 1 -type f -name '*.sql' | wc -l | tr -d '[:space:]')
echo "remaining: $COUNT (expected: $EXPECTED)"
if [ "$COUNT" -ne "$EXPECTED" ]; then
  echo "FAIL: rotation kept $COUNT files, expected exactly $EXPECTED"
  ls -la "$TMPDIR"
  exit 1
fi

echo "==> verifying the 3 most-recent files survived"
for d in "${SURVIVORS[@]}"; do
  if [ ! -f "$TMPDIR/db-$d.sql" ]; then
    echo "FAIL: expected surviving file db-$d.sql is missing"
    ls -la "$TMPDIR"
    exit 1
  fi
done

echo "PASS: local rotation kept exactly the $EXPECTED most-recent files"


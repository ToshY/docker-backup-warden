#!/usr/bin/env bash
# S3 config-mount smoke test: drive retention entirely from a bind-mounted INI
# config file instead of CLI flags. Mirrors the assertions of
# test_rotation_s3.sh (seed 8 daily-dated objects, assert 3 survive) but
# validates that mounting a backup-warden config into the container and
# invoking `--config <path>` works end-to-end against rustfs.
set -euo pipefail

BUCKET="test-bucket"
PREFIX="db/prod"
EXPECTED=3
DATES=(2026-04-10 2026-04-11 2026-04-12 2026-04-13 2026-04-14 2026-04-15 2026-04-16 2026-04-17)

CONF_DIR="$(mktemp -d -t backup-warden-s3-config.XXXXXX)"

mc_cmd() {
  docker compose run --rm --entrypoint /bin/sh mc -c "$1"
}
cleanup() {
  docker compose down -v >/dev/null 2>&1 || true
  rm -rf "$CONF_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> writing INI config to $CONF_DIR/backup-warden.ini"
# mktemp -d creates dirs with 0700; uid 65532 inside the container can't
# traverse it. Open up traversal + read so the bind-mounted /config is usable.
chmod 755 "$CONF_DIR"
# [main] provides source/bucket/path to the app-level args.
# [db/prod] provides the per-path Warden_Config; fnmatch("db/prod/...", "db/prod*")
# hits every seeded key.
cat > "$CONF_DIR/backup-warden.ini" <<INI
[main]
source = s3
bucket = $BUCKET
path = $PREFIX/
no_recency_check = true

[$PREFIX]
timestamp_pattern = (?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})
hourly = 0
daily = $EXPECTED
weekly = 0
monthly = 0
yearly = 0
include_list =
exclude_list =
INI
chmod 644 "$CONF_DIR/backup-warden.ini"
cat "$CONF_DIR/backup-warden.ini"

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
seed_script+="mc ls --recursive rustfs/$BUCKET | wc -l
"
mc_cmd "$seed_script"

echo "==> running backup-warden (--config /config/backup-warden.ini --delete)"
docker compose run --rm \
  -v "$CONF_DIR:/config:ro" \
  backup-warden \
    --config /config/backup-warden.ini \
    --delete

echo "==> counting remaining objects"
COUNT=$(mc_cmd "mc ls --recursive rustfs/$BUCKET | wc -l" | tr -d '[:space:]')
echo "remaining: $COUNT (expected: $EXPECTED)"
if [ "$COUNT" -ne "$EXPECTED" ]; then
  echo "FAIL: config-driven rotation kept $COUNT objects, expected exactly $EXPECTED"
  mc_cmd "mc ls --recursive rustfs/$BUCKET"
  exit 1
fi

echo "PASS: s3 config-mount rotation kept exactly $EXPECTED most-recent backups"




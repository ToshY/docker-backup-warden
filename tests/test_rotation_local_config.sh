#!/usr/bin/env bash
# Local-filesystem config-mount smoke test: drive retention entirely from a
# bind-mounted INI config file instead of CLI flags. Mirrors the assertions of
# test_rotation_local.sh (seed 5 daily-dated files, assert 3 survive) but
# validates that mounting a backup-warden config into the container and
# invoking `--config <path>` works end-to-end.
set -euo pipefail

EXPECTED=3
DATES=(2026-04-10 2026-04-11 2026-04-12 2026-04-13 2026-04-14)
SURVIVORS=(2026-04-12 2026-04-13 2026-04-14)

DATA_DIR="$(mktemp -d -t backup-warden-local-config-data.XXXXXX)"
CONF_DIR="$(mktemp -d -t backup-warden-local-config-conf.XXXXXX)"
cleanup() {
  rm -rf "$DATA_DIR" "$CONF_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> preparing $DATA_DIR (chmod 777 so uid 65532 in the container can delete)"
chmod 777 "$DATA_DIR"

echo "==> seeding ${#DATES[@]} dated files"
for d in "${DATES[@]}"; do
  : > "$DATA_DIR/db-$d.sql"
done
ls -1 "$DATA_DIR"

# mktemp -d creates dirs with 0700; uid 65532 inside the container can't even
# traverse it. Open up traversal + read so the bind-mounted /config is usable.
chmod 755 "$CONF_DIR"

echo "==> writing INI config to $CONF_DIR/backup-warden.ini"
# [main] drives app-level args (source, path). The [/data] section drives the
# Warden_Config for any backup under /data via fnmatch("/data*"), which
# includes our /data/db-*.sql files. timestamp_pattern must carry the named
# capture groups (year/month/day) — same contract as the CLI `-t` flag.
cat > "$CONF_DIR/backup-warden.ini" <<'INI'
[main]
source = local
path = /data
no_recency_check = true

[/data]
timestamp_pattern = (?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})
hourly = 0
daily = 3
weekly = 0
monthly = 0
yearly = 0
include_list =
exclude_list =
INI
chmod 644 "$CONF_DIR/backup-warden.ini"
cat "$CONF_DIR/backup-warden.ini"

echo "==> running backup-warden (--config /config/backup-warden.ini --delete)"
# --no-deps: skip rustfs healthcheck; local mode doesn't need S3.
# Two mounts: data dir at /data, config dir at /config (read-only).
docker compose run --rm --no-deps \
  -v "$DATA_DIR:/data" \
  -v "$CONF_DIR:/config:ro" \
  backup-warden \
    --config /config/backup-warden.ini \
    --delete

echo "==> counting remaining files"
COUNT=$(find "$DATA_DIR" -maxdepth 1 -type f -name '*.sql' | wc -l | tr -d '[:space:]')
echo "remaining: $COUNT (expected: $EXPECTED)"
if [ "$COUNT" -ne "$EXPECTED" ]; then
  echo "FAIL: config-driven rotation kept $COUNT files, expected exactly $EXPECTED"
  ls -la "$DATA_DIR"
  exit 1
fi

echo "==> verifying the 3 most-recent files survived"
for d in "${SURVIVORS[@]}"; do
  if [ ! -f "$DATA_DIR/db-$d.sql" ]; then
    echo "FAIL: expected surviving file db-$d.sql is missing"
    ls -la "$DATA_DIR"
    exit 1
  fi
done

echo "PASS: local config-mount rotation kept exactly the $EXPECTED most-recent files"




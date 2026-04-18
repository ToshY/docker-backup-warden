#!/usr/bin/env bash
# Custom-filename smoke test: verify backup-warden's `-t` regex correctly
# extracts timestamps from non-trivial key names (prefixes, suffixes, embedded
# separators). Two scenarios run back-to-back against a shared rustfs.
#
# Scenario 1: MySQL dump layout — mysql_<db>_mysql_YYYYMMDD-HHMMSS.sql.gz
# Scenario 2: App tarball layout — app-media-backup-YYYY-MM-DDTHH-MM-SS.tar.gz
#
# Both seed 5 consecutive daily backups, apply --daily=3 --delete, and assert
# exactly the 3 most-recent files remain.
set -euo pipefail
mc_cmd() {
  docker compose run --rm --entrypoint /bin/sh mc -c "$1"
}
cleanup() { docker compose down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT
echo "==> starting rustfs"
docker compose up -d rustfs >/dev/null
# ----------------------------------------------------------------------------
# Scenario 1: mysql_my_database_mysql_YYYYMMDD-HHMMSS.sql.gz
# ----------------------------------------------------------------------------
BUCKET1="mysql-bucket"
PREFIX1="db/mysql"
REGEX1='(?P<year>\d{4})(?P<month>\d{2})(?P<day>\d{2})-(?P<hour>\d{2})(?P<minute>\d{2})(?P<second>\d{2})'
DATES1=(20260410-030000 20260411-030000 20260412-030000 20260413-030000 20260414-030000)
EXPECTED1=(20260412-030000 20260413-030000 20260414-030000)
echo "==> [mysql] creating bucket + seeding ${#DATES1[@]} dumps"
# Batch bucket create + all seeds into one `mc` container to avoid paying
# docker-run overhead per key. `set -eu` inside keeps the first failure fatal.
seed_script="set -eu
mc mb --ignore-existing rustfs/$BUCKET1
"
for ts in "${DATES1[@]}"; do
  seed_script+="echo -n x | mc pipe rustfs/$BUCKET1/$PREFIX1/mysql_my_database_mysql_$ts.sql.gz
"
done
mc_cmd "$seed_script"
echo "==> [mysql] running backup-warden (--daily=3 --delete)"
docker compose run --rm backup-warden \
  -s s3 -b "$BUCKET1" -p "${PREFIX1%%/*}/" \
  -t "$REGEX1" \
  --hourly=0 --weekly=0 --monthly=0 --yearly=0 \
  --daily=3 --no-recency-check --delete
echo "==> [mysql] verifying survivors"
ACTUAL=$(mc_cmd "mc ls --recursive rustfs/$BUCKET1" \
  | awk '{print $NF}' \
  | grep -Eo '[0-9]{8}-[0-9]{6}' | sort -u)
EXPECTED=$(printf '%s\n' "${EXPECTED1[@]}" | sort -u)
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "FAIL [mysql]: survivor set mismatch"
  diff <(echo "$EXPECTED") <(echo "$ACTUAL") || true
  exit 1
fi
echo "PASS [mysql]: ${#EXPECTED1[@]} expected survivors, all present"
# ----------------------------------------------------------------------------
# Scenario 2: app-media-backup-YYYY-MM-DDTHH-MM-SS.tar.gz
# ----------------------------------------------------------------------------
BUCKET2="media-bucket"
PREFIX2="backups/media"
REGEX2='(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})T(?P<hour>\d{2})-(?P<minute>\d{2})-(?P<second>\d{2})'
DATES2=(
  2026-04-10T01-40-00 2026-04-11T01-40-00 2026-04-12T01-40-00
  2026-04-13T01-40-00 2026-04-14T01-40-00
)
EXPECTED2=(2026-04-12T01-40-00 2026-04-13T01-40-00 2026-04-14T01-40-00)
echo "==> [media] creating bucket + seeding ${#DATES2[@]} tarballs"
seed_script="set -eu
mc mb --ignore-existing rustfs/$BUCKET2
"
for ts in "${DATES2[@]}"; do
  seed_script+="echo -n x | mc pipe rustfs/$BUCKET2/$PREFIX2/app-media-backup-$ts.tar.gz
"
done
mc_cmd "$seed_script"
echo "==> [media] running backup-warden (--daily=3 --delete)"
docker compose run --rm backup-warden \
  -s s3 -b "$BUCKET2" -p "${PREFIX2%%/*}/" \
  -t "$REGEX2" \
  --hourly=0 --weekly=0 --monthly=0 --yearly=0 \
  --daily=3 --no-recency-check --delete
echo "==> [media] verifying survivors"
ACTUAL=$(mc_cmd "mc ls --recursive rustfs/$BUCKET2" \
  | awk '{print $NF}' \
  | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}' | sort -u)
EXPECTED=$(printf '%s\n' "${EXPECTED2[@]}" | sort -u)
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "FAIL [media]: survivor set mismatch"
  diff <(echo "$EXPECTED") <(echo "$ACTUAL") || true
  exit 1
fi
echo "PASS [media]: ${#EXPECTED2[@]} expected survivors, all present"
echo "==> all custom-filename scenarios passed"

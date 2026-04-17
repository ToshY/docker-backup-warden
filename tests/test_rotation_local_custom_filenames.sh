#!/usr/bin/env bash
# Local-filesystem custom-filename smoke test: mirrors
# tests/test_rotation_s3_custom_filenames.sh but against bind-mounted host
# directories. Two scenarios run back-to-back, each in its own subdirectory
# of a shared TMPDIR (= one bind-mount, separate `-p /data/<subdir>`).
#
# Scenario 1: MySQL dump layout  — mysql_<db>_mysql_YYYYMMDD-HHMMSS.sql.gz
# Scenario 2: App tarball layout — app-media-backup-YYYY-MM-DDTHH-MM-SS.tar.gz
#
# Each scenario seeds 5 consecutive daily backups, applies --daily=3 --delete,
# and asserts exactly the 3 most-recent files remain.
set -euo pipefail

TMPDIR="$(mktemp -d -t backup-warden-local-custom.XXXXXX)"
cleanup() { rm -rf "$TMPDIR" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> preparing $TMPDIR (chmod 777 so uid 65532 in the container can delete)"
chmod 777 "$TMPDIR"
mkdir -p "$TMPDIR/mysql" "$TMPDIR/media"
chmod 777 "$TMPDIR/mysql" "$TMPDIR/media"

# ----------------------------------------------------------------------------
# Scenario 1: mysql_my_database_mysql_YYYYMMDD-HHMMSS.sql.gz
# ----------------------------------------------------------------------------
REGEX1='(?P<year>\d{4})(?P<month>\d{2})(?P<day>\d{2})-(?P<hour>\d{2})(?P<minute>\d{2})(?P<second>\d{2})'
DATES1=(20260410-030000 20260411-030000 20260412-030000 20260413-030000 20260414-030000)
EXPECTED1=(20260412-030000 20260413-030000 20260414-030000)

echo "==> [mysql] seeding ${#DATES1[@]} dumps in $TMPDIR/mysql"
for ts in "${DATES1[@]}"; do
  : > "$TMPDIR/mysql/mysql_my_database_mysql_$ts.sql.gz"
done

echo "==> [mysql] running backup-warden (--daily=3 --delete)"
docker compose run --rm --no-deps \
  -v "$TMPDIR:/data" \
  backup-warden \
    -s local -p /data/mysql \
    -t "$REGEX1" \
    --hourly=0 --weekly=0 --monthly=0 --yearly=0 \
    --daily=3 --no-recency-check --delete

echo "==> [mysql] verifying survivors"
ACTUAL=$(find "$TMPDIR/mysql" -maxdepth 1 -type f -name '*.sql.gz' \
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
REGEX2='(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})T(?P<hour>\d{2})-(?P<minute>\d{2})-(?P<second>\d{2})'
DATES2=(
  2026-04-10T01-40-00 2026-04-11T01-40-00 2026-04-12T01-40-00
  2026-04-13T01-40-00 2026-04-14T01-40-00
)
EXPECTED2=(2026-04-12T01-40-00 2026-04-13T01-40-00 2026-04-14T01-40-00)

echo "==> [media] seeding ${#DATES2[@]} tarballs in $TMPDIR/media"
for ts in "${DATES2[@]}"; do
  : > "$TMPDIR/media/app-media-backup-$ts.tar.gz"
done

echo "==> [media] running backup-warden (--daily=3 --delete)"
docker compose run --rm --no-deps \
  -v "$TMPDIR:/data" \
  backup-warden \
    -s local -p /data/media \
    -t "$REGEX2" \
    --hourly=0 --weekly=0 --monthly=0 --yearly=0 \
    --daily=3 --no-recency-check --delete

echo "==> [media] verifying survivors"
ACTUAL=$(find "$TMPDIR/media" -maxdepth 1 -type f -name '*.tar.gz' \
  | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}' | sort -u)
EXPECTED=$(printf '%s\n' "${EXPECTED2[@]}" | sort -u)
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "FAIL [media]: survivor set mismatch"
  diff <(echo "$EXPECTED") <(echo "$ACTUAL") || true
  exit 1
fi
echo "PASS [media]: ${#EXPECTED2[@]} expected survivors, all present"
echo "==> all local custom-filename scenarios passed"


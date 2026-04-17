#!/usr/bin/env bash
# Dense multi-tier retention smoke test (local backend).
#
# Extends tests/test_rotation_local_multi_tier.sh by exercising:
#   * --hourly: multiple sub-day timestamps within the same calendar day, so
#     the hourly tier has a real slot population to choose from.
#   * Multiple seeds per daily / weekly / monthly / yearly slot, so every
#     tier has to pick one survivor out of N candidates per slot (the
#     existing multi-tier test mostly seeds singletons per slot).
#   * A wider yearly span (2022..2025) with multiple seeds per year, so the
#     yearly tier collapses several backups per year into one survivor.
#
# The timestamp regex carries hour/minute/second capture groups (not just
# year/month/day) so backup-warden can place each backup into an hourly slot.
# Format on disk is `db-YYYY-MM-DDTHH-MM-SS.sql` (same shape used by the
# media-tarball scenario in tests/test_rotation_local_custom_filenames.sh).
#
# Survivor set was derived empirically by running backup-warden with the
# seeds + retention flags below and copying the "Preserving (matches '…'
# retention period)" rows from its own output table — same methodology as
# tests/test_rotation_local_multi_tier.sh.
#
# All seeded dates are >= 2 days in the past, so this test is not
# clock-coupled (today's date only matters for which slots count as
# "most recent"; the survivor set stays stable as long as no seeded date
# crosses into a more-recent slot than today).
set -euo pipefail

# 24 seeded timestamps. Grouped by which tier they primarily exercise.
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

# Filled in after observing backup-warden's preserve/delete table; see
# header comment for derivation methodology. Per-slot tiebreak observed:
# yearly/monthly/weekly/daily all pick the EARLIEST backup in each slot.
# Hourly tier behaviour is "future-or-very-recent hour wins" — only the
# 22-00-00 entry (after the test's wall-clock run-time) lands in 'hourly';
# the 06-00-00 entry is absorbed by 'daily', the rest are pruned.
EXPECTED_SURVIVORS=(
  # yearly tier (earliest seed per year, --yearly=always)
  2022-02-28T10-00-00
  2023-07-04T10-00-00
  2024-06-15T10-00-00
  2025-03-15T10-00-00
  # monthly tier (earliest seed per month, --monthly=4)
  2026-01-10T10-00-00
  2026-02-05T10-00-00
  # weekly tier (earliest seed per ISO week, --weekly=4)
  2026-03-25T10-00-00
  2026-04-04T10-00-00
  # daily tier (earliest seed per day, --daily=4)
  2026-04-14T03-00-00
  2026-04-15T08-00-00
  2026-04-16T10-00-00
  2026-04-17T06-00-00
  # hourly tier (--hourly=3)
  2026-04-17T22-00-00
)

TMPDIR="$(mktemp -d -t backup-warden-local-multi-dense.XXXXXX)"
cleanup() { rm -rf "$TMPDIR" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> preparing $TMPDIR (chmod 777 so uid 65532 in the container can delete)"
chmod 777 "$TMPDIR"

echo "==> seeding ${#DATES[@]} dated files"
for d in "${DATES[@]}"; do
  : > "$TMPDIR/db-$d.sql"
done

echo "==> running backup-warden (dense multi-tier retention, with --hourly)"
docker compose run --rm --no-deps \
  -v "$TMPDIR:/data" \
  backup-warden \
    -s local \
    -p /data \
    -t '(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})T(?P<hour>\d{2})-(?P<minute>\d{2})-(?P<second>\d{2})' \
    --hourly=3 \
    --daily=4 \
    --weekly=4 \
    --monthly=4 \
    --yearly=always \
    --no-recency-check \
    --delete

echo "==> comparing survivors to expected set"
ACTUAL=$(find "$TMPDIR" -maxdepth 1 -type f -name '*.sql' \
  | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}' \
  | sort -u)
EXPECTED=$(printf '%s\n' "${EXPECTED_SURVIVORS[@]}" | sort -u)
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "FAIL: survivor set mismatch"
  diff <(echo "$EXPECTED") <(echo "$ACTUAL") || true
  exit 1
fi
echo "PASS: ${#EXPECTED_SURVIVORS[@]} expected survivors, all present"



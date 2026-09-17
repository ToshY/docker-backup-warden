# AGENTS.md

## What this repo actually is

Despite the name `docker-backup-warden`, this repo has two distinct concerns — keep them separate when editing:

1. **A Docker image around [`backup-warden`](https://pypi.org/project/backup-warden/)** (`Dockerfile`, `.github/workflows/release.yml`). The `prod` stage is **distroless** (`gcr.io/distroless/python3-debian13:nonroot`, Python 3.13, uid 65532, no shell, no pip); only `backup-warden` + deps are installed. There is **no `pyproject.toml` / `setup.py`** — do not add `pip install .` to the builder, or the build fails with `Directory '.' is not installable`.
2. **Ten shell smoke tests** under `tests/` — five variants per backend:
   - `-s s3` via `docker compose` + `mc` against [rustfs](https://github.com/rustfs/rustfs): `tests/test_rotation_s3.sh`, `tests/test_rotation_s3_multi_tier.sh`, `tests/test_rotation_s3_multi_tier_dense.sh`, `tests/test_rotation_s3_custom_filenames.sh`, `tests/test_rotation_s3_config.sh`.
   - `-s local` against a bind-mounted host directory (no rustfs/mc): `tests/test_rotation_local.sh`, `tests/test_rotation_local_multi_tier.sh`, `tests/test_rotation_local_multi_tier_dense.sh`, `tests/test_rotation_local_custom_filenames.sh`, `tests/test_rotation_local_config.sh`.

   Naming convention is `test_rotation_<backend>[_<variant>].sh` — keep it consistent when adding new tests. These are the only tests in the repo. There is deliberately no pytest, no boto3 test harness, no `dev` Docker stage.

## Dockerfile architecture

Two stages (`builder`, `prod`) with non-obvious coupling — changes rarely affect only one:

- **Builder** uses `python:${PYTHON_IMAGE_VERSION}-slim-trixie` (Debian-based). It **must** match the distroless runtime's Python minor and libc, or non-`abi3` C extensions like `_cffi_backend.cpython-313-*.so` will fail to load in prod. If you bump `PYTHON_IMAGE_VERSION`, verify `gcr.io/distroless/python3-debian13` still ships the same minor (`docker run --rm --entrypoint=/busybox/sh gcr.io/distroless/python3-debian13:debug -c 'python3 --version'`).
- **Prod** copies `/install/lib/python3.*/site-packages` → `/app/site-packages` (glob matches the single `python3.X/` directory pip creates under `--prefix=/install`) and sets `PYTHONPATH=/app/site-packages`. The glob is deliberate so a Python-minor bump in `PYTHON_IMAGE_VERSION` (e.g. 3.13 → 3.14) doesn't require a second Dockerfile edit — **do not** replace it with a hardcoded `python3.13` path.
- **Prod entrypoint** is `["python3", "/app/backup-warden"]`, not the pip-generated console script directly. The script's pip-generated shebang points at `/usr/local/bin/python3.13`, which doesn't exist on distroless; explicit `python3` bypasses it. Users pass flags via `docker run` positional args or compose `command:`; there is deliberately no env-var wrapper (would add quoting/maintenance surface with no real benefit over `command:`). Console-script entry function is `backup_warden.app:main`.
- Release smoke test is `docker run --rm <img>:prod --help` (`.github/workflows/release.yml`). Any prod-stage change must keep it exiting 0.

## The tests

Ten shell-only scripts under `tests/`, paired by variant across two backends. Naming: `test_rotation_<backend>[_<variant>].sh`. Scripts mirror each other on purpose — the S3 and local variants of each test assert the same retention outcome on the same set of seed dates, which is the whole point: retention logic is backend-agnostic, so both paths should produce identical survivor sets.

### `-s s3` backend (rustfs + mc)

- **`tests/test_rotation_s3.sh`** — daily-only retention. Seeds 8 consecutive daily backups, runs backup-warden with `--daily=3 --delete`, asserts exactly 3 remain (the 3 most-recent).
- **`tests/test_rotation_s3_multi_tier.sh`** — multi-tier retention (`--daily=4 --weekly=7 --monthly=4 --yearly=always`). Seeds 20 dates spanning 2022–2026 covering all four tiers (plus 3 mid-2025 monthlies that should be pruned), asserts the **exact set** of 16 surviving keys. The DATES and EXPECTED_SURVIVORS arrays document which backups fall in which bucket; backup-warden's own table output (e.g. `Preserving (matches 'weekly', 'monthly' retention periods)`) was used to derive the expected set.
- **`tests/test_rotation_s3_multi_tier_dense.sh`** — dense multi-tier variant that also exercises `--hourly`. Seeds 24 hour-precision timestamps (`YYYY-MM-DDTHH-MM-SS`) with **multiple entries per slot** (sub-day hours, multiple daily entries per day, multiple weekly entries per ISO week, multiple monthly per month, multiple yearly per year spanning 2022–2026). Applies `--hourly=3 --daily=4 --weekly=4 --monthly=4 --yearly=always`, asserts the exact 13 survivors. Per-slot tiebreak observed empirically: **yearly/monthly/weekly/daily all pick the earliest backup in each slot**; hourly tier preserves only the single post-"now" hour entry (the 06-00-00 entry is absorbed by daily). Like the original multi-tier test, the today-dated entries couple the test to the clock — survivors remain stable for roughly a week after 2026-04-17, after which today's dates age out of their current slots and EXPECTED_SURVIVORS must be re-derived.
- **`tests/test_rotation_s3_custom_filenames.sh`** — two back-to-back scenarios sharing one rustfs, validating that `-t` regex capture groups work for non-trivial key layouts: MySQL dumps (`mysql_<db>_mysql_YYYYMMDD-HHMMSS.sql.gz`, compact `%Y%m%d-%H%M%S` timestamp) and app tarballs (`app-media-backup-YYYY-MM-DDTHH-MM-SS.tar.gz`, ISO-ish with `T` and `-` separators). Each scenario seeds 5 daily backups, runs `--daily=3 --delete`, asserts the 3 most-recent survive.
- **`tests/test_rotation_s3_config.sh`** — config-mount variant of `test_rotation_s3.sh`. Same seed/assertion (8 daily-dated objects → 3 survive), but retention/source/bucket/path/timestamp pattern all live in a bind-mounted INI passed via `--config`. Exists separately because backup-warden's `allowed_options` rejects most CLI flags when `--config` is set, so the config path needs its own end-to-end coverage. Credentials/endpoint still come from the compose service's `AWS_*` env vars (boto3 reads them natively). `--no-recency-check` is rejected on the CLI in config mode (CRITICAL exit); the INI equivalent is `no_recency_check = true` under `[main]`.

### `-s local` backend (bind-mounted host dir)

- **`tests/test_rotation_local.sh`** — daily-only. Mirrors `test_rotation_s3.sh` (same DATES, same assertion) against a `mktemp`'d host directory bind-mounted as `/data`.
- **`tests/test_rotation_local_multi_tier.sh`** — multi-tier. Mirrors `test_rotation_s3_multi_tier.sh` exactly: same DATES and EXPECTED_SURVIVORS arrays, same retention flags, filesystem scan instead of `mc ls`.
- **`tests/test_rotation_local_multi_tier_dense.sh`** — mirrors `test_rotation_s3_multi_tier_dense.sh` (hour-precision timestamps, multiple seeds per slot, `--hourly=3`, 13 expected survivors). Same clock-coupling caveat applies.
- **`tests/test_rotation_local_custom_filenames.sh`** — mirrors `test_rotation_s3_custom_filenames.sh` (MySQL + media scenarios). Uses **one TMPDIR with subdirs** (`$TMPDIR/mysql`, `$TMPDIR/media`) rather than two separate mounts; backup-warden's `-p /data/mysql` / `-p /data/media` scopes each scenario.
- **`tests/test_rotation_local_config.sh`** — config-mount variant of `test_rotation_local.sh`. Same 5-daily-files → 3-survive assertion, but retention (`daily=`), `source`, `path`, and timestamp pattern all come from a bind-mounted INI passed via `--config`. The INI is written to a sibling tmpdir (not inside the data dir) so the regex never matches it. `--no-recency-check` is rejected on the CLI in config mode (CRITICAL exit); the INI equivalent is `no_recency_check = true` under `[main]`.

All local scripts share the same host-side setup: `mktemp -d -t backup-warden-local-<variant>.XXXXXX`, `chmod 777` on the dir (so uid `65532` inside the container can unlink files during `--delete`), seed via `: > "$TMPDIR/<name>"`, `docker compose run --rm --no-deps -v "$TMPDIR:/data" backup-warden -s local -p /data[/<subdir>] …`, assert via `find | grep -Eo | sort -u`, clean up with `rm -rf "$TMPDIR"` in the `EXIT` trap. **`--no-deps` is load-bearing** — without it, `docker compose run` waits for the rustfs healthcheck even though local mode never touches S3. The `backup-warden` compose service's `AWS_*` env vars are harmless no-ops in local mode.

The S3 scripts follow the same pattern across all five variants:

1. `docker compose up -d rustfs` + healthcheck wait.
2. Seed dated objects through the `mc` service via `mc_cmd`, **batched into a single `docker compose run --rm mc` invocation per bucket** (one long `sh -c "set -eu; mc mb ...; echo | mc pipe ...; ..."` string). Earlier revisions called `mc_cmd` once per key; this was measured at ~300–800 ms of pure docker-run overhead per call, so the multi-tier test alone spent 10–20 s spinning containers. Batching keeps first-failure-fatal via `set -eu` inside the script and preserves the `MC_HOST_rustfs` contract (no `mc alias set` needed).
3. `docker compose run --rm backup-warden <args>` — the compose `backup-warden` service **only defines the environment** (endpoint URL, creds) and builds the `prod` target; test-specific flags are passed at call time from the script, not baked into compose. This keeps the compose service reusable for ad-hoc runs. CLI-driven S3 tests pass `--no-recency-check` to silence backup-warden's "hasn't had a backup in the past 24 hours" warning (the seeded dates are deliberately historical); the config-mode test uses `no_recency_check = true` in the INI because the CLI flag is rejected with `--config`.
4. Assert survivors using one of two patterns: count-based checks (`mc ls --recursive ... | wc -l`) in `test_rotation_s3.sh` and `test_rotation_s3_config.sh`, or exact-set checks in the other S3 tests by parsing the key column from `mc ls --recursive` (`awk '{print $NF}'`) and matching the timestamp shape with `grep -Eo`.
5. `trap cleanup EXIT` runs `docker compose down -v` so each script is self-contained and can run back-to-back without state bleeding across.

Key constraints when editing:

- The `backup-warden` compose service builds the `prod` target, not a dev image. This is intentional — the tests validate what ships to users.
- The `mc` service in `compose.yaml` sets `MC_HOST_rustfs=http://rustfsadmin:rustfsadmin@rustfs:9000` so every `docker compose run --rm mc ...` immediately sees the `rustfs/` alias — **do NOT use `mc alias set` in ephemeral containers; state does not persist across `docker compose run` invocations**.
- `backup-warden`'s `-t` wants a regex **with named capture groups** (`year`, `month`, `day`, `hour`, `minute`, `second`); strftime-style patterns are silently rejected with `CRITICAL: Timestamp pattern is missing required capture group 'year'`.
- For S3, `-p` must not have a leading slash (`db/` works, `/db/` yields "No backups were found").
- Keys must live under sub-prefixes (e.g. `db/prod/2026-04-17.sql`), not at the bucket root.
- Exit code is `0` for both dry-run and `--delete` when args are valid; non-zero only on hard misconfiguration.
- Multi-tier retention semantics depend on **today's date** (backup-warden uses `datetime.now()` to compute which backup falls in which weekly/monthly/yearly slot). The fixed 2022–2026 DATES in `test_rotation_multi_tier.sh` are safe indefinitely because all slots are in the past; if you add dates within the last few days, you're coupling the test to the clock.
- Shellcheck runs via pre-commit (`.pre-commit-config.yaml`); keep scripts warning-free.

## Critical workflows

Use **Task** (`Taskfile.yml`) — don't invent new commands:

- `task contribute` — runs shellcheck over every `*.sh` in the repo via the `koalaman/shellcheck` Docker image (also wired into `.pre-commit-config.yaml`). No Python tests run (there are none); there is no Python lint/format pipeline in this repo — the only tracked source is shell + Dockerfile + compose.
- `task build` — builds the `prod` target locally via `docker compose build backup-warden`, same target as CI/release. Use this when iterating on the `Dockerfile` without waiting for CI. The `backup-warden` compose service already pins the `prod` target, so no extra flags.
- `task test` — runs all ten rotation smoke tests in order (the five `test_rotation_s3*.sh` against rustfs, then the five `test_rotation_local*.sh` against bind-mounted host dirs). Mirrors CI (`.github/workflows/test.yml`) which invokes `task test` verbatim. Each S3 script owns its own compose lifecycle (`up -d rustfs` → seed → run → assert → `down -v` via trap); the local scripts use `mktemp -d` and `rm -rf` in their traps and never touch compose services. Safe to run back-to-back; a failure in one doesn't leak state into the next. End-to-end runtime ≈ 2 min.
- `task rustfs:up` / `rustfs:down` — start/stop just the rustfs container; useful when iterating on a single shell test (run the script directly, e.g. `bash tests/test_rotation_multi_tier.sh`, and the script's own trap handles cleanup at the end).

## Integration points & dependency pinning

- **rustfs** is pinned in `compose.yaml` (`rustfs/rustfs:1.0.0-alpha.94`). Healthcheck hits `:9000/health` and `:9001/rustfs/console/health`; the `backup-warden` compose service uses `depends_on: condition: service_healthy`, so don't remove the healthcheck.
- **mc** (minio/mc) is pinned in `compose.yaml` and used only by the shell test. `MC_HOST_rustfs` env var is the contract between the test script and the `mc` service — don't switch back to `mc alias set`.
- **Updatecli** lives under `updatecli/` with a manifest per dependency:
  - `updatecli/updatecli.d/backup-warden.yaml` — PyPI source, matches `ARG BACKUP_WARDEN_VERSION`
  - `updatecli/updatecli.d/python-slim-trixie.yaml` — Docker source for `python`, regex filter `^3\.\d+-slim-trixie$`
  - `updatecli/values.yaml` — SCM credentials (user, email, username, token ref) shared by all manifests
  - `.github/workflows/updatecli.yaml` — runs `updatecli diff` then `updatecli apply` every Saturday 06:00 UTC (also `workflow_dispatch`-able). The workflow uses `--values updatecli/values.yaml` so manifests stay generic. `UPDATECLI_GITHUB_USERNAME` is set to `${{ github.actor }}`.
  - To add a new managed dependency, create a manifest under `updatecli/updatecli.d/` following the existing pattern; the workflow picks it up automatically.
- When bumping `PYTHON_IMAGE_VERSION`, no other Dockerfile edit is required — the prod-stage `COPY --from=builder /install/lib/python3.*/site-packages` line globs the minor out of the path. Do verify that `gcr.io/distroless/python3-debian13` ships the same minor as the builder base (`docker run --rm --entrypoint=/busybox/sh gcr.io/distroless/python3-debian13:debug -c 'python3 --version'`); a mismatch still breaks non-`abi3` C extensions at runtime.
- No Python dev dependencies are tracked in the repo (no `requirements.dev.txt`, no `pyproject.toml`). Pre-commit only wires shellcheck. If you reach for `pytest`/`boto3`, reconsider; the shell script + mc has been deliberately chosen over a Python test harness.
- Release image is published to `ghcr.io/toshy/docker-backup-warden` and smoke-tested with `docker run --rm <img>:prod --help` — new prod-stage changes must keep `--help` working. Current prod image is ~117 MB uncompressed; regressions past ~130 MB usually mean an unintended bytecode/cache duplication or a base-image bump.

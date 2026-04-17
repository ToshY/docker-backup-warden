<h1 align="center">🐋 Docker backup-warden</h1>

<div align="center">
    <div>Distroless Docker image for <a href="https://github.com/charles-001/backup-warden"><code>charles-001/backup-warden</code></a></div>
</div>

> [!IMPORTANT]
> This repository only packages `backup-warden` into a distroless Docker image and it does not maintain `backup-warden` itself. Questions about `backup-warden`'s flags, retention semantics, S3 behaviour, or bugs in its Python code belong in the upstream repository: [`charles-001/backup-warden`](https://github.com/charles-001/backup-warden/issues).
>
> Issues not related to this image will be closed.

## 📝 Quickstart

```sh
docker run --rm ghcr.io/toshy/docker-backup-warden:latest --help
```

## 📚 Examples

Rotate S3 backups with a retention policy (this is a dry-run — add `--delete` to actually prune):

```sh
docker run --rm \
  -e AWS_ACCESS_KEY_ID=... \
  -e AWS_SECRET_ACCESS_KEY=... \
  -e AWS_DEFAULT_REGION=eu-west-1 \
  ghcr.io/toshy/docker-backup-warden:latest \
    -s s3 \
    -b my-backups-bucket \
    -p db/production/ \
    -t '(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})T(?P<hour>\d{2})-(?P<minute>\d{2})-(?P<second>\d{2})' \
    --daily 7 --weekly 4 --monthly 12 --yearly 3
```

> [!NOTE]
> `backup-warden` argument `-t` expects a regex with named capture groups (`year`, `month`, `day`, `hour`, `minute`, `second`). The pattern above matches filenames like `db-2026-04-17T03-00-00.sql`.

Rotate **local** backups by bind-mounting the directory (the image runs as uid `65532`, thus the mount must be readable, and writable too when `--delete` is used):

```sh
docker run --rm \
  -v /srv/backups:/data \
  ghcr.io/toshy/docker-backup-warden:latest \
    -s local \
    -p /data \
    -t '(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})' \
    --daily 7 --weekly 4 --monthly 12 \
    --delete
```

Minimal compose snippet for a scheduled run (pair with `cron`, `systemd-timer`, or any orchestrator-level scheduler):

```yaml
services:
  backup-warden:
    image: ghcr.io/toshy/docker-backup-warden:latest
    environment:
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
      AWS_DEFAULT_REGION: eu-west-1
    command: [
      "-s", "s3",
      "-b", "my-backups-bucket",
      "-p", "db/production/",
      "-t", "(?P<year>\\d{4})-(?P<month>\\d{2})-(?P<day>\\d{2})T(?P<hour>\\d{2})-(?P<minute>\\d{2})-(?P<second>\\d{2})",
      "--daily=7", "--weekly=4", "--monthly=12",
      "--delete"
    ]
```

### S3-compatible providers (Backblaze B2, MinIO, Cloudflare R2)

`backup-warden` uses `boto3` under the hood, meaning any S3-compatible service works by pointing it at a custom endpoint via boto3's env var `AWS_ENDPOINT_URL_S3`.

```sh
docker run --rm \
  -e AWS_ACCESS_KEY_ID=<applicationKeyId> \
  -e AWS_SECRET_ACCESS_KEY=<applicationKey> \
  -e AWS_DEFAULT_REGION=us-west-004 \
  -e AWS_ENDPOINT_URL_S3=https://s3.us-west-004.backblazeb2.com \
  ghcr.io/toshy/docker-backup-warden:latest \
    -s s3 \
    -b my-b2-bucket \
    -p db/production/ \
    -t '(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})' \
    --daily 7 --weekly 4 --monthly 12 \
    --delete
```

- **Backblaze**: use `AWS_DEFAULT_REGION` values `us-west-00X` / `eu-central-00X` and `AWS_ENDPOINT_URL_S3=https://s3.${AWS_DEFAULT_REGION}.backblazeb2.com` see B2 console.
- **Cloudflare R2**: use `AWS_DEFAULT_REGION=auto` and `AWS_ENDPOINT_URL_S3=https://<account-id>.r2.cloudflarestorage.com`.
- **MinIO**: point at the internal URL and use whatever region the deployment was configured with (default `us-east-1`).

> [!NOTE]
> The `AWS_DEFAULT_REGION` and `AWS_ENDPOINT_URL_S3` should use the same region.

## ✨ Why this image?

|                         | This image                                   | Upstream reference      |
|-------------------------|----------------------------------------------|-------------------------|
| Base                    | `gcr.io/distroless/python3-debian13:nonroot` | `python:alpine`         |
| Uncompressed size       | ~117 MB                                      | ~291 MB                 |
| Shell / package manager | none (distroless)                            | `/bin/sh`, `apt`, `pip` |
| Default user            | non-root (uid `65532`)                       | root                    |

Concretely, that means:

- **~60% smaller image** (~174 MB less to pull on every CI run / cold node), because only `backup-warden` + its Python dependencies ship in the runtime stage — no `apt`, no `pip`, no shell, no build toolchain left over from the builder.
- **Smaller attack surface.** No shell means no `docker exec <container> sh`, no in-container shell injection, and a pile of common CVE categories (shell-based RCE chains, `apt`/`dpkg` advisories, coreutils issues) simply don't apply.
- **Runs as non-root by default** (`uid 65532`), so bind-mounts need to be readable by that uid — see the local-rotation example below.
- **Reproducible & pinned.** Python minor, `backup-warden` version, and base digest are all pinned in the `Dockerfile` and kept current by Renovate.

## 🛠️ Contribute

### Requirements

* ☑️ [Pre-commit](https://pre-commit.com/#installation)
* 🐋 [Docker Compose V2](https://docs.docker.com/compose/install/)
* 📋 [Task 3.37+](https://taskfile.dev/installation/)

### 🧪 Tests

```sh
task test
```

## ❕ License

- This repository: [BSD 3-Clause](./LICENSE).
- The published image bundles [`backup-warden`](https://github.com/charles-001/backup-warden) under **GPL-3.0-or-later**; the license text is embedded in the image via the upstream wheel, and the pinned source version is recorded in `Dockerfile` (`BACKUP_WARDEN_VERSION`).

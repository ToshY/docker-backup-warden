ARG PYTHON_IMAGE_VERSION=3.13

ARG BACKUP_WARDEN_VERSION=1.0.16

FROM python:${PYTHON_IMAGE_VERSION}-slim-trixie AS builder

LABEL maintainer="ToshY (github.com/ToshY)"

ENV PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

ARG BACKUP_WARDEN_VERSION

WORKDIR /build

RUN pip install --no-cache-dir --prefix=/install "backup-warden==${BACKUP_WARDEN_VERSION}"

FROM gcr.io/distroless/python3-debian13:nonroot AS prod

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app/site-packages

WORKDIR /app

COPY --from=builder /install/lib/python3.*/site-packages /app/site-packages
COPY --from=builder /install/bin/backup-warden /app/backup-warden

ENTRYPOINT ["python3", "/app/backup-warden"]

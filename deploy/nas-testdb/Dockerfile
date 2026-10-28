# GET.ride test database runner for the office NAS (see README.md).
# linux/amd64. The Postgres tools match the live database's version (17), so
# pg_dump can read it and pg_restore can write the copy.
FROM python:3.11.10-slim-bookworm

ARG PG_MAJOR=17
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gzip \
 && install -d /usr/share/postgresql-common/pgdg \
 && curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc \
 && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update && apt-get install -y --no-install-recommends "postgresql-client-${PG_MAJOR}" \
 && apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY core.py runner.py prepare.sql scramble.sql ./

RUN useradd --system --create-home runner && mkdir -p /data /work && chown runner /data /work
USER runner

ENV PYTHONUNBUFFERED=1 RUNNER_DATA=/data RUNNER_WORK=/work BACKUP_DIR=/backups
CMD ["python", "runner.py"]

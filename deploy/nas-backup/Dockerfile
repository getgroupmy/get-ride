# GET.ride backup and uptime app for the office NAS (see README.md).
# linux/amd64. pg_dump and pg_restore 17 from the PostgreSQL project's own
# packages (they read Supabase's Postgres 15 and 17), age for the
# encryption, Python for the app.
FROM python:3.11.10-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl age tzdata \
 && install -d /usr/share/postgresql-common/pgdg \
 && curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc \
 && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update && apt-get install -y --no-install-recommends postgresql-client-17 \
 && apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY core.py agent.py ./

RUN useradd --system --create-home backup && mkdir -p /data /backups && chown backup /data /backups
USER backup

ENV PYTHONUNBUFFERED=1 NAS_DATA=/data BACKUP_DIR=/backups
CMD ["python", "agent.py"]

"""The test database runner's decisions, without the network or Postgres
(see runner.py; tests in test_core.py).

- when the nightly refresh is due (the time is set in Admin, office time);
- which backup file to restore (the newest that is fresh enough), or none
  (then pg_dump straight from the live database);
- which files of a pull request are migrations to try, in order;
- the short error to show in Admin from what psql printed, with secrets
  taken out.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, time, timedelta
from pathlib import PurePosixPath

MIGRATION_PATH = re.compile(r"^supabase/migrations/[A-Za-z0-9._-]+\.sql$")
BACKUP_SUFFIXES = (".dump", ".backup", ".pgdump", ".sql.gz", ".sql")


def parse_hhmm(value: str | None, default: str = "02:30") -> time:
    m = re.fullmatch(r"(\d{1,2}):(\d{2})", (value or "").strip())
    if m and int(m.group(1)) <= 23 and int(m.group(2)) <= 59:
        return time(int(m.group(1)), int(m.group(2)))
    h, mi = default.split(":")
    return time(int(h), int(mi))


def last_slot(now: datetime, refresh_at: str | None) -> datetime:
    """The most recent nightly time at or before now (both local)."""
    at = parse_hhmm(refresh_at)
    slot = now.replace(hour=at.hour, minute=at.minute, second=0, microsecond=0)
    return slot if slot <= now else slot - timedelta(days=1)


def refresh_due(now: datetime, refresh_at: str | None, last_refresh: datetime | None) -> bool:
    """True when the copy hasn't been refreshed since the latest nightly time.

    A NAS that was off at the time catches up when it comes back, once.
    """
    slot = last_slot(now, refresh_at)
    return last_refresh is None or last_refresh < slot


def next_refresh(now: datetime, refresh_at: str | None) -> datetime:
    return last_slot(now, refresh_at) + timedelta(days=1)


@dataclass(frozen=True)
class BackupFile:
    path: str
    mtime: datetime
    size: int


def backup_kind(path: str) -> str | None:
    """custom (pg_restore), gzip (zcat | psql) or plain (psql); None if not a backup."""
    p = path.lower()
    if p.endswith((".dump", ".backup", ".pgdump")):
        return "custom"
    if p.endswith(".sql.gz"):
        return "gzip"
    if p.endswith(".sql"):
        return "plain"
    return None


def pick_backup(files: list[BackupFile], now: datetime, max_age_hours: float = 36) -> BackupFile | None:
    """The newest database backup that is fresh enough and not empty.

    Storage-bucket copies and half-written files (.part, .tmp) are not backups.
    """
    fresh = [
        f for f in files
        if backup_kind(f.path) and f.size > 1024 and now - f.mtime <= timedelta(hours=max_age_hours)
        and not re.search(r"(\.part|\.tmp|~)$", f.path)
    ]
    return max(fresh, key=lambda f: f.mtime, default=None)


def migration_files(pr_files: list[dict]) -> list[str]:
    """The PR's new or changed migrations, in the order they'd run."""
    out = []
    for f in pr_files:
        name = f.get("filename") or ""
        if f.get("status") == "removed" or not MIGRATION_PATH.match(name):
            continue
        out.append(name)
    return sorted(set(out), key=lambda n: PurePosixPath(n).name)


def is_fork(pr: dict) -> bool:
    """A PR from another repository: its code isn't the owner's, so it isn't run."""
    head = ((pr.get("head") or {}).get("repo") or {}).get("full_name")
    base = ((pr.get("base") or {}).get("repo") or {}).get("full_name")
    return bool(head and base and head != base)


SECRET_URL = re.compile(r"(postgres(?:ql)?://[^:/@\s]+:)[^@\s]+@")


def redact(text: str, secrets: list[str] | None = None) -> str:
    """Passwords in connection strings and any of [secrets] taken out."""
    out = SECRET_URL.sub(r"\1***@", text or "")
    for s in secrets or []:
        if s and len(s) >= 6:
            out = out.replace(s, "***")
    return out


def psql_error(output: str, limit: int = 1500) -> str:
    """The lines of psql's output that say what went wrong.

    psql prints `psql:file.sql:123: ERROR:  …` then DETAIL / HINT / CONTEXT /
    LINE lines; NOTICEs and the rest are left out.
    """
    keep = []
    started = False
    for line in (output or "").splitlines():
        stripped = re.sub(r"^psql:[^:]*:\d+:\s*", "", line)
        if re.match(r"(ERROR|FATAL|PANIC):", stripped):
            started = True
        if not started:
            continue
        if re.match(r"(ERROR|FATAL|PANIC|DETAIL|HINT|CONTEXT|LINE \d+|WHERE|QUERY):", stripped) or stripped.startswith(" "):
            keep.append(stripped.rstrip())
        if len(keep) >= 12:
            break
    text = "\n".join(keep).strip()
    if not text:
        lines = (output or "").strip().splitlines()
        text = lines[-1] if lines else ""
    return text[:limit]


def target_text(run: dict) -> str:
    return f"PR #{run['pr_number']}" if run.get("pr_number") else f"branch {run.get('branch') or '?'}"

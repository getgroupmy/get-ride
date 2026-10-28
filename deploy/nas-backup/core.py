"""The pure half of the GET.ride NAS backup and uptime app (see README.md):
when a backup or restore test is due, which nightly and monthly copies to
keep, which storage files are new or changed, whether a restore test passed,
what an uptime check means, the box's numbers and the off-site copy's last
run from Hyper Backup's log. No network, no disk writes: test_core.py.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta

DATE_DIR = re.compile(r"^\d{4}-\d{2}-\d{2}$")


# ---- When ---------------------------------------------------------------------------------------

def parse_at(at: str | None) -> time:
    """'HH:MM' as a time; 02:00 when it isn't one (as the server does)."""
    m = re.fullmatch(r"([01]\d|2[0-3]):([0-5]\d)", (at or "").strip())
    return time(int(m.group(1)), int(m.group(2))) if m else time(2, 0)


def backup_due(now: datetime, at: str | None, last_started: datetime | None) -> bool:
    """Whether the nightly backup should start now (all times local).

    Due once today's time has passed and no backup started since it; a NAS
    that was off at that time catches up when it comes back. The first one
    runs as soon as the app is set up.
    """
    slot = datetime.combine(now.date(), parse_at(at), tzinfo=now.tzinfo)
    if now < slot:
        slot -= timedelta(days=1)
    return last_started is None or last_started < slot


def next_backup_at(now: datetime, at: str | None) -> datetime:
    slot = datetime.combine(now.date(), parse_at(at), tzinfo=now.tzinfo)
    return slot if slot > now else slot + timedelta(days=1)


def restore_test_due(today: date, day: int, last: date | None) -> bool:
    """The monthly restore test: from its day of the month on, once a month."""
    if today.day < max(1, min(28, day)):
        return False
    return last is None or (last.year, last.month) != (today.year, today.month)


# ---- What to keep -------------------------------------------------------------------------------

def to_prune(names: list[str], keep_nightly: int, keep_monthly: int) -> list[str]:
    """The nightly folders (YYYY-MM-DD) to delete.

    Kept: the newest [keep_nightly], and the first backup of each of the
    newest [keep_monthly] months. Anything that isn't a date is left alone.
    """
    dates = sorted({n for n in names if DATE_DIR.match(n)}, reverse=True)
    keep = set(dates[: max(1, keep_nightly)])
    firsts: dict[str, str] = {}
    for d in dates:  # newest first, so the last one seen in a month is its first
        firsts[d[:7]] = d
    for month in sorted(firsts, reverse=True)[: max(0, keep_monthly)]:
        keep.add(firsts[month])
    return sorted(d for d in dates if d not in keep)


def monthly_count(names: list[str], keep_monthly: int) -> int:
    dates = sorted({n for n in names if DATE_DIR.match(n)})
    return min(len({d[:7] for d in dates}), max(0, keep_monthly))


# ---- Storage ------------------------------------------------------------------------------------

@dataclass(frozen=True)
class StoredFile:
    bucket: str
    path: str
    size: int
    etag: str
    updated_at: str

    @property
    def key(self) -> str:
        return f"{self.bucket}/{self.path}"

    @property
    def signature(self) -> str:
        return f"{self.etag}|{self.size}|{self.updated_at}"


def from_listing(bucket: str, prefix: str, item: dict) -> StoredFile | None:
    """One entry of Storage's list call, or None for a folder."""
    if not isinstance(item, dict) or not item.get("name") or item.get("id") is None:
        return None
    meta = item.get("metadata") or {}
    path = f"{prefix}{item['name']}"
    if ".." in path.split("/") or path.startswith("/"):
        return None
    return StoredFile(bucket, path, int(meta.get("size") or 0), str(meta.get("eTag") or ""), str(item.get("updated_at") or ""))


def changed_files(files: list[StoredFile], manifest: dict[str, str]) -> list[StoredFile]:
    """New files, and files whose tag, size or time changed since the last copy."""
    return [f for f in files if manifest.get(f.key) != f.signature]


def gone_upstream(files: list[StoredFile], manifest: dict[str, str], buckets: list[str]) -> int:
    """Files in the copy no longer on GET.ride (kept on the NAS, only counted)."""
    live = {f.key for f in files}
    return sum(1 for k in manifest if k.split("/", 1)[0] in buckets and k not in live)


def buckets_to_copy(all_buckets: list[str], skip: list[str]) -> list[str]:
    skipped = {s.strip() for s in skip if s.strip()}
    return sorted(b for b in all_buckets if b and b not in skipped)


# ---- Restore test -------------------------------------------------------------------------------

KEY_TABLES = ("profiles", "partners", "ride_requests", "app_settings", "settings_entries")


def toc_tables(toc: str, schema: str = "public") -> list[str]:
    """The tables whose data is in a dump, from `pg_restore -l`."""
    out = []
    for line in toc.splitlines():
        m = re.search(r"\bTABLE DATA (\S+) (\S+) ", line)
        if m and not line.lstrip().startswith(";") and m.group(1) == schema:
            out.append(m.group(2).strip('"'))
    return sorted(set(out))


def restore_errors(stderr: str) -> int:
    """How many errors pg_restore reported ("errors ignored on restore: N")."""
    m = re.search(r"errors ignored on restore: (\d+)", stderr)
    if m:
        return int(m.group(1))
    return len(re.findall(r"^pg_restore: error:", stderr, re.M))


@dataclass
class Verdict:
    ok: bool
    summary: str
    detail: dict = field(default_factory=dict)


def restore_verdict(expected: list[str], restored: list[str], live_counts: dict[str, int],
                    restored_counts: dict[str, int], errors: int) -> Verdict:
    """Passed when every table whose data is in the dump came back, and each
    key table has about as many rows as the live database had when the dump
    was made (1% or 50 rows either way). Errors pg_restore skipped (objects
    of Supabase's own that a test copy can't make) are counted, not failed
    on, as long as the tables are whole."""
    missing = sorted(set(expected) - set(restored))
    short = []
    for t, live in sorted(live_counts.items()):
        got = restored_counts.get(t)
        if got is None:
            continue
        if abs(got - live) > max(50, live // 100):
            short.append(f"{t} {got} of {live}")
    detail = {"tables": len(expected), "restored": len(set(expected) & set(restored)), "missing": missing[:20],
              "rows": restored_counts, "live": live_counts, "skippedErrors": errors}
    if not expected:
        return Verdict(False, "The dump has no tables", detail)
    if missing:
        return Verdict(False, f"{len(missing)} of {len(expected)} tables didn't come back ({', '.join(missing[:3])})", detail)
    if short:
        return Verdict(False, "Rows missing: " + "; ".join(short[:3]), detail)
    rows = sum(restored_counts.values())
    return Verdict(True, f"{len(expected)} tables restored, key tables whole ({rows:,} rows checked)", detail)


# ---- Uptime -------------------------------------------------------------------------------------

def classify(http_status: int | None, ms: int, slow_ms: int, error: str | None = None) -> str:
    """As the cloud does: no answer or 500+ is down; else up, or slow."""
    if error or http_status is None or http_status >= 500:
        return "down"
    return "slow" if ms >= slow_ms else "up"


def fill_url(url: str | None, project: str) -> str | None:
    return url.replace("{project}", project.rstrip("/")) if url else None


def project_of(getride_url: str) -> str:
    """https://abc.supabase.co/functions/v1/nas-ops -> https://abc.supabase.co"""
    m = re.match(r"^(https://[^/]+)", getride_url.strip())
    return m.group(1) if m else ""


# ---- The box ------------------------------------------------------------------------------------

def meminfo(text: str) -> tuple[int, int] | None:
    """(used MB, total MB) from /proc/meminfo."""
    vals = {}
    for line in text.splitlines():
        m = re.match(r"(\w+):\s+(\d+) kB", line)
        if m:
            vals[m.group(1)] = int(m.group(2))
    if "MemTotal" not in vals or "MemAvailable" not in vals:
        return None
    return (vals["MemTotal"] - vals["MemAvailable"]) // 1024, vals["MemTotal"] // 1024


def cpu_busy(a: str, b: str) -> int | None:
    """Percent busy between two reads of /proc/stat's first line."""
    def nums(s: str) -> list[int]:
        parts = s.split()
        return [int(x) for x in parts[1:]] if parts and parts[0] == "cpu" else []
    x, y = nums(a), nums(b)
    if len(x) < 4 or len(y) < 4:
        return None
    idle = (y[3] + (y[4] if len(y) > 4 else 0)) - (x[3] + (x[4] if len(x) > 4 else 0))
    total = sum(y) - sum(x)
    return round(100 * (total - idle) / total) if total > 0 else None


# ---- Off-site copy (Hyper Backup's log) ---------------------------------------------------------

_LOG_TIME = re.compile(r"(\d{4})[/-](\d{2})[/-](\d{2})[ T](\d{2}):(\d{2}):(\d{2})")


def offsite_from_log(lines: list[str], task: str | None = None) -> dict | None:
    """The newest backup task result in Hyper Backup's log, as {at, ok}.

    Best effort: DSM's wording differs between versions, so a line counts when
    it says a backup task finished, completed or failed (and names [task],
    when given). None when nothing matches: the admin's date is used instead.
    """
    found = None
    for line in lines:
        low = line.lower()
        if "backup" not in low:
            continue
        if task and task.lower() not in low:
            continue
        if "fail" in low or "partially" in low or "cancel" in low:
            ok = False
        elif "finished successfully" in low or "completed" in low or "backup task finished" in low:
            ok = True
        else:
            continue
        m = _LOG_TIME.search(line)
        if not m:
            continue
        at = datetime(*map(int, m.groups()))
        if found is None or at >= found["at"]:
            found = {"at": at, "ok": ok}
    if found is None:
        return None
    return {"at": found["at"].isoformat(), "ok": found["ok"]}

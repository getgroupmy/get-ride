"""The GET.ride backup and uptime app on the office NAS (see README.md).

It only calls out, to the nas-ops edge function:
  1. pairs once with the code from Admin > Settings > Office NAS and keeps
     the key it gets in /data/state.json;
  2. checks in every minute: the box's numbers and the backups' state go up;
     the settings, the uptime targets and a waiting "Back up now" or "Run a
     restore test" come back;
  3. every night (the time set in Admin) dumps the database with pg_dump,
     copies the storage files that are new or changed, encrypts everything
     with the owner's age key (only its public half is on the NAS), keeps N
     nightly and M monthly copies, and reports the run;
  4. once a month restores that night's dump into the local test database
     (the restore-db container) and checks the tables came back;
  5. checks the uptime targets (every minute, as set in Admin) and reports.

The database's connection string and the storage service key are in .env on
the NAS and are never sent anywhere but to the database and storage
themselves.

    python agent.py               run
    python agent.py setup-key     make the encryption key (prints the secret half once)
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import queue
import shutil
import socket
import subprocess
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timezone
from pathlib import Path
from urllib.parse import quote
from zoneinfo import ZoneInfo

import requests

import core

VERSION = "1.0.0"
URL = os.environ.get("GETRIDE_URL", "").strip()
PROJECT = core.project_of(URL)
DATA = Path(os.environ.get("NAS_DATA", "/data"))
BACKUPS = Path(os.environ.get("BACKUP_DIR", "/backups"))
DATABASE_URL = os.environ.get("DATABASE_URL", "").strip()
SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_KEY", "").strip()
RESTORE_DB_URL = os.environ.get("RESTORE_DB_URL", "").strip() or (
    "postgresql://postgres:%s@restore-db:5432/postgres" % quote(os.environ.get("RESTORE_DB_PASSWORD", ""), safe=""))
DUMP_SCHEMAS = [s.strip() for s in os.environ.get("PG_DUMP_SCHEMAS", "public,auth,storage").split(",") if s.strip()]
HYPERBACKUP_LOG = os.environ.get("HYPERBACKUP_LOG", "").strip()
HYPERBACKUP_TASK = os.environ.get("HYPERBACKUP_TASK", "").strip() or None
LABEL = os.environ.get("NAS_LABEL", "").strip() or None
HEARTBEAT_SECONDS = 60

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("nas-backup")


# ---- State on the NAS -----------------------------------------------------------------------------

_state_lock = threading.Lock()


def state() -> dict:
    try:
        return json.loads((DATA / "state.json").read_text())
    except Exception:  # noqa: BLE001
        return {}


def save_state(**changes) -> bool:
    with _state_lock:
        s = state()
        s.update(changes)
        try:
            DATA.mkdir(parents=True, exist_ok=True)
            p = DATA / "state.json"
            tmp = p.with_suffix(".tmp")
            tmp.write_text(json.dumps(s))
            tmp.chmod(0o600)
            tmp.replace(p)
            return True
        except OSError as e:
            log.error("Can't save to %s (%s). Make the data folder and give it to the app (README.md, step 3).",
                      DATA, type(e).__name__)
            return False


def recipient() -> str | None:
    try:
        r = (DATA / "recipient.txt").read_text().strip()
        return r if r.startswith("age1") else None
    except OSError:
        return None


# ---- GET.ride ---------------------------------------------------------------------------------------

def call(action: str, key: str | None = None, **body) -> tuple[int, dict]:
    headers = {"content-type": "application/json"}
    if key:
        headers["x-nas-key"] = key
    r = requests.post(URL, json={"action": action, **body}, headers=headers, timeout=30)
    try:
        return r.status_code, r.json()
    except ValueError:
        return r.status_code, {}


def model() -> str:
    try:
        cpu = next(l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name"))
    except Exception:  # noqa: BLE001
        cpu = "unknown processor"
    return f"{socket.gethostname()} · {cpu}"


def pair() -> str | None:
    s = state()
    if s.get("key"):
        return s["key"]
    device = s.get("device_id") or str(uuid.uuid4())
    if not save_state(device_id=device):
        return None
    code = os.environ.get("PAIR_CODE", "").strip()
    if not code:
        log.info("Not connected. Make a code in Admin > Settings > Office NAS, put it in .env as PAIR_CODE and restart.")
        return None
    status, answer = call("pair", code=code, device_id=device, label=LABEL, model=model(), version=VERSION)
    if status != 200 or not answer.get("key"):
        log.warning("Pairing refused (%s): %s", status, answer.get("hint") or answer.get("error"))
        return None
    save_state(key=answer["key"], agent=answer.get("agent"))
    log.info("Connected as %s. You can remove PAIR_CODE from .env now.", answer.get("label"))
    return answer["key"]


# ---- Shell helpers ---------------------------------------------------------------------------------

def run(cmd: list[str], timeout: int, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)


def psql(url: str, sql: str, timeout: int = 60) -> str:
    r = run(["psql", url, "-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql], timeout)
    if r.returncode != 0:
        raise RuntimeError(_clean(r.stderr) or "psql failed")
    return r.stdout


def _clean(text: str) -> str:
    """An error for GET.ride, without the connection strings or keys."""
    out = text.strip().splitlines()[-1] if text.strip() else ""
    for secret in (DATABASE_URL, RESTORE_DB_URL, SERVICE_KEY):
        if secret:
            out = out.replace(secret, "••••")
    return out[:300]


def encrypt(src: Path, dst: Path, to: str) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + ".part")
    r = run(["age", "-r", to, "-o", str(tmp), str(src)], 3600)
    if r.returncode != 0:
        tmp.unlink(missing_ok=True)
        raise RuntimeError("Encrypting failed: " + _clean(r.stderr))
    tmp.replace(dst)


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_size(p: Path) -> int:
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) if p.exists() else 0


# ---- The database --------------------------------------------------------------------------------

def live_counts() -> dict[str, int]:
    """Rows in the key tables right now, for the restore test to compare."""
    out = {}
    for t in core.KEY_TABLES:
        try:
            out[t] = int(psql(DATABASE_URL, f'select count(*) from public."{t}"', 120).strip())
        except Exception:  # noqa: BLE001 (a table this backend doesn't have)
            continue
    return out


def dump(to: Path) -> None:
    args = ["pg_dump", "--format=custom", "--compress=6", "--file", str(to), "--dbname", DATABASE_URL]
    for s in DUMP_SCHEMAS:
        args += ["--schema", s]
    r = run(args, 4 * 3600)
    if r.returncode != 0:
        raise RuntimeError("pg_dump failed: " + _clean(r.stderr))


def restore_test(dump_file: Path, counts: dict[str, int]) -> core.Verdict:
    """Restores [dump_file] into the local test database and checks it."""
    toc = run(["pg_restore", "--list", str(dump_file)], 600)
    if toc.returncode != 0:
        return core.Verdict(False, "The dump can't be read: " + _clean(toc.stderr))
    expected = core.toc_tables(toc.stdout)
    try:
        psql(RESTORE_DB_URL, "select 1", 30)
    except Exception as e:  # noqa: BLE001
        return core.Verdict(False, f"The test database isn't running ({e})")
    r = run(["pg_restore", "--clean", "--if-exists", "--no-owner", "--no-privileges", "--jobs", "2",
             "--dbname", RESTORE_DB_URL, str(dump_file)], 4 * 3600)
    errors = core.restore_errors(r.stderr) if r.returncode != 0 else 0
    restored = [t for t in psql(RESTORE_DB_URL, "select tablename from pg_tables where schemaname = 'public'").split()]
    got = {}
    for t in counts:
        if t in restored:
            got[t] = int(psql(RESTORE_DB_URL, f'select count(*) from public."{t}"', 600).strip())
    return core.restore_verdict(expected, restored, counts, got, errors)


# ---- Storage ---------------------------------------------------------------------------------------

def _storage_headers() -> dict:
    return {"Authorization": f"Bearer {SERVICE_KEY}", "apikey": SERVICE_KEY}


def list_buckets() -> list[str]:
    r = requests.get(f"{PROJECT}/storage/v1/bucket", headers=_storage_headers(), timeout=30)
    r.raise_for_status()
    return [b.get("id") or b.get("name") for b in r.json() if isinstance(b, dict)]


def list_files(bucket: str) -> list[core.StoredFile]:
    out: list[core.StoredFile] = []
    folders = [""]
    while folders:
        folder = folders.pop()
        offset = 0
        while True:
            r = requests.post(f"{PROJECT}/storage/v1/object/list/{quote(bucket, safe='')}", headers=_storage_headers(),
                              json={"prefix": folder, "limit": 1000, "offset": offset,
                                    "sortBy": {"column": "name", "order": "asc"}}, timeout=60)
            r.raise_for_status()
            items = r.json() or []
            for it in items:
                if it.get("id") is None and it.get("name"):
                    folders.append(f"{folder}/{it['name']}" if folder else it["name"])
                else:
                    f = core.from_listing(bucket, f"{folder}/" if folder else "", it)
                    if f:
                        out.append(f)
            if len(items) < 1000:
                break
            offset += 1000
    return out


def copy_file(f: core.StoredFile, tmp: Path, to: str) -> int:
    url = f"{PROJECT}/storage/v1/object/{quote(f.bucket, safe='')}/{quote(f.path)}"
    part = tmp / "download"
    with requests.get(url, headers=_storage_headers(), timeout=300, stream=True) as r:
        r.raise_for_status()
        with open(part, "wb") as out:
            for chunk in r.iter_content(1 << 20):
                out.write(chunk)
    size = part.stat().st_size
    encrypt(part, BACKUPS / "storage" / f.bucket / (f.path + ".age"), to)
    part.unlink(missing_ok=True)
    return size


def copy_storage(skip: list[str], tmp: Path, to: str) -> dict:
    """New and changed files of every bucket not skipped. Files deleted on
    GET.ride stay in the copy (counted as gone upstream)."""
    manifest_file = DATA / "storage-manifest.json"
    try:
        manifest = json.loads(manifest_file.read_text())
    except Exception:  # noqa: BLE001
        manifest = {}
    seen = list_buckets()
    buckets = core.buckets_to_copy(seen, skip)
    files: list[core.StoredFile] = []
    per_bucket = {}
    for b in buckets:
        listed = list_files(b)
        per_bucket[b] = len(listed)
        files += listed
    todo = core.changed_files(files, manifest)
    copied = copied_bytes = 0
    failed: list[str] = []
    for f in todo:
        try:
            copied_bytes += copy_file(f, tmp, to)
            manifest[f.key] = f.signature
            copied += 1
        except Exception as e:  # noqa: BLE001
            failed.append(f"{f.key}: {type(e).__name__}")
        if copied and copied % 200 == 0:
            manifest_file.write_text(json.dumps(manifest))
    manifest_file.write_text(json.dumps(manifest))
    save_state(buckets=seen)
    return {"bucketsSeen": seen, "buckets": per_bucket, "copied": copied, "copiedBytes": copied_bytes,
            "failed": failed[:20], "goneUpstream": core.gone_upstream(files, manifest, buckets),
            "mirrorBytes": tree_size(BACKUPS / "storage")}


# ---- Jobs ------------------------------------------------------------------------------------------

class Worker:
    """Backups and restore tests, one at a time, beside the check-ins."""

    def __init__(self) -> None:
        self.jobs: queue.Queue = queue.Queue()
        self.running: str | None = None
        self.last_error: str | None = None
        self.key: str | None = None
        self.cfg: dict = {}
        threading.Thread(target=self._loop, daemon=True).start()

    def add(self, kind: str, trigger: str, request: str | None = None) -> None:
        if self.running == kind or any(j[0] == kind for j in list(self.jobs.queue)):
            return
        self.jobs.put((kind, trigger, request))

    def _loop(self) -> None:
        while True:
            kind, trigger, request = self.jobs.get()
            self.running = kind
            try:
                if kind == "backup":
                    self.backup(trigger, request)
                else:
                    self.restore(trigger, request)
            except Exception as e:  # noqa: BLE001
                log.warning("%s stopped: %s", kind, type(e).__name__)
            finally:
                self.running = None

    def _start(self, kind: str, trigger: str, request: str | None) -> str | None:
        status, answer = call("backup_start", self.key, kind=kind, trigger=trigger, request=request)
        return answer.get("run") if status == 200 else None

    def _finish(self, run_id: str | None, ok: bool, **fields) -> None:
        if not run_id:
            return
        for _ in range(5):
            try:
                call("backup_finish", self.key, run=run_id, ok=ok, **fields)
                return
            except requests.RequestException:
                time.sleep(30)

    def backup(self, trigger: str, request: str | None) -> None:
        cfg = self.cfg.get("backup") or {}
        tz = ZoneInfo(cfg.get("timezone") or "Asia/Kuala_Lumpur")
        save_state(last_backup_started=datetime.now(tz).isoformat())
        run_id = self._start("backup", trigger, request)
        to = recipient()
        tmp = BACKUPS / "tmp"
        started = time.monotonic()
        try:
            if not to:
                raise RuntimeError("No encryption key on the NAS: run setup-key (README.md, step 4)")
            if not DATABASE_URL:
                raise RuntimeError("DATABASE_URL isn't set in .env")
            shutil.rmtree(tmp, ignore_errors=True)
            tmp.mkdir(parents=True)
            tmp.chmod(0o700)
            today = datetime.now(tz).date()
            folder = BACKUPS / "nightly" / today.isoformat()

            counts = live_counts()
            plain = tmp / "db.dump"
            dump(plain)
            db_plain = plain.stat().st_size

            # The monthly restore test runs on tonight's dump, before it is encrypted.
            rt = cfg.get("restoreTest") or {}
            last_rt = state().get("last_restore_test")
            if trigger == "schedule" and rt.get("on", True) and core.restore_test_due(
                    today, int(rt.get("day") or 1), date.fromisoformat(last_rt) if last_rt else None):
                self._restore_on(plain, counts, "schedule", None)

            encrypt(plain, folder / "db.dump.age", to)
            plain.unlink(missing_ok=True)
            db_bytes = (folder / "db.dump.age").stat().st_size
            digest = sha256(folder / "db.dump.age")

            files = {"copied": 0, "copiedBytes": 0}
            if SERVICE_KEY:
                files = copy_storage(cfg.get("skipBuckets") or [], tmp, to)
            (folder / "manifest.json").write_text(json.dumps({
                "made": datetime.now(timezone.utc).isoformat(), "app": VERSION, "schemas": DUMP_SCHEMAS,
                "dbDumpBytes": db_plain, "sha256": digest, "rows": counts,
                "decrypt": "age -d -i your-key.txt -o db.dump db.dump.age; then pg_restore (README.md, Restoring)"},
                indent=2))

            names = [p.name for p in (BACKUPS / "nightly").iterdir() if p.is_dir()]
            pruned = core.to_prune(names, int(cfg.get("keepNightly") or 30), int(cfg.get("keepMonthly") or 12))
            for name in pruned:
                shutil.rmtree(BACKUPS / "nightly" / name, ignore_errors=True)
            kept = [n for n in names if n not in pruned]
            total = tree_size(folder) + int(files.get("copiedBytes") or 0)
            self.last_error = None
            minutes = (time.monotonic() - started) / 60
            log.info("Backup done in %.1f min: database %d MB, %d files copied", minutes, db_bytes // 2**20,
                     files.get("copied", 0))
            self._finish(run_id, True, db_bytes=db_bytes, files=files.get("copied", 0),
                         files_bytes=files.get("copiedBytes", 0), total_bytes=total,
                         detail={"date": today.isoformat(), "sha256": digest, "rows": counts, "storage": files,
                                 "kept": len(kept), "monthly": core.monthly_count(kept, int(cfg.get("keepMonthly") or 12)),
                                 "pruned": pruned, "minutes": round(minutes, 1)})
        except Exception as e:  # noqa: BLE001
            self.last_error = _clean(str(e)) or type(e).__name__
            log.warning("Backup failed: %s", self.last_error)
            self._finish(run_id, False, error=self.last_error)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def _restore_on(self, plain: Path, counts: dict, trigger: str, request: str | None) -> None:
        run_id = self._start("restore_test", trigger, request)
        tz = ZoneInfo((self.cfg.get("backup") or {}).get("timezone") or "Asia/Kuala_Lumpur")
        save_state(last_restore_test=datetime.now(tz).date().isoformat())
        try:
            v = restore_test(plain, counts)
        except Exception as e:  # noqa: BLE001
            v = core.Verdict(False, _clean(str(e)) or type(e).__name__)
        log.info("Restore test %s: %s", "passed" if v.ok else "failed", v.summary)
        self._finish(run_id, v.ok, error=None if v.ok else v.summary, detail={"summary": v.summary, **v.detail})

    def restore(self, trigger: str, request: str | None) -> None:
        """A restore test on demand: a fresh dump, restored and checked, then deleted."""
        tmp = BACKUPS / "tmp-restore"
        shutil.rmtree(tmp, ignore_errors=True)
        try:
            tmp.mkdir(parents=True)
            tmp.chmod(0o700)
            counts = live_counts()
            plain = tmp / "db.dump"
            dump(plain)
            self._restore_on(plain, counts, trigger, request)
        except Exception as e:  # noqa: BLE001
            run_id = self._start("restore_test", trigger, request)
            self._finish(run_id, False, error=_clean(str(e)) or type(e).__name__)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


# ---- Uptime ----------------------------------------------------------------------------------------

def check(t: dict) -> dict:
    slow = int(t.get("slowMs") or 3000)
    started = time.monotonic()
    if t.get("kind") == "database":
        try:
            psql(DATABASE_URL, "select 1", 10)
            ms = int((time.monotonic() - started) * 1000)
            return {"id": t["id"], "status": "slow" if ms >= slow else "up", "ms": ms, "detail": f"Answered in {ms} ms"}
        except Exception as e:  # noqa: BLE001
            return {"id": t["id"], "status": "down", "ms": None, "detail": ("Query failed: " + _clean(str(e)))[:200]}
    url = core.fill_url(t.get("url"), PROJECT)
    status, error = None, None
    try:
        r = requests.get(url, timeout=10, allow_redirects=True, headers={"user-agent": "get.ride uptime monitor (NAS)"})
        status = r.status_code
    except requests.Timeout:
        error = "No answer in 10 s"
    except Exception as e:  # noqa: BLE001
        error = f"Couldn't connect ({type(e).__name__})"
    ms = int((time.monotonic() - started) * 1000)
    return {"id": t["id"], "status": core.classify(status, ms, slow, error), "ms": ms,
            "detail": error or f"HTTP {status} in {ms} ms"}


def check_all(targets: list[dict]) -> list[dict]:
    with ThreadPoolExecutor(max_workers=8) as pool:
        return list(pool.map(check, [t for t in targets if t.get("id")]))


# ---- The box ---------------------------------------------------------------------------------------

def box() -> dict:
    out: dict = {"model": model()}
    try:
        used, total = core.meminfo(Path("/proc/meminfo").read_text()) or (None, None)
        out.update(memUsedMb=used, memTotalMb=total)
        a = Path("/proc/stat").read_text().splitlines()[0]
        time.sleep(0.5)
        b = Path("/proc/stat").read_text().splitlines()[0]
        out["cpuPct"] = core.cpu_busy(a, b)
    except Exception:  # noqa: BLE001
        pass
    try:
        du = shutil.disk_usage(BACKUPS)
        out.update(diskFreeBytes=du.free, diskTotalBytes=du.total)
    except OSError:
        pass
    temps = []
    for z in Path("/sys/class/thermal").glob("thermal_zone*/temp"):
        try:
            temps.append(int(z.read_text().strip()) / 1000)
        except (OSError, ValueError):
            pass
    if temps:
        out["tempC"] = round(max(temps))
    return out


def offsite() -> dict | None:
    if not HYPERBACKUP_LOG:
        return None
    try:
        with open(HYPERBACKUP_LOG, errors="replace") as f:
            lines = f.readlines()[-5000:]
        found = core.offsite_from_log(lines, HYPERBACKUP_TASK)
        return {**found, "source": "log"} if found else None
    except OSError:
        return None


def services(worker: Worker, last_uptime: dict) -> dict:
    s = state()
    cfg = worker.cfg.get("backup") or {}
    tz = ZoneInfo(cfg.get("timezone") or "Asia/Kuala_Lumpur")
    nightly = [p.name for p in (BACKUPS / "nightly").iterdir() if p.is_dir()] if (BACKUPS / "nightly").exists() else []
    keep_m = int(cfg.get("keepMonthly") or 12)
    status = "running" if worker.running else ("failed" if worker.last_error else ("setup" if not recipient() else "ok"))
    return {
        "backup": {"status": status, "detail": {
            "running": worker.running, "keyReady": recipient() is not None, "lastError": worker.last_error,
            "buckets": s.get("buckets") or [], "storage": bool(SERVICE_KEY), "database": bool(DATABASE_URL),
            "nextRunAt": core.next_backup_at(datetime.now(tz), cfg.get("at")).isoformat() if cfg.get("on", True) else None,
            "lastRestoreTest": s.get("last_restore_test"), "nightly": len(nightly),
            "monthly": core.monthly_count(nightly, keep_m), "offsite": offsite()}},
        "uptime": {"status": "ok" if last_uptime.get("at") else "starting", "detail": last_uptime},
        "box": {"status": "ok", "detail": box()},
    }


# ---- Main -----------------------------------------------------------------------------------------

def setup_key(replace: bool) -> None:
    if recipient() and not replace:
        print("There is already a key (data/recipient.txt). Run with --replace to make a new one: backups made "
              "with the old key still need the old secret.")
        sys.exit(1)
    r = run(["age-keygen"], 30)
    if r.returncode != 0:
        print("age-keygen failed:", r.stderr)
        sys.exit(1)
    secret = "\n".join(l for l in r.stdout.splitlines() if l.startswith("AGE-SECRET-KEY-"))
    public = next(l.split(":", 1)[1].strip() for l in (r.stdout + r.stderr).splitlines() if "public key:" in l)
    DATA.mkdir(parents=True, exist_ok=True)
    (DATA / "recipient.txt").write_text(public + "\n")
    print("\n" + "=" * 72)
    print("YOUR BACKUP KEY. It is shown once and is NOT kept on the NAS.")
    print("Copy it now into your password manager (and a printed copy in a safe).")
    print("Without it nobody, not even you, can open the backups.\n")
    print(secret)
    print("\nPublic half (kept on the NAS, only locks): " + public)
    print("=" * 72 + "\n")


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "setup-key":
        setup_key("--replace" in sys.argv)
        return
    if not URL.startswith("https://"):
        log.error("Set GETRIDE_URL in .env (see README.md).")
        sys.exit(2)
    log.info("GET.ride NAS backup and uptime %s, %s", VERSION, model())
    if not recipient():
        log.warning("No encryption key yet: run setup-key (README.md, step 4). Backups wait for it.")
    worker = Worker()
    key = None
    last_beat = 0.0
    last_uptime_run = 0.0
    last_uptime: dict = {}
    while True:
        try:
            if key is None:
                key = pair()
                if key is None:
                    time.sleep(60)
                    continue
                worker.key = key
            if time.monotonic() - last_beat >= HEARTBEAT_SECONDS:
                status, beat = call("heartbeat", key, model=model(), version=VERSION,
                                    services=services(worker, last_uptime))
                if status == 401:
                    raise PermissionError(beat.get("hint"))
                if status == 200:
                    worker.cfg = beat
                    for req in beat.get("requests") or []:
                        worker.add(req.get("kind"), "manual", req.get("id"))
                last_beat = time.monotonic()
            cfg = worker.cfg.get("backup") or {}
            if cfg and cfg.get("on", True) and recipient():
                tz = ZoneInfo(cfg.get("timezone") or "Asia/Kuala_Lumpur")
                last = state().get("last_backup_started")
                if core.backup_due(datetime.now(tz), cfg.get("at"), datetime.fromisoformat(last) if last else None):
                    worker.add("backup", "schedule")
            every = 60 * int((worker.cfg.get("uptime") or {}).get("nasEveryMinutes") or 1)
            targets = worker.cfg.get("targets") or []
            if targets and time.monotonic() - last_uptime_run >= every:
                last_uptime_run = time.monotonic()
                results = check_all(targets)
                call("uptime_report", key, results=results)
                last_uptime = {"at": datetime.now(timezone.utc).isoformat(), "targets": len(results),
                               "down": [r["id"] for r in results if r["status"] == "down"]}
            time.sleep(5)
        except PermissionError as e:
            log.warning("This NAS app was disconnected in Admin (%s). Put a new PAIR_CODE in .env and restart.", e)
            save_state(key=None)
            key = None
            time.sleep(60)
        except requests.RequestException as e:
            log.warning("GET.ride can't be reached (%s); trying again in a minute.", type(e).__name__)
            time.sleep(60)


if __name__ == "__main__":
    main()

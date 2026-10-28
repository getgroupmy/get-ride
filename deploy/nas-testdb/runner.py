"""The GET.ride test database runner on the office NAS (see README.md).

It only calls out, to the nas-testdb edge function and (read-only) GitHub:
  1. pairs once with the code from Admin > Settings > Office NAS > Test
     database and keeps the key it gets in /data/key.json;
  2. checks in every minute (the admin page shows it online, with its copy);
  3. every night at the time set in Admin, restores the newest backup from
     the backups folder (deploy/nas-backup) into the local Postgres, or, if
     there is none fresh enough, takes a pg_dump of the live database with
     the read-only connection string in .env; then scrambles personal data
     (scramble.sql) when Admin says so, and swaps the new copy in;
  4. when an admin asks to try a PR's migrations, fetches that PR's new or
     changed files in supabase/migrations from GitHub, applies them in order
     to a throw-away copy of the copy, runs them a second time (they must be
     re-runnable), and reports pass / fail, the error and the time.

The database container has no internet; only this runner does.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import socket
import subprocess
import sys
import time
import uuid
from datetime import datetime
from pathlib import Path
from urllib.parse import quote, urlsplit, urlunsplit

import requests

from core import (BackupFile, backup_kind, is_fork, migration_files, next_refresh, pick_backup, psql_error, redact,
                  refresh_due, target_text)

VERSION = "1.0.0"
URL = os.environ.get("GETRIDE_URL", "").strip()
DATA = Path(os.environ.get("RUNNER_DATA", "/data"))
WORK = Path(os.environ.get("RUNNER_WORK", "/work"))
BACKUP_DIR = Path(os.environ.get("BACKUP_DIR", "/backups"))
BACKUP_MAX_AGE_HOURS = float(os.environ.get("BACKUP_MAX_AGE_HOURS", "36") or 36)
LABEL = os.environ.get("RUNNER_LABEL", "").strip() or None
LOCAL_DB_URL = os.environ.get("LOCAL_DB_URL", "").strip()
SOURCE_DB_URL = os.environ.get("SOURCE_DB_URL", "").strip()
GITHUB_REPO = os.environ.get("GITHUB_REPO", "getgroupmy/get-ride").strip()
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "").strip()
SINGLE_TRANSACTION = os.environ.get("SINGLE_TRANSACTION", "1").strip() != "0"
HEARTBEAT_SECONDS = 60
COPY_DB = "getride_test"
NEXT_DB = "getride_next"
OLD_DB = "getride_old"
TRY_DB = "getride_try"
# Only the parts of the live database the app is: its tables and functions,
# sign-in users, storage's file list. Sessions and tokens never come along.
DUMP_SCHEMAS = ["public", "auth", "storage"]
DUMP_SKIP_DATA = ["auth.sessions", "auth.refresh_tokens", "auth.one_time_tokens", "auth.mfa_challenges",
                  "auth.mfa_amr_claims", "auth.flow_state", "auth.audit_log_entries", "auth.saml_relay_states"]

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("nas-testdb")
SECRETS = [p for p in (urlsplit(LOCAL_DB_URL).password, urlsplit(SOURCE_DB_URL).password, GITHUB_TOKEN) if p]


def model() -> str:
    try:
        cpu = next(line.split(":", 1)[1].strip() for line in open("/proc/cpuinfo") if line.startswith("model name"))
    except Exception:  # noqa: BLE001
        cpu = "unknown processor"
    return f"{socket.gethostname()} · {cpu}"


# ---- Saved state -------------------------------------------------------------------------------
def state() -> dict:
    try:
        return json.loads((DATA / "key.json").read_text())
    except Exception:  # noqa: BLE001
        return {}


def save_state(s: dict) -> bool:
    try:
        DATA.mkdir(parents=True, exist_ok=True)
        p = DATA / "key.json"
        p.write_text(json.dumps(s))
        p.chmod(0o600)
        return True
    except OSError as e:
        log.error("Can't save to %s (%s). Make the data folder next to docker-compose.yml and give it to the runner "
                  "(README.md, step 4), then restart.", DATA, type(e).__name__)
        return False


def remember(**kv) -> None:
    s = state()
    s.update(kv)
    save_state(s)


# ---- get.ride ---------------------------------------------------------------------------------
def call(action: str, key: str | None = None, **body) -> tuple[int, dict]:
    headers = {"content-type": "application/json"}
    if key:
        headers["x-runner-key"] = key
    r = requests.post(URL, json={"action": action, **body}, headers=headers, timeout=30)
    try:
        return r.status_code, r.json()
    except ValueError:
        return r.status_code, {}


def pair() -> str | None:
    s = state()
    if s.get("key"):
        return s["key"]
    code = os.environ.get("PAIR_CODE", "").strip()
    device = s.get("device_id") or str(uuid.uuid4())
    if not save_state({**s, "device_id": device}):
        return None
    if not code:
        log.info("Not connected. Make a code in Admin > Settings > Office NAS > Test database, put it in .env as "
                 "PAIR_CODE and restart.")
        return None
    status, answer = call("pair", code=code, device_id=device, label=LABEL, model=model(), version=VERSION)
    if status != 200 or not answer.get("key"):
        log.warning("Pairing refused (%s): %s", status, answer.get("hint") or answer.get("error"))
        return None
    remember(device_id=device, key=answer["key"], runner=answer.get("runner"))
    log.info("Connected as %s. You can remove PAIR_CODE from .env now.", answer.get("label"))
    return answer["key"]


# ---- Local Postgres --------------------------------------------------------------------------
def db_url(name: str) -> str:
    u = urlsplit(LOCAL_DB_URL)
    return urlunsplit((u.scheme, u.netloc, "/" + quote(name), u.query, u.fragment))


def run(args: list[str], *, timeout: int = 3600, env: dict | None = None, stdin=None) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, env={**os.environ, **(env or {})},
                          stdin=stdin, check=False)


def sql(db: str, statement: str, *, timeout: int = 600) -> str:
    r = run(["psql", db_url(db), "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-c", statement], timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(redact(psql_error(r.stderr), SECRETS))
    return r.stdout.strip()


def exists(db: str) -> bool:
    return sql("postgres", f"select 1 from pg_database where datname = '{db}'") == "1"


def drop(db: str) -> None:
    sql("postgres", f"select pg_terminate_backend(pid) from pg_stat_activity where datname = '{db}' "
                    f"and pid <> pg_backend_pid()")
    sql("postgres", f'drop database if exists "{db}"')


def copy_info() -> dict:
    if not exists(COPY_DB):
        return {}
    return {
        "size_bytes": int(sql(COPY_DB, "select pg_database_size(current_database())") or 0),
        "tables": int(sql(COPY_DB, "select count(*) from pg_tables where schemaname = 'public'") or 0),
    }


# ---- Nightly refresh --------------------------------------------------------------------------
def find_backup() -> BackupFile | None:
    if not BACKUP_DIR.is_dir():
        return None
    files = []
    for p in BACKUP_DIR.rglob("*"):
        if p.is_file() and backup_kind(p.name):
            st = p.stat()
            files.append(BackupFile(str(p), datetime.fromtimestamp(st.st_mtime), st.st_size))
    return pick_backup(files, datetime.now(), BACKUP_MAX_AGE_HOURS)


def dump_live() -> Path:
    """pg_dump of the live database with the read-only connection string."""
    if not SOURCE_DB_URL:
        raise RuntimeError("No fresh backup in the backups folder, and no SOURCE_DB_URL in .env to dump from.")
    WORK.mkdir(parents=True, exist_ok=True)
    out = WORK / "live.dump"
    args = ["pg_dump", SOURCE_DB_URL, "-Fc", "--no-subscriptions", "--no-publications", "-f", str(out)]
    for s in DUMP_SCHEMAS:
        args += ["-n", s]
    for t in DUMP_SKIP_DATA:
        args += ["--exclude-table-data", t]
    r = run(args, timeout=4 * 3600)
    if r.returncode != 0:
        raise RuntimeError("pg_dump failed: " + redact(r.stderr.strip()[-800:], SECRETS))
    return out


def restore(source: Path, kind: str) -> int:
    """Restores into NEXT_DB; returns how many statements failed (pg_restore
    carries on past an object Supabase's own image already has)."""
    if kind == "custom":
        args = ["pg_restore", "-d", db_url(NEXT_DB), "--no-subscriptions", "--no-publications", "-j", "2"]
        for s in DUMP_SCHEMAS:
            args += ["-n", s]
        r = run(args + [str(source)], timeout=4 * 3600)
        text = r.stderr
    else:
        with open(source, "rb") as f:
            if kind == "gzip":
                z = subprocess.Popen(["gunzip", "-c"], stdin=f, stdout=subprocess.PIPE)
                r = run(["psql", db_url(NEXT_DB), "-X", "-q"], timeout=4 * 3600, stdin=z.stdout)
                z.wait()
            else:
                r = run(["psql", db_url(NEXT_DB), "-X", "-q"], timeout=4 * 3600, stdin=f)
        text = r.stderr
    errors = sum(1 for line in text.splitlines() if "ERROR:" in line)
    if kind == "custom" and r.returncode not in (0, 1):
        raise RuntimeError("pg_restore failed: " + redact(psql_error(text), SECRETS))
    return errors


def refresh(key: str, settings: dict, run_id: str | None) -> None:
    started = time.monotonic()
    scramble = settings.get("scramble", True) is not False
    detail: dict = {"scrambled": scramble}
    remember(busy="refreshing the copy")
    beat(key)
    try:
        backup = find_backup()
        if backup:
            source, kind = Path(backup.path), backup_kind(backup.path)
            detail["source"] = f"backup {Path(backup.path).name}"
        else:
            source, kind = dump_live(), "custom"
            detail["source"] = "pg_dump"
        log.info("Refreshing the copy from %s", detail["source"])
        drop(NEXT_DB)
        sql("postgres", f'create database "{NEXT_DB}"')
        # Every session in the copy knows it is one (scramble.sql checks).
        sql("postgres", f"alter database \"{NEXT_DB}\" set getride.test_copy = 'yes'")
        r = run(["psql", db_url(NEXT_DB), "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", "/app/prepare.sql"])
        if r.returncode != 0:
            raise RuntimeError(redact(psql_error(r.stderr), SECRETS))
        detail["restore_errors"] = restore(source, kind)
        if scramble:
            r = run(["psql", db_url(NEXT_DB), "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", "/app/scramble.sql"],
                    timeout=3 * 3600)
            if r.returncode != 0:
                # A copy that should be scrambled and isn't is never kept.
                drop(NEXT_DB)
                raise RuntimeError("Scrambling failed, copy not kept: " + redact(psql_error(r.stderr), SECRETS))
        # Swap: the old copy goes only once the new one is ready.
        drop(OLD_DB)
        if exists(COPY_DB):
            drop(TRY_DB)
            sql("postgres", f"select pg_terminate_backend(pid) from pg_stat_activity where datname = '{COPY_DB}'")
            sql("postgres", f'alter database "{COPY_DB}" rename to "{OLD_DB}"')
        sql("postgres", f'alter database "{NEXT_DB}" rename to "{COPY_DB}"')
        drop(OLD_DB)
        if detail["source"] == "pg_dump":
            (WORK / "live.dump").unlink(missing_ok=True)
        info = copy_info()
        detail.update(info)
        ms = int((time.monotonic() - started) * 1000)
        remember(refreshed_at=datetime.now().astimezone().isoformat(), scrambled=scramble, busy="", **info,
                 source=detail["source"])
        call("report", key, id=run_id, kind="refresh", ok=True, ms=ms, detail=detail)
        log.info("Copy refreshed in %d s (%s)", ms // 1000, detail)
    except Exception as e:  # noqa: BLE001
        ms = int((time.monotonic() - started) * 1000)
        error = redact(str(e), SECRETS)[:4000]
        remember(busy="", last_refresh_attempt=datetime.now().astimezone().isoformat())
        log.warning("Refresh failed: %s", error)
        call("report", key, id=run_id, kind="refresh", ok=False, ms=ms, error=error, detail=detail)


# ---- Trying a PR's migrations -------------------------------------------------------------------
def github(path: str, *, raw: bool = False, params: dict | None = None) -> requests.Response:
    headers = {"Accept": "application/vnd.github.raw" if raw else "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28"}
    if GITHUB_TOKEN:
        headers["Authorization"] = f"Bearer {GITHUB_TOKEN}"
    r = requests.get(f"https://api.github.com/repos/{GITHUB_REPO}{path}", headers=headers, params=params, timeout=30)
    if r.status_code in (401, 403, 404):
        raise RuntimeError(f"GitHub said {r.status_code} for {path.split('?')[0]}: check GITHUB_TOKEN and GITHUB_REPO "
                           "(README.md, step 2).")
    r.raise_for_status()
    return r


def pr_migrations(run_row: dict) -> tuple[str, list[str]]:
    """The head commit and the migration files to try, in order."""
    if run_row.get("pr_number"):
        n = int(run_row["pr_number"])
        pr = github(f"/pulls/{n}").json()
        if is_fork(pr):
            raise RuntimeError(f"PR #{n} comes from another repository; it isn't run on the NAS.")
        sha = pr["head"]["sha"]
        files: list[dict] = []
        for page in range(1, 31):
            batch = github(f"/pulls/{n}/files", params={"per_page": 100, "page": page}).json()
            files += batch
            if len(batch) < 100:
                break
    else:
        branch = run_row["branch"]
        repo = github("").json()
        cmp = github(f"/compare/{quote(repo['default_branch'], safe='')}...{quote(branch, safe='')}").json()
        sha = (cmp.get("commits") or [{}])[-1].get("sha") or cmp.get("merge_base_commit", {}).get("sha")
        files = cmp.get("files") or []
    return sha, migration_files(files)


def apply(db: str, path: Path) -> tuple[bool, int, str]:
    args = ["psql", db_url(db), "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(path)]
    if SINGLE_TRANSACTION:
        args.insert(-2, "--single-transaction")
    t0 = time.monotonic()
    r = run(args, timeout=1800)
    return r.returncode == 0, int((time.monotonic() - t0) * 1000), redact(psql_error(r.stderr), SECRETS)


def try_migrations(key: str, run_row: dict) -> None:
    started = time.monotonic()
    what = target_text(run_row)
    remember(busy=f"trying {what}")
    beat(key)
    sha, files, detail = None, [], {"steps": []}
    try:
        if not exists(COPY_DB):
            raise RuntimeError("No test copy yet: wait for tonight's refresh or press Refresh the copy now.")
        sha, files = pr_migrations(run_row)
        if not files:
            raise RuntimeError(f"{what} changes no file in supabase/migrations.")
        folder = WORK / "try"
        shutil.rmtree(folder, ignore_errors=True)
        folder.mkdir(parents=True)
        local = []
        for f in files:
            p = folder / Path(f).name
            p.write_bytes(github(f"/contents/{quote(f)}", raw=True, params={"ref": sha}).content)
            local.append(p)
        drop(TRY_DB)
        sql("postgres", f"select pg_terminate_backend(pid) from pg_stat_activity where datname = '{COPY_DB}'")
        sql("postgres", f'create database "{TRY_DB}" template "{COPY_DB}"')
        log.info("Trying %s (%s): %s", what, sha[:7] if sha else "?", ", ".join(p.name for p in local))
        ok, error = True, None
        for p in local:
            good, ms, err = apply(TRY_DB, p)
            detail["steps"].append({"file": p.name, "ok": good, "ms": ms})
            if not good:
                ok, error = False, f"{p.name}: {err}"
                break
        if ok:
            # Migrations here must be re-runnable: the same files again.
            for p in local:
                good, _, err = apply(TRY_DB, p)
                if not good:
                    detail["rerun"] = f"failed: {p.name}: {err}"[:1500]
                    break
            else:
                detail["rerun"] = "ok"
        drop(TRY_DB)
        ms = int((time.monotonic() - started) * 1000)
        migrate_ms = sum(s["ms"] for s in detail["steps"])
        call("report", key, id=run_row["id"], kind="migration", ok=ok, ms=migrate_ms, error=error,
             detail={**detail, "total_ms": ms}, head_sha=sha, files=files)
        log.info("%s %s in %.1f s", what, "passed" if ok else "failed", migrate_ms / 1000)
    except Exception as e:  # noqa: BLE001
        error = redact(str(e), SECRETS)[:4000]
        try:
            drop(TRY_DB)
        except Exception:  # noqa: BLE001
            pass
        log.warning("%s couldn't be tried: %s", what, error)
        call("report", key, id=run_row["id"], kind="migration", ok=False, error=error,
             ms=int((time.monotonic() - started) * 1000), detail=detail, head_sha=sha, files=files)
    finally:
        remember(busy="")


# ---- The loop ----------------------------------------------------------------------------------
def beat(key: str) -> dict:
    s = state()
    payload = {k: s[k] for k in ("refreshed_at", "size_bytes", "tables", "scrambled", "source", "busy") if k in s}
    if s.get("settings", {}).get("refreshAt"):
        payload["next_refresh_at"] = next_refresh(datetime.now(), s["settings"]["refreshAt"]).astimezone().isoformat()
    status, answer = call("heartbeat", key, model=model(), version=VERSION, state=payload)
    if status == 401:
        raise PermissionError(answer.get("hint"))
    if answer.get("settings"):
        remember(settings=answer["settings"])
    return answer


def main() -> None:
    if not URL.startswith("https://"):
        log.error("Set GETRIDE_URL in .env (see README.md).")
        sys.exit(2)
    if not LOCAL_DB_URL:
        log.error("Set LOCAL_DB_URL in .env (see README.md).")
        sys.exit(2)
    log.info("GET.ride test database runner %s, %s", VERSION, model())
    remember(busy="")
    key = None
    last_beat = 0.0
    while True:
        try:
            if key is None:
                key = pair()
                if key is None:
                    time.sleep(60)
                    continue
            if time.monotonic() - last_beat >= HEARTBEAT_SECONDS:
                beat(key)
                last_beat = time.monotonic()
            s = state()
            settings = s.get("settings") or {}
            # A failed refresh waits for the next night (or Refresh now) too.
            tried = [datetime.fromisoformat(v).replace(tzinfo=None)
                     for v in (s.get("refreshed_at"), s.get("last_refresh_attempt")) if v]
            if settings and refresh_due(datetime.now(), settings.get("refreshAt"), max(tried, default=None)):
                refresh(key, settings, None)
                continue
            status, answer = call("claim", key)
            if status == 401:
                raise PermissionError(answer.get("hint"))
            job = answer.get("run") if status == 200 else None
            if job and job.get("kind") == "refresh":
                refresh(key, settings, job["id"])
            elif job:
                try_migrations(key, job)
            time.sleep(min(60, max(5, int(answer.get("pollAfter") or 60))))
        except PermissionError as e:
            log.warning("This runner was disconnected in Admin (%s). Put a new PAIR_CODE in .env and restart.", e)
            save_state({"device_id": state().get("device_id")})
            key = None
            time.sleep(60)
        except requests.RequestException as e:
            log.warning("get.ride or GitHub can't be reached (%s); trying again in a minute.", type(e).__name__)
            time.sleep(60)


if __name__ == "__main__":
    main()

"""The runner's decisions (core.py): pytest deploy/nas-testdb/test_core.py"""

from datetime import datetime, timedelta

from core import (BackupFile, backup_kind, is_fork, last_slot, migration_files, next_refresh, parse_hhmm,
                  pick_backup, psql_error, redact, refresh_due, target_text)

NOW = datetime(2026, 10, 28, 9, 0)


def test_time_from_admin():
    assert parse_hhmm("7:05").strftime("%H:%M") == "07:05"
    assert parse_hhmm("25:00").strftime("%H:%M") == "02:30"
    assert parse_hhmm(None).strftime("%H:%M") == "02:30"


def test_refresh_due_once_a_night():
    assert last_slot(NOW, "02:30") == datetime(2026, 10, 28, 2, 30)
    assert last_slot(datetime(2026, 10, 28, 1, 0), "02:30") == datetime(2026, 10, 27, 2, 30)
    assert refresh_due(NOW, "02:30", None), "no copy yet"
    assert not refresh_due(NOW, "02:30", datetime(2026, 10, 28, 2, 41)), "done tonight"
    assert refresh_due(NOW, "02:30", datetime(2026, 10, 27, 2, 41)), "the NAS was off at 02:30: catch up"
    assert not refresh_due(datetime(2026, 10, 28, 2, 29), "02:30", datetime(2026, 10, 27, 2, 41)), "not yet"
    assert refresh_due(datetime(2026, 10, 28, 2, 30), "02:30", datetime(2026, 10, 27, 2, 41))
    assert next_refresh(NOW, "02:30") == datetime(2026, 10, 29, 2, 30)


def test_newest_fresh_backup():
    files = [
        BackupFile("/backups/db/2026-10-27.dump", NOW - timedelta(hours=31), 5_000_000),
        BackupFile("/backups/db/2026-10-28.dump", NOW - timedelta(hours=7), 5_000_000),
        BackupFile("/backups/db/2026-10-28b.dump.part", NOW - timedelta(hours=1), 5_000_000),
        BackupFile("/backups/storage/ids.tar", NOW - timedelta(hours=1), 9_000_000),
        BackupFile("/backups/db/empty.sql.gz", NOW - timedelta(hours=1), 20),
    ]
    assert pick_backup(files, NOW).path == "/backups/db/2026-10-28.dump"
    assert pick_backup(files[:1], NOW, max_age_hours=24) is None, "too old: pg_dump instead"
    assert backup_kind("x.sql.gz") == "gzip" and backup_kind("x.SQL") == "plain" and backup_kind("x.backup") == "custom"
    assert backup_kind("x.tar") is None


def test_migrations_of_a_pr_in_order():
    files = [
        {"filename": "supabase/migrations/0322_b.sql", "status": "added"},
        {"filename": "supabase/migrations/0321_a.sql", "status": "modified"},
        {"filename": "supabase/migrations/0300_old.sql", "status": "removed"},
        {"filename": "supabase/tests/a_0321.sql", "status": "added"},
        {"filename": "supabase/migrations/sub/x.sql", "status": "added"},
        {"filename": "lib/main.dart", "status": "modified"},
    ]
    assert migration_files(files) == ["supabase/migrations/0321_a.sql", "supabase/migrations/0322_b.sql"]
    assert migration_files([]) == []


def test_forks_are_not_run():
    same = {"head": {"repo": {"full_name": "getgroupmy/get-ride"}}, "base": {"repo": {"full_name": "getgroupmy/get-ride"}}}
    fork = {"head": {"repo": {"full_name": "someone/get-ride"}}, "base": {"repo": {"full_name": "getgroupmy/get-ride"}}}
    assert not is_fork(same) and is_fork(fork)


def test_the_error_admin_sees():
    out = """NOTICE:  relation "x" already exists, skipping
psql:/work/try/0321_a.sql:42: ERROR:  column "nope" does not exist
LINE 3:   select nope from public.profiles;
                 ^
CONTEXT:  PL/pgSQL function inline_code_block line 5 at SQL statement
"""
    e = psql_error(out)
    assert e.startswith('ERROR:  column "nope" does not exist')
    assert "LINE 3" in e and "CONTEXT" in e and "NOTICE" not in e
    assert psql_error("could not connect to server") == "could not connect to server"
    assert psql_error("") == ""
    assert len(psql_error("ERROR: " + "x" * 5000)) == 1500


def test_secrets_never_reported():
    msg = "pg_dump: error: connection to postgresql://postgres.abc:Sup3rS3cret@pooler.supabase.com:5432/postgres failed"
    assert "Sup3rS3cret" not in redact(msg)
    assert redact("token ghp_abcdef123 refused", ["ghp_abcdef123"]) == "token *** refused"


def test_target_text():
    assert target_text({"pr_number": 554}) == "PR #554"
    assert target_text({"branch": "claude/x"}) == "branch claude/x"

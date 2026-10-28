"""pytest deploy/nas-backup/test_core.py: when backups run, what is kept,
which files are copied, what a restore test and an uptime check mean. No
network, no database. All data is made up."""

from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from core import (StoredFile, backup_due, buckets_to_copy, changed_files, classify, cpu_busy, fill_url,
                  from_listing, gone_upstream, meminfo, monthly_count, next_backup_at, offsite_from_log, parse_at,
                  project_of, restore_errors, restore_test_due, restore_verdict, to_prune, toc_tables)

KL = ZoneInfo("Asia/Kuala_Lumpur")


def at(day: int, hh: int, mm: int = 0) -> datetime:
    return datetime(2026, 10, day, hh, mm, tzinfo=KL)


def test_time_of_day():
    assert parse_at("03:30") == time(3, 30)
    assert parse_at("24:00") == time(2, 0)
    assert parse_at(None) == time(2, 0)


def test_backup_due():
    assert backup_due(at(28, 1, 59), "02:00", at(27, 2, 0)) is False, "before tonight's time"
    assert backup_due(at(28, 2, 0), "02:00", at(27, 2, 0)) is True
    assert backup_due(at(28, 2, 5), "02:00", at(28, 2, 0)) is False, "already started tonight"
    assert backup_due(at(28, 14, 0), "02:00", at(27, 2, 1)) is True, "the NAS was off at 02:00: it catches up"
    assert backup_due(at(28, 1, 0), "02:00", at(26, 2, 0)) is True, "last night's was missed"
    assert backup_due(at(28, 1, 0), "02:00", None) is True, "the first one runs at once"
    assert next_backup_at(at(28, 1, 0), "02:00") == at(28, 2, 0)
    assert next_backup_at(at(28, 3, 0), "02:00") == at(29, 2, 0)


def test_restore_test_due():
    assert restore_test_due(date(2026, 11, 1), 1, date(2026, 10, 1)) is True
    assert restore_test_due(date(2026, 11, 2), 1, date(2026, 11, 1)) is False, "once a month"
    assert restore_test_due(date(2026, 11, 3), 5, None) is False, "not before its day"
    assert restore_test_due(date(2026, 11, 9), 5, date(2026, 10, 5)) is True, "a missed day catches up"
    assert restore_test_due(date(2026, 2, 28), 31, None) is True, "day 31 means 28"


def test_what_is_kept():
    days = [(date(2026, 10, 28) - timedelta(days=i)).isoformat() for i in range(120)]
    gone = to_prune(days + ["tmp", "notes"], 30, 3)
    kept = sorted(set(days) - set(gone))
    assert len(kept) == 30 + 2, "30 nightly (1 Oct among them) and the firsts of September and August"
    assert "2026-10-01" in kept and "2026-09-01" in kept and "2026-08-01" in kept
    assert "2026-07-01" not in kept
    assert "tmp" not in gone and "notes" not in gone, "only dated folders are touched"
    assert to_prune(["2026-10-28"], 0, 0) == [], "the newest always stays"
    assert monthly_count(days, 12) == 4, "July to October"
    assert monthly_count(days, 2) == 2


def file(path: str, etag: str = "e1", size: int = 10, bucket: str = "avatars") -> StoredFile:
    return StoredFile(bucket, path, size, etag, "2026-10-27T10:00:00Z")


def test_listing():
    f = from_listing("ID_Image", "p1/", {"name": "ic.jpg", "id": "x", "updated_at": "t", "metadata": {"size": 5, "eTag": '"a"'}})
    assert f == StoredFile("ID_Image", "p1/ic.jpg", 5, '"a"', "t")
    assert from_listing("b", "", {"name": "folder", "id": None}) is None, "folders are walked, not copied"
    assert from_listing("b", "../", {"name": "x", "id": "1"}) is None


def test_only_new_and_changed_files():
    manifest = {"avatars/a.jpg": file("a.jpg").signature, "avatars/b.jpg": file("b.jpg").signature,
                "avatars/gone.jpg": "x", "ID_Image/z.jpg": "y"}
    now = [file("a.jpg"), file("b.jpg", etag="e2"), file("c.jpg")]
    assert [f.path for f in changed_files(now, manifest)] == ["b.jpg", "c.jpg"]
    assert gone_upstream(now, manifest, ["avatars"]) == 1, "deleted on GET.ride: kept on the NAS, counted"
    assert buckets_to_copy(["avatars", "ai-reports", "ID_Image", ""], ["ai-reports", " "]) == ["ID_Image", "avatars"]


TOC = """;
; Archive created at 2026-10-28 02:00:01 +08
;
4120; 0 0 TABLE DATA public profiles postgres
4121; 0 0 TABLE DATA public ride_requests postgres
4122; 0 0 TABLE DATA auth users supabase_auth_admin
;4123; 0 0 TABLE DATA public skipped postgres
4124; 0 0 TABLE DATA public "app_settings" postgres
"""


def test_restore_test():
    assert toc_tables(TOC) == ["app_settings", "profiles", "ride_requests"]
    assert toc_tables(TOC, "auth") == ["users"]
    assert restore_errors("pg_restore: warning: errors ignored on restore: 7\n") == 7
    assert restore_errors("pg_restore: error: could not execute query\npg_restore: error: x\n") == 2

    live = {"profiles": 10000, "ride_requests": 52000}
    ok = restore_verdict(toc_tables(TOC), ["profiles", "ride_requests", "app_settings", "extra"], live,
                         {"profiles": 10003, "ride_requests": 51990}, 7)
    assert ok.ok, ok.summary
    assert ok.detail["skippedErrors"] == 7

    missing = restore_verdict(toc_tables(TOC), ["profiles"], live, {"profiles": 10000}, 0)
    assert not missing.ok and "2 of 3 tables" in missing.summary

    short = restore_verdict(toc_tables(TOC), ["profiles", "ride_requests", "app_settings"], live,
                            {"profiles": 0, "ride_requests": 52000}, 0)
    assert not short.ok and "profiles 0 of 10000" in short.summary

    assert not restore_verdict([], [], {}, {}, 0).ok


def test_uptime():
    assert classify(200, 100, 3000) == "up"
    assert classify(404, 100, 3000) == "up"
    assert classify(200, 3000, 3000) == "slow"
    assert classify(503, 100, 3000) == "down"
    assert classify(None, 100, 3000, "No answer in 10 s") == "down"
    assert project_of("https://abc.supabase.co/functions/v1/nas-ops") == "https://abc.supabase.co"
    assert project_of("http://x") == ""
    assert fill_url("{project}/functions/v1/uptime-check?ping=1", "https://abc.supabase.co/") == \
        "https://abc.supabase.co/functions/v1/uptime-check?ping=1"
    assert fill_url(None, "x") is None


def test_box():
    assert meminfo("MemTotal:       18874368 kB\nMemFree: 1 kB\nMemAvailable:    9437184 kB\n") == (9216, 18432)
    assert meminfo("nothing") is None
    assert cpu_busy("cpu  100 0 100 800 0 0 0", "cpu  130 0 120 850 0 0 0") == 50
    assert cpu_busy("x", "y") is None


def test_offsite_from_hyper_backup_log():
    lines = [
        "2026/10/26 03:40:10\tinfo\tSYSTEM:\t[Network][getride-b2] Backup task finished successfully. [3104 files]\n",
        "2026/10/27 03:41:00\terr\tSYSTEM:\t[Network][getride-b2] Backup task failed. [network]\n",
        "2026/10/27 05:00:00\tinfo\tSYSTEM:\t[Local][photos] Backup task finished successfully.\n",
        "2026/10/27 06:00:00\tinfo\tSYSTEM:\tSomething else entirely\n",
    ]
    assert offsite_from_log(lines, "getride-b2") == {"at": "2026-10-27T03:41:00", "ok": False}
    assert offsite_from_log(lines) == {"at": "2026-10-27T05:00:00", "ok": True}
    assert offsite_from_log(["no dates here, backup completed"]) is None
    assert offsite_from_log([]) is None

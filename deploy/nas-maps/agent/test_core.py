"""pytest deploy/nas-maps/agent/test_core.py"""

import json
from datetime import datetime, timedelta, timezone

from core import base_url, check, heartbeat_body, osrm_ok, overall, photon_ok, read_refresh, secret_ok, tilejson_ok

UP = check(True, 80.4)
DOWN = check(False)
NOW = datetime(2026, 10, 25, 4, 30, tzinfo=timezone.utc)


def test_check_rounds_and_drops_empty_extras():
    assert UP == {"ok": True, "ms": 80}
    assert check(True, 5, bytes=10, date=None) == {"ok": True, "ms": 5, "bytes": 10}


def test_overall():
    idle = {"running": False}
    assert overall(UP, UP, UP, UP, idle) == "ok"
    assert overall(UP, UP, UP, None, idle) == "ok", "no tunnel set yet: not held against it"
    assert overall(UP, DOWN, UP, UP, idle) == "degraded"
    assert overall(UP, UP, UP, DOWN, idle) == "degraded"
    assert overall(DOWN, DOWN, UP, UP, idle) == "down"
    assert overall(DOWN, DOWN, UP, UP, {"running": True}) == "refreshing"
    assert overall(UP, UP, DOWN, UP, {"running": True}) == "refreshing"


def test_read_refresh(tmp_path):
    p = tmp_path / "refresh.json"
    assert read_refresh(p, NOW) == {"running": False}
    p.write_text("not json")
    assert read_refresh(p, NOW) == {"running": False}
    p.write_text(json.dumps({"running": True, "stage": "routes", "percent": 140,
                             "updatedAt": (NOW - timedelta(minutes=5)).isoformat(),
                             "lastOkAt": "2026-10-18T04:52:00Z", "dataDate": "2026-10-24T20:00:00+00:00"}))
    r = read_refresh(p, NOW)
    assert r == {"running": True, "stage": "routes", "percent": 100, "lastOkAt": "2026-10-18T04:52:00Z",
                 "dataDate": "2026-10-24T20:00:00Z"}
    p.write_text(json.dumps({"running": True, "stage": "routes", "updatedAt": (NOW - timedelta(hours=7)).isoformat(),
                             "lastError": "x" * 400}))
    r = read_refresh(p, NOW)
    assert r["running"] is False and "stage" not in r, "a run silent for 6 hours died"
    assert len(r["lastError"]) == 300


def test_urls_and_secret():
    assert base_url(" https://maps.getride.my/ ") == "https://maps.getride.my"
    assert base_url("http://maps.getride.my") is None
    assert base_url("https://maps.getride.my/route") is None
    assert base_url(None) is None
    assert secret_ok("a" * 64)
    assert not secret_ok("short")
    assert not secret_ok("a" * 40 + " " + "b" * 40)


def test_answers():
    assert osrm_ok({"code": "Ok", "routes": [{}]})
    assert not osrm_ok({"code": "NoRoute", "routes": []})
    assert photon_ok({"features": [{}]})
    assert not photon_ok({"features": []})
    assert tilejson_ok({"tiles": ["https://tiles.getride.my/basemap/{z}/{x}/{y}.mvt"]})
    assert not tilejson_ok([])


def test_heartbeat_body_sends_the_secret_only_when_good():
    b = heartbeat_body("ok", {"osrm": UP}, "1.0.0", "DS224+", "https://maps.getride.my", None, "s" * 64)
    assert b["secret"] == "s" * 64 and b["mapsUrl"] == "https://maps.getride.my" and "tilesUrl" not in b
    assert "secret" not in heartbeat_body("ok", {}, "1.0.0", "DS224+", None, None, "short")

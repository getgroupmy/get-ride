"""The GET.ride maps agent's pure half (see ../README.md): what the agent
tells GET.ride each minute about the NAS's maps. No network: tested in
test_core.py.

Each check is {"ok": bool, "ms": int | None, ...}. The overall status is
  "down"        neither routes (OSRM) nor search (Photon) answer
  "refreshing"  the weekly data refresh is running (what is up still serves)
  "degraded"    one of routes, search, tiles or the tunnel is not answering
  "ok"          everything answers
GET.ride only offers a part (routes, search, tiles) whose own check is ok.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path

STAGES = ("download", "routes", "search", "tiles", "style", "swap")


def check(ok: bool, ms: float | None = None, **extra) -> dict:
    out = {"ok": bool(ok), "ms": None if ms is None else int(round(ms))}
    out.update({k: v for k, v in extra.items() if v is not None})
    return out


def overall(osrm: dict, photon: dict, tiles: dict, tunnel: dict | None, refresh: dict) -> str:
    if not osrm.get("ok") and not photon.get("ok"):
        return "refreshing" if refresh.get("running") else "down"
    if refresh.get("running"):
        return "refreshing"
    parts = [osrm, photon, tiles] + ([tunnel] if tunnel is not None else [])
    return "ok" if all(p.get("ok") for p in parts) else "degraded"


def read_refresh(path: Path, now: datetime | None = None) -> dict:
    """refresh.sh's status file, as the admin page shows it. A run that
    hasn't written for 6 hours is taken to have died."""
    now = now or datetime.now(timezone.utc)
    try:
        raw = json.loads(path.read_text())
    except (OSError, ValueError):
        return {"running": False}
    if not isinstance(raw, dict):
        return {"running": False}
    stage = raw.get("stage") if raw.get("stage") in STAGES else None
    updated = _time(raw.get("updatedAt"))
    running = bool(raw.get("running")) and updated is not None and (now - updated).total_seconds() < 6 * 3600
    out = {
        "running": running,
        "stage": stage if running else None,
        "percent": _percent(raw.get("percent")) if running else None,
        "lastOkAt": _iso(raw.get("lastOkAt")),
        "lastError": str(raw.get("lastError"))[:300] if raw.get("lastError") else None,
        "dataDate": _iso(raw.get("dataDate")),
        "tilesDate": _iso(raw.get("tilesDate")),
        "nextAt": _iso(raw.get("nextAt")),
    }
    return {k: v for k, v in out.items() if v is not None}


def _time(v) -> datetime | None:
    if not isinstance(v, str):
        return None
    try:
        t = datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def _iso(v) -> str | None:
    t = _time(v)
    return t.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if t else None


def _percent(v) -> int | None:
    return max(0, min(100, int(v))) if isinstance(v, (int, float)) else None


_HTTPS_BASE = re.compile(r"^https://[A-Za-z0-9.-]+(:\d{1,5})?$")


def base_url(v: str | None) -> str | None:
    """An https base address without a trailing slash, or None."""
    v = (v or "").strip().rstrip("/")
    return v if _HTTPS_BASE.match(v) else None


def secret_ok(v: str | None) -> bool:
    """The tunnel secret: 32 to 200 characters, no spaces (openssl rand -hex 32 gives 64)."""
    return bool(v) and 32 <= len(v) <= 200 and not re.search(r"\s", v)


def osrm_ok(body) -> bool:
    return isinstance(body, dict) and body.get("code") == "Ok" and bool(body.get("routes"))


def photon_ok(body) -> bool:
    return isinstance(body, dict) and isinstance(body.get("features"), list) and len(body["features"]) > 0


def tilejson_ok(body) -> bool:
    return isinstance(body, dict) and isinstance(body.get("tiles"), list) and len(body["tiles"]) > 0


def heartbeat_body(status: str, detail: dict, version: str, model: str, maps_url: str | None,
                   tiles_url: str | None, secret: str | None) -> dict:
    body = {"action": "heartbeat", "status": status, "detail": detail, "version": version, "model": model}
    if maps_url:
        body["mapsUrl"] = maps_url
    if tiles_url:
        body["tilesUrl"] = tiles_url
    if secret_ok(secret):
        body["secret"] = secret
    return body

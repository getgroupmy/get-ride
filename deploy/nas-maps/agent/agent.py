"""The GET.ride maps agent on the office NAS (see ../README.md).

It only calls out, to the nas-maps edge function:
  1. pairs once with the code from Admin > Settings > Office NAS > Maps and
     keeps the key it gets in /data/key.json;
  2. every minute, checks OSRM (routes), Photon (search), the tile server
     and, when set, its own Cloudflare Tunnel from outside, reads the weekly
     refresh's status file, and tells GET.ride; with the check-in go the
     tunnel addresses and the secret the geo function must send to it.

It never sees a rider's trip or search: those go from the geo function
through the tunnel straight to the gateway.
"""

from __future__ import annotations

import json
import logging
import os
import socket
import sys
import time
import uuid
from pathlib import Path

import requests

from core import (
    base_url,
    check,
    heartbeat_body,
    osrm_ok,
    overall,
    photon_ok,
    read_refresh,
    secret_ok,
    tilejson_ok,
)

VERSION = "1.0.0"
URL = os.environ.get("GETRIDE_URL", "").strip()
DATA = Path(os.environ.get("AGENT_DATA", "/data"))
MAPS_DATA = Path(os.environ.get("MAPS_DATA", "/maps"))
LABEL = os.environ.get("NAS_LABEL", "").strip() or None
MAPS_URL = base_url(os.environ.get("MAPS_URL"))
TILES_URL = base_url(os.environ.get("TILES_URL"))
SECRET = os.environ.get("MAPS_SECRET", "").strip()
HEARTBEAT_SECONDS = 60

# Inside the compose network.
OSRM = "http://osrm:5000"
PHOTON = "http://photon:2322"
TILES = "http://tiles:8080"
# Kuala Lumpur Sentral to KLCC: a trip every extract has.
PROBE_ROUTE = "101.6869,3.1340;101.7123,3.1579"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("nas-maps-agent")


def model() -> str:
    try:
        cpu = next(l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name"))
    except Exception:  # noqa: BLE001
        cpu = "unknown processor"
    return f"{socket.gethostname()} · {cpu}"


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
        log.error("Can't save to %s (%s). Make the agent-data folder next to docker-compose.yml and give it to the "
                  "agent (README.md, step 4), then restart.", DATA, type(e).__name__)
        return False


def call(action: str, key: str | None = None, **body) -> tuple[int, dict]:
    headers = {"content-type": "application/json"}
    if key:
        headers["x-nas-key"] = key
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
    if not save_state({"device_id": device}):
        return None
    if not code:
        log.info("Not connected. Make a code in Admin > Settings > Office NAS > Maps, put it in .env as PAIR_CODE "
                 "and restart.")
        return None
    status, answer = call("pair", code=code, device_id=device, label=LABEL, model=model(), version=VERSION)
    if status != 200 or not answer.get("key"):
        log.warning("Pairing refused (%s): %s", status, answer.get("hint") or answer.get("error"))
        return None
    save_state({"device_id": device, "key": answer["key"], "server": answer.get("server")})
    log.info("Connected as %s. You can remove PAIR_CODE from .env now.", answer.get("label"))
    return answer["key"]


def timed_get(url: str, ok, headers: dict | None = None, timeout: float = 5) -> dict:
    started = time.monotonic()
    try:
        r = requests.get(url, headers=headers or {}, timeout=timeout)
        ms = (time.monotonic() - started) * 1000
        body = r.json() if r.status_code == 200 else None
        return check(r.status_code == 200 and ok(body), ms, http=r.status_code)
    except (requests.RequestException, ValueError) as e:
        return check(False, None, error=type(e).__name__)


def tiles_size() -> int | None:
    try:
        return (MAPS_DATA / "tiles" / "basemap.pmtiles").stat().st_size
    except OSError:
        return None


def checks() -> tuple[str, dict]:
    osrm = timed_get(f"{OSRM}/route/v1/driving/{PROBE_ROUTE}?overview=false", osrm_ok)
    photon = timed_get(f"{PHOTON}/api?q=Kuala%20Lumpur&limit=1", photon_ok)
    tiles = timed_get(f"{TILES}/basemap.json", tilejson_ok)
    size = tiles_size()
    if size is not None:
        tiles["bytes"] = size
    # The tunnel, from outside, as the geo function sees it.
    tunnel = None
    if MAPS_URL and secret_ok(SECRET):
        tunnel = timed_get(f"{MAPS_URL}/route/v1/driving/{PROBE_ROUTE}?overview=false", osrm_ok,
                           headers={"X-Nas-Maps-Key": SECRET}, timeout=10)
    refresh = read_refresh(MAPS_DATA / "status" / "refresh.json")
    detail = {"osrm": osrm, "photon": photon, "tiles": tiles, "refresh": refresh}
    if tunnel is not None:
        detail["tunnel"] = tunnel
    return overall(osrm, photon, tiles, tunnel, refresh), detail


def main() -> None:
    if not URL.startswith("https://"):
        log.error("Set GETRIDE_URL in .env (see README.md).")
        sys.exit(2)
    if not MAPS_URL or not secret_ok(SECRET):
        log.warning("MAPS_URL or MAPS_SECRET is missing from .env: GET.ride can't reach the maps until both are set.")
    log.info("GET.ride maps agent %s, %s", VERSION, model())
    key = None
    while True:
        try:
            if key is None:
                key = pair()
                if key is None:
                    time.sleep(60)
                    continue
            status, detail = checks()
            code, answer = call("heartbeat", key, **{k: v for k, v in heartbeat_body(
                status, detail, VERSION, model(), MAPS_URL, TILES_URL, SECRET).items() if k != "action"})
            if code == 401:
                raise PermissionError(answer.get("hint"))
            if code != 200:
                log.warning("Check-in not taken (%s); trying again in a minute.", code)
            elif status != "ok":
                log.info("Checked in: %s (routes %s, search %s, tiles %s)", status, detail["osrm"]["ok"],
                         detail["photon"]["ok"], detail["tiles"]["ok"])
            time.sleep(answer.get("pollAfter", HEARTBEAT_SECONDS) if code == 200 else HEARTBEAT_SECONDS)
        except PermissionError as e:
            log.warning("This NAS was disconnected in Admin (%s). Put a new PAIR_CODE in .env and restart.", e)
            save_state({"device_id": state().get("device_id")})
            key = None
            time.sleep(60)
        except requests.RequestException as e:
            log.warning("GET.ride can't be reached (%s); trying again in a minute.", type(e).__name__)
            time.sleep(60)


if __name__ == "__main__":
    main()

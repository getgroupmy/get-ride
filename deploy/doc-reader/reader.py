"""The GET.ride document reader on the office NAS (see README.md).

It only calls out, to the doc-reader edge function:
  1. pairs once with the code from Admin > Settings > Document reading and
     keeps the key it gets in /data/key.json;
  2. checks in every minute (the admin page shows it online);
  3. asks for photos to read, reads plates, document numbers and QR codes
     with PP-OCR (RapidOCR, OpenVINO on the processor: no AVX needed) and
     reports what it found and how sure it is.

Each photo comes as a 5-minute link, is read in memory and dropped: nothing
is written to disk or logged but counts and timings.
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

import cv2
import numpy as np
import requests

from core import Line, poll_after, read

VERSION = "1.0.1"
URL = os.environ.get("GETRIDE_URL", "").strip()
DATA = Path(os.environ.get("READER_DATA", "/data"))
LABEL = os.environ.get("READER_LABEL", "").strip() or None
MAX_PHOTO_BYTES = 15 * 1024 * 1024
HEARTBEAT_SECONDS = 60

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("doc-reader")


def model() -> str:
    try:
        cpu = next(l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name"))
    except Exception:  # noqa: BLE001
        cpu = "unknown processor"
    return f"{socket.gethostname()} · {cpu} · OpenVINO"


def state() -> dict:
    try:
        return json.loads((DATA / "key.json").read_text())
    except Exception:  # noqa: BLE001
        return {}


def save_state(s: dict) -> bool:
    """Keeps the key in /data; False (and says why) when the folder can't be
    written, which on a Synology means the data folder wasn't made for it."""
    try:
        DATA.mkdir(parents=True, exist_ok=True)
        p = DATA / "key.json"
        p.write_text(json.dumps(s))
        p.chmod(0o600)
        return True
    except OSError as e:
        log.error("Can't save to %s (%s). Make the data folder next to docker-compose.yml and give it to the reader "
                  "(README.md, step 3), then restart.", DATA, type(e).__name__)
        return False


def call(action: str, key: str | None = None, **body) -> tuple[int, dict]:
    headers = {"content-type": "application/json"}
    if key:
        headers["x-reader-key"] = key
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
        # Don't spend the one-time code on a key that can't be kept.
        return None
    if not code:
        log.info("Not connected. Make a code in Admin > Settings > Document reading, put it in .env as PAIR_CODE and restart.")
        return None
    status, answer = call("pair", code=code, device_id=device, label=LABEL, model=model(), version=VERSION)
    if status != 200 or not answer.get("key"):
        log.warning("Pairing refused (%s): %s", status, answer.get("hint") or answer.get("error"))
        return None
    save_state({"device_id": device, "key": answer["key"], "reader": answer.get("reader")})
    log.info("Connected as %s. You can remove PAIR_CODE from .env now.", answer.get("label"))
    return answer["key"]


class Ocr:
    """PP-OCR on the processor through OpenVINO (built and timed on the DS224+)."""

    def __init__(self) -> None:
        from rapidocr import EngineType, RapidOCR

        e = EngineType.OPENVINO
        self._ocr = RapidOCR(params={"Det.engine_type": e, "Cls.engine_type": e, "Rec.engine_type": e})
        self._qr = cv2.QRCodeDetector()

    def lines(self, image: np.ndarray) -> list[Line]:
        res = self._ocr(image)
        texts = list(res.txts or ()) if res is not None else []
        scores = list(res.scores or ()) if res is not None else []
        return [Line(t, float(s)) for t, s in zip(texts, scores)]

    def qr(self, image: np.ndarray) -> list[str]:
        try:
            ok, values, _, _ = self._qr.detectAndDecodeMulti(image)
            return [v for v in values if v] if ok else []
        except cv2.error:
            return []


def download(url: str) -> np.ndarray | None:
    with requests.get(url, timeout=60, stream=True) as r:
        if r.status_code != 200:
            return None
        data = bytearray()
        for chunk in r.iter_content(65536):
            data.extend(chunk)
            if len(data) > MAX_PHOTO_BYTES:
                return None
    image = cv2.imdecode(np.frombuffer(bytes(data), np.uint8), cv2.IMREAD_COLOR)
    return image


def work(key: str, ocr: Ocr) -> float:
    """One round: claim a photo, read it, report. Returns how long to wait."""
    status, answer = call("claim", key, limit=1)
    if status == 401:
        raise PermissionError(answer.get("hint") or "key refused")
    if status != 200:
        return 30
    for job in answer.get("jobs", []):
        started = time.monotonic()
        try:
            image = download(job["url"]) if job.get("url") else None
            if image is None:
                call("report", key, id=job["id"], ok=False, error="photo not available or not an image")
                continue
            wants = job.get("wants") or []
            reading = read(ocr.lines(image), wants, ocr.qr(image) if "qr" in wants else None)
            del image
            ms = int((time.monotonic() - started) * 1000)
            _, done = call("report", key, id=job["id"], ok=True, result=reading.result(),
                           confidence=reading.confidence, ms=ms)
            log.info("Read a photo in %d ms: %d plates, %d numbers, %d QR, %.0f%% sure (%s)", ms,
                     len(reading.plates), len(reading.numbers), len(reading.qr), reading.confidence, done.get("status"))
        except Exception as e:  # noqa: BLE001
            log.warning("Couldn't read a photo: %s", type(e).__name__)
            try:
                call("report", key, id=job["id"], ok=False, error=type(e).__name__)
            except Exception:  # noqa: BLE001
                pass
    return poll_after(answer, 15)


def main() -> None:
    if not URL.startswith("https://"):
        log.error("Set GETRIDE_URL in .env (see README.md).")
        sys.exit(2)
    ocr = Ocr()
    log.info("GET.ride document reader %s, %s", VERSION, model())
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
                status, beat = call("heartbeat", key, model=model(), version=VERSION)
                if status == 401:
                    raise PermissionError(beat.get("hint"))
                last_beat = time.monotonic()
                if not beat.get("on", True):
                    time.sleep(poll_after(beat, 60))
                    continue
            time.sleep(work(key, ocr))
        except PermissionError as e:
            log.warning("This reader was disconnected in Admin (%s). Put a new PAIR_CODE in .env and restart.", e)
            save_state({"device_id": state().get("device_id")})
            key = None
            time.sleep(60)
        except requests.RequestException as e:
            log.warning("GET.ride can't be reached (%s); trying again in a minute.", type(e).__name__)
            time.sleep(60)


if __name__ == "__main__":
    main()

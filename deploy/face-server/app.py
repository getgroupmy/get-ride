"""get.ride face match server: how alike the face on a selfie is to the face
on an ID photo, for Admin > Documents > Sign-in checks (the face-compare
edge function calls it). A score for the admin, never an approval.

    GET  /health                         -> {"status": "ok", "model": "SFace", "key"?: "ok"}
    POST /compare  x-api-key: FACE_API_KEY
         {"image1": base64, "image2": base64}
                                         -> {"similarity": 0..1, "model": "SFace", "verified": bool}
                                            422 {"error": "no_face"}

Photos are decoded in memory, compared and dropped: nothing is written to
disk or logged. Models: SFace (Apache 2.0, the default) or Dlib (Boost
licence, optional). VGG-Face, ArcFace and the others DeepFace offers are
not allowed: their weights are for non-commercial use.
"""

import io
import json
import logging
import os

import numpy as np
from fastapi import FastAPI, Header, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool
from PIL import Image, ImageOps, UnidentifiedImageError

from core import DEFAULT_MAX_IMAGE_MB, ImageTooBig, NotAnImage, decode_image, key_ok, similarity

ALLOWED_MODELS = {"SFace", "Dlib"}
MODEL = os.environ.get("FACE_MODEL", "SFace")
if MODEL not in ALLOWED_MODELS:
    raise SystemExit(f"FACE_MODEL must be one of {sorted(ALLOWED_MODELS)}")
DETECTOR = os.environ.get("FACE_DETECTOR", "opencv")
API_KEY = os.environ.get("FACE_API_KEY", "")
if len(API_KEY) < 16:
    raise SystemExit("Set FACE_API_KEY to a secret of 16 characters or more (openssl rand -hex 32)")
MAX_BYTES = int(float(os.environ.get("FACE_MAX_IMAGE_MB", DEFAULT_MAX_IMAGE_MB)) * 1024 * 1024)
# Two photos as base64 plus a little JSON.
MAX_BODY = MAX_BYTES * 2 * 4 // 3 + 4096
Image.MAX_IMAGE_PIXELS = 40_000_000

log = logging.getLogger("face-server")
app = FastAPI(title="get.ride face match", docs_url=None, redoc_url=None, openapi_url=None)

# Loads the model once, at start, so the first check isn't slow.
from deepface import DeepFace  # noqa: E402

DeepFace.build_model(MODEL)


def _array(raw: bytes) -> np.ndarray:
    """The photo as DeepFace takes it: a BGR array, turned upright."""
    try:
        img = Image.open(io.BytesIO(raw))
        img.load()
    except (UnidentifiedImageError, OSError, Image.DecompressionBombError) as e:
        raise NotAnImage("not an image") from e
    # Phone photos say which way is up in their EXIF.
    try:
        img = ImageOps.exif_transpose(img)
    except Exception:  # noqa: BLE001 - a photo without usable EXIF is fine as it is
        pass
    img = img.convert("RGB")
    return np.asarray(img)[:, :, ::-1].copy()


def _error(status: int, code: str) -> JSONResponse:
    return JSONResponse({"error": code}, status_code=status)


@app.get("/health")
def health(x_api_key: str | None = Header(default=None)):
    body = {"status": "ok", "model": MODEL}
    # Sent a key (Admin > API Keys > Test): say whether it is the right one.
    if x_api_key is not None:
        if not key_ok(x_api_key, API_KEY):
            return _error(401, "bad_key")
        body["key"] = "ok"
    return body


@app.post("/compare")
async def compare(request: Request, x_api_key: str | None = Header(default=None)):
    if not key_ok(x_api_key, API_KEY):
        return _error(401, "bad_key")
    length = request.headers.get("content-length")
    if length is not None and length.isdigit() and int(length) > MAX_BODY:
        return _error(413, "too_big")
    raw = await request.body()
    if len(raw) > MAX_BODY:
        return _error(413, "too_big")
    try:
        body = json.loads(raw)
        a = _array(decode_image(body.get("image1"), MAX_BYTES))
        b = _array(decode_image(body.get("image2"), MAX_BYTES))
    except ImageTooBig:
        return _error(413, "too_big")
    except (NotAnImage, ValueError, AttributeError):
        return _error(400, "bad_image")
    del raw
    try:
        r = await run_in_threadpool(
            DeepFace.verify,
            img1_path=a,
            img2_path=b,
            model_name=MODEL,
            detector_backend=DETECTOR,
            distance_metric="cosine",
            enforce_detection=True,
        )
    except ValueError:
        # DeepFace: "Face could not be detected" in one of the photos.
        return _error(422, "no_face")
    except Exception:  # noqa: BLE001
        log.exception("compare failed")
        return _error(500, "compare_failed")
    finally:
        del a, b
    s = similarity(float(r["distance"]), float(r["threshold"]))
    return {"similarity": s, "model": MODEL, "verified": bool(r["verified"])}

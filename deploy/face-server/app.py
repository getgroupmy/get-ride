"""get.ride face match server: how alike the face on a selfie is to the face
on an ID photo, for Admin > Documents > Sign-in checks (the face-compare
edge function calls it). A score for the admin, never an approval.

    GET  /health                         -> {"status": "ok", "model": "SFace", "key"?: "ok"}
    POST /compare  x-api-key: FACE_API_KEY
         {"image1": base64, "image2": base64}
                                         -> {"similarity": 0..1, "model": "SFace", "verified": bool,
                                             "cosine": -1..1}
                                            422 {"error": "no_face"}

OpenCV only (cv2.dnn, no TensorFlow, no onnxruntime), so it runs on CPUs
without AVX such as the Celeron J4125: YuNet finds the face
(cv2.FaceDetectorYN), SFace compares them (cv2.FaceRecognizerSF, cosine
score). Both models are opencv_zoo's, Apache 2.0, fetched and checked at
image build time (Dockerfile). The cosine score is put on a 0..1 scale where
0.8 is OpenCV's same-person threshold (0.363): see core.similarity.

Photos are decoded in memory, compared and dropped: nothing is written to
disk or logged.
"""

import json
import logging
import os
import threading

import cv2
import numpy as np
from fastapi import FastAPI, Header, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

from core import (
    DEFAULT_MAX_IMAGE_MB,
    SFACE_COSINE_THRESHOLD,
    ImageTooBig,
    NotAnImage,
    decode_image,
    key_ok,
    similarity,
)

MODEL = "SFace"
MODELS = os.environ.get("FACE_MODELS_DIR", "/app/models")
DETECTOR_FILE = os.path.join(MODELS, "face_detection_yunet_2023mar.onnx")
RECOGNIZER_FILE = os.path.join(MODELS, "face_recognition_sface_2021dec.onnx")
API_KEY = os.environ.get("FACE_API_KEY", "")
if len(API_KEY) < 16:
    raise SystemExit("Set FACE_API_KEY to a secret of 16 characters or more (openssl rand -hex 32)")
MAX_BYTES = int(float(os.environ.get("FACE_MAX_IMAGE_MB", DEFAULT_MAX_IMAGE_MB)) * 1024 * 1024)
# Two photos as base64 plus a little JSON.
MAX_BODY = MAX_BYTES * 2 * 4 // 3 + 4096
# Photos are made smaller than this (longest side) before looking for a face.
MAX_SIDE = 1280
# How sure YuNet must be that it is a face.
DETECT_SCORE = float(os.environ.get("FACE_DETECT_SCORE", "0.8"))

log = logging.getLogger("face-server")
app = FastAPI(title="get.ride face match", docs_url=None, redoc_url=None, openapi_url=None)

# Loaded once, at start. cv2.dnn networks aren't safe to share between
# threads, so one check runs at a time (a check takes well under a second).
cv2.setNumThreads(2)
_detector = cv2.FaceDetectorYN.create(DETECTOR_FILE, "", (320, 320), DETECT_SCORE, 0.3, 5000)
_recognizer = cv2.FaceRecognizerSF.create(RECOGNIZER_FILE, "")
_lock = threading.Lock()


class NoFace(ValueError):
    pass


def _image(raw: bytes) -> np.ndarray:
    """The photo as a BGR array, turned upright (phones say which way is up
    in EXIF; OpenCV's decoder follows it) and no bigger than MAX_SIDE."""
    img = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)
    if img is None or img.size == 0:
        raise NotAnImage("not an image")
    h, w = img.shape[:2]
    scale = MAX_SIDE / max(h, w)
    if scale < 1:
        img = cv2.resize(img, (max(1, round(w * scale)), max(1, round(h * scale))), interpolation=cv2.INTER_AREA)
    return img


def _feature(img: np.ndarray) -> np.ndarray:
    """SFace's feature of the biggest face (an ID card's main photo, not its
    small ghost picture), or NoFace."""
    h, w = img.shape[:2]
    _detector.setInputSize((w, h))
    _, faces = _detector.detect(img)
    if faces is None or len(faces) == 0:
        raise NoFace("no face")
    face = max(faces, key=lambda f: float(f[2]) * float(f[3]))
    aligned = _recognizer.alignCrop(img, face)
    return _recognizer.feature(aligned).copy()


def _compare(a: np.ndarray, b: np.ndarray) -> float:
    with _lock:
        fa = _feature(a)
        fb = _feature(b)
        return float(_recognizer.match(fa, fb, cv2.FaceRecognizerSF_FR_COSINE))


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
        a = _image(decode_image(body.get("image1"), MAX_BYTES))
        b = _image(decode_image(body.get("image2"), MAX_BYTES))
    except ImageTooBig:
        return _error(413, "too_big")
    except (NotAnImage, ValueError, AttributeError):
        return _error(400, "bad_image")
    del raw
    try:
        cosine = await run_in_threadpool(_compare, a, b)
    except NoFace:
        # A real answer: one of the photos has no face we can find.
        return _error(422, "no_face")
    except Exception:  # noqa: BLE001
        log.exception("compare failed")
        return _error(500, "compare_failed")
    finally:
        del a, b
    return {
        "similarity": similarity(cosine),
        "model": MODEL,
        "verified": cosine >= SFACE_COSINE_THRESHOLD,
        "cosine": round(cosine, 4),
    }

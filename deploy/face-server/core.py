"""The parts of the face server that need no model: the API key check, the
photo size limit and the similarity scale. Kept apart so they are tested
without OpenCV or the models (test_core.py)."""

import base64
import binascii
import hmac

# Over this the request is refused. Phone photos are well under it.
DEFAULT_MAX_IMAGE_MB = 6

# On the scale face-compare reads, 0.8 is the model's own "same person"
# threshold: above it the same person, below it not.
SAME_PERSON = 0.8

# OpenCV's suggested same-person threshold for SFace's cosine score
# (FaceRecognizerSF.match with FR_COSINE; opencv_zoo's SFace README).
SFACE_COSINE_THRESHOLD = 0.363


def key_ok(sent: str | None, expected: str | None) -> bool:
    """Whether the x-api-key sent is the server's FACE_API_KEY, compared in
    constant time. No key set on the server lets nobody in."""
    if not expected or not sent:
        return False
    return hmac.compare_digest(sent.encode("utf-8"), expected.encode("utf-8"))


class ImageTooBig(ValueError):
    pass


class NotAnImage(ValueError):
    pass


def decode_image(b64: object, max_bytes: int) -> bytes:
    """A photo sent as base64 (a data: prefix is allowed), as bytes, or
    ImageTooBig / NotAnImage. The size is checked before decoding."""
    if not isinstance(b64, str) or not b64:
        raise NotAnImage("no image")
    if b64.startswith("data:"):
        b64 = b64.split(",", 1)[-1]
    # base64 is 4 characters for every 3 bytes.
    if len(b64) * 3 // 4 > max_bytes + 3:
        raise ImageTooBig("image too big")
    try:
        raw = base64.b64decode(b64, validate=True)
    except (binascii.Error, ValueError) as e:
        raise NotAnImage("not base64") from e
    if len(raw) > max_bytes:
        raise ImageTooBig("image too big")
    if not raw:
        raise NotAnImage("empty image")
    return raw


def similarity(cosine: float, threshold: float = SFACE_COSINE_THRESHOLD) -> float:
    """SFace's cosine score (-1..1) as 0..1, with the threshold at SAME_PERSON.

    At or above the threshold, linear from 0.8 (the threshold) to 1.0 (a
    cosine of 1); below it, linear from 0.0 (a cosine of 0 or less) to 0.8.
    So 0.363 is 0.8, 0.6 is about 0.87 and 0.2 is about 0.44."""
    c = max(-1.0, min(1.0, float(cosine)))
    if not 0 < threshold < 1:
        raise ValueError("threshold must be between 0 and 1")
    if c >= threshold:
        return round(SAME_PERSON + (1 - SAME_PERSON) * (c - threshold) / (1 - threshold), 4)
    return round(SAME_PERSON * max(0.0, c) / threshold, 4)

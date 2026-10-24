"""The parts of the face server that need no model: the API key check, the
photo size limit and the similarity scale. Kept apart so they are tested
without DeepFace (test_core.py)."""

import base64
import binascii
import hmac

# Over this the request is refused. Phone photos are well under it.
DEFAULT_MAX_IMAGE_MB = 6

# On the scale face-compare reads, 0.8 is the model's own "same person"
# threshold: above it the same person, below it not.
SAME_PERSON = 0.8


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


def similarity(distance: float, threshold: float) -> float:
    """The model's cosine distance as 0..1, with its threshold at SAME_PERSON:
    0 distance is 1.0, the threshold 0.8, a distance of 1 or more 0."""
    if threshold <= 0:
        return 0.0
    d = max(0.0, float(distance))
    if d <= threshold:
        return round(SAME_PERSON + (1 - SAME_PERSON) * (1 - d / threshold), 4)
    far = 1.0
    if threshold >= far:
        return 0.0
    return round(max(0.0, SAME_PERSON * (1 - (d - threshold) / (far - threshold))), 4)

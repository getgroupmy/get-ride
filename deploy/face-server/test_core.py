"""pytest deploy/face-server/test_core.py: the key check, the size limit and
the similarity scale, without OpenCV or the models."""

import base64

import pytest

from core import ImageTooBig, NotAnImage, decode_image, key_ok, similarity

KEY = "0123456789abcdef0123456789abcdef"


def test_the_right_key_only():
    assert key_ok(KEY, KEY)
    assert not key_ok(KEY[:-1] + "0", KEY)
    assert not key_ok(KEY + "x", KEY)
    assert not key_ok("", KEY)
    assert not key_ok(None, KEY)


def test_no_key_on_the_server_lets_nobody_in():
    assert not key_ok("", "")
    assert not key_ok("anything", "")
    assert not key_ok("anything", None)


def test_the_key_is_compared_in_constant_time(monkeypatch):
    import core

    seen = []
    real = core.hmac.compare_digest
    monkeypatch.setattr(core.hmac, "compare_digest", lambda a, b: seen.append((a, b)) or real(a, b))
    assert key_ok(KEY, KEY)
    assert seen == [(KEY.encode(), KEY.encode())]


def test_photos_over_the_limit_are_refused_before_decoding():
    small = base64.b64encode(b"x" * 100).decode()
    assert decode_image(small, 1000) == b"x" * 100
    assert decode_image("data:image/jpeg;base64," + small, 1000) == b"x" * 100
    with pytest.raises(ImageTooBig):
        decode_image(base64.b64encode(b"x" * 2000).decode(), 1000)
    with pytest.raises(NotAnImage):
        decode_image("not base64!", 1000)
    with pytest.raises(NotAnImage):
        decode_image(None, 1000)


def test_the_similarity_scale():
    # OpenCV's same-person threshold for SFace's cosine score is 0.8 here.
    assert similarity(0.363) == 0.8
    assert similarity(1.0) == 1.0
    assert similarity(0.0) == 0.0
    assert similarity(-0.4) == 0.0
    assert 0.8 < similarity(0.6) < 1.0
    assert 0.0 < similarity(0.2) < 0.8
    assert similarity(0.6) == 0.8744
    # Higher cosine, higher similarity, all the way.
    scores = [similarity(c / 100) for c in range(-100, 101)]
    assert scores == sorted(scores)
    assert all(0.0 <= s <= 1.0 for s in scores)

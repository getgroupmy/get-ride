"""pytest deploy/doc-reader/test_core.py: what the reader pulls out of OCR
text, without the OCR. All numbers are made up."""

from core import Line, find_numbers, find_plates, plate_key, poll_after, read


def test_plates():
    assert find_plates("WXY 1234") == ["WXY 1234"]
    assert find_plates("No. Pendaftaran: VBN8821A") == ["VBN 8821 A"]
    assert find_plates("JQK 5") == ["JQK 5"]
    assert find_plates("PKD 7070 A and WXY 1234") == ["PKD 7070 A", "WXY 1234"]
    assert find_plates("NO 1234 KP 5678") == [], "labels aren't plates"
    assert plate_key("wxy 1234") == "WXY1234"


def test_numbers():
    assert find_numbers("No. Kad Pengenalan 900101-14-5678") == ["900101-14-5678"]
    assert find_numbers("IC 900101145678") == ["900101-14-5678"]
    assert find_numbers("No. Casis PM2B200S00K123456") == ["PM2B200S00K123456"]
    assert find_numbers("Cover note no. CN-26-0012345") == ["CN-26-0012345"]
    assert find_numbers("No. Enjin 1KR-A123456") == ["1KR-A123456"]
    assert find_numbers("Permit EVP-123456 sah hingga 31/12/2026") == ["EVP-123456"], "a date isn't a number"
    assert find_numbers("Nama: CONTOH SAHAJA") == []
    assert find_numbers("RM 1,086.40") == []


def test_only_what_was_asked_with_the_lowest_score():
    lines = [Line("SAMPLE DOCUMENT", 0.99), Line("No. pendaftaran WXY 1234", 0.95), Line("No. casis PM2B200S00K123456", 0.81),
             Line("Nama: CONTOH SAHAJA", 0.97)]
    r = read(lines, ["numbers", "plates", "qr"], qr=["https://myinvois.example/abc"])
    assert r.plates == ["WXY 1234"]
    assert r.numbers == ["PM2B200S00K123456"]
    assert r.qr == ["https://myinvois.example/abc"]
    assert r.confidence == 81.0
    assert "CONTOH" not in str(r.result()), "names are never sent back"

    only_numbers = read(lines, ["numbers"])
    assert only_numbers.plates == []
    assert only_numbers.qr == []

    nothing = read([Line("blurred", 0.4)], ["numbers"])
    assert nothing.result() == {"plates": [], "numbers": [], "qr": []}
    assert nothing.confidence == 0.0, "nothing found: passed on"


def test_qr_is_kept_short_and_few():
    r = read([], ["qr"], qr=["x" * 900, "", "b", "c", "d"])
    assert [len(q) for q in r.qr] == [500, 1, 1]


def test_poll_after():
    assert poll_after({"pollAfter": 2}, 15) == 2
    assert poll_after({}, 15) == 15
    assert poll_after(None, 15) == 15
    assert poll_after({"pollAfter": "x"}, 15) == 15
    assert poll_after({"pollAfter": 0}, 15) == 1
    assert poll_after({"pollAfter": 99999}, 15) == 300

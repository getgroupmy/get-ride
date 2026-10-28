"""pytest deploy/doc-reader/test_core.py: what the reader pulls out of OCR
text, without the OCR. All numbers are made up."""

import json
from datetime import date
from pathlib import Path

from core import ID_FIELDS, Line, find_numbers, find_plates, plate_key, poll_after, read, read_id_card

CASES = Path(__file__).resolve().parents[2] / "supabase" / "functions" / "_shared" / "id_card_cases.json"


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


def test_id_cards_read_as_the_phone_and_google_vision_do():
    """The same cases the phone's and the id-read function's readers are held to."""
    cases = json.loads(CASES.read_text())["cases"]
    assert cases
    for c in cases:
        got, _ = read_id_card(c["text"].split("\n"), today=date(2026, 10, 28))
        assert {k: got[k] for k in ("name", "ic", "passport", "expiry")} == c["expect"], c["name"]


def test_id_card_birth_date_and_nationality():
    today = date(2026, 10, 28)
    mykad, used = read_id_card(["KAD PENGENALAN", "MyKad", "880202-10-1234", "AINA BINTI AHMAD", "NO 12 JALAN SS2/24",
                                "WARGANEGARA"], today=today)
    assert (mykad["birth"], mykad["nationality"], used) == ("1988-02-02", "MYS", [2, 3])
    child, _ = read_id_card(["150303-14-0001", "ADAM BIN ALI"], today=today)
    assert child["birth"] == "2015-03-03" and child["nationality"] is None, "not said to be a citizen: not guessed"
    gbr, _ = read_id_card(["P<GBRSMITH<<JOHN<PAUL<<<<<<<<<<<<<<<<<<<<<<<",
                           "9876543210GBR7501011M2908156<<<<<<<<<<<<<<04"], today=today)
    assert (gbr["birth"], gbr["nationality"], gbr["expiry"]) == ("1975-01-01", "GBR", "2029-08-15")
    bad, _ = read_id_card(["881399-10-1234"], today=today)
    assert bad["ic"] == "881399-10-1234" and bad["birth"] is None, "no 99th day"


def test_an_id_job_sends_back_the_id_fields_only():
    lines = [Line("KAD PENGENALAN", 0.99), Line("880202-10-1234", 0.93), Line("AINA BINTI AHMAD", 0.88),
             Line("NO 12 JALAN SS2/24 PETALING JAYA", 0.97), Line("WARGANEGARA", 0.9)]
    r = read(lines, ["id_card", "plates"], qr=["https://x.example"])
    assert set(r.result()) == {"id"}
    assert set(r.result()["id"]) == set(ID_FIELDS)
    assert r.result()["id"]["ic"] == "880202-10-1234"
    assert r.confidence == 88.0, "the lowest score of the lines used"
    assert "JALAN" not in json.dumps(r.result()), "never the address"
    blank = read([Line("a blurry photo", 0.5)], ["id_card"])
    assert blank.confidence == 0.0 and not any(blank.result()["id"].values()), "nothing found: passed on"

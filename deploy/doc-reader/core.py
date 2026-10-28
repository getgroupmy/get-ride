"""The GET.ride document reader's pure half (see README.md): what is pulled
out of the text the OCR read, and how sure the reading is. No network, no
OCR: tested in test_core.py.

The reader only keeps what GET.ride asked for (`wants`): plates, document
numbers and QR codes. The rest of the text on the document (names,
addresses) is never sent back.

For a sign-in check's MyKad or passport (`wants` ["id_card"], migration
0320) it sends back the name, the IC number, the passport number, the birth
date, the nationality and the expiry, read with the same rules as the phone
and Google Vision (supabase/functions/_shared/id_card_cases.json), and
nothing else: not the address, not the rest of the card.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date

# Malaysian plates: 1-3 letters, 1-4 digits, up to 2 letters (WXY 1234,
# VBN 8821 A, JQK 5). Sabah/Sarawak and newer series fit the same shape.
_PLATE = re.compile(r"\b([A-Z]{1,3})\s?(\d{1,4})\s?([A-Z]{0,2})\b")

# Words that look like plates but are labels on documents.
_NOT_PLATES = {"NO", "KP", "IC", "JPJ", "LKM", "VOC", "EVP", "PSV", "GDL", "CDL", "MY", "RM", "CC", "KM", "MYS"}

# A MyKad number: yymmdd-pb-####.
_MYKAD = re.compile(r"\b(\d{6})\s?-?\s?(\d{2})\s?-?\s?(\d{4})\b")

# A chassis number (VIN): 17 letters and digits, never I, O or Q.
_VIN = re.compile(r"\b([A-HJ-NPR-Z0-9]{17})\b")

# Other document numbers: letters, digits, dashes and slashes, with at least
# 4 digits (CN-26-0012345, EVP-123456, 1KR-A123456, A12345678).
_DOC_NUMBER = re.compile(r"\b([A-Z0-9][A-Z0-9/-]{4,24}[A-Z0-9])\b")

MAX_ITEMS = 12
MAX_QR_CHARS = 500


@dataclass
class Line:
    text: str
    score: float  # 0..1, from the OCR


@dataclass
class Reading:
    plates: list[str] = field(default_factory=list)
    numbers: list[str] = field(default_factory=list)
    qr: list[str] = field(default_factory=list)
    confidence: float = 0.0  # 0..100
    # A sign-in check's ID card: only these fields, only when asked.
    id: dict | None = None

    def result(self) -> dict:
        if self.id is not None:
            return {"id": self.id}
        return {"plates": self.plates, "numbers": self.numbers, "qr": self.qr}


def plate_key(s: str) -> str:
    return re.sub(r"[^A-Z0-9]", "", s.upper())


def find_plates(text: str) -> list[str]:
    out: list[str] = []
    for m in _PLATE.finditer(text.upper()):
        letters, digits, tail = m.group(1), m.group(2), m.group(3)
        if letters in _NOT_PLATES or (tail and tail in _NOT_PLATES):
            continue
        plate = " ".join(p for p in (letters, digits + (" " + tail if tail else "")) if p).strip()
        if plate not in out:
            out.append(plate)
    return out


def find_numbers(text: str) -> list[str]:
    up = text.upper()
    out: list[str] = []

    def add(s: str) -> None:
        if s not in out:
            out.append(s)

    for m in _MYKAD.finditer(up):
        add(f"{m.group(1)}-{m.group(2)}-{m.group(3)}")
    for m in _VIN.finditer(up):
        if re.search(r"\d", m.group(1)) and re.search(r"[A-Z]", m.group(1)):
            add(m.group(1))
    taken = {re.sub(r"\D", "", n) for n in out}
    for m in _DOC_NUMBER.finditer(up):
        s = m.group(1)
        digits = re.sub(r"\D", "", s)
        if len(digits) < 4 or digits in taken:
            continue
        # A plate or a date isn't a document number.
        if _PLATE.fullmatch(s) or re.fullmatch(r"\d{1,2}[/-]\d{1,2}[/-]\d{2,4}", s):
            continue
        if any(digits in re.sub(r"\D", "", n) for n in out):
            continue
        add(s)
    return out


# ---- ID cards (MyKad, passport) for the sign-in checks ----------------------------------------

_IC = re.compile(r"\b(\d{6})\s*-?\s*(\d{2})\s*-?\s*(\d{4})\b")
_NAME = re.compile(r"^[A-Z][A-Z '@./-]+$")
_NOT_NAMES = {
    "KAD", "PENGENALAN", "MALAYSIA", "MYKAD", "IDENTITY", "CARD", "WARGANEGARA", "LELAKI", "PEREMPUAN", "ISLAM",
    "PASPORT", "PASSPORT", "JALAN", "TAMAN", "LORONG", "KAMPUNG", "NO", "KUALA", "LUMPUR", "SELANGOR", "JOHOR",
    "PULAU", "PINANG", "PERAK", "KEDAH", "KELANTAN", "TERENGGANU", "PAHANG", "MELAKA", "SABAH", "SARAWAK",
    "NEGERI", "SEMBILAN", "PERLIS", "LABUAN", "PUTRAJAYA", "BANDAR", "MYS", "TYPE", "JENIS",
}
ID_FIELDS = ("name", "ic", "passport", "birth", "nationality", "expiry")


def _ymd(yymmdd: str, future: bool, today: date | None = None) -> str | None:
    """yyyy-mm-dd from YYMMDD: an expiry is this century; a birth date is the
    last hundred years."""
    if not re.fullmatch(r"\d{6}", yymmdd):
        return None
    yy, mm, dd = int(yymmdd[:2]), int(yymmdd[2:4]), int(yymmdd[4:6])
    now = (today or date.today()).year % 100
    year = 2000 + yy if future or yy <= now else 1900 + yy
    try:
        return date(year, mm, dd).isoformat()
    except ValueError:
        return None


def _mrz(lines: list[str], today: date | None) -> tuple[dict, list[int]] | None:
    """The two machine lines of a passport (ICAO 9303, 44 characters each)."""
    clean = [l.replace(" ", "").upper() for l in lines]
    for i in range(len(clean) - 1):
        a, b = clean[i], clean[i + 1]
        if not a.startswith("P") or len(a) < 40 or len(b) < 40 or not re.fullmatch(r"[A-Z0-9<]+", b):
            continue
        names = a[5:].split("<<")
        surname = names[0].replace("<", " ").strip()
        given = names[1].replace("<", " ").strip() if len(names) > 1 else ""
        name = " ".join(x for x in (given, surname) if x)
        personal = b[28:42].replace("<", "") if len(b) >= 42 else ""
        ic = f"{personal[:6]}-{personal[6:8]}-{personal[8:]}" if re.fullmatch(r"\d{12}", personal) else None
        number = b[:9].replace("<", "")
        nationality = b[10:13]
        return {
            "name": name or None,
            "ic": ic,
            "passport": number if re.fullmatch(r"[A-Z0-9]{5,9}", number) else None,
            "birth": _ymd(b[13:19], future=False, today=today),
            "nationality": nationality if re.fullmatch(r"[A-Z]{3}", nationality) else None,
            "expiry": _ymd(b[21:27], future=True, today=today),
        }, [i, i + 1]
    return None


def read_id_card(lines: list[str], today: date | None = None) -> tuple[dict, list[int]]:
    """A MyKad's IC number as printed (YYMMDD-PB-####), the birth date in it
    and the name under it; a passport's name, number, nationality, birth
    date, expiry and (a Malaysian one's) IC from its machine lines. None for
    what can't be read; with the indexes of the lines it came from."""
    lines = [l.strip() for l in lines if l and l.strip()]
    mrz = _mrz(lines, today)
    if mrz:
        return mrz
    out = dict.fromkeys(ID_FIELDS)
    used: list[int] = []
    ic_line = -1
    for i, l in enumerate(lines):
        m = _IC.search(l)
        if m:
            out["ic"] = f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
            out["birth"] = _ymd(m.group(1), future=False, today=today)
            ic_line = i
            used.append(i)
            break
    for i in range(ic_line + 1, len(lines)):
        l = lines[i]
        if not _NAME.match(l):
            continue
        words = l.split()
        if len(words) < 2 or any(re.sub(r"[^A-Z]", "", w) in _NOT_NAMES for w in words):
            continue
        out["name"] = re.sub(r"\s+", " ", l)
        used.append(i)
        break
    if out["ic"] and any(re.search(r"\bWARGANEGARA\b", l.upper()) for l in lines):
        out["nationality"] = "MYS"  # "citizen" on a MyKad
    return out, used


def read(lines: list[Line], wants: list[str], qr: list[str] | None = None) -> Reading:
    """What GET.ride asked for, from the OCR's lines, and how sure: the
    lowest score of the lines it came from (0 when nothing was found)."""
    r = Reading()
    if "id_card" in wants:
        fields, used_lines = read_id_card([line.text for line in lines])
        r.id = fields
        kept = [l for l in lines if l.text and l.text.strip()]
        scores = [kept[i].score for i in used_lines if i < len(kept)]
        r.confidence = round(min(scores) * 100, 1) if scores and any(fields.values()) else 0.0
        return r
    used: list[float] = []
    for line in lines:
        hit = False
        if "plates" in wants:
            for p in find_plates(line.text):
                if p not in r.plates:
                    r.plates.append(p)
                    hit = True
        if "numbers" in wants:
            for n in find_numbers(line.text):
                if n not in r.numbers:
                    r.numbers.append(n)
                    hit = True
        if hit:
            used.append(line.score)
    if "qr" in wants and qr:
        r.qr = [q[:MAX_QR_CHARS] for q in qr if q][:3]
        used.append(1.0)
    r.plates = r.plates[:MAX_ITEMS]
    r.numbers = r.numbers[:MAX_ITEMS]
    r.confidence = round(min(used) * 100, 1) if used else 0.0
    return r


def poll_after(answer: dict | None, default: float) -> float:
    """How long to wait before asking again: the server's word, kept to 1..300 s."""
    try:
        v = float((answer or {}).get("pollAfter", default))
    except (TypeError, ValueError):
        v = default
    return max(1.0, min(300.0, v))

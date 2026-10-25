"""The GET.ride document reader's pure half (see README.md): what is pulled
out of the text the OCR read, and how sure the reading is. No network, no
OCR: tested in test_core.py.

The reader only keeps what GET.ride asked for (`wants`): plates, document
numbers and QR codes. The rest of the text on the document (names,
addresses) is never sent back.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

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

    def result(self) -> dict:
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


def read(lines: list[Line], wants: list[str], qr: list[str] | None = None) -> Reading:
    """What GET.ride asked for, from the OCR's lines, and how sure: the
    lowest score of the lines it came from (0 when nothing was found)."""
    r = Reading()
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

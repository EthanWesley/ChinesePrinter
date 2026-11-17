"""Text → Alt-code item list.

A faithful port of ``textToAltSequence()`` in ``templates/index.html`` so the
MCP server produces byte-identical sequences to the web typewriter.
"""

from __future__ import annotations

import base64
import json
import re
from functools import lru_cache
from pathlib import Path

ENCODINGS = ("auto", "gbk", "unicode", "mdwin", "ascii", "base64")

_ASCII_ALNUM = re.compile(r"^[A-Za-z0-9]$")
MDWIN_XOR_KEY = 996

_DATA = Path(__file__).resolve().parent / "data" / "gbk_table.json"


@lru_cache(maxsize=1)
def load_gbk_table() -> dict[str, int]:
    """Load the GBK Alt-code table shipped with the package (empty on error)."""
    try:
        data = json.loads(_DATA.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {k: int(v) for k, v in data.items() if isinstance(v, (int, float))}


def _utf16_units(text: str) -> list[int]:
    """Split into UTF-16 code units, matching JavaScript's charCodeAt()."""
    raw = text.encode("utf-16-le", errors="surrogatepass")
    return [raw[i] | (raw[i + 1] << 8) for i in range(0, len(raw), 2)]


def text_to_alt_sequence(
    text: str, encoding: str = "gbk", gbk_table: dict[str, int] | None = None
) -> list[dict]:
    """Convert text into ``[{"code": n} | {"control": name}, ...]``.

    ``auto`` behaves like ``gbk`` when a table is available and like
    ``unicode`` otherwise, mirroring the web UI's per-character fallback.
    """
    if encoding not in ENCODINGS:
        raise ValueError(f"unknown encoding: {encoding}")

    items: list[dict] = []

    if encoding == "mdwin":
        for unit in _utf16_units(text):
            if 32 <= unit <= 126 or unit >= 128:
                items.append({"code": unit ^ MDWIN_XOR_KEY})
            elif unit == 10:
                items.append({"control": "enter"})
            elif unit == 9:
                items.append({"control": "tab"})
            elif unit == 8:
                items.append({"control": "backspace"})
            elif unit == 27:
                items.append({"control": "esc"})
        return items

    if encoding == "base64":
        encoded = base64.b64encode(text.encode("utf-8")).decode("ascii")
        return [{"code": ord(ch)} for ch in encoded if ord(ch) > 0]

    if encoding == "ascii":
        for ch in text:
            if ch == "\n":
                items.append({"control": "enter"})
            elif ch == "\t":
                items.append({"control": "tab"})
            elif ch == " ":
                items.append({"control": "space"})
            elif ch == "\r":
                continue
            elif _ASCII_ALNUM.match(ch):
                items.append({"code": ord(ch)})
        return items

    table = gbk_table if gbk_table is not None else (load_gbk_table() if encoding in ("gbk", "auto") else {})
    for ch in text:
        if ch == "\n":
            items.append({"control": "enter"})
        elif ch == "\t":
            items.append({"control": "tab"})
        elif ch == " ":
            items.append({"control": "space"})
        elif ch == "\r":
            continue
        else:
            code = table.get(ch) if encoding in ("gbk", "auto") else None
            if code is None:
                code = ord(ch)
            items.append({"code": code})
    return items

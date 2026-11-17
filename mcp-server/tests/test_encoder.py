"""Encoder parity with the browser's textToAltSequence()."""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "mcp-server"))

from chinese_printer_mcp.encoder import load_gbk_table, text_to_alt_sequence  # noqa: E402

FIXTURES = ROOT / "tests" / "encoding_fixtures.json"


def test_gbk_table_loads():
    table = load_gbk_table()
    assert table.get("中") == 54992
    assert len(table) > 10000


def test_matches_javascript_fixtures():
    table = load_gbk_table()
    cases = json.loads(FIXTURES.read_text(encoding="utf-8"))
    assert len(cases) >= 60
    failures = []
    for case in cases:
        got = text_to_alt_sequence(case["text"], case["encoding"], table)
        if got != case["items"]:
            failures.append(
                f"encoding={case['encoding']} text={case['text']!r}\n  expected={case['items']}\n  got={got}"
            )
    assert not failures, "\n".join(failures[:5])


def test_auto_falls_back_to_unicode_without_table():
    items = text_to_alt_sequence("中", "auto", {})
    assert items == [{"code": ord("中")}]


def test_auto_uses_gbk_table_when_available():
    items = text_to_alt_sequence("中", "auto", {"中": 54992})
    assert items == [{"code": 54992}]


def test_mdwin_encrypts_utf16_units():
    # 空格也要加密；代理对拆成两个单元，与 JS charCodeAt 一致
    assert text_to_alt_sequence(" ", "mdwin") == [{"code": ord(" ") ^ 996}]
    assert text_to_alt_sequence("😀", "mdwin") == [
        {"code": 0xD83D ^ 996},
        {"code": 0xDE00 ^ 996},
    ]


def test_unknown_encoding_rejected():
    try:
        text_to_alt_sequence("a", "rot13")
    except ValueError as exc:
        assert "unknown encoding" in str(exc)
    else:
        raise AssertionError("expected ValueError")

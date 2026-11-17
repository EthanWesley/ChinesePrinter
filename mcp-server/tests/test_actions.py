"""Action validation and translation to the seq_writer line protocol."""

import pathlib
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "mcp-server"))

from chinese_printer_mcp.actions import (  # noqa: E402
    ActionError,
    Translator,
    validate_actions,
)
from chinese_printer_mcp.mouse import MouseState  # noqa: E402

TABLE = {"中": 54992}


def translate(actions, width=1920, height=1080, rehome=False):
    translator = Translator(MouseState(width=width, height=height, rehome=rehome), TABLE)
    steps = translator.translate(validate_actions(actions))
    return [line for step in steps for line in step.lines]


def test_rejects_unknown_action_type():
    with pytest.raises(ActionError) as exc:
        validate_actions([{"t": "teleport"}])
    assert "actions[0].t" in str(exc.value)


def test_rejects_unknown_field():
    with pytest.raises(ActionError):
        validate_actions([{"t": "move", "x": 1, "y": 2, "z": 3}])


def test_click_requires_both_coordinates():
    with pytest.raises(ActionError):
        validate_actions([{"t": "click", "x": 5}])


def test_key_chord_translation():
    assert translate([{"t": "key", "keys": ["ctrl", "s"]}]) == [
        "step 0",
        "kbdset 1 22",
        "kbdset 0",
    ]


def test_type_uses_gbk_table():
    assert translate([{"t": "type", "text": "A中"}]) == [
        "step 0",
        "code 65",
        "code 54992",
    ]


def test_type_control_characters():
    assert translate([{"t": "type", "text": "a\nb\tc"}]) == [
        "step 0",
        "code 97",
        "control enter",
        "code 98",
        "control tab",
        "code 99",
    ]


def test_click_moves_then_clicks():
    lines = translate([{"t": "click", "x": 100, "y": 50}], rehome=False)
    # 光标假设从 (0,0) 开始（rehome 关闭时直接以 0,0 为起点）
    assert lines == ["step 0", "mmove 100 50", "wait 40", "mclick 1"]


def test_click_without_coordinates_clicks_in_place():
    assert translate([{"t": "click"}]) == ["step 0", "mclick 1"]


def test_doubleclick_and_right_button():
    lines = translate([{"t": "doubleclick", "x": 0, "y": 0, "button": "right"}])
    assert lines[-1] == "mdclick 2"


def test_drag_presses_moves_releases():
    lines = translate(
        [{"t": "drag", "from": {"x": 0, "y": 0}, "to": {"x": 200, "y": 0}}],
        rehome=False,
    )
    assert lines == [
        "step 0",
        "wait 60",
        "mbtn 1",
        "wait 60",
        "mmove 127 0",
        "mmove 73 0",
        "wait 80",
        "mbtn 0",
    ]


def test_scroll_direction_and_horizontal():
    assert translate([{"t": "scroll", "dy": -3}]) == ["step 0", "wheel -3"]
    assert translate([{"t": "scroll", "dy": 2, "dx": -1}]) == ["step 0", "wheel 2 -1"]


def test_wait_bounds():
    assert translate([{"t": "wait", "ms": 250}]) == ["step 0", "wait 250"]
    with pytest.raises(ActionError):
        validate_actions([{"t": "wait", "ms": 0}])


def test_key_down_up_tracks_state():
    lines = translate(
        [
            {"t": "key_down", "keys": ["ctrl"]},
            {"t": "key_down", "keys": ["shift", "a"]},
            {"t": "key_up", "keys": ["shift"]},
            {"t": "key_up", "keys": ["ctrl"]},
        ]
    )
    assert lines == [
        "step 0",
        "kbdset 1",
        "step 1",
        "kbdset 3 4",
        "step 2",
        "kbdset 1 4",
        "step 3",
        "kbdset 0 4",
    ]


def test_key_released_after_key_up():
    translator = Translator(MouseState(rehome=False), TABLE)
    translator.translate(validate_actions([{"t": "key_down", "keys": ["ctrl"]}]))
    steps = translator.translate(validate_actions([{"t": "key", "keys": ["s"]}]))
    assert [line for step in steps for line in step.lines] == [
        "step 0",
        "kbdset 1 22",
        "kbdset 1",
    ]


def test_unknown_key_name_reports_action():
    with pytest.raises(ActionError):
        translate([{"t": "key", "keys": ["hyper"]}])


def test_shifted_symbol_implies_shift():
    assert translate([{"t": "key", "keys": ["!"]}]) == ["step 0", "kbdset 2 30", "kbdset 0"]

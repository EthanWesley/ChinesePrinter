"""Absolute → relative pointer translation."""

import math
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "mcp-server"))

from chinese_printer_mcp.mouse import MouseState  # noqa: E402


def test_first_move_rehomes_to_origin():
    state = MouseState(width=1920, height=1080, rehome=True)
    lines = state.move_lines(100, 100)
    expected_rehome = math.ceil((1920 + 1080) / 127) + 4
    assert lines[:expected_rehome] == ["mmove -127 -127"] * expected_rehome
    assert lines[expected_rehome:] == ["mmove 100 100"]
    assert state.cursor == (100, 100)


def test_no_rehome_when_disabled():
    state = MouseState(width=1920, height=1080, rehome=False)
    assert state.move_lines(10, 20) == ["mmove 10 20"]


def test_long_move_splits_into_steps_and_sums_exactly():
    state = MouseState(width=1920, height=1080, rehome=False)
    state.cursor = (0, 0)
    lines = state.move_lines(1000, 500)
    deltas = [tuple(int(v) for v in line.split()[1:]) for line in lines]
    assert sum(d[0] for d in deltas) == 1000
    assert sum(d[1] for d in deltas) == 500
    assert all(abs(d[0]) <= 127 and abs(d[1]) <= 127 for d in deltas)
    assert len(lines) == 8  # ceil(1000/127)


def test_move_backwards():
    state = MouseState(width=1920, height=1080, rehome=False)
    state.cursor = (1000, 800)
    deltas = [tuple(int(v) for v in line.split()[1:]) for line in state.move_lines(0, 0)]
    assert sum(d[0] for d in deltas) == -1000
    assert sum(d[1] for d in deltas) == -800


def test_coordinates_are_clamped_to_screen():
    state = MouseState(width=1920, height=1080, rehome=False)
    state.cursor = (0, 0)
    state.move_lines(5000, -20)
    assert state.cursor == (1919, 0)


def test_rehome_step_count_scales_with_resolution():
    state = MouseState(width=3840, height=2160)
    assert len(state.rehome_lines()) == math.ceil((3840 + 2160) / 127) + 4


def test_absolute_mode_emits_single_report():
    state = MouseState(width=1920, height=1080, absolute=True)
    lines = state.move_lines(960, 540)
    assert len(lines) == 1, lines
    assert lines[0].startswith("mabs ")
    ax, ay = (int(v) for v in lines[0].split()[1:])
    assert ax == round(960 * 32767 / 1919)
    assert ay == round(540 * 32767 / 1079)
    assert state.cursor == (960, 540)


def test_absolute_mode_ignores_rehome():
    state = MouseState(width=1920, height=1080, absolute=True, rehome=True)
    assert all(line.startswith("mabs ") for line in state.move_lines(10, 10))

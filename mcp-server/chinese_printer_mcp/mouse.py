"""Absolute (x, y) → relative HID mouse movement.

The KVM mouse gadget is a boot-protocol relative pointer, so the PC side
tracks the assumed cursor position and emits ``mmove`` reports of at most
127 px per axis. Before the first movement the cursor is pinned to the
top-left corner ("rehome") so the assumption survives manual pointer use.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

MAX_STEP = 127


def _clamp(value: int, low: int, high: int) -> int:
    return low if value < low else high if value > high else value


@dataclass
class MouseState:
    width: int = 1920
    height: int = 1080
    cursor: tuple[int, int] | None = None
    rehome: bool = True
    absolute: bool = False

    def set_screen(self, width: int, height: int) -> None:
        if width > 0 and height > 0:
            self.width, self.height = width, height

    def forget_cursor(self) -> None:
        self.cursor = None

    def rehome_lines(self) -> list[str]:
        # 屏幕边缘会 clamp，多打几发确保收敛到 (0, 0)
        steps = math.ceil((self.width + self.height) / MAX_STEP) + 4
        return [f"mmove {-MAX_STEP} {-MAX_STEP}"] * steps

    def move_lines(self, x: int, y: int) -> list[str]:
        x = _clamp(x, 0, self.width - 1)
        y = _clamp(y, 0, self.height - 1)

        # 绝对坐标 gadget：一条 mabs 报告直达，无需 rehome 与分段
        if self.absolute:
            ax = round(x * 32767 / max(self.width - 1, 1))
            ay = round(y * 32767 / max(self.height - 1, 1))
            self.cursor = (x, y)
            return [f"mabs {ax} {ay}"]

        lines: list[str] = []
        if self.cursor is None:
            if self.rehome:
                lines.extend(self.rehome_lines())
            self.cursor = (0, 0)

        dx = x - self.cursor[0]
        dy = y - self.cursor[1]
        while dx or dy:
            step_x = _clamp(dx, -MAX_STEP, MAX_STEP)
            step_y = _clamp(dy, -MAX_STEP, MAX_STEP)
            lines.append(f"mmove {step_x} {step_y}")
            dx -= step_x
            dy -= step_y

        self.cursor = (x, y)
        return lines

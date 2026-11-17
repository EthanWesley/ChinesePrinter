"""High-level action schema (LLM-facing) and translation to the device line protocol."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal, Union

from pydantic import BaseModel, ConfigDict, Field, model_validator

from . import encoder, keymap
from .mouse import MouseState

BUTTON_MASK = {"left": 1, "right": 2, "middle": 4}
MAX_ACTIONS = 2000
COORD_MAX = 100000


class ActionError(ValueError):
    """Raised when an action list is invalid."""


class _Base(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Point(_Base):
    x: int = Field(ge=0, le=COORD_MAX)
    y: int = Field(ge=0, le=COORD_MAX)


class MoveAction(_Base):
    t: Literal["move"]
    x: int = Field(ge=0, le=COORD_MAX)
    y: int = Field(ge=0, le=COORD_MAX)


class ClickAction(_Base):
    t: Literal["click"]
    x: int | None = Field(default=None, ge=0, le=COORD_MAX)
    y: int | None = Field(default=None, ge=0, le=COORD_MAX)
    button: Literal["left", "right", "middle"] = "left"

    @model_validator(mode="after")
    def _both_or_neither(self):
        if (self.x is None) != (self.y is None):
            raise ValueError("x and y must be provided together")
        return self


class DoubleClickAction(ClickAction):
    t: Literal["doubleclick"]


class DragAction(_Base):
    t: Literal["drag"]
    from_: Point = Field(alias="from")
    to: Point
    button: Literal["left", "right", "middle"] = "left"
    model_config = ConfigDict(extra="forbid", populate_by_name=True)


class ScrollAction(_Base):
    t: Literal["scroll"]
    dy: int = Field(default=0, ge=-127, le=127)
    dx: int = Field(default=0, ge=-127, le=127)
    x: int | None = Field(default=None, ge=0, le=COORD_MAX)
    y: int | None = Field(default=None, ge=0, le=COORD_MAX)


class TypeAction(_Base):
    t: Literal["type"]
    text: str = Field(min_length=1, max_length=20000)
    enc: Literal["auto", "gbk", "unicode", "mdwin", "ascii", "base64"] = "auto"
    char_delay_ms: int = Field(default=0, ge=0, le=1000)


class KeyAction(_Base):
    t: Literal["key"]
    keys: list[str] = Field(min_length=1, max_length=6)


class KeyDownAction(_Base):
    t: Literal["key_down"]
    keys: list[str] = Field(min_length=1, max_length=6)


class KeyUpAction(_Base):
    t: Literal["key_up"]
    keys: list[str] = Field(min_length=1, max_length=6)


class WaitAction(_Base):
    t: Literal["wait"]
    ms: int = Field(ge=1, le=60000)


Action = Union[
    MoveAction,
    ClickAction,
    DoubleClickAction,
    DragAction,
    ScrollAction,
    TypeAction,
    KeyAction,
    KeyDownAction,
    KeyUpAction,
    WaitAction,
]

ACTION_TYPES = (
    "move",
    "click",
    "doubleclick",
    "drag",
    "scroll",
    "type",
    "key",
    "key_down",
    "key_up",
    "wait",
)

_MODELS = {
    "move": MoveAction,
    "click": ClickAction,
    "doubleclick": DoubleClickAction,
    "drag": DragAction,
    "scroll": ScrollAction,
    "type": TypeAction,
    "key": KeyAction,
    "key_down": KeyDownAction,
    "key_up": KeyUpAction,
    "wait": WaitAction,
}


def validate_actions(raw: list) -> list:
    """Validate the raw action list, raising ActionError with the failing index."""
    if not isinstance(raw, list) or not raw:
        raise ActionError("actions must be a non-empty list")
    if len(raw) > MAX_ACTIONS:
        raise ActionError(f"too many actions ({len(raw)} > {MAX_ACTIONS})")

    actions = []
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            raise ActionError(f"actions[{index}] must be an object")
        kind = item.get("t")
        model = _MODELS.get(kind)
        if model is None:
            raise ActionError(
                f"actions[{index}].t={kind!r} is not supported; use one of {list(ACTION_TYPES)}"
            )
        try:
            actions.append(model.model_validate(item))
        except Exception as exc:  # pydantic ValidationError
            raise ActionError(f"actions[{index}]: {exc}") from exc
    return actions


@dataclass
class Step:
    """One high-level action translated into device lines."""

    index: int
    kind: str
    lines: list[str] = field(default_factory=list)

    def byte_size(self) -> int:
        return sum(len(line) + 1 for line in self.lines)


class Translator:
    """Translate validated actions into seq_writer lines."""

    def __init__(self, mouse: MouseState, gbk_table: dict[str, int] | None = None):
        self.mouse = mouse
        self.gbk_table = gbk_table if gbk_table is not None else encoder.load_gbk_table()
        self.kb_mods = 0
        self.kb_codes: list[int] = []

    # ---- keyboard state helpers ----
    def _split_keys(self, names: list[str]) -> tuple[int, list[int]]:
        try:
            return keymap.resolve_keys(names)
        except ValueError as exc:
            raise ActionError(str(exc)) from exc

    def _kbdset(self) -> str:
        codes = " ".join(str(c) for c in self.kb_codes)
        return f"kbdset {self.kb_mods} {codes}".rstrip()

    # ---- action translation ----
    def translate(self, actions: list) -> list[Step]:
        steps: list[Step] = []
        for index, action in enumerate(actions):
            step = Step(index=index, kind=action.t, lines=[f"step {index}"])
            handler = getattr(self, f"_do_{action.t}")
            handler(action, step)
            steps.append(step)
        return steps

    def _do_move(self, action: MoveAction, step: Step) -> None:
        step.lines.extend(self.mouse.move_lines(action.x, action.y))

    def _do_click(self, action: ClickAction, step: Step) -> None:
        if action.x is not None and action.y is not None:
            step.lines.extend(self.mouse.move_lines(action.x, action.y))
            step.lines.append("wait 40")
        step.lines.append(f"mclick {BUTTON_MASK[action.button]}")

    def _do_doubleclick(self, action: DoubleClickAction, step: Step) -> None:
        if action.x is not None and action.y is not None:
            step.lines.extend(self.mouse.move_lines(action.x, action.y))
            step.lines.append("wait 40")
        step.lines.append(f"mdclick {BUTTON_MASK[action.button]}")

    def _do_drag(self, action: DragAction, step: Step) -> None:
        mask = BUTTON_MASK[action.button]
        step.lines.extend(self.mouse.move_lines(action.from_.x, action.from_.y))
        step.lines.append("wait 60")
        step.lines.append(f"mbtn {mask}")
        step.lines.append("wait 60")
        step.lines.extend(self.mouse.move_lines(action.to.x, action.to.y))
        step.lines.append("wait 80")
        step.lines.append("mbtn 0")

    def _do_scroll(self, action: ScrollAction, step: Step) -> None:
        if action.x is not None and action.y is not None:
            step.lines.extend(self.mouse.move_lines(action.x, action.y))
            step.lines.append("wait 30")
        wheel = f"wheel {action.dy}"
        if action.dx:
            wheel += f" {action.dx}"
        step.lines.append(wheel)

    def _do_type(self, action: TypeAction, step: Step) -> None:
        encoding = action.enc
        if encoding == "auto":
            encoding = "gbk" if self.gbk_table else "unicode"
        items = encoder.text_to_alt_sequence(action.text, encoding, self.gbk_table)
        if not items:
            raise ActionError(f"type action produced no input (encoding={encoding})")
        for item in items:
            if "control" in item:
                step.lines.append(f"control {item['control']}")
            else:
                step.lines.append(f"code {item['code']}")
            if action.char_delay_ms:
                step.lines.append(f"wait {action.char_delay_ms}")

    def _kbd_line(self, mods: int, codes: list[int]) -> str:
        body = " ".join(str(c) for c in codes)
        return f"kbdset {mods} {body}".strip()

    def _do_key(self, action: KeyAction, step: Step) -> None:
        mods, codes = self._split_keys(action.keys)
        pressed_mods = self.kb_mods | mods
        pressed_codes = list(dict.fromkeys(self.kb_codes + codes))[:6]
        step.lines.append(self._kbd_line(pressed_mods, pressed_codes))
        step.lines.append(self._kbd_line(self.kb_mods, self.kb_codes))

    def _do_key_down(self, action: KeyDownAction, step: Step) -> None:
        mods, codes = self._split_keys(action.keys)
        self.kb_mods |= mods
        for code in codes:
            if code not in self.kb_codes:
                self.kb_codes.append(code)
        self.kb_codes = self.kb_codes[:6]
        step.lines.append(self._kbdset())

    def _do_key_up(self, action: KeyUpAction, step: Step) -> None:
        mods, codes = self._split_keys(action.keys)
        self.kb_mods &= ~mods
        self.kb_codes = [c for c in self.kb_codes if c not in codes]
        step.lines.append(self._kbdset())

    def _do_wait(self, action: WaitAction, step: Step) -> None:
        step.lines.append(f"wait {action.ms}")

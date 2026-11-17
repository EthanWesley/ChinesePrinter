"""Key names → USB HID usage / modifier bits.

Modifier bits follow the HID boot keyboard report:
bit0 LCtrl, bit1 LShift, bit2 LAlt, bit3 LGui,
bit4 RCtrl, bit5 RShift, bit6 RAlt, bit7 RGui.
"""

from __future__ import annotations

MOD_CTRL = 0x01
MOD_SHIFT = 0x02
MOD_ALT = 0x04
MOD_WIN = 0x08
MOD_RCTRL = 0x10
MOD_RSHIFT = 0x20
MOD_RALT = 0x40
MOD_RWIN = 0x80

MODIFIERS: dict[str, int] = {
    "ctrl": MOD_CTRL,
    "control": MOD_CTRL,
    "lctrl": MOD_CTRL,
    "shift": MOD_SHIFT,
    "lshift": MOD_SHIFT,
    "alt": MOD_ALT,
    "option": MOD_ALT,
    "lalt": MOD_ALT,
    "win": MOD_WIN,
    "gui": MOD_WIN,
    "meta": MOD_WIN,
    "cmd": MOD_WIN,
    "super": MOD_WIN,
    "lwin": MOD_WIN,
    "rctrl": MOD_RCTRL,
    "rshift": MOD_RSHIFT,
    "ralt": MOD_RALT,
    "rwin": MOD_RWIN,
}

KEYS: dict[str, int] = {
    # letters
    **{chr(ord("a") + i): 0x04 + i for i in range(26)},
    # digits (1..9 then 0)
    **{str(d): 0x1E + (d - 1) for d in range(1, 10)},
    "0": 0x27,
    # control keys
    "enter": 0x28,
    "return": 0x28,
    "esc": 0x29,
    "escape": 0x29,
    "backspace": 0x2A,
    "tab": 0x2B,
    "space": 0x2C,
    "capslock": 0x39,
    # punctuation (US layout)
    "-": 0x2D,
    "minus": 0x2D,
    "=": 0x2E,
    "equal": 0x2E,
    "[": 0x2F,
    "]": 0x30,
    "\\": 0x31,
    ";": 0x33,
    "'": 0x34,
    "`": 0x35,
    ",": 0x36,
    ".": 0x37,
    "/": 0x38,
    # editing / navigation
    "insert": 0x49,
    "home": 0x4A,
    "pageup": 0x4B,
    "pgup": 0x4B,
    "delete": 0x4C,
    "del": 0x4C,
    "end": 0x4D,
    "pagedown": 0x4E,
    "pgdn": 0x4E,
    "right": 0x4F,
    "left": 0x50,
    "down": 0x51,
    "up": 0x52,
    "printscreen": 0x46,
    "scrolllock": 0x47,
    "pause": 0x48,
    "menu": 0x65,
    # function keys
    **{f"f{i}": 0x3A + (i - 1) for i in range(1, 13)},
}

SHIFTED_SYMBOLS: dict[str, int] = {
    "!": 0x1E,
    "@": 0x1F,
    "#": 0x20,
    "$": 0x21,
    "%": 0x22,
    "^": 0x23,
    "&": 0x24,
    "*": 0x25,
    "(": 0x26,
    ")": 0x27,
    "_": 0x2D,
    "+": 0x2E,
    "{": 0x2F,
    "}": 0x30,
    "|": 0x31,
    ":": 0x33,
    '"': 0x34,
    "~": 0x35,
    "<": 0x36,
    ">": 0x37,
    "?": 0x38,
}


class KeyError_(ValueError):
    """Raised when a key name cannot be resolved."""


def resolve_keys(names: list[str]) -> tuple[int, list[int]]:
    """Resolve a key chord into (modifier_mask, keycodes).

    Accepts modifier names (ctrl/shift/alt/win), regular key names and
    single shifted symbols such as "!" (which imply Shift).
    """
    mods = 0
    codes: list[int] = []
    for raw in names:
        name = raw.strip().lower()
        if not name:
            continue
        if name in MODIFIERS:
            mods |= MODIFIERS[name]
            continue
        if name in KEYS:
            codes.append(KEYS[name])
            continue
        if name in SHIFTED_SYMBOLS:
            mods |= MOD_SHIFT
            codes.append(SHIFTED_SYMBOLS[name])
            continue
        raise KeyError_(f"unknown key: {raw}")
    if not codes and not mods:
        raise KeyError_("empty key chord")
    return mods, codes[:6]

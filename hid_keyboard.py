# -*- coding: utf-8 -*-
"""USB HID 键盘控制模块：直接写 /dev/hidg0 发送键盘报告。

适用于 Luckfox Pico KVM (RV1106G3) 等 Linux USB HID gadget 设备。

HID 键盘报告格式（8 字节）：
  byte 0: 修饰键位图
      0x01 Left Ctrl   0x02 Left Shift   0x04 Left Alt   0x08 Left GUI
      0x10 Right Ctrl  0x20 Right Shift  0x40 Right Alt  0x80 Right GUI
  byte 1: 保留（0x00）
  byte 2-7: 最多 6 个同时按下的键码

Alt 码打字原理（Windows 目标机）：
  1. 按住左 Alt
  2. 在小键盘上依次敲击数字
  3. 松开 Alt —— 目标电脑根据编码方案输入对应字符
  注意：必须用小键盘（Numpad）数字，不是主键盘数字行。
"""

import os
import time

# 默认 HID 设备路径（Linux USB gadget HID keyboard）
DEFAULT_DEVICE = "/dev/hidg0"
REPORT_SIZE = 8

# 修饰键
MOD_LCTRL = 0x01
MOD_LSHIFT = 0x02
MOD_LALT = 0x04
MOD_LGUI = 0x08
MOD_RCTRL = 0x10
MOD_RSHIFT = 0x20
MOD_RALT = 0x40
MOD_RGUI = 0x80

# 小键盘数字 HID 键码（Numpad0~9）
NUMPAD_KEYS = {
    "0": 0x62,
    "1": 0x59,
    "2": 0x5A,
    "3": 0x5B,
    "4": 0x5C,
    "5": 0x5D,
    "6": 0x5E,
    "7": 0x5F,
    "8": 0x60,
    "9": 0x61,
}

# 控制字符 -> HID 键码
KEY_ENTER = 0x28
KEY_TAB = 0x2B
KEY_SPACE = 0x2C
KEY_BACKSPACE = 0x2A

CONTROL_KEYS = {
    "\n": KEY_ENTER,
    "\r": KEY_ENTER,
    "\t": KEY_TAB,
}

# 默认延时（秒）。嵌入式设备上太快容易丢键。
DEFAULT_KEY_DELAY = 0.05
DEFAULT_ALT_RELEASE_DELAY = 0.08


class HidError(Exception):
    """HID 设备操作异常。"""


class HidKeyboard:
    """直接写 /dev/hidg0 模拟 USB HID 键盘。

    用法：
        kb = HidKeyboard("/dev/hidg0")
        kb.open()
        kb.type_alt_code(54992)   # 输入 "中" 的 GBK 十进制
        kb.close()

    或用 context manager：
        with HidKeyboard() as kb:
            kb.type_alt_code(20013)  # 输入 "中" 的 Unicode 十进制
    """

    def __init__(
        self,
        device=DEFAULT_DEVICE,
        key_delay=DEFAULT_KEY_DELAY,
        alt_release_delay=DEFAULT_ALT_RELEASE_DELAY,
    ):
        self.device = device
        self.key_delay = key_delay
        self.alt_release_delay = alt_release_delay
        self._fd = None

    # ---- 设备开关 ----

    def open(self):
        if self._fd is not None:
            return
        try:
            self._fd = os.open(self.device, os.O_WRONLY)
        except FileNotFoundError:
            raise HidError(
                f"HID 设备不存在: {self.device}\n"
                "请确认 USB HID gadget 已配置（通常在 /dev/hidg0）"
            )
        except PermissionError:
            raise HidError(
                f"无权限访问 {self.device}，请以 root 运行或加入对应用户组"
            )
        except OSError as exc:
            raise HidError(f"打开 HID 设备 {self.device} 失败: {exc}")

    def close(self):
        if self._fd is not None:
            try:
                os.close(self._fd)
            except OSError:
                pass
            self._fd = None

    def __enter__(self):
        self.open()
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close()

    # ---- 底层报告写入 ----

    def _write_report(self, modifier=0, keys=()):
        """写一个 8 字节 HID 键盘报告。"""
        if self._fd is None:
            raise HidError("HID 设备未打开")
        report = bytearray(REPORT_SIZE)
        report[0] = modifier & 0xFF
        for i, k in enumerate(keys[:6]):
            report[2 + i] = k
        try:
            os.write(self._fd, bytes(report))
        except OSError as exc:
            raise HidError(f"写入 HID 报告失败: {exc}")
        time.sleep(self.key_delay)

    def _release_all(self):
        """松开所有键。"""
        self._write_report(0)

    def _press_key(self, keycode, modifier=0):
        """按下单个键（保留修饰键状态）。"""
        self._write_report(modifier, (keycode,))

    def _release_key(self, modifier=0):
        """松开当前键（保留修饰键状态）。"""
        self._write_report(modifier)

    def _tap_key(self, keycode, modifier=0):
        """敲击一个键：按下再松开。"""
        self._press_key(keycode, modifier)
        self._release_key(modifier)

    # ---- Alt 码打字 ----

    def type_alt_code(self, code):
        """用 Alt + 十进制数字 + 松开 Alt 输入一个字符。

        code 必须是非负整数。
        GBK 模式：code = GBK 双字节拼成的十进制（如 "中"=54992）
        Unicode 模式：code = Unicode 码点十进制（如 "中"=20013）
        """
        if code is None or code < 0:
            return
        digits = str(code)
        # 1. 按住左 Alt
        self._write_report(MOD_LALT)
        # 2. 依次敲击小键盘数字
        for d in digits:
            keycode = NUMPAD_KEYS.get(d)
            if keycode is None:
                continue
            self._tap_key(keycode, MOD_LALT)
        # 3. 等待目标电脑处理完数字序列后松开 Alt
        time.sleep(self.alt_release_delay)
        self._release_all()

    def type_control_char(self, char):
        """输入控制字符（回车/制表符/空格等）。"""
        keycode = CONTROL_KEYS.get(char)
        if keycode is not None:
            self._tap_key(keycode)
        elif char == " ":
            self._tap_key(KEY_SPACE)

    def type_sequences(self, sequences, stop_event=None):
        """根据 encoding 模块产出的序列逐个输入。

        sequences 中每个元素：
            {"char": "中", "code": 54992, "control": False}
            {"char": "\\n", "code": None, "control": True}

        stop_event: threading.Event，set() 后会尽快停止打字。
        """
        for item in sequences:
            if stop_event is not None and stop_event.is_set():
                break
            if item.get("control"):
                self.type_control_char(item["char"])
            elif item.get("code") is not None:
                self.type_alt_code(item["code"])

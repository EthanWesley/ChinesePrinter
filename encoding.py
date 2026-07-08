# -*- coding: utf-8 -*-
"""编码转换模块：把中文字符转换为 GBK 或 Unicode 的十进制编码序列。

Alt 码打字原理：
- GBK 模式：按住 Alt + 输入 GBK 十进制编码 + 松开 Alt
  例如 "中" 的 GBK 编码是 0xD6D0 = 54992，所以输入 Alt+54992
- Unicode 模式：按住 Alt + 输入 Unicode 十进制码点 + 松开 Alt
  例如 "中" 的 Unicode 是 U+4E2D = 20013，所以输入 Alt+20013

GBK 编码策略（双保险）：
  1. 优先使用 Python 内置的 gbk 编解码（速度快，需 _codecs_cn 模块）
  2. 若内置 gbk 不可用（精简版 Python），回退到 gbk_table.py 内置编码表
  两种方式对调用方完全透明。
"""


def _check_system_gbk():
    """检测 Python 内置 GBK 编解码是否可用。"""
    try:
        "中".encode("gbk")
        return True
    except (LookupError, UnicodeEncodeError):
        return False


# Python 内置 GBK 是否可用
SYSTEM_GBK_AVAILABLE = _check_system_gbk()

# 内置回退表是否可用
_FALLBACK_AVAILABLE = False
try:
    import gbk_table as _gbk_table
    _FALLBACK_AVAILABLE = True
except ImportError:
    _FALLBACK_AVAILABLE = False

# 对外暴露：GBK 模式是否可用（系统或回退表任一可用即可）
GBK_AVAILABLE = SYSTEM_GBK_AVAILABLE or _FALLBACK_AVAILABLE

# 标记当前使用的 GBK 来源
GBK_SOURCE = (
    "system" if SYSTEM_GBK_AVAILABLE
    else ("fallback_table" if _FALLBACK_AVAILABLE else "none")
)


def char_to_gbk_decimal(ch: str):
    """把单个字符转换为 GBK 编码的十进制整数。

    GBK 用双字节表示中文字符，把两个字节拼成一个整数。
    例如 "中" -> b'\\xd6\\xd0' -> 0xD6D0 -> 54992
    ASCII 字符（单字节）返回字节值（0-127）。
    无法用 GBK 编码的字符返回 None。
    """
    # 优先用系统 GBK
    if SYSTEM_GBK_AVAILABLE:
        try:
            raw = ch.encode("gbk")
            if len(raw) == 1:
                return raw[0]
            value = 0
            for byte in raw:
                value = (value << 8) | byte
            return value
        except (UnicodeEncodeError, LookupError):
            return None
    # 回退到内置表
    if _FALLBACK_AVAILABLE:
        return _gbk_table.char_to_gbk_decimal(ch)
    return None


def char_to_unicode_decimal(ch: str) -> int:
    """把单个字符转换为 Unicode 码点的十进制整数。

    例如 "中" -> ord("中") -> 20013
    """
    return ord(ch)


def text_to_gbk_sequences(text: str):
    """把整段文本转换成每个字符的 GBK 十进制编码列表。

    无法用 GBK 编码的字符会被记录到 skipped 列表。
    返回 (sequences, skipped) 二元组：
      sequences: [{char, code}] 每个字符及其十进制编码
      skipped:   无法编码的字符列表
    """
    sequences = []
    skipped = []
    for ch in text:
        if ch in ("\r", "\n", "\t"):
            # 控制字符直接保留，打字时映射成对应按键
            sequences.append({"char": ch, "code": None, "control": True})
            continue
        code = char_to_gbk_decimal(ch)
        if code is None:
            skipped.append(ch)
            sequences.append({"char": ch, "code": None, "control": False})
        else:
            sequences.append({"char": ch, "code": code, "control": False})
    return sequences, skipped


def text_to_unicode_sequences(text: str):
    """把整段文本转换成每个字符的 Unicode 十进制码点列表。

    返回 (sequences, skipped) 二元组，结构与 gbk 版本一致。
    Unicode 能表示所有字符，所以 skipped 通常为空。
    """
    sequences = []
    skipped = []
    for ch in text:
        if ch in ("\r", "\n", "\t"):
            sequences.append({"char": ch, "code": None, "control": True})
            continue
        code = char_to_unicode_decimal(ch)
        sequences.append({"char": ch, "code": code, "control": False})
    return sequences, skipped


def encode_text(text: str, encoding: str):
    """根据编码方案把文本转换成 Alt 码序列。

    encoding 取值：
      "gbk"     -> GBK 十进制
      "unicode" -> Unicode 十进制码点
    返回 (sequences, skipped)。
    """
    if encoding == "gbk":
        if not GBK_AVAILABLE:
            raise RuntimeError(
                "GBK 编码不可用：Python 内置 GBK 不支持，且内置回退表缺失。\n"
                "请改用 Unicode 编码方案。"
            )
        return text_to_gbk_sequences(text)
    if encoding == "unicode":
        return text_to_unicode_sequences(text)
    raise ValueError(f"不支持的编码方案: {encoding}（仅支持 gbk / unicode）")

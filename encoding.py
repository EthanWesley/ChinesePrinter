# -*- coding: utf-8 -*-
"""编码转换模块：把中文字符转换为 GBK 或 Unicode 的十进制编码序列。

Alt 码打字原理：
- GBK 模式：按住 Alt + 输入 GBK 十进制编码 + 松开 Alt
  例如 "中" 的 GBK 编码是 0xD6D0 = 54992，所以输入 Alt+54992
- Unicode 模式：按住 Alt + 输入 Unicode 十进制码点 + 松开 Alt
  例如 "中" 的 Unicode 是 U+4E2D = 20013，所以输入 Alt+20013
"""

def _check_gbk_available():
    """检测当前 Python 环境是否支持 GBK 编码。

    嵌入式 Linux（如 Buildroot）上的精简 Python 可能未包含 _codecs_cn
    模块，导致 GBK 编码不可用。
    """
    try:
        "中".encode("gbk")
        return True
    except (LookupError, UnicodeEncodeError):
        return False


GBK_AVAILABLE = _check_gbk_available()


def char_to_gbk_decimal(ch: str) -> int:
    """把单个字符转换为 GBK 编码的十进制整数。

    GBK 用双字节表示中文字符，把两个字节拼成一个整数。
    例如 "中" -> b'\\xd6\\xd0' -> 0xD6D0 -> 54992
    非 GBK 字符（如 ASCII）会抛出异常，调用方需自行处理。
    """
    raw = ch.encode("gbk")
    if len(raw) == 1:
        # ASCII 字符直接返回字节值（0-127），Alt 码一般用不上
        return raw[0]
    # 多字节拼成一个大整数：高位字节在前
    value = 0
    for byte in raw:
        value = (value << 8) | byte
    return value


def char_to_unicode_decimal(ch: str) -> int:
    """把单个字符转换为 Unicode 码点的十进制整数。

    例如 "中" -> ord("中") -> 20013
    """
    return ord(ch)


def text_to_gbk_sequences(text: str):
    """把整段文本转换成每个字符的 GBK 十进制编码列表。

    无法用 GBK 编码的字符会被替换成问号占位并记录。
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
        try:
            code = char_to_gbk_decimal(ch)
            sequences.append({"char": ch, "code": code, "control": False})
        except (UnicodeEncodeError, LookupError):
            skipped.append(ch)
            sequences.append({"char": ch, "code": None, "control": False})
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
                "当前 Python 环境不支持 GBK 编码。\n"
                "请安装完整版 Python 或 _codecs_cn 模块，或改用 Unicode 编码方案。"
            )
        return text_to_gbk_sequences(text)
    if encoding == "unicode":
        return text_to_unicode_sequences(text)
    raise ValueError(f"不支持的编码方案: {encoding}（仅支持 gbk / unicode）")

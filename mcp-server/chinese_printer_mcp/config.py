"""Configuration loading: JSON file < environment variables < set_config tool."""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, fields
from pathlib import Path

CONFIG_ENV = "CHINESEPRINTER_CONFIG"
DEFAULT_CONFIG_PATH = Path.home() / ".chinese-printer-mcp.json"

DEFAULTS = {
    "host": "chinese-printer.local",
    "port": 8849,
    "typewriter_port": 8848,
    "mouse_assume_absolute": False,
    "rehome_before_first_move": True,
    "poll_interval_ms": 300,
    "capture_scale": 0.5,
    "capture_quality": 75,
    "default_timeout_s": 120,
}


@dataclass
class Config:
    host: str = DEFAULTS["host"]
    port: int = DEFAULTS["port"]
    typewriter_port: int = DEFAULTS["typewriter_port"]
    mouse_assume_absolute: bool = DEFAULTS["mouse_assume_absolute"]
    rehome_before_first_move: bool = DEFAULTS["rehome_before_first_move"]
    poll_interval_ms: int = DEFAULTS["poll_interval_ms"]
    capture_scale: float = DEFAULTS["capture_scale"]
    capture_quality: int = DEFAULTS["capture_quality"]
    default_timeout_s: int = DEFAULTS["default_timeout_s"]

    @property
    def base_url(self) -> str:
        return f"http://{self.host}:{self.port}"

    @property
    def typewriter_url(self) -> str:
        return f"http://{self.host}:{self.typewriter_port}"

    def update(self, **values) -> None:
        for key, value in values.items():
            if value is not None and hasattr(self, key):
                setattr(self, key, value)

    def to_dict(self) -> dict:
        return asdict(self)


def config_path() -> Path:
    raw = os.environ.get(CONFIG_ENV)
    return Path(raw) if raw else DEFAULT_CONFIG_PATH


def load_config() -> Config:
    cfg = Config()
    path = config_path()
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            data = {}
        if isinstance(data, dict):
            cfg.update(**{k: v for k, v in data.items() if k in DEFAULTS})
    # 环境变量覆盖（便于 MCP 客户端在启动配置中注入设备地址）
    if os.environ.get("CHINESEPRINTER_HOST"):
        cfg.host = os.environ["CHINESEPRINTER_HOST"]
    if os.environ.get("CHINESEPRINTER_PORT"):
        try:
            cfg.port = int(os.environ["CHINESEPRINTER_PORT"])
        except ValueError:
            pass
    if os.environ.get("CHINESEPRINTER_TYPEWRITER_PORT"):
        try:
            cfg.typewriter_port = int(os.environ["CHINESEPRINTER_TYPEWRITER_PORT"])
        except ValueError:
            pass
    return cfg


def save_config(cfg: Config) -> Path:
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    data = {f.name: getattr(cfg, f.name) for f in fields(cfg)}
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return path

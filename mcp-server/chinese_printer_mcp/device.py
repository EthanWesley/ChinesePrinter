"""HTTP client for the :8849 automation channel (and :8848 busy probe)."""

from __future__ import annotations

import httpx

from .config import Config


class DeviceError(RuntimeError):
    """Raised when the device is unreachable or returns an error."""


class DeviceClient:
    def __init__(self, cfg: Config, timeout: float = 30.0, transport: httpx.BaseTransport | None = None):
        self.cfg = cfg
        self.timeout = timeout
        self._transport = transport

    # ---- helpers ----
    def _request(self, method: str, url: str, **kwargs) -> httpx.Response:
        try:
            with httpx.Client(
                timeout=kwargs.pop("timeout", self.timeout), transport=self._transport
            ) as client:
                return client.request(method, url, **kwargs)
        except httpx.ConnectError as exc:
            raise DeviceError(
                f"无法连接设备 {url}：{exc}。请确认设备已上电、与 PC 同网段，"
                "并用 set_config(host=...) 设置正确地址。"
            ) from exc
        except httpx.TimeoutException as exc:
            raise DeviceError(f"请求超时：{url}") from exc

    def _json(self, response: httpx.Response) -> dict:
        try:
            data = response.json()
        except ValueError as exc:
            raise DeviceError(f"设备返回了非 JSON 响应 (HTTP {response.status_code})") from exc
        if not isinstance(data, dict):
            raise DeviceError("设备返回了意外的 JSON 结构")
        return data

    # ---- endpoints ----
    def health(self) -> dict:
        response = self._request("GET", f"{self.cfg.base_url}/health", timeout=8.0)
        if response.status_code != 200:
            raise DeviceError(f"/health 返回 HTTP {response.status_code}")
        return self._json(response)

    def capture(self, warmup: int = 3) -> tuple[bytes, dict]:
        response = self._request(
            "GET", f"{self.cfg.base_url}/capture", params={"warmup": warmup}, timeout=30.0
        )
        if response.status_code != 200:
            detail = ""
            try:
                detail = response.json().get("detail", "")
            except ValueError:
                pass
            raise DeviceError(
                f"抓取失败 (HTTP {response.status_code}) {detail}".strip()
            )
        headers = {
            "width": _int(response.headers.get("x-frame-width")),
            "height": _int(response.headers.get("x-frame-height")),
            "format": response.headers.get("x-frame-format", ""),
        }
        if not response.content:
            raise DeviceError("抓取返回了空响应体")
        return response.content, headers

    def post_sequence(self, lines: list[str]) -> dict:
        body = ("\n".join(lines) + "\n").encode("ascii")
        response = self._request(
            "POST",
            f"{self.cfg.base_url}/seq",
            content=body,
            headers={"Content-Type": "text/plain; charset=ascii"},
            timeout=10.0,
        )
        data = self._json(response)
        if response.status_code != 200 or not data.get("ok"):
            raise DeviceError(data.get("msg") or f"/seq 返回 HTTP {response.status_code}")
        return data

    def stop(self) -> dict:
        response = self._request("POST", f"{self.cfg.base_url}/stop", timeout=8.0)
        return self._json(response)

    def abort(self) -> dict:
        response = self._request("POST", f"{self.cfg.base_url}/abort", timeout=8.0)
        return self._json(response)

    def probe(self) -> dict:
        response = self._request("GET", f"{self.cfg.base_url}/probe", timeout=20.0)
        return self._json(response)

    def typewriter_busy(self) -> bool:
        """True when the :8848 typewriter is typing (best-effort, never raises)."""
        try:
            response = self._request(
                "GET", f"{self.cfg.typewriter_url}/api/health", timeout=4.0
            )
            if response.status_code != 200:
                return False
            return bool(self._json(response).get("busy"))
        except DeviceError:
            return False


def _int(value: str | None) -> int:
    try:
        return int(value) if value is not None else 0
    except ValueError:
        return 0

from __future__ import annotations

import json
import socket
from dataclasses import dataclass
from typing import Any

from .ws import MiniWebSocket

PING_CODE = "result={'agentcontroller': True, 'objects': len(__import__('bpy').data.objects)}"


@dataclass
class Endpoint:
    host: str
    port: int
    kind: str
    detail: str

    def as_dict(self) -> dict[str, Any]:
        return {"host": self.host, "port": self.port, "backend": self.kind, "detail": self.detail}


def encode_lab(code: str, strict_json: bool = True) -> bytes:
    payload = json.dumps({"type": "execute", "code": code, "strict_json": strict_json}, separators=(",", ":"))
    return payload.encode("utf-8") + b"\0"


def decode_lab(data: bytes) -> dict[str, Any]:
    slice_ = data.split(b"\0", 1)[0]
    return json.loads(slice_.decode("utf-8"))


def is_lab_success(value: dict[str, Any]) -> bool:
    status = str(value.get("status") or "").lower()
    return status in {"ok", "success"} or "result" in value


def handshake(host: str = "127.0.0.1", ports: range | None = None) -> list[Endpoint]:
    found: list[Endpoint] = []
    for port in ports or range(9876, 9897):
        if ep := _probe_lab(host, port):
            found.append(ep)
            continue
        if ep := _probe_ws(host, port):
            found.append(ep)
    return found


def execute(endpoint: Endpoint, code: str) -> Any:
    if endpoint.kind == "bpy-lab":
        data = _roundtrip(endpoint.host, endpoint.port, encode_lab(code), timeout=8.0, until_null=True)
        return decode_lab(data)
    ws = MiniWebSocket(f"ws://{endpoint.host}:{endpoint.port}", timeout=8.0)
    try:
        ws.send_text(json.dumps({"type": "execute_code", "params": {"code": code}}))
        return json.loads(ws.recv_text())
    finally:
        ws.close()


def scene_objects(endpoint: Endpoint) -> list[dict[str, Any]]:
    code = "import bpy\nresult=[{'name': o.name, 'type': o.type} for o in bpy.data.objects]"
    raw = execute(endpoint, code)
    result = raw.get("result", raw) if isinstance(raw, dict) else raw
    if isinstance(result, dict) and "result" in result:
        result = result["result"]
    if not isinstance(result, list):
        return []
    return [item for item in result if isinstance(item, dict) and item.get("name")]


def _probe_lab(host: str, port: int) -> Endpoint | None:
    try:
        data = _roundtrip(host, port, encode_lab(PING_CODE), timeout=0.25, until_null=True)
        decoded = decode_lab(data)
    except (OSError, json.JSONDecodeError, UnicodeDecodeError, TimeoutError, ValueError):
        return None
    if not is_lab_success(decoded):
        return None
    return Endpoint(host, port, "bpy-lab", "Blender Lab MCP (null-terminated JSON)")


def _probe_ws(host: str, port: int) -> Endpoint | None:
    try:
        ws = MiniWebSocket(f"ws://{host}:{port}", timeout=0.25)
        try:
            ws.send_text('{"type":"get_scene_info"}')
            text = ws.recv_text()
        finally:
            ws.close()
    except OSError:
        return None
    if "unknown" in text.lower() and "error" in text.lower():
        return None
    if "{" not in text:
        return None
    return Endpoint(host, port, "bpy-ws", "Blender community WebSocket")


def _roundtrip(host: str, port: int, payload: bytes, timeout: float, until_null: bool) -> bytes:
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(payload)
        collected = bytearray()
        while True:
            chunk = sock.recv(16384)
            if not chunk:
                break
            collected.extend(chunk)
            if until_null and 0 in collected:
                break
            if not until_null:
                break
        if not collected:
            raise TimeoutError("empty blender response")
        return bytes(collected)

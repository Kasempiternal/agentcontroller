"""Identity classification and capability probe. Mirrors Sources/MCPTools/Routing."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urlparse

from .result import ToolResult

ROUTABLE_TOOLS = frozenset(
    {
        "snapshot",
        "describe_screen",
        "click",
        "double_click",
        "right_click",
        "type_text",
        "read_text",
        "read_all_text",
        "assert_visible",
        "assert_not_visible",
        "assert_value",
        "wait_for_element",
        "find_elements",
        "get_element_tree",
        "get_element_attributes",
        "get_focused_element",
        "screenshot_window",
        "screenshot_element",
        "scroll",
        "scroll_until_visible",
        "swipe",
        "drag_drop",
        "send_shortcut",
        "open_url",
        "run_app_code",
    }
)

CHROMIUM_BUNDLES = {
    "com.google.chrome",
    "google-chrome",
    "chromium",
    "chromium-browser",
    "brave",
    "brave-browser",
    "microsoft-edge",
    "msedge",
    "chrome",
    "google chrome",
}
BROWSER_BUNDLES = CHROMIUM_BUNDLES | {"firefox", "safari", "org.mozilla.firefox"}
BLENDER_BUNDLES = {"org.blenderfoundation.blender", "blender", "blender.exe"}


@dataclass
class TargetIdentity:
    raw: str
    kind: str  # url | iosSimulator | processID | application
    url: str | None = None
    pid: int | None = None
    bundle_hint: str | None = None
    udid: str | None = None

    @property
    def is_http(self) -> bool:
        if not self.url:
            return False
        scheme = urlparse(self.url).scheme.lower()
        return scheme in {"http", "https", "file", "about", "data"}


def parse_url(raw: str) -> str | None:
    lowered = raw.lower()
    if lowered.startswith(("http://", "https://", "file://", "about:", "data:")):
        return raw
    return None


def parse_udid(raw: str) -> str | None:
    value = raw[4:] if raw.startswith("sim:") else raw
    if value.lower() == "booted":
        return "booted"
    compact = value.replace("-", "")
    if compact.isalnum() and all(c in "0123456789abcdefABCDEF" for c in compact):
        if len(compact) in {32, 40}:
            return value
    return None


def parse_pid(raw: str) -> int | None:
    if raw.isdigit() and int(raw) > 0:
        return int(raw)
    return None


def identity_from_args(args: dict[str, Any]) -> TargetIdentity | None:
    url = args.get("url")
    if isinstance(url, str) and parse_url(url):
        return TargetIdentity(raw=url, kind="url", url=url)
    udid = args.get("udid")
    if isinstance(udid, str) and parse_udid(udid):
        parsed = parse_udid(udid)
        return TargetIdentity(raw=udid, kind="iosSimulator", udid=parsed)
    for key in ("app", "target", "bundleId"):
        value = args.get(key)
        if isinstance(value, str) and value:
            return parse_identity(value)
    return None


def parse_identity(raw: str) -> TargetIdentity:
    trimmed = raw.strip()
    if url := parse_url(trimmed):
        return TargetIdentity(raw=trimmed, kind="url", url=url)
    if udid := parse_udid(trimmed):
        return TargetIdentity(raw=trimmed, kind="iosSimulator", udid=udid)
    if pid := parse_pid(trimmed):
        return TargetIdentity(raw=trimmed, kind="processID", pid=pid)
    return TargetIdentity(raw=trimmed, kind="application", bundle_hint=trimmed)


def _hint(identity: TargetIdentity) -> str:
    return (identity.bundle_hint or "").lower()


def is_chromium(identity: TargetIdentity) -> bool:
    if identity.kind == "url":
        return identity.is_http
    return _hint(identity) in CHROMIUM_BUNDLES


def is_browser(identity: TargetIdentity) -> bool:
    if identity.kind == "url":
        return identity.is_http
    return _hint(identity) in BROWSER_BUNDLES


def is_blender(identity: TargetIdentity) -> bool:
    return _hint(identity) in BLENDER_BUNDLES


@dataclass
class CapabilityRecord:
    target: str
    backend: str
    reason: str
    fallback: str = "ax"
    endpoint: str | None = None
    protocol_name: str | None = None
    pid: int | None = None
    headless: bool = False
    ask: str | None = None
    ask_detail: str | None = None
    candidates: list[dict[str, Any]] = field(default_factory=list)
    extras: dict[str, Any] = field(default_factory=dict)

    def handles(self, tool: str) -> bool:
        if self.backend in {"ax", "hid"}:
            return False
        return tool in ROUTABLE_TOOLS

    def as_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "target": self.target,
            "backend": self.backend,
            "fallback": self.fallback,
            "reason": self.reason,
            "headless": self.headless,
        }
        if self.endpoint:
            payload["endpoint"] = self.endpoint
        if self.protocol_name:
            payload["protocol"] = self.protocol_name
        if self.pid is not None:
            payload["pid"] = self.pid
        if self.ask:
            payload["ask"] = self.ask
        if self.ask_detail:
            payload["ask_detail"] = self.ask_detail
        if self.candidates:
            payload["candidates"] = self.candidates
        payload.update(self.extras)
        return payload


def classify(identity: TargetIdentity) -> CapabilityRecord:
    if identity.kind == "url" and identity.is_http:
        return CapabilityRecord(
            identity.raw,
            "cdp",
            "URL identity — CDP compact a11y refs; headless unless a user Chrome debug port is open.",
            headless=True,
        )
    if identity.kind == "iosSimulator":
        return CapabilityRecord(
            identity.raw,
            "ios-sim",
            "iOS simulator UDID — idb/WDA. On Linux this MCP reports missing-addon; drive sims from the macOS server.",
            extras={"udid": identity.udid or identity.raw},
        )
    if is_blender(identity):
        return CapabilityRecord(
            identity.raw,
            "bpy-lab",
            "Blender identity — in-process bpy if a socket handshakes, AT-SPI/UIA for chrome otherwise.",
        )
    if is_chromium(identity):
        return CapabilityRecord(
            identity.raw,
            "cdp",
            "Chromium-family browser — CDP for page content when a debug port is reachable.",
        )
    if is_browser(identity):
        return CapabilityRecord(
            identity.raw,
            "ax",
            "Browser without a CDP attach path. Native accessibility of the window.",
        )
    return CapabilityRecord(
        identity.raw,
        "ax",
        "Native app — accessibility backend; HID/focus only as escape hatch.",
    )


def probe(identity: TargetIdentity) -> CapabilityRecord:
    record = classify(identity)
    if record.backend == "cdp":
        return _probe_cdp(identity, record)
    if record.backend in {"bpy-lab", "bpy-ws"}:
        return _probe_blender(identity, record)
    if record.backend == "ios-sim":
        record.backend = "ax"
        record.ask = "missing-addon"
        record.ask_detail = "iOS simulator control is implemented on the macOS AgentController server."
        record.reason = "ax-fallback: iOS sim routing is macOS-only"
        return record
    return record


def _probe_cdp(identity: TargetIdentity, record: CapabilityRecord) -> CapabilityRecord:
    from .backends.cdp import find_chrome_binary, find_debug_port

    binary = find_chrome_binary()
    if binary:
        record.extras["chromeBinary"] = binary
    port = find_debug_port()
    if port is not None:
        record.endpoint = f"127.0.0.1:{port}"
        record.protocol_name = "cdp"
        record.headless = False
        record.extras["attached"] = True
        record.reason = "Attached to an existing Chrome DevTools port."
        return record
    if identity.kind == "url" and identity.is_http:
        if binary is None:
            record.backend = "ax"
            record.ask = "missing-addon"
            record.ask_detail = "No Chromium browser found. Install Chrome/Chromium/Edge, or launch with --remote-debugging-port=9222."
            record.reason = "URL target but no CDP browser is available."
            record.extras["available"] = False
            return record
        record.headless = True
        record.protocol_name = "cdp"
        record.extras["available"] = True
        return record
    record.backend = "ax"
    record.reason = "Chromium without a DevTools port — native accessibility for browser chrome."
    return record


def _probe_blender(identity: TargetIdentity, record: CapabilityRecord) -> CapabilityRecord:
    from .backends.blender import handshake

    endpoints = handshake()
    if not endpoints:
        record.backend = "ax"
        record.ask = "missing-addon"
        record.ask_detail = "Blender identified but no Lab/community socket answered on 127.0.0.1:9876-9896."
        record.reason = "ax-fallback: blender addon not listening"
        return record
    if len(endpoints) > 1:
        record.backend = "ax"
        record.ask = "multi-instance"
        record.ask_detail = "Multiple Blender sockets answered. Pass a port to pick one."
        record.candidates = [ep.as_dict() for ep in endpoints]
        record.reason = "ax-fallback until the Blender instance is disambiguated"
        return record
    hit = endpoints[0]
    record.backend = hit.kind
    record.endpoint = f"{hit.host}:{hit.port}"
    record.protocol_name = "blender-lab" if hit.kind == "bpy-lab" else "blender-ws"
    record.reason = "Blender socket handshake succeeded."
    if not code_exec_granted("bpy"):
        record.ask = "code-exec-consent"
        record.ask_detail = "run_app_code executes Python inside Blender. Pass consent:true once."
    return record


def consent_path() -> str:
    override = os.environ.get("AGENTCONTROLLER_CONSENT_PATH")
    if override:
        return override
    xdg = os.environ.get("XDG_DATA_HOME")
    root = os.path.join(xdg, "agentcontroller") if xdg else os.path.join(os.path.expanduser("~"), ".local", "share", "agentcontroller")
    return os.path.join(root, "code-exec-consent.json")


def code_exec_granted(backend: str) -> bool:
    path = consent_path()
    try:
        with open(path, encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return False
    granted = payload.get("granted") or []
    return backend in granted


def grant_code_exec(backend: str) -> None:
    path = consent_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    granted: set[str] = set()
    try:
        with open(path, encoding="utf-8") as handle:
            granted = set(json.load(handle).get("granted") or [])
    except (OSError, json.JSONDecodeError):
        granted = set()
    granted.add(backend)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump({"granted": sorted(granted)}, handle)


def require_consent(args: dict[str, Any], backend: str, detail: str) -> dict[str, Any] | None:
    if code_exec_granted(backend):
        return None
    if args.get("consent") is True:
        grant_code_exec(backend)
        return None
    return ToolResult.error(
        f"Code execution ({detail}) requires consent:true once per machine. This runs inside the target app."
    )

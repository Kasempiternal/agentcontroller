from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
from typing import Any
from urllib.error import URLError
from urllib.request import urlopen

from .ws import MiniWebSocket

INTERACTIVE_ROLES = {
    "button",
    "link",
    "textbox",
    "searchbox",
    "checkbox",
    "radio",
    "combobox",
    "slider",
    "tab",
    "menuitem",
    "switch",
    "option",
    "treeitem",
    "spinbutton",
    "listbox",
    "textfield",
}

_owned: dict[str, Any] = {"process": None, "port": None, "ws": None, "key": None}


def find_chrome_binary() -> str | None:
    if "AGENTCONTROLLER_CHROME" in os.environ:
        override = os.environ["AGENTCONTROLLER_CHROME"]
        if override and os.access(override, os.X_OK):
            return override
        return None
    for name in ("google-chrome", "chromium", "chromium-browser", "microsoft-edge", "brave-browser"):
        path = shutil.which(name)
        if path:
            return path
    return None


def find_debug_port() -> int | None:
    for port in (9222, 9229, 9333):
        if list_pages(port):
            return port
    return None


def list_pages(port: int) -> list[dict[str, str]]:
    try:
        with urlopen(f"http://127.0.0.1:{port}/json/list", timeout=0.3) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (URLError, TimeoutError, json.JSONDecodeError, OSError):
        return []
    pages = []
    if not isinstance(payload, list):
        return []
    for item in payload:
        if not isinstance(item, dict):
            continue
        if item.get("type") not in {"page", "webview"}:
            continue
        ws = item.get("webSocketDebuggerUrl")
        if not ws:
            continue
        pages.append({"url": str(item.get("url") or ""), "ws": ws})
    return pages


def flatten_ax(nodes: list[Any], interactive_only: bool = True, session_key: str = "page") -> list[dict[str, Any]]:
    refs: list[dict[str, Any]] = []
    for node in nodes:
        if not isinstance(node, dict) or node.get("ignored"):
            continue
        role = _ax_atom(node.get("role")) or "generic"
        name = _ax_atom(node.get("name")) or ""
        if interactive_only and role.lower() not in INTERACTIVE_ROLES:
            continue
        backend = node.get("backendDOMNodeId")
        if not isinstance(backend, int) or backend <= 0:
            continue
        refs.append(
            {
                "kind": "cdp",
                "sessionKey": session_key,
                "backendNodeId": backend,
                "role": role,
                "label": name,
            }
        )
    return refs


def compact_elements(ids: list[str], refs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out = []
    for ident, ref in zip(ids, refs):
        item = {"id": ident, "role": ref.get("role", "generic"), "enabled": True}
        if ref.get("label"):
            item["label"] = ref["label"]
        out.append(item)
    return out


def _ax_atom(value: Any) -> str | None:
    if isinstance(value, str):
        return value
    if isinstance(value, dict) and isinstance(value.get("value"), str):
        return value["value"]
    return None


class CDPClient:
    def __init__(self, ws_url: str) -> None:
        self.ws = MiniWebSocket(ws_url, timeout=15.0)
        self.next_id = 1
        self.call("Runtime.enable")
        self.call("Page.enable")

    def call(self, method: str, params: dict[str, Any] | None = None) -> Any:
        ident = self.next_id
        self.next_id += 1
        self.ws.send_text(json.dumps({"id": ident, "method": method, "params": params or {}}))
        deadline = time.time() + 15
        while time.time() < deadline:
            message = json.loads(self.ws.recv_text())
            if message.get("id") != ident:
                continue
            if "error" in message:
                raise RuntimeError(message["error"].get("message") or "CDP error")
            return message.get("result") or {}
        raise TimeoutError(method)

    def close(self) -> None:
        self.ws.close()


def ensure_session(url: str | None, headless: bool = True) -> CDPClient:
    if _owned.get("ws") and _owned.get("key") == (url or "default"):
        return _owned["ws"]
    pages = []
    port = find_debug_port()
    if port is not None:
        pages = list_pages(port)
    if not pages:
        binary = find_chrome_binary()
        if not binary:
            raise RuntimeError(
                "No Chromium browser found. Install Chrome/Chromium/Edge, or launch with --remote-debugging-port=9222."
            )
        port = _launch(binary, headless=headless)
        pages = list_pages(port)
    if not pages:
        raise RuntimeError("Chrome launched but no DevTools page target was listed")
    target = pages[0]
    if url:
        for page in pages:
            if page["url"].startswith(url) or url.startswith(page["url"]):
                target = page
                break
    client = CDPClient(target["ws"])
    if url:
        client.call("Page.navigate", {"url": url})
        time.sleep(0.3)
    _owned["ws"] = client
    _owned["key"] = url or "default"
    return client


def snapshot(url: str, interactive_only: bool = True) -> list[dict[str, Any]]:
    client = ensure_session(url, headless=True)
    client.call("Accessibility.enable")
    tree = client.call("Accessibility.getFullAXTree")
    nodes = tree.get("nodes") if isinstance(tree, dict) else None
    return flatten_ax(nodes or [], interactive_only, session_key=url)


def click(client: CDPClient, backend_node_id: int) -> None:
    resolved = client.call("DOM.resolveNode", {"backendNodeId": backend_node_id})
    object_id = (resolved.get("object") or {}).get("objectId")
    if not object_id:
        raise RuntimeError("DOM.resolveNode did not return an objectId")
    client.call(
        "Runtime.callFunctionOn",
        {
            "objectId": object_id,
            "functionDeclaration": "function(){ this.click(); if (this.focus) this.focus(); }",
            "returnByValue": True,
        },
    )


def type_text(client: CDPClient, backend_node_id: int, text: str) -> None:
    resolved = client.call("DOM.resolveNode", {"backendNodeId": backend_node_id})
    object_id = (resolved.get("object") or {}).get("objectId")
    if not object_id:
        raise RuntimeError("DOM.resolveNode did not return an objectId")
    client.call(
        "Runtime.callFunctionOn",
        {
            "objectId": object_id,
            "functionDeclaration": "function(t){ this.focus(); if ('value' in this){ this.value=t; this.dispatchEvent(new Event('input',{bubbles:true})); this.dispatchEvent(new Event('change',{bubbles:true})); } }",
            "arguments": [{"value": text}],
            "returnByValue": True,
        },
    )


def evaluate(url: str, expression: str) -> Any:
    client = ensure_session(url, headless=True)
    return client.call(
        "Runtime.evaluate",
        {"expression": expression, "returnByValue": True, "awaitPromise": True},
    )


def screenshot_jpeg(url: str) -> bytes:
    import base64

    client = ensure_session(url, headless=True)
    result = client.call("Page.captureScreenshot", {"format": "jpeg", "quality": 70})
    data = result.get("data")
    if not data:
        raise RuntimeError("Page.captureScreenshot returned no data")
    return base64.b64decode(data)


def _launch(binary: str, headless: bool) -> int:
    port = _free_port()
    profile = os.path.join(tempfile.gettempdir(), "agentcontroller-cdp-profile")
    os.makedirs(profile, exist_ok=True)
    args = [
        binary,
        f"--remote-debugging-port={port}",
        f"--user-data-dir={profile}",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-gpu",
        "about:blank",
    ]
    if headless:
        args.insert(1, "--headless=new")
    process = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    _owned["process"] = process
    _owned["port"] = port
    for _ in range(100):
        if list_pages(port):
            break
        time.sleep(0.05)
    return port


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])

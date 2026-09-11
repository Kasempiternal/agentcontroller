from __future__ import annotations

from typing import Any

from ..result import ToolResult
from ..routing import (
    ROUTABLE_TOOLS,
    CapabilityRecord,
    identity_from_args,
    probe,
    require_consent,
)

_HANDLES: dict[str, dict[str, Any]] = {}
_SEQ = 0


def allocate_ids(count: int) -> list[str]:
    global _SEQ
    ids = []
    for _ in range(count):
        _SEQ += 1
        ids.append(f"e{_SEQ}")
    return ids


def store_refs(refs: list[dict[str, Any]]) -> list[str]:
    ids = allocate_ids(len(refs))
    for ident, ref in zip(ids, refs):
        _HANDLES[ident] = ref
    return ids


def resolve_handle(element_id: str | None) -> dict[str, Any] | None:
    if not element_id:
        return None
    return _HANDLES.get(element_id)


def try_route(name: str, arguments: dict[str, Any]) -> dict[str, Any] | None:
    handle = resolve_handle(arguments.get("elementId") if isinstance(arguments.get("elementId"), str) else None)
    if handle is not None:
        try:
            return _perform_handle(name, arguments, handle)
        except Exception as exc:
            return ToolResult.error(str(exc))

    if name not in ROUTABLE_TOOLS:
        return None
    identity = identity_from_args(arguments)
    if identity is None:
        return None
    capability = probe(identity)
    if identity.kind == "url" and capability.backend != "cdp":
        return ToolResult.error(capability.ask_detail or capability.reason)
    if identity.kind == "iosSimulator":
        return ToolResult.error(capability.ask_detail or capability.reason)
    if not capability.handles(name):
        return None
    try:
        return _perform(name, arguments, identity, capability)
    except Exception as exc:
        if identity.kind in {"url", "iosSimulator"}:
            return ToolResult.error(str(exc))
        return None


def _perform_handle(name: str, arguments: dict[str, Any], handle: dict[str, Any]) -> dict[str, Any]:
    kind = handle.get("kind")
    if kind == "cdp":
        from ..backends import cdp

        client = cdp.ensure_session(handle.get("sessionKey"), headless=True)
        if name in {"click", "double_click"}:
            cdp.click(client, int(handle["backendNodeId"]))
            if name == "double_click":
                cdp.click(client, int(handle["backendNodeId"]))
            return ToolResult.json({"success": True, "method": "cdp-click"})
        if name == "type_text":
            text = arguments.get("text")
            if not isinstance(text, str):
                return ToolResult.error("Missing text.")
            cdp.type_text(client, int(handle["backendNodeId"]), text)
            return ToolResult.json({"success": True, "method": "cdp-type"})
        if name in {"read_text", "read_all_text"}:
            return ToolResult.json({"text": handle.get("label") or "", "backend": "cdp"})
    if kind == "blender":
        from ..backends import blender as blender_backend

        endpoints = blender_backend.handshake()
        if len(endpoints) != 1:
            return ToolResult.error("Blender socket not uniquely available")
        denied = require_consent(arguments, "bpy", "Python inside Blender")
        if denied:
            return denied
        name_esc = str(handle.get("name") or "").replace("\\", "\\\\").replace("'", "\\'")
        code = (
            "import bpy\n"
            f"obj=bpy.data.objects.get('{name_esc}')\n"
            "result={'selected': False}\n"
            "if obj:\n"
            "    bpy.context.view_layer.objects.active=obj\n"
            "    obj.select_set(True)\n"
            "    result={'selected': True, 'name': obj.name}\n"
        )
        result = blender_backend.execute(endpoints[0], code)
        return ToolResult.json({"backend": endpoints[0].kind, "result": result, "method": "bpy-select"})
    return ToolResult.error(f"Unknown routed handle kind {kind}")


def _perform(name: str, arguments: dict[str, Any], identity: Any, capability: CapabilityRecord) -> dict[str, Any]:
    if capability.backend == "cdp":
        return _perform_cdp(name, arguments, identity)
    if capability.backend in {"bpy-lab", "bpy-ws"}:
        return _perform_blender(name, arguments, capability)
    return ToolResult.error(f"Router asked to handle {capability.backend}")


def _perform_cdp(name: str, arguments: dict[str, Any], identity: Any) -> dict[str, Any]:
    from ..backends import cdp

    url = identity.url or identity.raw
    if name in {"snapshot", "describe_screen"}:
        interactive = str(arguments.get("mode") or "interactive").lower() != "all"
        refs = cdp.snapshot(url, interactive)
        ids = store_refs(refs)
        elements = cdp.compact_elements(ids, refs)
        return ToolResult.json(
            {"backend": "cdp", "mode": "interactive" if interactive else "all", "count": len(elements), "elements": elements}
        )
    if name == "run_app_code":
        code = arguments.get("code")
        if not isinstance(code, str):
            return ToolResult.error("Missing code.")
        denied = require_consent(arguments, "cdp", "JavaScript inside the page")
        if denied:
            return denied
        result = cdp.evaluate(url, code)
        return ToolResult.json({"backend": "cdp", "result": result})
    if name in {"screenshot_window", "screenshot_element", "screenshot_screen"}:
        data = cdp.screenshot_jpeg(url)
        return ToolResult.image(data, "image/jpeg")
    if name == "open_url":
        cdp.ensure_session(url, headless=True)
        return ToolResult.json({"backend": "cdp", "url": url})
    raise RuntimeError(f"CDP routing for {name} is not implemented")


def _perform_blender(name: str, arguments: dict[str, Any], capability: CapabilityRecord) -> dict[str, Any]:
    from ..backends import blender as blender_backend

    endpoints = blender_backend.handshake()
    if len(endpoints) != 1:
        return ToolResult.error(capability.ask_detail or "Blender socket unavailable")
    endpoint = endpoints[0]
    if name in {"snapshot", "describe_screen"}:
        objects = blender_backend.scene_objects(endpoint)
        refs = [{"kind": "blender", "name": item["name"], "role": item.get("type") or "OBJECT"} for item in objects]
        ids = store_refs(refs)
        elements = [
            {"id": ident, "role": ref["role"], "label": ref["name"], "enabled": True}
            for ident, ref in zip(ids, refs)
        ]
        return ToolResult.json({"backend": endpoint.kind, "count": len(elements), "elements": elements})
    if name == "run_app_code":
        code = arguments.get("code")
        if not isinstance(code, str):
            return ToolResult.error("Missing code.")
        denied = require_consent(arguments, "bpy", "Python inside Blender")
        if denied:
            return denied
        result = blender_backend.execute(endpoint, code)
        return ToolResult.json({"backend": endpoint.kind, "result": result})
    raise RuntimeError(f"Blender routing for {name} is not implemented")

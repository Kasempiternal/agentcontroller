"""Screenshots plus explicit recording stubs."""

from __future__ import annotations

from typing import Any

from .. import app_service, capture_service
from ..args import as_int, required
from ..atspi_service import AtspiService
from ..result import ToolError, ToolResult
from ..schema import ToolSchema


def register(registry: Any, automation: AtspiService) -> None:
    registry.register("screenshot_screen",
        "Capture the visible desktop. X11 uses ImageMagick import; Wayland uses grim. JPEG when convert exists.",
        ToolSchema.empty(),
        _screen,
        read_only=True,
    )

    window_schema = ToolSchema.object(ToolSchema.app_properties(), "app")
    registry.register("screenshot_window",
        "Capture one top-level window. X11 uses import -window; Wayland uses grim on AT-SPI extents.",
        window_schema,
        lambda args: _window(automation, args),
        read_only=True,
    )

    registry.register("screenshot_element",
        "Capture the visible pixels inside an element's bounding rectangle.",
        ToolSchema.object(ToolSchema.selector_properties(), "app"),
        lambda args: _element(automation, args),
        read_only=True,
    )

    registry.register("start_recording", "Video recording is not implemented in the Linux milestone.", ToolSchema.object(ToolSchema.app_properties(), "app"), lambda _: ToolResult.error("start_recording is not implemented on Linux yet; use screenshot_window for evidence."))
    registry.register("stop_recording", "Video recording is not implemented in the Linux milestone.", ToolSchema.empty(), lambda _: ToolResult.error("stop_recording is not implemented on Linux yet."))


def _screen(_args: dict[str, Any]) -> dict[str, Any]:
    data, mime, mode = capture_service.capture_screen()
    return ToolResult.image(data, mime, {"captureMode": mode})


def _window(automation: AtspiService, args: dict[str, Any]) -> dict[str, Any]:
    app = app_service.resolve(required(args, "app"))
    window = app_service.resolve_window(app, as_int(args, "windowIndex", 0, 0, 100))
    if window.is_minimized:
        raise ToolError("Minimized windows cannot be captured; restore_window first.")
    if window.xid is not None:
        try:
            data, mime, mode = capture_service.capture_window_xid(window.xid)
            return ToolResult.image(
                data,
                mime,
                {
                    "app": app.name,
                    "pid": app.pid,
                    "windowIndex": window.index,
                    "captureMode": mode,
                },
            )
        except ToolError:
            pass
    frame = window.bounds
    if frame["width"] <= 0 or frame["height"] <= 0:
        root = automation.root_for(str(app.pid), window.index)
        frame = automation.extents(root)
    data, mime, mode = capture_service.capture_region(
        frame["x"], frame["y"], frame["width"], frame["height"]
    )
    return ToolResult.image(
        data,
        mime,
        {
            "app": app.name,
            "pid": app.pid,
            "windowIndex": window.index,
            "captureMode": mode,
        },
    )


def _element(automation: AtspiService, args: dict[str, Any]) -> dict[str, Any]:
    element = automation.resolve_element(required(args, "app"), args)
    described = automation.describe(element)
    if described.get("offscreen"):
        raise ToolError("Element is offscreen and cannot be captured.")
    frame = described.get("frame") or {}
    data, mime, mode = capture_service.capture_region(
        int(frame.get("x", 0)),
        int(frame.get("y", 0)),
        int(frame.get("width", 0)),
        int(frame.get("height", 0)),
    )
    return ToolResult.image(data, mime, {"captureMode": mode})

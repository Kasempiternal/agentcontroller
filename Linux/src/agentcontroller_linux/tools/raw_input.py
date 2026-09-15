"""Raw pointer/keyboard tools. Always require foreground:true and restore prior focus."""

from __future__ import annotations

from typing import Any

from ..args import as_number, optional_number, required, string_list
from ..atspi_service import AtspiService
from ..input_service import click_at, drag, require_foreground, send_shortcut
from ..result import ToolError, ToolResult
from ..schema import ToolSchema


def register(registry: Any, automation: AtspiService) -> None:
    double_properties = _point_or_selector("Allow a real global double-click and temporary focus change.")
    registry.register("double_click",
        "Double-click an element or coordinates. Linux raw input requires explicit foreground:true; focus and cursor are restored afterward.",
        ToolSchema.object(double_properties, "app"),
        lambda args: _click_tool(automation, args, "double_click", button=1, clicks=2, method="foreground-double-click"),
    )

    right_properties = _point_or_selector("Allow a real global right-click and temporary focus change.")
    registry.register("right_click",
        "Right-click an element or coordinates. Linux raw input requires explicit foreground:true; focus and cursor are restored afterward.",
        ToolSchema.object(right_properties, "app"),
        lambda args: _click_tool(automation, args, "right_click", button=3, clicks=1, method="foreground-right-click"),
    )

    shortcut_properties = ToolSchema.app_properties()
    shortcut_properties["key"] = ToolSchema.string("Key name such as s, return, tab, delete, left, or f5.")
    shortcut_properties["modifiers"] = {
        "type": "array",
        "items": {"type": "string"},
        "description": "Modifier keys: ctrl, shift, alt/opt, or win/cmd/super.",
    }
    shortcut_properties["foreground"] = ToolSchema.boolean(
        "Required on Linux because synthesized input is global.", False
    )
    registry.register("send_shortcut",
        "Send a Linux keyboard chord. Requires explicit foreground:true; the previous focused window is restored afterward.",
        ToolSchema.object(shortcut_properties, "app", "key"),
        lambda args: _shortcut(args),
    )

    swipe_properties = ToolSchema.app_properties()
    swipe_properties["startX"] = ToolSchema.number("Start X coordinate.")
    swipe_properties["startY"] = ToolSchema.number("Start Y coordinate.")
    swipe_properties["endX"] = ToolSchema.number("End X coordinate.")
    swipe_properties["endY"] = ToolSchema.number("End Y coordinate.")
    swipe_properties["duration"] = ToolSchema.number("Duration in seconds, from 0.05 to 10. Default 0.3.")
    swipe_properties["foreground"] = ToolSchema.boolean(
        "Required on Linux because pointer input is global.", False
    )
    registry.register("swipe",
        "Swipe from one screen coordinate to another as a mouse drag. Requires explicit foreground:true; focus and cursor are restored afterward.",
        ToolSchema.object(swipe_properties, "app", "startX", "startY", "endX", "endY"),
        lambda args: _gesture(args, "swipe", "foreground-swipe", 0.3, "startX", "startY", "endX", "endY"),
    )

    drag_properties = ToolSchema.app_properties()
    drag_properties["fromX"] = ToolSchema.number("Source X coordinate.")
    drag_properties["fromY"] = ToolSchema.number("Source Y coordinate.")
    drag_properties["toX"] = ToolSchema.number("Target X coordinate.")
    drag_properties["toY"] = ToolSchema.number("Target Y coordinate.")
    drag_properties["duration"] = ToolSchema.number("Duration in seconds, from 0.05 to 10. Default 0.5.")
    drag_properties["foreground"] = ToolSchema.boolean(
        "Required on Linux because pointer input is global.", False
    )
    registry.register("drag_drop",
        "Drag from one screen coordinate and drop at another. Requires explicit foreground:true; focus and cursor are restored afterward.",
        ToolSchema.object(drag_properties, "app", "fromX", "fromY", "toX", "toY"),
        lambda args: _gesture(args, "drag_drop", "foreground-drag-drop", 0.5, "fromX", "fromY", "toX", "toY"),
    )


def _point_or_selector(foreground_description: str) -> dict[str, Any]:
    properties = ToolSchema.selector_properties()
    properties["x"] = ToolSchema.number(
        "Optional screen X coordinate; provide with y instead of an element selector."
    )
    properties["y"] = ToolSchema.number(
        "Optional screen Y coordinate; provide with x instead of an element selector."
    )
    properties["foreground"] = ToolSchema.boolean(foreground_description, False)
    return properties


def _click_tool(
    automation: AtspiService,
    args: dict[str, Any],
    tool: str,
    button: int,
    clicks: int,
    method: str,
) -> dict[str, Any]:
    require_foreground(args, tool)
    from ..app_service import resolve

    app = required(args, "app")
    process = resolve(app)
    x, y = _resolve_point(automation, app, args)
    activated = click_at(process.pid, x, y, button=button, clicks=clicks)
    return ToolResult.json({"success": True, "method": method, "activated": activated, "x": x, "y": y})


def _shortcut(args: dict[str, Any]) -> dict[str, Any]:
    require_foreground(args, "send_shortcut")
    from ..app_service import resolve

    process = resolve(required(args, "app"))
    modifiers = string_list(args, "modifiers")
    key = required(args, "key")
    activated = send_shortcut(process.pid, key, modifiers)
    return ToolResult.json(
        {
            "success": True,
            "method": "foreground-keyboard",
            "activated": activated,
            "key": key,
            "modifiers": modifiers,
        }
    )


def _gesture(
    args: dict[str, Any],
    tool: str,
    method: str,
    default_duration: float,
    sx_name: str,
    sy_name: str,
    ex_name: str,
    ey_name: str,
) -> dict[str, Any]:
    require_foreground(args, tool)
    from ..app_service import resolve

    process = resolve(required(args, "app"))
    sx = int(round(as_number(args, sx_name)))
    sy = int(round(as_number(args, sy_name)))
    ex = int(round(as_number(args, ex_name)))
    ey = int(round(as_number(args, ey_name)))
    duration = optional_number(args, "duration", default_duration)
    activated = drag(process.pid, sx, sy, ex, ey, duration)
    return ToolResult.json(
        {
            "success": True,
            "method": method,
            "activated": activated,
            "from": {"x": sx, "y": sy},
            "to": {"x": ex, "y": ey},
            "duration": duration,
        }
    )


def _resolve_point(automation: AtspiService, app: str, args: dict[str, Any]) -> tuple[int, int]:
    has_x = args.get("x") is not None
    has_y = args.get("y") is not None
    if has_x != has_y:
        raise ToolError("Provide both x and y, or neither.")
    if has_x:
        return int(round(as_number(args, "x"))), int(round(as_number(args, "y")))
    element = automation.resolve_element(app, args)
    rect = automation.extents(element)
    if rect["width"] <= 0 or rect["height"] <= 0:
        raise ToolError("Element has no clickable bounds.")
    return rect["x"] + rect["width"] // 2, rect["y"] + rect["height"] // 2

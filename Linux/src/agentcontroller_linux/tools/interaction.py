"""Background-safe AT-SPI click, type, and scroll."""

from __future__ import annotations

from typing import Any

from ..args import as_bool, as_int, as_number, as_string, required
from ..atspi_service import AtspiService, has_selector
from ..result import ToolError, ToolResult
from ..schema import ToolSchema


def register(registry: Any, automation: AtspiService) -> None:
    click_properties = ToolSchema.selector_properties()
    click_properties["foreground"] = ToolSchema.boolean(
        "Allow a focus-changing coordinate fallback when no AT-SPI action exists.", False
    )
    registry.register("click",
        "Activate a control with AT-SPI actions; coordinate fallback requires foreground:true.",
        ToolSchema.object(click_properties, "app"),
        lambda args: _click(automation, args),
    )

    type_properties = ToolSchema.selector_properties()
    type_properties["text"] = ToolSchema.string(
        "Replacement text for editable text, or typed text for foreground fallback."
    )
    type_properties["foreground"] = ToolSchema.boolean(
        "Allow a focus-changing keyboard fallback when editable text is unavailable.", False
    )
    registry.register("type_text",
        "Set a control's AT-SPI editable text in the background; keyboard fallback requires foreground:true.",
        ToolSchema.object(type_properties, "app", "text"),
        lambda args: _type_text(automation, args),
    )

    scroll_properties = ToolSchema.selector_properties()
    scroll_properties["deltaY"] = ToolSchema.number("Positive scrolls down; negative scrolls up.")
    scroll_properties["amount"] = ToolSchema.integer("Number of AT-SPI scroll increments.", 1, 1, 50)
    registry.register("scroll",
        "Scroll an accessible container with AT-SPI without moving the pointer.",
        ToolSchema.object(scroll_properties, "app", "deltaY"),
        lambda args: _scroll(automation, args),
    )

    scroll_until = ToolSchema.selector_properties()
    scroll_until["maxScrolls"] = ToolSchema.integer("Maximum scroll increments.", 20, 1, 100)
    scroll_until["direction"] = {
        "type": "string",
        "enum": ["down", "up"],
        "default": "down",
    }
    registry.register("scroll_until_visible",
        "Scroll the target window until a matching element is onscreen.",
        ToolSchema.object(scroll_until, "app"),
        lambda args: _scroll_until(automation, args),
    )


def _click(automation: AtspiService, args: dict[str, Any]) -> dict[str, Any]:
    element = automation.resolve_element(required(args, "app"), args)
    method = automation.invoke(element, as_bool(args, "foreground"))
    return ToolResult.json({"success": True, "method": method})


def _type_text(automation: AtspiService, args: dict[str, Any]) -> dict[str, Any]:
    element = automation.resolve_element(required(args, "app"), args)
    method = automation.type_text(element, required(args, "text"), as_bool(args, "foreground"))
    return ToolResult.json({"success": True, "method": method})


def _scroll(automation: AtspiService, args: dict[str, Any]) -> dict[str, Any]:
    app = required(args, "app")
    if has_selector(args) or as_string(args, "elementId"):
        element = automation.resolve_element(app, args)
    else:
        element = automation.root_for(app, as_int(args, "windowIndex", 0, 0, 100))
    scrollable = automation.find_scrollable(element) or element
    delta = as_number(args, "deltaY")
    amount = as_int(args, "amount", 1, 1, 50)
    method = automation.scroll_element(scrollable, delta, amount)
    return ToolResult.json({"success": True, "method": method})


def _scroll_until(automation: AtspiService, args: dict[str, Any]) -> dict[str, Any]:
    app = required(args, "app")
    window_index = as_int(args, "windowIndex", 0, 0, 100)
    root = automation.root_for(app, window_index)
    scrollable = automation.find_scrollable(root)
    if scrollable is None:
        raise ToolError("No AT-SPI scroll container found.")
    maximum = as_int(args, "maxScrolls", 20, 1, 100)
    direction = as_string(args, "direction") or "down"
    delta = -1.0 if direction == "up" else 1.0
    for step in range(maximum + 1):
        matches = automation.find(app, args, window_index)
        if matches and matches[0].get("offscreen") is False:
            return ToolResult.json({"success": True, "scrolls": step, "element": matches[0]})
        if step < maximum:
            automation.scroll_element(scrollable, delta, 1)
    return ToolResult.error(f"Element did not become visible after {maximum} scrolls.")

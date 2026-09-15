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

    perform_properties = ToolSchema.selector_properties()
    perform_properties["action"] = ToolSchema.string(
        "AT-SPI action name (e.g. 'click', 'press', 'activate'). Omit to list what this element supports instead of performing anything."
    )
    registry.register("perform_action",
        "Escape hatch: perform ANY AT-SPI action a control exposes, not just the ones with a dedicated tool. Call it WITHOUT `action` first to discover what the element supports — it returns the action list with each name's description, plus the element's role and current value. Then call it again with one of those names. The action vocabulary is the platform's own and is NOT portable across backends — discovery mode is how you find the right name on whichever platform you are on. Runs through AT-SPI, so it does not move the pointer or change focus.",
        ToolSchema.object(perform_properties, "app"),
        lambda args: _perform_action(automation, args),
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


def _perform_action(automation: AtspiService, args: dict[str, Any]) -> dict[str, Any]:
    if not has_selector(args) and not as_string(args, "elementId"):
        raise ToolError(
            "perform_action needs a target: pass elementId from a snapshot, or a selector "
            "(role/title/identifier/labelContains/…). Without one it would act on whichever "
            "element the search happened to reach first."
        )
    element = automation.resolve_element(required(args, "app"), args)
    described = automation.describe(element)
    available = automation.list_actions(element)
    role = described.get("role") or "unknown"

    action = as_string(args, "action")
    if action is None:
        fields: dict[str, Any] = {
            "role": role,
            "enabled": described.get("enabled"),
            "actions": available,
        }
        if described.get("value") is not None:
            fields["value"] = described["value"]
        if not available:
            fields["note"] = (
                "This element exposes no AT-SPI action. Interact with its parent (rows and "
                "cells often carry the actions their contents do not), or click its frame coordinates."
            )
        return ToolResult.json(fields)

    names = [entry["name"] for entry in available]
    if action not in names:
        hint = "it exposes none at all" if not names else f"it exposes: {', '.join(names)}"
        raise ToolError(
            f"{role} does not support '{action}' — {hint}. "
            "Call perform_action without `action` for the full list with descriptions."
        )
    if not described.get("enabled"):
        raise ToolError(
            f"{role} is disabled, so '{action}' would have been a no-op. Satisfy whatever the "
            "control requires first (a selection, a filled field, an active app), then retry."
        )
    if not automation.perform_named_action(element, action):
        raise ToolError(
            f"{role} advertises '{action}' but refused it. The control may require the app to "
            "be active, or its state may have changed since the snapshot — re-snapshot and retry."
        )
    result: dict[str, Any] = {"success": True, "method": "atspi-action", "action": action, "role": role}
    refreshed = automation.describe(element).get("value")
    if refreshed is not None:
        result["value"] = refreshed
    return ToolResult.json(result)


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

"""Snapshot, search, wait, assertions, and text reads over AT-SPI."""

from __future__ import annotations

import time
from typing import Any

from ..args import as_int, required
from ..atspi_service import AtspiService
from ..result import ToolError, ToolResult
from ..schema import ToolSchema


def register(registry: Any, automation: AtspiService) -> None:
    snapshot_properties = ToolSchema.app_properties()
    snapshot_properties["maxDepth"] = ToolSchema.integer("Maximum AT-SPI tree depth.", 12, 0, 30)
    snapshot_properties["maxElements"] = ToolSchema.integer("Maximum elements returned.", 250, 1, 2000)
    snapshot_schema = ToolSchema.object(snapshot_properties, "app")
    registry.register("snapshot",
        "Return a compact AT-SPI snapshot with stable element IDs.",
        snapshot_schema,
        lambda args: ToolResult.json(
            automation.snapshot(required(args, "app"), _depth(args), _max_elements(args), _window(args))
        ),
        read_only=True,
    )
    registry.register("describe_screen",
        "Alias of snapshot for cross-platform AgentController compatibility.",
        snapshot_schema,
        lambda args: ToolResult.json(
            automation.snapshot(required(args, "app"), _depth(args), _max_elements(args), _window(args))
        ),
        read_only=True,
    )

    tree_properties = ToolSchema.app_properties()
    tree_properties["maxDepth"] = ToolSchema.integer("Maximum AT-SPI tree depth.", 12, 0, 30)
    tree_properties["maxElements"] = ToolSchema.integer("Maximum elements returned.", 1000, 1, 5000)
    registry.register("get_element_tree",
        "Return the target window's AT-SPI tree as a flat depth-annotated list.",
        ToolSchema.object(tree_properties, "app"),
        lambda args: ToolResult.json(
            automation.snapshot(
                required(args, "app"),
                _depth(args),
                as_int(args, "maxElements", 1000, 1, 5000),
                _window(args),
            )
        ),
        read_only=True,
    )

    registry.register("find_elements",
        "Find AT-SPI elements using AgentController-compatible selectors.",
        ToolSchema.object(ToolSchema.selector_properties(), "app"),
        lambda args: _find(automation, args),
        read_only=True,
    )

    registry.register("get_element_attributes",
        "Return current properties and supported interfaces for one UI element.",
        ToolSchema.object(ToolSchema.selector_properties(), "app"),
        lambda args: ToolResult.json(
            automation.describe(
                automation.resolve_element(required(args, "app"), args),
                args.get("elementId") if isinstance(args.get("elementId"), str) else None,
            )
        ),
        read_only=True,
    )

    registry.register("get_focused_element",
        "Return the focused AT-SPI element when it belongs to the target app.",
        ToolSchema.object(ToolSchema.app_properties(), "app"),
        lambda args: ToolResult.json(automation.focused(required(args, "app"))),
        read_only=True,
    )

    wait_properties = ToolSchema.selector_properties()
    wait_properties["timeoutMs"] = ToolSchema.integer("Maximum wait in milliseconds.", 5000, 0, 60000)
    registry.register("wait_for_element",
        "Poll until a matching element exists or the timeout expires.",
        ToolSchema.object(wait_properties, "app"),
        lambda args: _wait(automation, args, should_exist=True),
        read_only=True,
    )
    registry.register("assert_visible",
        "Pass when a matching element becomes available; return MCP isError on timeout.",
        ToolSchema.object(wait_properties, "app"),
        lambda args: _assert_visible(automation, args),
        read_only=True,
    )
    registry.register("assert_not_visible",
        "Pass when no matching element is available; return MCP isError on timeout.",
        ToolSchema.object(wait_properties, "app"),
        lambda args: _assert_not_visible(automation, args),
        read_only=True,
    )

    value_properties = ToolSchema.selector_properties()
    value_properties["expected"] = ToolSchema.string("Expected value converted to text.")
    value_properties["timeoutMs"] = ToolSchema.integer("Maximum wait in milliseconds.", 5000, 0, 60000)
    registry.register("assert_value",
        "Poll until an element's value/checked state equals expected.",
        ToolSchema.object(value_properties, "app", "expected"),
        lambda args: _assert_value(automation, args),
        read_only=True,
    )

    registry.register("read_text",
        "Read text from AT-SPI Text, Value, or accessible name.",
        ToolSchema.object(ToolSchema.selector_properties(), "app"),
        lambda args: _read_text(automation, args),
        read_only=True,
    )

    read_all = ToolSchema.app_properties()
    read_all["maxElements"] = ToolSchema.integer("Maximum UI elements inspected.", 500, 1, 5000)
    registry.register("read_all_text",
        "Extract unique visible accessible text from the target window.",
        ToolSchema.object(read_all, "app"),
        lambda args: _read_all(automation, args),
        read_only=True,
    )


def _find(automation: AtspiService, args: dict[str, Any]) -> dict[str, Any]:
    matches = automation.find(required(args, "app"), args, _window(args))
    return ToolResult.json({"count": len(matches), "elements": matches})


def _wait(automation: AtspiService, args: dict[str, Any], should_exist: bool) -> dict[str, Any]:
    element = automation.wait_for(required(args, "app"), args, should_exist)
    if element is None:
        return ToolResult.error("wait_for_element timed out before a match appeared.")
    return ToolResult.json({"found": True, "element": automation.describe(element)})


def _assert_visible(automation: AtspiService, args: dict[str, Any]) -> dict[str, Any]:
    element = automation.wait_for(required(args, "app"), args, True)
    if element is None:
        return ToolResult.error("assert_visible failed: element did not become visible.")
    return ToolResult.json({"passed": True})


def _assert_not_visible(automation: AtspiService, args: dict[str, Any]) -> dict[str, Any]:
    element = automation.wait_for(required(args, "app"), args, False)
    if element is None:
        return ToolResult.json({"passed": True})
    return ToolResult.error("assert_not_visible failed: element remained visible.")


def _assert_value(automation: AtspiService, args: dict[str, Any]) -> dict[str, Any]:
    timeout = as_int(args, "timeoutMs", 5000, 0, 60000)
    expected = required(args, "expected")
    deadline = time.time() + timeout / 1000.0
    actual: str | None = None
    app = required(args, "app")
    while True:
        try:
            element = automation.resolve_element(app, args)
            value = automation.value_of(element)
            actual = None if value is None else str(value)
            if actual is not None and actual.lower() == expected.lower():
                return ToolResult.json({"passed": True, "actual": actual})
        except ToolError:
            pass
        if time.time() >= deadline:
            break
        time.sleep(0.1)
    return ToolResult.error(f"assert_value failed: expected '{expected}', actual '{actual or '<missing>'}'.")


def _read_text(automation: AtspiService, args: dict[str, Any]) -> dict[str, Any]:
    element = automation.resolve_element(required(args, "app"), args)
    text = automation.read_text(element)
    if text is None:
        return ToolResult.error("Element exposes no readable text.")
    return ToolResult.json({"text": text})


def _read_all(automation: AtspiService, args: dict[str, Any]) -> dict[str, Any]:
    values = automation.read_all_text(
        required(args, "app"), _window(args), as_int(args, "maxElements", 500, 1, 5000)
    )
    return ToolResult.json({"count": len(values), "items": values})


def _window(args: dict[str, Any]) -> int:
    return as_int(args, "windowIndex", 0, 0, 100)


def _depth(args: dict[str, Any]) -> int:
    return as_int(args, "maxDepth", 12, 0, 30)


def _max_elements(args: dict[str, Any]) -> int:
    return as_int(args, "maxElements", 250, 1, 2000)

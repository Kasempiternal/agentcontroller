"""Menu structure and navigation through AT-SPI."""

from __future__ import annotations

from typing import Any

from ..args import as_int, required, string_list
from ..atspi_service import AtspiService
from ..result import ToolError, ToolResult
from ..schema import ToolSchema


def register(registry: Any, automation: AtspiService) -> None:
    structure_properties = ToolSchema.app_properties()
    structure_properties["maxDepth"] = ToolSchema.integer("Maximum AT-SPI depth inspected.", 12, 1, 30)
    structure_properties["maxItems"] = ToolSchema.integer("Maximum menu entries returned.", 250, 1, 1000)
    registry.register("get_menu_structure",
        "Read accessible MenuBar and MenuItem elements without clicking them.",
        ToolSchema.object(structure_properties, "app"),
        lambda args: _structure(automation, args),
        read_only=True,
    )

    navigate_properties = ToolSchema.app_properties()
    navigate_properties["menuPath"] = {
        "type": "array",
        "items": {"type": "string"},
        "minItems": 1,
        "description": "Accessible menu names from outermost to target item.",
    }
    registry.register("navigate_menu",
        "Expand and invoke a Linux menu path through AT-SPI actions.",
        ToolSchema.object(navigate_properties, "app", "menuPath"),
        lambda args: _navigate(automation, args),
    )


def _structure(automation: AtspiService, args: dict[str, Any]) -> dict[str, Any]:
    items = automation.menu_items(
        required(args, "app"),
        as_int(args, "windowIndex", 0, 0, 100),
        as_int(args, "maxDepth", 12, 1, 30),
        as_int(args, "maxItems", 250, 1, 1000),
    )
    return ToolResult.json({"count": len(items), "items": items})


def _navigate(automation: AtspiService, args: dict[str, Any]) -> dict[str, Any]:
    path = string_list(args, "menuPath")
    if not path:
        raise ToolError("menuPath must not be empty.")
    automation.navigate_menu(required(args, "app"), as_int(args, "windowIndex", 0, 0, 100), path)
    return ToolResult.json({"success": True, "path": path, "method": "atspi-menu"})

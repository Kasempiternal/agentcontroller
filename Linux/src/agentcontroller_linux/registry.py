"""MCP tool registry. Annotations match Swift ToolRegistry readOnlyTools / destructiveTools."""

from __future__ import annotations

from typing import Any, Callable

from .result import ToolResult

Handler = Callable[[dict[str, Any]], dict[str, Any]]

# Copied from Sources/MCPTools/ToolRegistry.swift — keep identical.
READ_ONLY_TOOLS = frozenset(
    {
        "assert_not_visible",
        "assert_value",
        "assert_visible",
        "check_permissions",
        "describe_screen",
        "find_elements",
        "get_clipboard",
        "get_element_attributes",
        "get_element_tree",
        "get_focused_element",
        "get_frontmost_app",
        "get_menu_structure",
        "get_window_bounds",
        "list_apps",
        "list_flows",
        "list_windows",
        "read_all_text",
        "read_text",
        "screenshot_element",
        "screenshot_screen",
        "screenshot_window",
        "snapshot",
        "wait_for_element",
    }
)

DESTRUCTIVE_TOOLS = frozenset({"quit_app", "reset_app_state", "set_clipboard"})


class ToolRegistry:
    def __init__(self) -> None:
        self._tools: dict[str, dict[str, Any]] = {}
        from .atspi_service import AtspiService
        from .tools.app import register as register_app
        from .tools.capture import register as register_capture
        from .tools.elements import register as register_elements
        from .tools.flows import register as register_flows
        from .tools.interaction import register as register_interaction
        from .tools.menus import register as register_menus
        from .tools.raw_input import register as register_raw_input
        from .tools.system import register as register_system

        automation = AtspiService()
        register_app(self)
        register_elements(self, automation)
        register_interaction(self, automation)
        register_raw_input(self, automation)
        register_capture(self, automation)
        register_system(self)
        register_menus(self, automation)
        register_flows(self)

    def register(
        self,
        name: str,
        description: str,
        schema: dict[str, Any],
        handler: Handler,
        read_only: bool = False,
        destructive: bool = False,
    ) -> None:
        _ = read_only, destructive
        self._tools[name] = {
            "name": name,
            "description": description,
            "schema": schema,
            "handler": handler,
            "read_only": name in READ_ONLY_TOOLS,
            "destructive": name in DESTRUCTIVE_TOOLS,
        }

    def list_tools(self) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        for tool in sorted(self._tools.values(), key=lambda item: item["name"]):
            annotations: dict[str, Any] = {
                "openWorldHint": False,
                "destructiveHint": tool["destructive"],
            }
            if tool["read_only"]:
                annotations["readOnlyHint"] = True
            result.append(
                {
                    "name": tool["name"],
                    "description": tool["description"],
                    "inputSchema": tool["schema"],
                    "annotations": annotations,
                }
            )
        return result

    def names(self) -> set[str]:
        return set(self._tools)

    def call(self, name: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        tool = self._tools.get(name)
        if tool is None:
            return ToolResult.error(f"Unknown tool: {name}")
        payload = arguments if isinstance(arguments, dict) else {}
        return tool["handler"](payload)

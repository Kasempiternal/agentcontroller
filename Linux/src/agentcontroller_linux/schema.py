"""JSON Schema helpers for MCP tool inputSchema. Mirrors Windows ToolSchema.cs."""

from __future__ import annotations

from typing import Any


class ToolSchema:
    @staticmethod
    def empty() -> dict[str, Any]:
        return ToolSchema.object({})

    @staticmethod
    def object(properties: dict[str, Any], *required: str) -> dict[str, Any]:
        schema: dict[str, Any] = {
            "type": "object",
            "properties": dict(properties),
            "additionalProperties": False,
        }
        if required:
            schema["required"] = list(required)
        return schema

    @staticmethod
    def string(description: str) -> dict[str, Any]:
        return {"type": "string", "description": description}

    @staticmethod
    def boolean(description: str, default: bool | None = None) -> dict[str, Any]:
        value: dict[str, Any] = {"type": "boolean", "description": description}
        if default is not None:
            value["default"] = default
        return value

    @staticmethod
    def integer(
        description: str,
        default: int | None = None,
        minimum: int | None = None,
        maximum: int | None = None,
    ) -> dict[str, Any]:
        value: dict[str, Any] = {"type": "integer", "description": description}
        if default is not None:
            value["default"] = default
        if minimum is not None:
            value["minimum"] = minimum
        if maximum is not None:
            value["maximum"] = maximum
        return value

    @staticmethod
    def number(description: str) -> dict[str, Any]:
        return {"type": "number", "description": description}

    @staticmethod
    def app_properties() -> dict[str, Any]:
        return {
            "app": ToolSchema.string(
                "PID, process name, WM_CLASS, window title, or desktop application id."
            ),
            "windowIndex": ToolSchema.integer("Zero-based top-level window index.", 0, 0, 100),
        }

    @staticmethod
    def selector_properties() -> dict[str, Any]:
        properties = ToolSchema.app_properties()
        properties["elementId"] = ToolSchema.string(
            "Stable element handle returned by snapshot or find_elements."
        )
        properties["role"] = ToolSchema.string(
            "AT-SPI role or a compatible AX role such as AXButton, AXTextField, AXStaticText."
        )
        properties["title"] = ToolSchema.string("Exact accessible name/title.")
        properties["titleContains"] = ToolSchema.string(
            "Case-insensitive substring of accessible name/title."
        )
        properties["identifier"] = ToolSchema.string(
            "Exact accessible id, object id attribute, or toolkit widget name."
        )
        properties["value"] = ToolSchema.string("Exact accessible value converted to text.")
        properties["description"] = ToolSchema.string("Exact accessible description.")
        properties["descriptionContains"] = ToolSchema.string(
            "Case-insensitive description substring."
        )
        properties["labelContains"] = ToolSchema.string(
            "Case-insensitive substring across name, description, identifier, and value."
        )
        properties["index"] = ToolSchema.integer(
            "Zero-based index among selector matches.", None, 0, 5000
        )
        properties["maxDepth"] = ToolSchema.integer("Maximum AT-SPI tree depth.", 12, 0, 30)
        properties["maxResults"] = ToolSchema.integer("Maximum matches.", 20, 1, 500)
        return properties

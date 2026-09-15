"""MCP tool-call payloads. Mirrors Windows ToolResult.cs."""

from __future__ import annotations

import base64
import copy
import json
from typing import Any


def compact_json(payload: Any) -> str:
    return json.dumps(payload, separators=(",", ":"), ensure_ascii=False)


class ToolResult:
    """Builders for MCP tools/call result objects (content + isError)."""

    @staticmethod
    def json(payload: Any) -> dict[str, Any]:
        return {
            "content": [{"type": "text", "text": compact_json(payload)}],
            "structuredContent": copy.deepcopy(payload),
            "isError": False,
        }

    @staticmethod
    def text(text: str) -> dict[str, Any]:
        return {
            "content": [{"type": "text", "text": text}],
            "isError": False,
        }

    @staticmethod
    def error(message: str) -> dict[str, Any]:
        return {
            "content": [{"type": "text", "text": message}],
            "isError": True,
        }

    @staticmethod
    def image(data: bytes, mime_type: str, metadata: dict[str, Any] | None = None) -> dict[str, Any]:
        content: list[dict[str, Any]] = [
            {
                "type": "image",
                "data": base64.b64encode(data).decode("ascii"),
                "mimeType": mime_type,
            }
        ]
        if metadata is not None:
            content.append({"type": "text", "text": compact_json(metadata)})
        return {"content": content, "isError": False}


class ToolError(Exception):
    """User-facing tool failure, returned as MCP isError rather than JSON-RPC error."""

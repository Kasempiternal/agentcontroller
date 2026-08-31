"""Newline-delimited JSON-RPC MCP stdio server. Mirrors Windows StdioMcpServer.cs."""

from __future__ import annotations

import json
import sys
import traceback
from typing import Any, Mapping, TextIO

from . import __version__
from .registry import ToolRegistry
from .result import ToolError, ToolResult, compact_json

SUPPORTED_VERSIONS = ("2024-11-05", "2025-03-26", "2025-06-18")
DEFAULT_VERSION = "2025-06-18"

INSTRUCTIONS = (
    "AgentController Linux drives desktop applications through AT-SPI. "
    "Start with list_apps, then snapshot or find_elements. AT-SPI actions and "
    "editable text are background-safe; raw coordinate and keyboard fallbacks "
    "require foreground:true and restore prior focus afterward. X11 screenshots "
    "use ImageMagick import; Wayland screenshots use grim."
)


class StdioMcpServer:
    def __init__(
        self,
        registry: ToolRegistry,
        stdin: TextIO | None = None,
        stdout: TextIO | None = None,
        stderr: TextIO | None = None,
    ) -> None:
        self.registry = registry
        self.stdin = stdin if stdin is not None else sys.stdin
        self.stdout = stdout if stdout is not None else sys.stdout
        self.stderr = stderr if stderr is not None else sys.stderr

    def run(self) -> None:
        while True:
            line = self.stdin.readline()
            if line == "":
                return
            response = self.handle_line(line)
            if response is None:
                continue
            self.stdout.write(response)
            self.stdout.write("\n")
            self.stdout.flush()

    def handle_line(self, line: str) -> str | None:
        line = line.lstrip("\ufeff").strip()
        if not line:
            return None
        try:
            parsed = json.loads(line)
            if not isinstance(parsed, dict):
                return compact_json(_failure(None, -32700, "Parse error: Request must be a JSON object."))
            response = self.dispatch(parsed)
        except json.JSONDecodeError as exc:
            response = _failure(None, -32700, f"Parse error: {exc.msg}")
        except Exception as exc:
            print(f"agentcontroller-linux request error: {exc}", file=self.stderr)
            traceback.print_exc(file=self.stderr)
            response = _failure(None, -32603, "Internal error")
        if response is None:
            return None
        return compact_json(response)

    def dispatch(self, request: Mapping[str, Any]) -> dict[str, Any] | None:
        if "id" not in request or request["id"] is None:
            return None
        request_id = request["id"]
        method = request.get("method")
        params = request.get("params")
        if not isinstance(params, dict):
            params = {}
        if method == "initialize":
            return _success(request_id, _initialize(params))
        if method == "ping":
            return _success(request_id, {})
        if method == "tools/list":
            return _success(request_id, {"tools": self.registry.list_tools()})
        if method == "tools/call":
            return _success(request_id, self.call_tool(params))
        return _failure(request_id, -32601, f"Method not found: {method}")

    def call_tool(self, parameters: Mapping[str, Any]) -> dict[str, Any]:
        name = parameters.get("name")
        if not isinstance(name, str) or not name.strip():
            return ToolResult.error("Missing tool name.")
        arguments = parameters.get("arguments")
        if not isinstance(arguments, dict):
            arguments = {}
        try:
            return self.registry.call(name, arguments)
        except ToolError as exc:
            return ToolResult.error(f"{name}: {exc}")
        except Exception as exc:
            print(f"agentcontroller-linux tool {name} failed: {exc}", file=self.stderr)
            traceback.print_exc(file=self.stderr)
            return ToolResult.error(f"{name}: {exc}")


def _initialize(parameters: Mapping[str, Any]) -> dict[str, Any]:
    requested = parameters.get("protocolVersion")
    version = requested if isinstance(requested, str) and requested in SUPPORTED_VERSIONS else DEFAULT_VERSION
    return {
        "protocolVersion": version,
        "capabilities": {"tools": {}},
        "serverInfo": {"name": "agentcontroller-linux", "version": __version__},
        "instructions": INSTRUCTIONS,
    }


def _success(request_id: Any, result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "result": result, "id": request_id}


def _failure(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "error": {"code": code, "message": message}, "id": request_id}

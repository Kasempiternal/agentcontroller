"""Replayable MCP flows stored under the XDG data directory."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from ..args import as_bool, required
from ..result import ToolError, ToolResult, compact_json
from ..schema import ToolSchema


def flow_directory() -> Path:
    override = os.environ.get("AGENTCONTROLLER_FLOW_DIR")
    if override:
        return Path(override)
    xdg = os.environ.get("XDG_DATA_HOME")
    root = Path(xdg) if xdg else Path.home() / ".local" / "share"
    return root / "agentcontroller" / "flows"


def register(registry: Any) -> None:
    run_properties = {
        "steps": {"type": "array", "description": "Array of {tool, arguments} MCP tool calls."},
        "stopOnError": ToolSchema.boolean("Stop after the first MCP tool error.", True),
        "includeNestedMedia": ToolSchema.boolean(
            "Keep nested screenshot/image payloads in step results (default false).", False
        ),
    }
    registry.register("run_steps",
        "THE default way to drive a UI: run an ordered list of tool steps in ONE call instead of one call per action.",
        ToolSchema.object(run_properties, "steps"),
        lambda args: _run_steps(registry, args),
    )

    save_properties = {
        "name": ToolSchema.string("Flow name; letters, numbers, dash, underscore, and spaces are accepted."),
        "steps": {"type": "array", "description": "Array of {tool, arguments} MCP tool calls."},
    }
    registry.register("save_flow",
        "Save a reusable flow under the current user's XDG data directory.",
        ToolSchema.object(save_properties, "name", "steps"),
        lambda args: _save(args),
    )

    registry.register("list_flows",
        "List saved Linux AgentController flows.",
        ToolSchema.empty(),
        lambda _: _list(),
        read_only=True,
    )

    run_saved_properties = {
        "name": ToolSchema.string("Saved flow name."),
        "stopOnError": ToolSchema.boolean("Stop after the first MCP tool error.", True),
    }
    registry.register("run_saved_flow",
        "Run a previously saved Linux AgentController flow.",
        ToolSchema.object(run_saved_properties, "name"),
        lambda args: _run_saved(registry, args),
    )


def _save(args: dict[str, Any]) -> dict[str, Any]:
    name = _sanitize(required(args, "name"))
    steps = args.get("steps")
    if not isinstance(steps, list):
        raise ToolError("steps must be an array.")
    directory = flow_directory()
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{name}.json"
    path.write_text(json.dumps({"name": name, "steps": steps}, indent=2), encoding="utf-8")
    return ToolResult.json({"saved": True, "name": name, "path": str(path)})


def _list() -> dict[str, Any]:
    directory = flow_directory()
    directory.mkdir(parents=True, exist_ok=True)
    flows = sorted(path.stem for path in directory.glob("*.json"))
    return ToolResult.json({"flows": flows})


def _run_saved(registry: Any, args: dict[str, Any]) -> dict[str, Any]:
    name = _sanitize(required(args, "name"))
    path = flow_directory() / f"{name}.json"
    if not path.is_file():
        return ToolResult.error(f"Flow not found: {name}")
    try:
        saved = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ToolError("Saved flow is invalid JSON.") from exc
    if not isinstance(saved, dict):
        raise ToolError("Saved flow is invalid JSON.")
    run_args = {"steps": saved.get("steps"), "stopOnError": as_bool(args, "stopOnError", True)}
    return _run_steps(registry, run_args)


def _run_steps(registry: Any, args: dict[str, Any]) -> dict[str, Any]:
    steps = args.get("steps")
    if not isinstance(steps, list):
        raise ToolError("steps must be an array.")
    stop_on_error = as_bool(args, "stopOnError", True)
    results: list[dict[str, Any]] = []
    passed = 0
    for index, raw in enumerate(steps):
        if not isinstance(raw, dict):
            raise ToolError(f"Step {index} must be an object.")
        name = raw.get("tool") if isinstance(raw.get("tool"), str) else raw.get("name")
        if not isinstance(name, str) or not name:
            raise ToolError(f"Step {index} is missing tool.")
        if name in {"run_steps", "run_saved_flow"}:
            return ToolResult.error("Recursive flow execution is not allowed.")
        arguments = raw.get("arguments")
        if arguments is None:
            arguments = raw.get("args")
        if not isinstance(arguments, dict):
            arguments = {}
        try:
            result = registry.call(name, arguments)
        except Exception as exc:
            result = ToolResult.error(f"{name}: {exc}")
        is_error = bool(result.get("isError"))
        if not is_error:
            passed += 1
        results.append(
            {
                "index": index,
                "tool": name,
                "isError": is_error,
                "result": _compact_step_result(result, as_bool(args, "includeNestedMedia", False)),
            }
        )
        if is_error and stop_on_error:
            break
    return ToolResult.json(
        {"passed": passed, "executed": len(results), "total": len(steps), "results": results}
    )


def _compact_step_result(result: dict[str, Any], include_nested_media: bool) -> dict[str, Any]:
    if include_nested_media or not isinstance(result, dict):
        return result
    content = result.get("content")
    if not isinstance(content, list):
        return result
    omitted = False
    rewritten: list[Any] = []
    for item in content:
        if isinstance(item, dict) and item.get("type") == "image":
            omitted = True
            data = item.get("data") or ""
            rewritten.append(
                {
                    "type": "text",
                    "text": compact_json(
                        {
                            "omitted": True,
                            "kind": "image",
                            "mimeType": item.get("mimeType") or "image",
                            "approxBytes": (len(data) * 3) // 4,
                        }
                    ),
                }
            )
        else:
            rewritten.append(item)
    if not omitted:
        return result
    copy = dict(result)
    copy["content"] = rewritten
    copy["nestedMediaOmitted"] = True
    return copy


def _sanitize(name: str) -> str:
    filtered = "".join(ch for ch in name if ch.isalnum() or ch in "-_ ").strip()
    if not filtered:
        raise ToolError("Flow name has no valid characters.")
    return filtered

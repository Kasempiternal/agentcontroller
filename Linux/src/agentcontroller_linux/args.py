"""Typed argument extraction from MCP tool argument objects."""

from __future__ import annotations

from typing import Any, Mapping

from .result import ToolError


def as_string(args: Mapping[str, Any], name: str) -> str | None:
    value = args.get(name)
    if value is None:
        return None
    if isinstance(value, str):
        return value
    raise ToolError(f"{name} must be a string.")


def required(args: Mapping[str, Any], name: str) -> str:
    value = as_string(args, name)
    if value is None or value == "":
        raise ToolError(f"Missing {name}.")
    return value


def as_bool(args: Mapping[str, Any], name: str, fallback: bool = False) -> bool:
    value = args.get(name)
    if value is None:
        return fallback
    if isinstance(value, bool):
        return value
    raise ToolError(f"{name} must be a boolean.")


def as_number(args: Mapping[str, Any], name: str) -> float:
    value = args.get(name)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ToolError(f"Missing {name}.")
    return float(value)


def optional_number(args: Mapping[str, Any], name: str, fallback: float) -> float:
    if args.get(name) is None:
        return fallback
    return as_number(args, name)


def as_int(args: Mapping[str, Any], name: str, fallback: int, minimum: int, maximum: int) -> int:
    value = args.get(name)
    if value is None:
        number = fallback
    elif isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ToolError(f"{name} must be an integer.")
    else:
        number = int(round(float(value)))
    return max(minimum, min(maximum, number))


def optional_int(args: Mapping[str, Any], name: str) -> int | None:
    value = args.get(name)
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ToolError(f"{name} must be an integer.")
    return int(round(float(value)))


def string_list(args: Mapping[str, Any], name: str) -> list[str]:
    value = args.get(name)
    if value is None:
        return []
    if not isinstance(value, list):
        raise ToolError(f"{name} must be an array.")
    result: list[str] = []
    for item in value:
        if not isinstance(item, str):
            raise ToolError(f"{name} entries must be strings.")
        result.append(item)
    return result

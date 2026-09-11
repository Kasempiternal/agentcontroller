from __future__ import annotations

from typing import Any

from ..result import ToolResult
from ..routing import identity_from_args, probe
from ..schema import ToolSchema

INSPECT_DESCRIPTION = (
    "Probe a target (bundle ID, PID, URL, or iOS simulator UDID) and return the best backend this MCP will use. "
    "Handshakes native sockets (Blender Lab/community, Chrome CDP, idb). Does not ask except to report "
    "multi-instance, missing add-on, or code-exec consent. Do not pick Playwright vs AX vs bpy vs idb — call this, "
    "or just snapshot/click, and the server routes."
)

RUN_APP_CODE_DESCRIPTION = (
    "Run a script on the auto-selected backend: Python in Blender (bpy) when the socket handshakes, "
    "JavaScript in a CDP page, otherwise an error pointing at AX run_steps. One script is the batch — "
    "do not issue one MCP call per primitive. First use per backend requires consent:true (RCE inside the app). "
    "Returns {backend, result}."
)


def register(registry: Any) -> None:
    inspect_properties = {
        "target": ToolSchema.string("Bundle ID, app name, PID, URL, or iOS simulator UDID"),
        "app": ToolSchema.string("Alias of target"),
        "url": ToolSchema.string("Page URL (forces the CDP backend)"),
        "udid": ToolSchema.string("iOS simulator UDID or 'booted'"),
    }
    registry.register("inspect_capabilities",
        INSPECT_DESCRIPTION,
        ToolSchema.object(inspect_properties),
        _inspect,
        read_only=True,
    )

    run_properties = {
        "app": ToolSchema.string("Bundle ID, app name, PID, URL, or simulator UDID"),
        "target": ToolSchema.string("Alias of app"),
        "url": ToolSchema.string("Page URL for CDP JavaScript"),
        "code": ToolSchema.string("Python (Blender) or JavaScript (CDP) to execute"),
        "language": ToolSchema.string("Optional hint: python or javascript."),
        "consent": ToolSchema.boolean("Required the first time per backend; persists after that."),
    }
    registry.register("run_app_code",
        RUN_APP_CODE_DESCRIPTION,
        ToolSchema.object(run_properties, "code"),
        _run_app_code,
    )


def _inspect(args: dict[str, Any]) -> dict[str, Any]:
    identity = identity_from_args(args)
    if identity is None:
        return ToolResult.error("Missing target.")
    return ToolResult.json(probe(identity).as_dict())


def _run_app_code(args: dict[str, Any]) -> dict[str, Any]:
    identity = identity_from_args(args)
    if identity is None:
        return ToolResult.error("Missing app.")
    if not isinstance(args.get("code"), str):
        return ToolResult.error("Missing code.")
    capability = probe(identity)
    return ToolResult.error(
        f"No in-process backend for '{identity.raw}' (probe backend={capability.backend}). "
        "Use snapshot → elementId → run_steps for native UI."
    )

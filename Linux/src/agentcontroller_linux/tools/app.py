"""App control, URL open, window geometry, and the explicit reset_app_state error."""

from __future__ import annotations

from typing import Any

from .. import app_service
from ..args import as_bool, as_int, as_string, optional_number, required
from ..result import ToolResult
from ..schema import ToolSchema


def register(registry: Any) -> None:
    registry.register("list_apps",
        "List desktop applications with top-level windows.",
        ToolSchema.empty(),
        lambda _: ToolResult.json({"apps": [app_service.app_json(app) for app in app_service.list_apps()]}),
        read_only=True,
    )

    registry.register("get_frontmost_app",
        "Return the application that currently owns foreground focus.",
        ToolSchema.empty(),
        lambda _: ToolResult.json(app_service.app_json(app_service.frontmost())),
        read_only=True,
    )

    launch = {
        "path": ToolSchema.string("Executable path, desktop file, or PATH command."),
        "bundleId": ToolSchema.string("Compatibility alias for path on Linux."),
        "arguments": ToolSchema.string("Optional command-line arguments (parsed, never passed to a shell)."),
        "foreground": ToolSchema.boolean("Allow the launched app to take focus.", False),
    }
    registry.register("launch_app",
        "Launch a Linux application. Use path; bundleId is accepted as a compatibility alias.",
        ToolSchema.object(launch),
        _launch,
    )

    app_only = ToolSchema.object(ToolSchema.app_properties(), "app")
    registry.register("activate_app",
        "Bring an application to the foreground. This intentionally changes user focus.",
        app_only,
        _activate,
    )

    quit_properties = ToolSchema.app_properties()
    quit_properties["force"] = ToolSchema.boolean(
        "Force-kill if a graceful close is unavailable. Unsaved work can be lost.", False
    )
    registry.register("quit_app",
        "Request that an application close. force:true terminates it and can lose unsaved work.",
        ToolSchema.object(quit_properties, "app"),
        _quit,
        destructive=True,
    )

    registry.register("hide_app",
        "Hide all top-level windows without terminating the process.",
        app_only,
        lambda args: _show(args, hide=True),
    )
    registry.register("unhide_app",
        "Show hidden top-level windows without intentionally activating them.",
        app_only,
        lambda args: _show(args, hide=False),
    )

    url_schema = ToolSchema.object(
        {
            "url": ToolSchema.string("URL, file path, or xdg-open URI."),
            "foreground": ToolSchema.boolean(
                "Accepted for compatibility; the handler application decides activation.", False
            ),
        },
        "url",
    )
    registry.register("open_url",
        "Open a URL, file, or URI with the default Linux handler via xdg-open.",
        url_schema,
        _open_url,
    )

    registry.register("reset_app_state", "Not generically available on Linux; application data locations are app-specific.", ToolSchema.object({
        "app": ToolSchema.string("Application identifier."),
        "wipeData": ToolSchema.boolean("Required opt-in in the macOS implementation.", False),
    }, "app"), lambda _: ToolResult.error("reset_app_state is unsupported on Linux because Linux applications do not share one safe data-container model."), destructive=True)

    _register_window_tools(registry)


def _register_window_tools(registry: Any) -> None:
    list_properties = {"app": ToolSchema.string("Optional application identifier; omit for all visible windows.")}
    registry.register("list_windows",
        "List top-level Linux desktop windows.",
        ToolSchema.object(list_properties),
        _list_windows,
        read_only=True,
    )

    app_schema = ToolSchema.object(ToolSchema.app_properties(), "app")
    registry.register("get_window_bounds",
        "Get a top-level window's bounds.",
        app_schema,
        _get_bounds,
        read_only=True,
    )

    set_properties = ToolSchema.app_properties()
    set_properties["x"] = ToolSchema.number("New left coordinate; omit to preserve.")
    set_properties["y"] = ToolSchema.number("New top coordinate; omit to preserve.")
    set_properties["width"] = ToolSchema.number("New width; omit to preserve.")
    set_properties["height"] = ToolSchema.number("New height; omit to preserve.")
    registry.register("set_window_bounds",
        "Move or resize a top-level window without activating it.",
        ToolSchema.object(set_properties, "app"),
        _set_bounds,
    )

    registry.register("minimize_window", "Minimize a top-level window.", app_schema, _minimize)
    registry.register("restore_window",
        "Restore a minimized/hidden top-level window without intentionally activating it.",
        app_schema,
        _restore,
    )


def _launch(args: dict[str, Any]) -> dict[str, Any]:
    path = as_string(args, "path") or as_string(args, "bundleId")
    if not path:
        from ..result import ToolError

        raise ToolError("Missing path.")
    app = app_service.launch(path, as_string(args, "arguments"), as_bool(args, "foreground"))
    return ToolResult.json(app_service.app_json(app))


def _activate(args: dict[str, Any]) -> dict[str, Any]:
    app = app_service.resolve(required(args, "app"))
    window = app_service.resolve_window(app, as_int(args, "windowIndex", 0, 0, 100))
    app_service.activate_app(app, window)
    return ToolResult.json({"success": True, "pid": app.pid})


def _quit(args: dict[str, Any]) -> dict[str, Any]:
    app = app_service.resolve(required(args, "app"))
    method = app_service.quit_app(app, as_bool(args, "force"))
    return ToolResult.json({"success": True, "method": method})


def _show(args: dict[str, Any], hide: bool) -> dict[str, Any]:
    app = app_service.resolve(required(args, "app"))
    count = app_service.show_windows(app, hide=hide)
    return ToolResult.json(
        {"success": count > 0, "windowCount": count, "method": "hide" if hide else "show-no-activate"}
    )


def _open_url(args: dict[str, Any]) -> dict[str, Any]:
    value = required(args, "url")
    app_service.open_url(value)
    return ToolResult.json({"success": True, "url": value})


def _list_windows(args: dict[str, Any]) -> dict[str, Any]:
    identifier = as_string(args, "app")
    if identifier:
        app = app_service.resolve(identifier)
        windows = [app_service.window_json(window, app.name) for window in app.windows]
    else:
        windows = []
        for app in app_service.list_apps():
            windows.extend(app_service.window_json(window, app.name) for window in app.windows)
    return ToolResult.json({"windows": windows})


def _get_bounds(args: dict[str, Any]) -> dict[str, Any]:
    app = app_service.resolve(required(args, "app"))
    window = app_service.resolve_window(app, as_int(args, "windowIndex", 0, 0, 100))
    return ToolResult.json(app_service.window_json(window, app.name))


def _set_bounds(args: dict[str, Any]) -> dict[str, Any]:
    app = app_service.resolve(required(args, "app"))
    window = app_service.resolve_window(app, as_int(args, "windowIndex", 0, 0, 100))
    x = int(round(optional_number(args, "x", window.bounds["x"])))
    y = int(round(optional_number(args, "y", window.bounds["y"])))
    width = max(1, int(round(optional_number(args, "width", window.bounds["width"]))))
    height = max(1, int(round(optional_number(args, "height", window.bounds["height"]))))
    app_service.set_bounds(window, x, y, width, height)
    return ToolResult.json({"success": True})


def _minimize(args: dict[str, Any]) -> dict[str, Any]:
    app = app_service.resolve(required(args, "app"))
    window = app_service.resolve_window(app, as_int(args, "windowIndex", 0, 0, 100))
    app_service.minimize_window(window)
    return ToolResult.json({"success": True, "state": "minimized"})


def _restore(args: dict[str, Any]) -> dict[str, Any]:
    app = app_service.resolve(required(args, "app"))
    window = app_service.resolve_window(app, as_int(args, "windowIndex", 0, 0, 100))
    app_service.restore_window(window)
    return ToolResult.json({"success": True, "state": "restored"})

"""Permissions probe and clipboard tools."""

from __future__ import annotations

from typing import Any

from .. import clipboard
from ..args import required
from ..atspi_service import AtspiService
from ..display import clipboard_backend, display_server, screenshot_backend
from ..result import ToolResult
from ..schema import ToolSchema


def register(registry: Any) -> None:
    registry.register("check_permissions",
        "Report Linux automation readiness: AT-SPI, display server, and helper binaries.",
        ToolSchema.empty(),
        _permissions,
        read_only=True,
    )

    registry.register("get_clipboard",
        "Read Unicode text from the system clipboard.",
        ToolSchema.empty(),
        lambda _: ToolResult.json({"text": clipboard.get_text()}),
        read_only=True,
    )

    registry.register("set_clipboard",
        "Replace the system-wide clipboard text.",
        ToolSchema.object({"text": ToolSchema.string("Text to place on the clipboard.")}, "text"),
        lambda args: _set_clipboard(args),
        destructive=True,
    )


def _permissions(_args: dict[str, Any]) -> dict[str, Any]:
    atspi = AtspiService.shared().available()
    server = display_server()
    shots = screenshot_backend()
    clip = clipboard_backend()
    return ToolResult.json(
        {
            "allGranted": atspi and server != "none",
            "atspiAvailable": atspi,
            "displayServer": server,
            "screenshotBackend": shots,
            "clipboardBackend": clip,
            "limitations": [
                "AT-SPI actions and editable text are background-safe; raw input needs foreground:true.",
                "X11 screenshots use ImageMagick import; Wayland screenshots use grim.",
                "reset_app_state, start_recording, and stop_recording return explicit unsupported errors.",
            ],
        }
    )


def _set_clipboard(args: dict[str, Any]) -> dict[str, Any]:
    clipboard.set_text(required(args, "text"))
    return ToolResult.json({"success": True})

"""Display server detection and helper-binary backends."""

from __future__ import annotations

import os
from typing import Literal

from .proc import which

DisplayServer = Literal["x11", "wayland", "none"]
ScreenshotBackend = Literal["imagemagick-import", "grim", "none"]
ClipboardBackend = Literal["xclip", "xsel", "wl-clipboard", "none"]
PointerBackend = Literal["xdotool", "ydotool", "none"]


def display_server() -> DisplayServer:
    # Wayland compositors commonly keep DISPLAY for XWayland. Prefer Wayland.
    if os.environ.get("WAYLAND_DISPLAY"):
        return "wayland"
    if os.environ.get("DISPLAY"):
        return "x11"
    return "none"


def screenshot_backend() -> ScreenshotBackend:
    server = display_server()
    if server == "x11" and which("import"):
        return "imagemagick-import"
    if server == "wayland" and which("grim"):
        return "grim"
    return "none"


def clipboard_backend() -> ClipboardBackend:
    server = display_server()
    if server == "wayland" and which("wl-paste", "wl-copy"):
        return "wl-clipboard"
    if which("xclip"):
        return "xclip"
    if which("xsel"):
        return "xsel"
    return "none"


def pointer_backend() -> PointerBackend:
    server = display_server()
    if server == "x11" and which("xdotool"):
        return "xdotool"
    if which("ydotool"):
        return "ydotool"
    return "none"


def jpeg_encoder() -> str | None:
    return which("convert", "magick")


def require_display() -> DisplayServer:
    from .result import ToolError

    server = display_server()
    if server == "none":
        raise ToolError(
            "No display server: DISPLAY and WAYLAND_DISPLAY are both unset. "
            "Linux GUI tools need an X11 or Wayland session."
        )
    return server

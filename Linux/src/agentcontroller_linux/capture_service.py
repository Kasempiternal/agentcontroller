"""Screen capture: X11 via ImageMagick import, Wayland via grim. JPEG when convert exists."""

from __future__ import annotations

import os
import tempfile
from pathlib import Path

from .display import jpeg_encoder, require_display, screenshot_backend
from .proc import run_argv, which
from .result import ToolError

MAX_LONGEST_SIDE = 1400
JPEG_QUALITY = 70  # ImageMagick quality; 0.7 in the contract


def capture_screen() -> tuple[bytes, str, str]:
    require_display()
    backend = screenshot_backend()
    with tempfile.TemporaryDirectory(prefix="agentcontroller-") as tmp:
        png = str(Path(tmp) / "capture.png")
        if backend == "imagemagick-import":
            completed = run_argv(["import", "-window", "root", png])
            mode = "imagemagick-import"
        elif backend == "grim":
            completed = run_argv(["grim", png])
            mode = "grim"
        else:
            raise ToolError(_missing_backend())
        if completed.returncode != 0 or not Path(png).is_file():
            err = completed.stderr.decode("utf-8", "replace").strip()
            raise ToolError(f"Screenshot failed ({mode}): {err or f'exit {completed.returncode}'}")
        data, mime = _encode(png)
        return data, mime, mode


def capture_window_xid(xid: int) -> tuple[bytes, str, str]:
    require_display()
    backend = screenshot_backend()
    if backend == "imagemagick-import":
        with tempfile.TemporaryDirectory(prefix="agentcontroller-") as tmp:
            png = str(Path(tmp) / "window.png")
            completed = run_argv(["import", "-window", hex(xid), png])
            if completed.returncode != 0 or not Path(png).is_file():
                err = completed.stderr.decode("utf-8", "replace").strip()
                raise ToolError(f"Window screenshot failed: {err or f'exit {completed.returncode}'}")
            data, mime = _encode(png)
            return data, mime, "imagemagick-import"
    if backend == "grim":
        raise ToolError(
            "grim captures a region, not an X11 window id. Use screenshot_window with AT-SPI "
            "extents, or screenshot_element."
        )
    raise ToolError(_missing_backend())


def capture_region(x: int, y: int, width: int, height: int) -> tuple[bytes, str, str]:
    require_display()
    if width <= 0 or height <= 0:
        raise ToolError("Capture region has invalid bounds.")
    backend = screenshot_backend()
    with tempfile.TemporaryDirectory(prefix="agentcontroller-") as tmp:
        png = str(Path(tmp) / "region.png")
        if backend == "imagemagick-import":
            geometry = f"{width}x{height}+{x}+{y}"
            completed = run_argv(["import", "-window", "root", "-crop", geometry, png])
            mode = "imagemagick-import"
        elif backend == "grim":
            geometry = f"{x},{y} {width}x{height}"
            completed = run_argv(["grim", "-g", geometry, png])
            mode = "grim"
        else:
            raise ToolError(_missing_backend())
        if completed.returncode != 0 or not Path(png).is_file():
            err = completed.stderr.decode("utf-8", "replace").strip()
            raise ToolError(f"Region screenshot failed: {err or f'exit {completed.returncode}'}")
        data, mime = _encode(png)
        return data, mime, mode


def _encode(png_path: str) -> tuple[bytes, str]:
    encoder = jpeg_encoder()
    if encoder is None:
        return Path(png_path).read_bytes(), "image/png"
    jpeg_path = png_path + ".jpg"
    argv = [encoder]
    if os.path.basename(encoder) == "magick":
        argv.append("convert")
    argv.extend(
        [
            png_path,
            "-resize",
            f"{MAX_LONGEST_SIDE}x{MAX_LONGEST_SIDE}>",
            "-quality",
            str(JPEG_QUALITY),
            jpeg_path,
        ]
    )
    completed = run_argv(argv)
    if completed.returncode != 0 or not Path(jpeg_path).is_file():
        return Path(png_path).read_bytes(), "image/png"
    return Path(jpeg_path).read_bytes(), "image/jpeg"


def _missing_backend() -> str:
    server = screenshot_backend()
    _ = server
    if which("import") is None and which("grim") is None:
        return (
            "No screenshot backend: install ImageMagick (`import`) on X11, or grim on Wayland."
        )
    return (
        "No screenshot backend matches this display server. X11 uses ImageMagick `import`; "
        "Wayland uses grim."
    )

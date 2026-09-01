"""System clipboard via xclip/xsel (X11) or wl-clipboard (Wayland)."""

from __future__ import annotations

from .display import clipboard_backend
from .proc import run_argv, which
from .result import ToolError


def get_text() -> str:
    backend = clipboard_backend()
    if backend == "wl-clipboard":
        paste = which("wl-paste")
        if paste is None:
            raise ToolError("wl-paste is not on PATH.")
        completed = run_argv([paste, "-n"])
    elif backend == "xclip":
        completed = run_argv(["xclip", "-selection", "clipboard", "-o"])
    elif backend == "xsel":
        completed = run_argv(["xsel", "--clipboard", "--output"])
    else:
        raise ToolError(
            "No clipboard backend: install xclip or xsel on X11, or wl-clipboard on Wayland."
        )
    if completed.returncode != 0:
        err = completed.stderr.decode("utf-8", "replace").strip()
        raise ToolError(f"Clipboard read failed: {err or f'exit {completed.returncode}'}")
    return completed.stdout.decode("utf-8", "replace")


def set_text(text: str) -> None:
    backend = clipboard_backend()
    payload = text.encode("utf-8")
    if backend == "wl-clipboard":
        copy = which("wl-copy")
        if copy is None:
            raise ToolError("wl-copy is not on PATH.")
        completed = run_argv([copy], stdin_bytes=payload)
    elif backend == "xclip":
        completed = run_argv(["xclip", "-selection", "clipboard"], stdin_bytes=payload)
    elif backend == "xsel":
        completed = run_argv(["xsel", "--clipboard", "--input"], stdin_bytes=payload)
    else:
        raise ToolError(
            "No clipboard backend: install xclip or xsel on X11, or wl-clipboard on Wayland."
        )
    if completed.returncode != 0:
        err = completed.stderr.decode("utf-8", "replace").strip()
        raise ToolError(f"Clipboard write failed: {err or f'exit {completed.returncode}'}")

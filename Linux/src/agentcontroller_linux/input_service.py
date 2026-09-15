"""Global pointer/keyboard fallbacks. Require an explicit foreground:true caller and restore prior focus."""

from __future__ import annotations

import time
from typing import Callable

from .display import pointer_backend, require_display
from .proc import decode_out, run_argv, which
from .result import ToolError

KEY_NAMES = {
    "backspace": "BackSpace",
    "tab": "Tab",
    "return": "Return",
    "enter": "Return",
    "escape": "Escape",
    "esc": "Escape",
    "space": "space",
    "pageup": "Page_Up",
    "pagedown": "Page_Down",
    "end": "End",
    "home": "Home",
    "left": "Left",
    "up": "Up",
    "right": "Right",
    "down": "Down",
    "insert": "Insert",
    "delete": "Delete",
    "forwarddelete": "Delete",
}

MODIFIER_NAMES = {
    "ctrl": "ctrl",
    "control": "ctrl",
    "shift": "shift",
    "alt": "alt",
    "opt": "alt",
    "option": "alt",
    "cmd": "super",
    "win": "super",
    "windows": "super",
    "super": "super",
    "meta": "super",
}


def require_foreground(args: dict, tool: str) -> None:
    from .args import as_bool

    if not as_bool(args, "foreground"):
        raise ToolError(
            f"{tool} uses global pointer/keyboard input and cannot be background-safe. "
            "Retry with foreground:true to authorize a temporary focus/cursor change."
        )


def click_at(pid: int, x: int, y: int, button: int = 1, clicks: int = 1) -> bool:
    return _in_foreground(pid, lambda: _click(x, y, button, clicks))


def type_at_element(pid: int, element: object, text: str) -> bool:
    from .atspi_service import AtspiService

    frame = AtspiService.shared().extents(element)
    x = frame["x"] + max(frame["width"] // 2, 1)
    y = frame["y"] + max(frame["height"] // 2, 1)

    def body() -> None:
        _click(x, y, 1, 1)
        time.sleep(0.05)
        _type_text(text)

    return _in_foreground(pid, body)


def send_shortcut(pid: int, key: str, modifiers: list[str]) -> bool:
    chord = _xdotool_chord(key, modifiers)

    def body() -> None:
        backend = pointer_backend()
        if backend == "xdotool":
            completed = run_argv(["xdotool", "key", "--clearmodifiers", chord])
            if completed.returncode != 0:
                raise ToolError("xdotool rejected the key event.")
            return
        if backend == "ydotool":
            argv = ["ydotool", "key"]
            for modifier in modifiers:
                argv.append(f"{_ydotool_modifier(modifier)}:1")
            argv.append(f"{_ydotool_key(key)}:1")
            argv.append(f"{_ydotool_key(key)}:0")
            for modifier in reversed(modifiers):
                argv.append(f"{_ydotool_modifier(modifier)}:0")
            completed = run_argv(argv)
            if completed.returncode != 0:
                raise ToolError("ydotool rejected the key event.")
            return
        wtype = which("wtype")
        if wtype:
            argv = [wtype]
            for modifier in modifiers:
                argv.extend(["-M", MODIFIER_NAMES.get(modifier.lower(), modifier)])
            argv.extend(["-k", _wtype_key(key)])
            for modifier in reversed(modifiers):
                argv.extend(["-m", MODIFIER_NAMES.get(modifier.lower(), modifier)])
            completed = run_argv(argv)
            if completed.returncode != 0:
                raise ToolError("wtype rejected the key event.")
            return
        raise ToolError(_missing_pointer())

    return _in_foreground(pid, body)


def drag(pid: int, from_x: int, from_y: int, to_x: int, to_y: int, duration: float) -> bool:
    duration = min(10.0, max(0.05, duration))
    steps = min(300, max(4, int(round(duration * 60))))
    delay = max(0.001, duration / steps)

    def body() -> None:
        _move(from_x, from_y)
        _mouse_down(1)
        try:
            for step in range(1, steps + 1):
                progress = step / steps
                x = int(round(from_x + (to_x - from_x) * progress))
                y = int(round(from_y + (to_y - from_y) * progress))
                _move(x, y)
                time.sleep(delay)
        finally:
            _mouse_up(1)

    return _in_foreground(pid, body)


def _in_foreground(pid: int, action: Callable[[], None]) -> bool:
    require_display()
    from .app_service import activate_app, resolve, resolve_window, x11_active_xid, activate_xid

    app = resolve(str(pid))
    window = resolve_window(app, 0)
    previous_xid = x11_active_xid()
    previous_pointer = _pointer_position()
    activated = previous_xid is None or window.xid is None or previous_xid != window.xid
    if activated:
        activate_app(app, window)
        time.sleep(0.12)
    try:
        action()
        time.sleep(0.05)
        return activated
    finally:
        if previous_pointer is not None:
            _move(previous_pointer[0], previous_pointer[1])
        if activated and previous_xid is not None:
            activate_xid(previous_xid)


def _click(x: int, y: int, button: int, clicks: int) -> None:
    _move(x, y)
    backend = pointer_backend()
    if backend == "xdotool":
        argv = ["xdotool", "click", "--repeat", str(clicks), "--delay", "70", str(button)]
        completed = run_argv(argv)
        if completed.returncode != 0:
            raise ToolError("xdotool click failed.")
        return
    if backend == "ydotool":
        for _ in range(clicks):
            completed = run_argv(["ydotool", "click", f"{button}:1", f"{button}:0"])
            if completed.returncode != 0:
                raise ToolError("ydotool click failed.")
            time.sleep(0.07)
        return
    raise ToolError(_missing_pointer())


def _move(x: int, y: int) -> None:
    backend = pointer_backend()
    if backend == "xdotool":
        completed = run_argv(["xdotool", "mousemove", "--sync", str(x), str(y)])
        if completed.returncode != 0:
            raise ToolError("xdotool mousemove failed.")
        return
    if backend == "ydotool":
        completed = run_argv(["ydotool", "mousemove", "--absolute", str(x), str(y)])
        if completed.returncode != 0:
            raise ToolError("ydotool mousemove failed.")
        return
    raise ToolError(_missing_pointer())


def _mouse_down(button: int) -> None:
    backend = pointer_backend()
    if backend == "xdotool":
        run_argv(["xdotool", "mousedown", str(button)])
        return
    if backend == "ydotool":
        run_argv(["ydotool", "click", f"{button}:1"])
        return
    raise ToolError(_missing_pointer())


def _mouse_up(button: int) -> None:
    backend = pointer_backend()
    if backend == "xdotool":
        run_argv(["xdotool", "mouseup", str(button)])
        return
    if backend == "ydotool":
        run_argv(["ydotool", "click", f"{button}:0"])
        return
    raise ToolError(_missing_pointer())


def _type_text(text: str) -> None:
    backend = pointer_backend()
    if backend == "xdotool":
        completed = run_argv(["xdotool", "type", "--clearmodifiers", "--", text])
        if completed.returncode != 0:
            raise ToolError("xdotool type failed.")
        return
    wtype = which("wtype")
    if wtype:
        completed = run_argv([wtype, "--", text])
        if completed.returncode != 0:
            raise ToolError("wtype failed.")
        return
    if backend == "ydotool":
        completed = run_argv(["ydotool", "type", text])
        if completed.returncode != 0:
            raise ToolError("ydotool type failed.")
        return
    raise ToolError(_missing_pointer())


def _pointer_position() -> tuple[int, int] | None:
    if which("xdotool") is None:
        return None
    completed = run_argv(["xdotool", "getmouselocation", "--shell"])
    if completed.returncode != 0:
        return None
    values: dict[str, int] = {}
    for line in decode_out(completed).splitlines():
        key, _, raw = line.partition("=")
        if raw.lstrip("-").isdigit():
            values[key] = int(raw)
    if "X" in values and "Y" in values:
        return values["X"], values["Y"]
    return None


def _xdotool_chord(key: str, modifiers: list[str]) -> str:
    parts = [MODIFIER_NAMES.get(item.lower(), "") for item in modifiers]
    if any(not part for part in parts):
        unknown = [item for item in modifiers if item.lower() not in MODIFIER_NAMES]
        raise ToolError(f"Unknown modifier: {unknown[0]}")
    parts.append(_xdotool_key(key))
    return "+".join(parts)


def _xdotool_key(key: str) -> str:
    normalized = key.strip().lower()
    if len(normalized) == 1 and (normalized.isalnum() or normalized in ".,;[]\\'-=/`"):
        return normalized
    if normalized.startswith("f") and normalized[1:].isdigit():
        number = int(normalized[1:])
        if 1 <= number <= 24:
            return f"F{number}"
    if normalized in KEY_NAMES:
        return KEY_NAMES[normalized]
    raise ToolError(f"Unknown key: {key}")


def _wtype_key(key: str) -> str:
    return _xdotool_key(key)


def _ydotool_key(key: str) -> str:
    # ydotool uses linux event codes as numbers; prefer named keys when possible.
    return _xdotool_key(key)


def _ydotool_modifier(modifier: str) -> str:
    mapped = MODIFIER_NAMES.get(modifier.lower())
    if not mapped:
        raise ToolError(f"Unknown modifier: {modifier}")
    return mapped


def _missing_pointer() -> str:
    return (
        "No global input backend: install xdotool on X11, or ydotool (and optionally wtype) on Wayland."
    )

"""Desktop application and window discovery: AT-SPI first, then X11 properties."""

from __future__ import annotations

import os
import shlex
import signal
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

from .display import display_server, require_display
from .proc import decode_out, run_argv, which
from .result import ToolError


@dataclass
class WindowInfo:
    pid: int
    index: int
    title: str
    wm_class: str = ""
    desktop_id: str = ""
    xid: int | None = None
    bounds: dict[str, int] = field(default_factory=lambda: {"x": 0, "y": 0, "width": 0, "height": 0})
    is_visible: bool = True
    is_minimized: bool = False
    is_active: bool = False


@dataclass
class AppInfo:
    pid: int
    name: str
    identifier: str
    executable_path: str | None
    wm_class: str
    desktop_id: str
    title: str
    is_active: bool
    windows: list[WindowInfo] = field(default_factory=list)


def process_comm(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/comm").read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return ""


def process_exe(pid: int) -> str | None:
    try:
        return os.readlink(f"/proc/{pid}/exe")
    except OSError:
        return None


def _desktop_search_roots() -> list[Path]:
    home = Path.home()
    roots = [Path(os.environ.get("XDG_DATA_HOME", home / ".local" / "share"))]
    extra = os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share")
    roots.extend(Path(part) for part in extra.split(":") if part)
    return roots


def desktop_id_for_wm_class(wm_class: str) -> str:
    if not wm_class:
        return ""
    instance, _, klass = wm_class.partition(".")
    candidates = [klass, instance, wm_class]
    for root in _desktop_search_roots():
        applications = root / "applications"
        if not applications.is_dir():
            continue
        for candidate in candidates:
            if not candidate:
                continue
            path = applications / f"{candidate}.desktop"
            if path.is_file():
                return candidate
        try:
            for path in applications.glob("*.desktop"):
                text = path.read_text(encoding="utf-8", errors="replace")
                if f"StartupWMClass={klass}" in text or f"StartupWMClass={instance}" in text:
                    return path.stem
        except OSError:
            continue
    return klass or instance


def _parse_xprop_ids(raw: str) -> list[int]:
    ids: list[int] = []
    for token in raw.replace(",", " ").split():
        if token.startswith("0x"):
            try:
                ids.append(int(token, 16))
            except ValueError:
                continue
    return ids


def _xprop(xid: int | None, *atoms: str) -> str:
    argv = ["xprop"]
    if xid is None:
        argv.extend(["-root", *atoms])
    else:
        argv.extend(["-id", hex(xid), *atoms])
    completed = run_argv(argv, timeout=8)
    return decode_out(completed) if completed.returncode == 0 else ""


def _xprop_value(raw: str, atom: str) -> str:
    for line in raw.splitlines():
        if line.startswith(atom):
            _, _, rest = line.partition("=")
            if not rest:
                _, _, rest = line.partition(":")
            return rest.strip().strip('"')
    return ""


def _parse_wm_class(raw: str) -> str:
    # WM_CLASS(STRING) = "instance", "Class"
    parts = [part.strip().strip('"') for part in raw.split(",")]
    parts = [part for part in parts if part]
    if len(parts) >= 2:
        return f"{parts[0]}.{parts[1]}"
    return parts[0] if parts else ""


def _xwininfo_bounds(xid: int) -> dict[str, int]:
    bounds = {"x": 0, "y": 0, "width": 0, "height": 0}
    if which("xwininfo") is None:
        return bounds
    completed = run_argv(["xwininfo", "-id", hex(xid)], timeout=8)
    if completed.returncode != 0:
        return bounds
    mapping = {
        "Absolute upper-left X": "x",
        "Absolute upper-left Y": "y",
        "Width": "width",
        "Height": "height",
    }
    for line in decode_out(completed).splitlines():
        stripped = line.strip()
        for prefix, key in mapping.items():
            if stripped.startswith(prefix):
                _, _, rest = stripped.partition(":")
                try:
                    bounds[key] = int(rest.strip())
                except ValueError:
                    pass
    return bounds


def x11_active_xid() -> int | None:
    if which("xdotool"):
        completed = run_argv(["xdotool", "getactivewindow"], timeout=5)
        if completed.returncode == 0:
            text = decode_out(completed).strip()
            if text.isdigit():
                return int(text)
    raw = _xprop(None, "_NET_ACTIVE_WINDOW")
    ids = _parse_xprop_ids(raw)
    return ids[0] if ids else None


def x11_windows() -> list[WindowInfo]:
    if which("xprop") is None:
        return []
    ids = _parse_xprop_ids(_xprop(None, "_NET_CLIENT_LIST"))
    active = x11_active_xid()
    windows: list[WindowInfo] = []
    per_pid: dict[int, int] = {}
    for xid in ids:
        raw = _xprop(xid, "WM_CLASS", "WM_NAME", "_NET_WM_NAME", "_NET_WM_PID", "_NET_WM_DESKTOP", "_NET_WM_STATE")
        pid_text = _xprop_value(raw, "_NET_WM_PID").split()[0] if _xprop_value(raw, "_NET_WM_PID") else ""
        try:
            pid = int(pid_text)
        except ValueError:
            pid = 0
        title = _xprop_value(raw, "_NET_WM_NAME") or _xprop_value(raw, "WM_NAME")
        wm_class = _parse_wm_class(_xprop_value(raw, "WM_CLASS"))
        state = _xprop_value(raw, "_NET_WM_STATE").lower()
        desktop = _xprop_value(raw, "_NET_WM_DESKTOP").split()[0]
        index = per_pid.get(pid, 0)
        per_pid[pid] = index + 1
        windows.append(
            WindowInfo(
                pid=pid,
                index=index,
                title=title,
                wm_class=wm_class,
                desktop_id=desktop_id_for_wm_class(wm_class) or desktop,
                xid=xid,
                bounds=_xwininfo_bounds(xid),
                is_visible="hidden" not in state,
                is_minimized="hidden" in state,
                is_active=active is not None and xid == active,
            )
        )
    return windows


def _apps_from_windows(windows: Iterable[WindowInfo]) -> list[AppInfo]:
    grouped: dict[int, list[WindowInfo]] = {}
    for window in windows:
        if window.pid <= 0:
            continue
        grouped.setdefault(window.pid, []).append(window)
    apps: list[AppInfo] = []
    for pid, app_windows in grouped.items():
        app_windows.sort(key=lambda item: item.index)
        primary = app_windows[0]
        name = process_comm(pid) or primary.wm_class.split(".")[-1] or f"pid-{pid}"
        identifier = primary.wm_class or name
        apps.append(
            AppInfo(
                pid=pid,
                name=name,
                identifier=identifier,
                executable_path=process_exe(pid),
                wm_class=primary.wm_class,
                desktop_id=primary.desktop_id or desktop_id_for_wm_class(primary.wm_class),
                title=primary.title,
                is_active=any(window.is_active for window in app_windows),
                windows=app_windows,
            )
        )
    apps.sort(key=lambda app: app.name.lower())
    return apps


def list_apps() -> list[AppInfo]:
    from .atspi_service import AtspiService

    atspi_apps = AtspiService.shared().list_apps()
    x11_apps = _apps_from_windows(x11_windows()) if display_server() == "x11" else []
    if atspi_apps:
        by_pid = {app.pid: app for app in x11_apps}
        merged: list[AppInfo] = []
        for app in atspi_apps:
            extra = by_pid.pop(app.pid, None)
            if extra is not None:
                app.wm_class = app.wm_class or extra.wm_class
                app.desktop_id = app.desktop_id or extra.desktop_id
                app.executable_path = app.executable_path or extra.executable_path
                if extra.windows:
                    app.windows = extra.windows
                    app.title = app.title or extra.title
                    app.is_active = app.is_active or extra.is_active
            merged.append(app)
        for leftover in by_pid.values():
            merged.append(leftover)
        merged.sort(key=lambda app: app.name.lower())
        return merged
    if x11_apps:
        return x11_apps
    server = display_server()
    if server == "none" and not AtspiService.shared().available():
        raise ToolError(
            "No display server and AT-SPI is unavailable. Start a graphical session "
            "or install python3-gi and gir1.2-atspi-2.0 with the accessibility bus running."
        )
    if server == "wayland" and not AtspiService.shared().available():
        raise ToolError(
            "AT-SPI is unavailable on Wayland, so applications cannot be listed. "
            "Install python3-gi and gir1.2-atspi-2.0 and enable assistive technologies."
        )
    return []


def resolve(app: str) -> AppInfo:
    apps = list_apps()
    needle = app.strip()
    if needle.isdigit():
        pid = int(needle)
        for candidate in apps:
            if candidate.pid == pid:
                return candidate
        raise ToolError(f"Application not running: {app}")

    lowered = needle.lower()
    base = Path(needle).name.lower()
    if base.endswith(".desktop"):
        base = base[: -len(".desktop")]

    for candidate in apps:
        haystacks = [
            candidate.name,
            candidate.identifier,
            candidate.wm_class,
            candidate.wm_class.split(".")[0] if candidate.wm_class else "",
            candidate.wm_class.split(".")[-1] if candidate.wm_class else "",
            candidate.desktop_id,
            candidate.title,
            Path(candidate.executable_path).name if candidate.executable_path else "",
        ]
        for item in haystacks:
            if item and item.lower() in {lowered, base}:
                return candidate
        if candidate.title and candidate.title.lower() == lowered:
            return candidate
    raise ToolError(f"Application not running: {app}")


def resolve_window(app: AppInfo, index: int) -> WindowInfo:
    if not app.windows:
        # Synthesize a single unknown window so callers can still use pid-based tools.
        if index == 0:
            return WindowInfo(pid=app.pid, index=0, title=app.title, wm_class=app.wm_class, desktop_id=app.desktop_id)
        raise ToolError(f"Window {index} not found for {app.name}.")
    for window in app.windows:
        if window.index == index:
            return window
    raise ToolError(f"Window {index} not found for {app.name}.")


def window_json(window: WindowInfo, app_name: str) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "title": window.title,
        "appName": app_name,
        "pid": window.pid,
        "index": window.index,
        "wmClass": window.wm_class or None,
        "desktopId": window.desktop_id or None,
        "isVisible": window.is_visible,
        "isMinimized": window.is_minimized,
        "bounds": window.bounds,
    }
    if window.xid is not None:
        payload["handle"] = format(window.xid, "X")
    return payload


def app_json(app: AppInfo) -> dict[str, Any]:
    return {
        "name": app.name,
        "identifier": app.identifier,
        "executablePath": app.executable_path,
        "pid": app.pid,
        "wmClass": app.wm_class or None,
        "desktopId": app.desktop_id or None,
        "isActive": app.is_active,
        "mainWindowTitle": app.title,
    }


def frontmost() -> AppInfo:
    require_display()
    apps = list_apps()
    for app in apps:
        if app.is_active:
            return app
    xid = x11_active_xid()
    if xid is not None:
        for app in apps:
            for window in app.windows:
                if window.xid == xid:
                    return app
    raise ToolError("No foreground application found.")


def _desktop_exec(desktop_path: Path) -> list[str] | None:
    try:
        text = desktop_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    for line in text.splitlines():
        if line.startswith("Exec="):
            command = line[5:].strip()
            # Desktop spec field codes are not file arguments we were given.
            for code in ("%F", "%f", "%U", "%u", "%D", "%d", "%N", "%n", "%i", "%c", "%k", "%v", "%m"):
                command = command.replace(code, "")
            parts = shlex.split(command, posix=True)
            return parts or None
    return None


def _resolve_launch_argv(path: str, arguments: str | None) -> list[str]:
    extra = shlex.split(arguments, posix=True) if arguments else []
    expanded = os.path.expanduser(path)
    as_path = Path(expanded)
    if as_path.is_file() and os.access(as_path, os.X_OK):
        return [str(as_path), *extra]
    if as_path.suffix == ".desktop" and as_path.is_file():
        argv = _desktop_exec(as_path)
        if argv:
            return [*argv, *extra]
    name = as_path.name
    if name.endswith(".desktop"):
        stem = name[: -len(".desktop")]
        if which("gtk-launch"):
            return ["gtk-launch", stem, *extra]
        for root in _desktop_search_roots():
            desktop = root / "applications" / name
            if desktop.is_file():
                argv = _desktop_exec(desktop)
                if argv:
                    return [*argv, *extra]
    found = which(expanded) or which(name)
    if found:
        return [found, *extra]
    for root in _desktop_search_roots():
        for candidate in (f"{name}.desktop", f"{path}.desktop"):
            desktop = root / "applications" / candidate
            if desktop.is_file():
                if which("gtk-launch"):
                    return ["gtk-launch", desktop.stem, *extra]
                argv = _desktop_exec(desktop)
                if argv:
                    return [*argv, *extra]
    raise ToolError(f"Could not resolve launch path: {path}")


def launch(path: str, arguments: str | None, foreground: bool) -> AppInfo:
    require_display()
    argv = _resolve_launch_argv(path, arguments)
    previous = x11_active_xid()
    import subprocess

    try:
        started = subprocess.Popen(
            argv,
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError as exc:
        raise ToolError(f"Could not launch: {path} ({exc})") from exc

    deadline = time.time() + 5
    last_error = None
    while time.time() < deadline:
        try:
            found = resolve(str(started.pid))
            if not foreground and previous is not None:
                activate_xid(previous)
            elif foreground:
                window = resolve_window(found, 0)
                if window.xid is not None:
                    activate_xid(window.xid)
            found.is_active = foreground
            return found
        except ToolError as exc:
            last_error = exc
        if started.poll() is not None and started.returncode not in (None, 0):
            raise ToolError(f"Launch command exited with {started.returncode}: {path}")
        time.sleep(0.1)

    # Some daemons fork and exit 0; try matching the executable name.
    comm = Path(argv[0]).name
    try:
        return resolve(comm)
    except ToolError:
        raise ToolError(
            last_error.args[0]
            if last_error
            else f"The launch command completed, but no '{comm}' window appeared within 5 seconds."
        )


def activate_xid(xid: int) -> bool:
    if which("xdotool"):
        completed = run_argv(["xdotool", "windowactivate", "--sync", str(xid)], timeout=8)
        return completed.returncode == 0
    if which("wmctrl"):
        completed = run_argv(["wmctrl", "-i", "-a", hex(xid)], timeout=8)
        return completed.returncode == 0
    return False


def activate_app(app: AppInfo, window: WindowInfo) -> None:
    if window.xid is not None and activate_xid(window.xid):
        return
    from .atspi_service import AtspiService

    if AtspiService.shared().activate_app(app.pid):
        return
    raise ToolError("The window manager refused to activate the application.")


def show_windows(app: AppInfo, *, hide: bool, include_hidden: bool = True) -> int:
    count = 0
    windows = app.windows or [resolve_window(app, 0)]
    for window in windows:
        if window.xid is None:
            continue
        if hide:
            if which("xdotool"):
                run_argv(["xdotool", "windowunmap", str(window.xid)])
                count += 1
            elif which("wmctrl"):
                run_argv(["wmctrl", "-i", "-r", hex(window.xid), "-b", "add,hidden"])
                count += 1
        else:
            if which("xdotool"):
                run_argv(["xdotool", "windowmap", str(window.xid)])
                count += 1
            elif which("wmctrl"):
                run_argv(["wmctrl", "-i", "-r", hex(window.xid), "-b", "remove,hidden"])
                count += 1
        _ = include_hidden
    if count == 0:
        action = "hide" if hide else "show"
        raise ToolError(
            f"Could not {action} windows for {app.name}. On X11 install xdotool or wmctrl; "
            "Wayland compositors often do not expose hide/show."
        )
    return count


def set_bounds(window: WindowInfo, x: int, y: int, width: int, height: int) -> None:
    if window.xid is None:
        raise ToolError("Window has no X11 id; set_window_bounds needs X11 (xdotool or wmctrl).")
    if which("xdotool"):
        move = run_argv(["xdotool", "windowmove", str(window.xid), str(x), str(y)])
        size = run_argv(["xdotool", "windowsize", str(window.xid), str(width), str(height)])
        if move.returncode == 0 and size.returncode == 0:
            return
    if which("wmctrl"):
        geometry = f"0,{x},{y},{width},{height}"
        completed = run_argv(["wmctrl", "-i", "-r", hex(window.xid), "-e", geometry])
        if completed.returncode == 0:
            return
    raise ToolError("Could not move or resize the window. Install xdotool or wmctrl on X11.")


def minimize_window(window: WindowInfo) -> None:
    if window.xid is not None and which("xdotool"):
        completed = run_argv(["xdotool", "windowminimize", str(window.xid)])
        if completed.returncode == 0:
            return
    if window.xid is not None and which("wmctrl"):
        completed = run_argv(["wmctrl", "-i", "-r", hex(window.xid), "-b", "add,hidden"])
        if completed.returncode == 0:
            return
    raise ToolError("Could not minimize the window. Install xdotool or wmctrl on X11.")


def restore_window(window: WindowInfo) -> None:
    if window.xid is not None and which("xdotool"):
        run_argv(["xdotool", "windowmap", str(window.xid)])
        run_argv(["xdotool", "windowactivate", str(window.xid)])
        return
    if window.xid is not None and which("wmctrl"):
        run_argv(["wmctrl", "-i", "-r", hex(window.xid), "-b", "remove,hidden"])
        return
    raise ToolError("Could not restore the window. Install xdotool or wmctrl on X11.")


def quit_app(app: AppInfo, force: bool) -> str:
    if not force:
        closed = False
        for window in app.windows:
            if window.xid is not None and which("wmctrl"):
                completed = run_argv(["wmctrl", "-i", "-c", hex(window.xid)])
                closed = closed or completed.returncode == 0
            elif window.xid is not None and which("xdotool"):
                completed = run_argv(["xdotool", "windowclose", str(window.xid)])
                closed = closed or completed.returncode == 0
        if closed:
            return "close-window"
        try:
            os.kill(app.pid, signal.SIGTERM)
            return "terminate"
        except OSError as exc:
            raise ToolError(f"Could not signal {app.name}: {exc}") from exc
    try:
        os.kill(app.pid, signal.SIGKILL)
        return "terminate"
    except OSError as exc:
        raise ToolError(f"Could not force-kill {app.name}: {exc}") from exc


def open_url(url: str) -> None:
    opener = which("xdg-open")
    if opener is None:
        raise ToolError("xdg-open is not on PATH.")
    import subprocess

    try:
        subprocess.Popen(
            [opener, url],
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError as exc:
        raise ToolError(f"Could not open URL: {exc}") from exc

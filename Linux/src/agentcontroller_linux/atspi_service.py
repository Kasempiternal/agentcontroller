"""AT-SPI accessibility tree. gi.repository.Atspi is imported lazily so headless CI can import the package."""

from __future__ import annotations

import time
from collections import deque
from typing import Any, Iterator

from .args import as_int, as_string, optional_int
from .display import display_server
from .result import ToolError
from .roles import ax_alias, roles_match

SELECTOR_FIELDS = (
    "role",
    "title",
    "titleContains",
    "identifier",
    "value",
    "description",
    "descriptionContains",
    "labelContains",
)


def _try_load_atspi() -> Any | None:
    try:
        import gi

        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi
    except Exception:
        return None
    try:
        Atspi.init()
    except Exception:
        return None
    return Atspi


def _call(obj: Any, *names: str, default: Any = None) -> Any:
    for name in names:
        fn = getattr(obj, name, None)
        if not callable(fn):
            continue
        try:
            value = fn()
        except TypeError:
            continue
        except Exception:
            continue
        if value is not None:
            return value
    return default


def _iface(accessible: Any, *names: str) -> Any:
    return _call(accessible, *names)


class AtspiService:
    _shared: "AtspiService | None" = None

    def __init__(self) -> None:
        self._module: Any | None = None
        self._tried = False
        self._handles: dict[str, Any] = {}
        self._next_handle = 0

    @classmethod
    def shared(cls) -> "AtspiService":
        if cls._shared is None:
            cls._shared = cls()
        return cls._shared

    def available(self) -> bool:
        return self.module() is not None

    def module(self) -> Any | None:
        if not self._tried:
            self._tried = True
            self._module = _try_load_atspi()
        return self._module

    def require(self) -> Any:
        module = self.module()
        if module is None:
            raise ToolError(
                "AT-SPI is unavailable. Install python3-gi and gir1.2-atspi-2.0, "
                "and enable assistive technologies (at-spi-bus-launcher)."
            )
        return module

    def desktop(self) -> Any:
        module = self.require()
        try:
            desktop = module.get_desktop(0)
        except Exception as exc:
            raise ToolError(f"AT-SPI desktop is unreachable: {exc}") from exc
        if desktop is None:
            raise ToolError("AT-SPI returned no desktop. Is the accessibility bus running?")
        return desktop

    def list_apps(self) -> list[Any]:
        if self.module() is None:
            return []
        from .app_service import AppInfo, process_comm, process_exe, desktop_id_for_wm_class

        apps: list[AppInfo] = []
        try:
            desktop = self.desktop()
            count = int(desktop.get_child_count() or 0)
        except ToolError:
            return []
        except Exception:
            return []
        for index in range(count):
            try:
                child = desktop.get_child_at_index(index)
            except Exception:
                continue
            if child is None:
                continue
            pid = self._pid(child)
            if pid <= 0:
                continue
            name = _safe_name(child) or process_comm(pid) or f"pid-{pid}"
            apps.append(
                AppInfo(
                    pid=pid,
                    name=name,
                    identifier=name,
                    executable_path=process_exe(pid),
                    wm_class="",
                    desktop_id=desktop_id_for_wm_class(name),
                    title=_safe_name(child),
                    is_active=self._has_state(child, "ACTIVE"),
                )
            )
        apps.sort(key=lambda app: app.name.lower())
        return apps

    def activate_app(self, pid: int) -> bool:
        try:
            app = self._application(pid)
            window = self._window_at(app, 0)
        except ToolError:
            return False
        component = _iface(window, "get_component_iface", "get_component", "queryComponent")
        if component is not None:
            grab = getattr(component, "grab_focus", None)
            if callable(grab):
                try:
                    return bool(grab())
                except Exception:
                    return False
        return False

    def snapshot(self, app: str, max_depth: int, max_elements: int, window_index: int) -> dict[str, Any]:
        self._handles.clear()
        self._next_handle = 0
        root = self.root_for(app, window_index)
        elements = []
        for item, depth in self._walk(root, max_depth, max_elements):
            handle = self._new_handle(item)
            payload = self.describe(item, handle)
            payload["depth"] = depth
            elements.append(payload)
        return {
            "app": app,
            "windowIndex": window_index,
            "elementCount": len(elements),
            "elements": elements,
        }

    def find(self, app: str, criteria: dict[str, Any], window_index: int = 0) -> list[dict[str, Any]]:
        if not has_selector(criteria):
            raise ToolError("At least one selector is required.")
        max_depth = as_int(criteria, "maxDepth", 12, 0, 30)
        max_results = as_int(criteria, "maxResults", 20, 1, 500)
        index = optional_int(criteria, "index")
        root = self.root_for(app, window_index)
        matches: list[Any] = []
        for item, _depth in self._walk(root, max_depth, 10_000):
            if not self._matches(item, criteria):
                continue
            matches.append(item)
            if index is None and len(matches) >= max_results:
                break
            if index is not None and len(matches) > index:
                break
        if index is not None:
            matches = [matches[index]] if 0 <= index < len(matches) else []
        result = []
        for element in matches:
            handle = self._existing_or_new(element)
            result.append(self.describe(element, handle))
        return result

    def resolve_element(self, app: str, arguments: dict[str, Any]) -> Any:
        element_id = as_string(arguments, "elementId")
        if element_id:
            stored = self._handles.get(element_id)
            if stored is not None and _alive(stored):
                return stored
            self._handles.pop(element_id, None)
        if not has_selector(arguments) and not element_id:
            raise ToolError("Provide a fresh elementId or at least one selector.")
        window_index = as_int(arguments, "windowIndex", 0, 0, 100)
        found = self.find(app, arguments, window_index)
        if not found:
            raise ToolError("Element not found.")
        found_id = found[0].get("id")
        if not isinstance(found_id, str) or found_id not in self._handles:
            raise ToolError("Element handle missing.")
        return self._handles[found_id]

    def describe(self, element: Any, handle: str | None = None) -> dict[str, Any]:
        role = ax_alias(_safe_role_name(element))
        name = _safe_name(element)
        description = _safe_description(element)
        identifier = _safe_identifier(element)
        value = self.value_of(element)
        frame = self.extents(element)
        states = self._states(element)
        return {
            "id": handle,
            "role": role,
            "title": name or None,
            "label": name or description or None,
            "identifier": identifier or None,
            "description": description or None,
            "value": value,
            "enabled": "ENABLED" in states,
            "focused": "FOCUSED" in states,
            "offscreen": "SHOWING" not in states and "VISIBLE" not in states,
            "frame": frame,
            "interfaces": _interfaces(element),
        }

    def focused(self, app: str) -> dict[str, Any]:
        from .app_service import resolve

        target = resolve(app)
        module = self.require()
        element = _call(module, "get_focus", "get_focused")
        if element is None:
            raise ToolError("No focused AT-SPI element.")
        pid = self._pid(element)
        if pid != target.pid:
            raise ToolError("The target application does not own the focused element.")
        return self.describe(element, self._existing_or_new(element))

    def read_text(self, element: Any) -> str | None:
        text_iface = _iface(element, "get_text_iface", "get_text", "queryText")
        if text_iface is not None:
            getter = getattr(text_iface, "get_text", None)
            if callable(getter):
                try:
                    text = getter(0, -1)
                    if isinstance(text, str) and text.strip():
                        return text.rstrip("\r\n")
                except Exception:
                    pass
        value = self.value_of(element)
        if isinstance(value, str) and value.strip():
            return value
        name = _safe_name(element)
        return name or None

    def read_all_text(self, app: str, window_index: int, max_elements: int) -> list[dict[str, Any]]:
        root = self.root_for(app, window_index)
        items: list[dict[str, Any]] = []
        seen: set[str] = set()
        for element, depth in self._walk(root, 20, max_elements):
            states = self._states(element)
            if "SHOWING" not in states and "VISIBLE" not in states:
                continue
            text = self.read_text(element)
            if not text or text in seen:
                continue
            seen.add(text)
            items.append({"text": text, "role": ax_alias(_safe_role_name(element)), "depth": depth})
        return items

    def invoke(self, element: Any, foreground: bool) -> str:
        method = self._do_action(element)
        if method:
            return method
        if not foreground:
            raise ToolError(
                "Control exposes no background-safe AT-SPI action. "
                "Retry with foreground:true for a coordinate click."
            )
        frame = self.extents(element)
        if frame["width"] <= 0 or frame["height"] <= 0:
            raise ToolError("Element has no clickable bounds.")
        from .input_service import click_at

        click_at(self._pid(element), frame["x"] + frame["width"] // 2, frame["y"] + frame["height"] // 2)
        return "foreground-coordinate"

    def type_text(self, element: Any, text: str, foreground: bool) -> str:
        editable = _iface(element, "get_editable_text_iface", "get_editable_text", "queryEditableText")
        if editable is not None:
            setter = getattr(editable, "set_text_contents", None)
            if callable(setter):
                try:
                    ok = setter(text)
                    if ok is not False:
                        return "atspi-editable-text"
                except Exception:
                    pass
        if not foreground:
            raise ToolError(
                "Control exposes no writable AT-SPI editable text. "
                "Retry with foreground:true for keyboard input."
            )
        from .input_service import type_at_element

        type_at_element(self._pid(element), element, text)
        return "foreground-keyboard"

    def value_of(self, element: Any) -> Any:
        value_iface = _iface(element, "get_value_iface", "get_value", "queryValue")
        if value_iface is not None:
            current = getattr(value_iface, "get_current_value", None)
            if callable(current):
                try:
                    return current()
                except Exception:
                    pass
        states = self._states(element)
        if "CHECKABLE" in states or ax_alias(_safe_role_name(element)) in {"AXCheckBox", "AXSwitch"}:
            return "CHECKED" in states
        text = None
        text_iface = _iface(element, "get_text_iface", "get_text", "queryText")
        if text_iface is not None:
            getter = getattr(text_iface, "get_text", None)
            if callable(getter):
                try:
                    text = getter(0, -1)
                except Exception:
                    text = None
        if isinstance(text, str) and text:
            return text
        return None

    def extents(self, element: Any) -> dict[str, int]:
        component = _iface(element, "get_component_iface", "get_component", "queryComponent")
        if component is None:
            return {"x": 0, "y": 0, "width": 0, "height": 0}
        getter = getattr(component, "get_extents", None)
        if not callable(getter):
            return {"x": 0, "y": 0, "width": 0, "height": 0}
        module = self.module()
        coord = 0
        if module is not None:
            coord_type = getattr(module, "CoordType", None)
            coord = getattr(coord_type, "SCREEN", 0) if coord_type is not None else 0
        try:
            rect = getter(coord)
        except Exception:
            return {"x": 0, "y": 0, "width": 0, "height": 0}
        if rect is None:
            return {"x": 0, "y": 0, "width": 0, "height": 0}
        return {
            "x": int(getattr(rect, "x", 0) or 0),
            "y": int(getattr(rect, "y", 0) or 0),
            "width": int(getattr(rect, "width", 0) or 0),
            "height": int(getattr(rect, "height", 0) or 0),
        }

    def scroll_element(self, element: Any, delta_y: float, amount: int) -> str:
        component = _iface(element, "get_component_iface", "get_component", "queryComponent")
        scroll_to = getattr(component, "scroll_to", None) if component is not None else None
        module = self.module()
        scroll_type = getattr(module, "ScrollType", None) if module is not None else None
        target = getattr(scroll_type, "ANYWHERE", None) if scroll_type is not None else None
        if callable(scroll_to) and target is not None:
            try:
                scroll_to(target)
                return "atspi-scroll-to"
            except Exception:
                pass
        actioned = self._do_named_action(element, ("scroll", "scroll down", "scroll up"))
        if actioned:
            return actioned
        # Walk ancestors for a scroll pane.
        current = element
        for _ in range(12):
            parent = _call(current, "get_parent")
            if parent is None:
                break
            if ax_alias(_safe_role_name(parent)) == "AXScrollArea":
                named = "scroll down" if delta_y >= 0 else "scroll up"
                for _step in range(amount):
                    if not self._do_named_action(parent, (named, "scroll")):
                        break
                else:
                    return "atspi-scroll-action"
                return "atspi-scroll-action"
            current = parent
        raise ToolError("No AT-SPI scroll interface on this element.")

    def find_scrollable(self, start: Any) -> Any | None:
        for element, _depth in self._walk(start, 12, 2000):
            role = ax_alias(_safe_role_name(element))
            if role == "AXScrollArea":
                return element
            interfaces = _interfaces(element)
            if any(name.lower() == "component" for name in interfaces):
                component = _iface(element, "get_component_iface", "get_component", "queryComponent")
                if component is not None and callable(getattr(component, "scroll_to", None)):
                    return element
        return None

    def root_for(self, app: str, window_index: int = 0) -> Any:
        from .app_service import resolve

        target = resolve(app)
        application = self._application(target.pid)
        return self._window_at(application, window_index)

    def wait_for(self, app: str, arguments: dict[str, Any], should_exist: bool) -> Any | None:
        timeout_ms = as_int(arguments, "timeoutMs", 5000, 0, 60000)
        deadline = time.time() + timeout_ms / 1000.0
        last = None
        while True:
            try:
                element = self.resolve_element(app, arguments)
                last = element
                if should_exist:
                    return element
            except ToolError:
                if not should_exist:
                    return None
            if time.time() >= deadline:
                return last if not should_exist else None
            time.sleep(0.1)

    def menu_items(self, app: str, window_index: int, max_depth: int, max_items: int) -> list[dict[str, Any]]:
        root = self.root_for(app, window_index)
        items: list[dict[str, Any]] = []
        for element, depth in self._walk(root, max_depth, 8000):
            role = ax_alias(_safe_role_name(element))
            if role not in {"AXMenuBar", "AXMenu", "AXMenuItem"}:
                continue
            name = _safe_name(element) or ""
            items.append(
                {
                    "role": role,
                    "title": name,
                    "path": name,
                    "depth": depth,
                    "enabled": "ENABLED" in self._states(element),
                    "offscreen": "SHOWING" not in self._states(element),
                }
            )
            if len(items) >= max_items:
                break
        return items

    def navigate_menu(self, app: str, window_index: int, path: list[str]) -> None:
        current = self.root_for(app, window_index)
        for index, label in enumerate(path):
            found = None
            for element, _depth in self._walk(current, 8, 2000):
                role = ax_alias(_safe_role_name(element))
                if role != "AXMenuItem":
                    continue
                if (_safe_name(element) or "").lower() == label.lower():
                    found = element
                    break
            if found is None:
                raise ToolError(f"Menu item not found: {label}")
            is_last = index == len(path) - 1
            method = self._do_action(found)
            if not method:
                raise ToolError(f"Menu item exposes no AT-SPI action: {label}")
            time.sleep(0.1)
            if not is_last:
                current = found

    def _application(self, pid: int) -> Any:
        desktop = self.desktop()
        try:
            count = int(desktop.get_child_count() or 0)
        except Exception as exc:
            raise ToolError(f"AT-SPI desktop cannot be enumerated: {exc}") from exc
        for index in range(count):
            try:
                child = desktop.get_child_at_index(index)
            except Exception:
                continue
            if child is not None and self._pid(child) == pid:
                return child
        raise ToolError(f"AT-SPI application not found for pid {pid}.")

    def _window_at(self, application: Any, window_index: int) -> Any:
        windows: list[Any] = []
        try:
            count = int(application.get_child_count() or 0)
        except Exception:
            count = 0
        for index in range(count):
            try:
                child = application.get_child_at_index(index)
            except Exception:
                continue
            if child is None:
                continue
            role = ax_alias(_safe_role_name(child))
            if role == "AXWindow" or _safe_role_name(child) in {"frame", "window", "dialog", "alert"}:
                windows.append(child)
        if not windows:
            for index in range(count):
                try:
                    child = application.get_child_at_index(index)
                except Exception:
                    continue
                if child is not None:
                    windows.append(child)
        if window_index < 0 or window_index >= len(windows):
            raise ToolError(f"Window {window_index} not found in the AT-SPI tree.")
        return windows[window_index]

    def _walk(self, root: Any, max_depth: int, max_elements: int) -> Iterator[tuple[Any, int]]:
        queue: deque[tuple[Any, int]] = deque([(root, 0)])
        seen = 0
        while queue and seen < max_elements:
            element, depth = queue.popleft()
            seen += 1
            yield element, depth
            if depth >= max_depth:
                continue
            try:
                count = int(element.get_child_count() or 0)
            except Exception:
                continue
            for index in range(count):
                try:
                    child = element.get_child_at_index(index)
                except Exception:
                    continue
                if child is not None:
                    queue.append((child, depth + 1))

    def _matches(self, element: Any, criteria: dict[str, Any]) -> bool:
        try:
            role = ax_alias(_safe_role_name(element))
            name = _safe_name(element) or ""
            description = _safe_description(element) or ""
            identifier = _safe_identifier(element) or ""
            value = self.value_of(element)
            value_text = "" if value is None else str(value)
            wanted_role = as_string(criteria, "role")
            if wanted_role and not roles_match(role, wanted_role):
                return False
            title = as_string(criteria, "title")
            if title is not None and name != title:
                return False
            title_contains = as_string(criteria, "titleContains")
            if title_contains and title_contains.lower() not in name.lower():
                return False
            wanted_id = as_string(criteria, "identifier")
            if wanted_id is not None and identifier != wanted_id:
                return False
            wanted_description = as_string(criteria, "description")
            if wanted_description is not None and description != wanted_description:
                return False
            description_contains = as_string(criteria, "descriptionContains")
            if description_contains and description_contains.lower() not in description.lower():
                return False
            wanted_value = as_string(criteria, "value")
            if wanted_value is not None and value_text != wanted_value:
                return False
            label = as_string(criteria, "labelContains")
            if label:
                blob = " ".join([name, description, identifier, value_text]).lower()
                if label.lower() not in blob:
                    return False
            return True
        except Exception:
            return False

    def _do_action(self, element: Any) -> str | None:
        return self._do_named_action(element, ("click", "press", "activate", "toggle"))

    def _do_named_action(self, element: Any, preferred: tuple[str, ...]) -> str | None:
        action = _iface(element, "get_action_iface", "get_action", "queryAction")
        if action is None:
            return None
        count_fn = getattr(action, "get_n_actions", None)
        try:
            count = int(count_fn()) if callable(count_fn) else 0
        except Exception:
            return None
        names: list[str] = []
        name_fn = getattr(action, "get_action_name", None) or getattr(action, "get_name", None)
        for index in range(count):
            label = ""
            if callable(name_fn):
                try:
                    label = str(name_fn(index) or "")
                except Exception:
                    label = ""
            names.append(label.lower())
        do_fn = getattr(action, "do_action", None)
        if not callable(do_fn):
            return None
        for want in preferred:
            if want in names:
                try:
                    if do_fn(names.index(want)):
                        return f"atspi-{want.replace(' ', '-')}"
                except Exception:
                    continue
        if count > 0:
            try:
                if do_fn(0):
                    label = names[0] if names else "action"
                    return f"atspi-{label.replace(' ', '-') or 'action'}"
            except Exception:
                return None
        return None

    def _pid(self, accessible: Any) -> int:
        pid = _call(accessible, "get_process_id", "get_pid", default=0)
        if isinstance(pid, int) and pid > 0:
            return pid
        application = _call(accessible, "get_application")
        if application is not None:
            pid = _call(application, "get_process_id", "get_id", default=0)
            if isinstance(pid, int) and pid > 0:
                return pid
        return 0

    def _states(self, accessible: Any) -> set[str]:
        state_set = _call(accessible, "get_state_set", "get_states")
        if state_set is None:
            return set()
        names: set[str] = set()
        getter = getattr(state_set, "get_states", None)
        if callable(getter):
            try:
                for state in getter() or []:
                    value = getattr(state, "value_name", None) or getattr(state, "value_nick", None) or str(state)
                    names.add(str(value).upper().replace("ATSPI_STATE_", "").replace("STATE_", "").replace("-", "_"))
            except Exception:
                pass
        contains = getattr(state_set, "contains", None)
        module = self.module()
        state_type = getattr(module, "StateType", None) if module is not None else None
        if callable(contains) and state_type is not None:
            for label in (
                "ENABLED",
                "FOCUSED",
                "SHOWING",
                "VISIBLE",
                "ACTIVE",
                "CHECKED",
                "CHECKABLE",
                "SELECTED",
                "EXPANDABLE",
                "EXPANDED",
            ):
                enum_value = getattr(state_type, label, None)
                if enum_value is None:
                    continue
                try:
                    if contains(enum_value):
                        names.add(label)
                except Exception:
                    continue
        return names

    def _has_state(self, accessible: Any, name: str) -> bool:
        return name in self._states(accessible)

    def _new_handle(self, element: Any) -> str:
        self._next_handle += 1
        handle = f"e{self._next_handle}"
        self._handles[handle] = element
        return handle

    def _existing_or_new(self, element: Any) -> str:
        for handle, stored in list(self._handles.items()):
            if stored is element:
                return handle
            try:
                if _same(stored, element):
                    return handle
            except Exception:
                continue
        return self._new_handle(element)


def has_selector(arguments: dict[str, Any]) -> bool:
    return any(as_string(arguments, name) for name in SELECTOR_FIELDS)


def _safe_name(accessible: Any) -> str:
    value = _call(accessible, "get_name")
    return value.strip() if isinstance(value, str) else ""


def _safe_description(accessible: Any) -> str:
    value = _call(accessible, "get_description")
    return value.strip() if isinstance(value, str) else ""


def _safe_role_name(accessible: Any) -> str:
    value = _call(accessible, "get_role_name")
    if isinstance(value, str) and value.strip():
        return value
    role = _call(accessible, "get_role")
    nick = getattr(role, "value_nick", None) or getattr(role, "value_name", None)
    if isinstance(nick, str) and nick:
        return nick.replace("-", " ").replace("_", " ")
    return str(role) if role is not None else ""


def _safe_identifier(accessible: Any) -> str:
    value = _call(accessible, "get_accessible_id", "get_id")
    if isinstance(value, str) and value.strip():
        return value.strip()
    attributes = _call(accessible, "get_attributes")
    if isinstance(attributes, dict):
        for key in ("id", "class", "class:cls", "xml-roles"):
            item = attributes.get(key)
            if isinstance(item, str) and item.strip():
                return item.strip()
    return ""


def _interfaces(accessible: Any) -> list[str]:
    value = _call(accessible, "get_interfaces")
    if not value:
        return []
    try:
        return [str(item) for item in value]
    except TypeError:
        return []


def _alive(accessible: Any) -> bool:
    try:
        accessible.get_role_name()
        return True
    except Exception:
        return False


def _same(left: Any, right: Any) -> bool:
    if left is right:
        return True
    try:
        path_fn = getattr(left, "get_path", None)
        if callable(path_fn) and callable(getattr(right, "get_path", None)):
            return path_fn() == right.get_path()
    except Exception:
        return False
    return False

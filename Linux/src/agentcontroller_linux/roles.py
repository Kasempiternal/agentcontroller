"""AT-SPI role names mapped to macOS AX aliases, plus selector matching."""

from __future__ import annotations

import re

# AT-SPI get_role_name() strings (usually lowercase words) -> AX* aliases.
ROLE_NAME_TO_AX: dict[str, str] = {
    "push button": "AXButton",
    "button": "AXButton",
    "toggle button": "AXButton",
    "entry": "AXTextField",
    "password text": "AXSecureTextField",
    "spin button": "AXIncrementor",
    "text": "AXTextArea",
    "heading": "AXStaticText",
    "label": "AXStaticText",
    "static": "AXStaticText",
    "paragraph": "AXStaticText",
    "caption": "AXStaticText",
    "check box": "AXCheckBox",
    "radio button": "AXRadioButton",
    "combo box": "AXComboBox",
    "menu": "AXMenu",
    "menu bar": "AXMenuBar",
    "menu item": "AXMenuItem",
    "check menu item": "AXMenuItem",
    "radio menu item": "AXMenuItem",
    "window": "AXWindow",
    "frame": "AXWindow",
    "dialog": "AXWindow",
    "alert": "AXWindow",
    "file chooser": "AXWindow",
    "color chooser": "AXWindow",
    "font chooser": "AXWindow",
    "scroll pane": "AXScrollArea",
    "viewport": "AXScrollArea",
    "slider": "AXSlider",
    "image": "AXImage",
    "icon": "AXImage",
    "link": "AXLink",
    "page tab": "AXTab",
    "page tab list": "AXTabGroup",
    "table": "AXTable",
    "table cell": "AXCell",
    "column header": "AXCell",
    "row header": "AXCell",
    "list": "AXList",
    "list item": "AXListItem",
    "list box": "AXList",
    "progress bar": "AXProgressIndicator",
    "tool bar": "AXToolbar",
    "separator": "AXSplitter",
    "split pane": "AXSplitGroup",
    "tree": "AXOutline",
    "tree item": "AXOutlineRow",
    "tree table": "AXOutline",
    "application": "AXApplication",
    "document frame": "AXGroup",
    "document web": "AXWebArea",
    "html container": "AXWebArea",
    "panel": "AXGroup",
    "filler": "AXGroup",
    "section": "AXGroup",
    "layered pane": "AXGroup",
    "canvas": "AXGroup",
    "grouping": "AXGroup",
    "status bar": "AXStatusBar",
    "header": "AXGroup",
    "footer": "AXGroup",
    "form": "AXGroup",
    "page": "AXGroup",
    "switch": "AXSwitch",
    "menu button": "AXMenuButton",
    "popup menu": "AXPopUpButton",
}


def _pascal_ax(role_name: str) -> str:
    parts = [part for part in re.split(r"[_\s]+", role_name.strip()) if part]
    if not parts:
        return "AXUnknown"
    return "AX" + "".join(part[:1].upper() + part[1:] for part in parts)


def ax_alias(role_name: str | None) -> str:
    """Map an AT-SPI role name (or already-AX name) to an AX* alias."""
    if not role_name:
        return "AXUnknown"
    stripped = role_name.strip()
    if stripped.startswith("AX") and len(stripped) > 2 and stripped[2].isupper():
        return stripped
    key = re.sub(r"[_\s]+", " ", stripped.lower()).strip()
    return ROLE_NAME_TO_AX.get(key, _pascal_ax(stripped))


def _token(value: str) -> str:
    text = value.strip()
    if text.lower().startswith("ax") and len(text) > 2:
        text = text[2:]
    collapsed = re.sub(r"[^a-z0-9]", "", text.lower())
    synonyms = {
        "textfield": "textfield",
        "textarea": "textfield",
        "edit": "textfield",
        "entry": "textfield",
        "passwordtext": "textfield",
        "securetextfield": "textfield",
        "statictext": "statictext",
        "label": "statictext",
        "pushbutton": "button",
        "button": "button",
        "togglebutton": "button",
        "checkbox": "checkbox",
        "radiobutton": "radiobutton",
        "combobox": "combobox",
        "popupbutton": "combobox",
        "menubutton": "menubutton",
        "window": "window",
        "frame": "window",
        "dialog": "window",
        "scrollarea": "scrollarea",
        "scrollpane": "scrollarea",
        "outline": "outline",
        "tree": "outline",
        "cell": "cell",
        "tablecell": "cell",
        "menuitem": "menuitem",
        "progressindicator": "progressindicator",
        "progressbar": "progressindicator",
        "incrementor": "incrementor",
        "spinbutton": "incrementor",
        "webarea": "webarea",
        "documentweb": "webarea",
        "tabgroup": "tabgroup",
        "pagetablist": "tabgroup",
        "tab": "tab",
        "pagetab": "tab",
        "toolbar": "toolbar",
        "toolbarrole": "toolbar",
        "listitem": "listitem",
        "outlinerow": "outlinerow",
        "treeitem": "outlinerow",
        "splitgroup": "splitgroup",
        "splitpane": "splitgroup",
        "splitter": "splitter",
        "separator": "splitter",
        "statusbar": "statusbar",
        "image": "image",
        "icon": "image",
        "link": "link",
        "slider": "slider",
        "application": "application",
        "group": "group",
        "panel": "group",
        "switch": "switch",
        "menu": "menu",
        "menubar": "menubar",
        "list": "list",
        "listbox": "list",
        "table": "table",
        "text": "statictext",
    }
    return synonyms.get(collapsed, collapsed)


def roles_match(actual_ax: str, wanted: str) -> bool:
    if not wanted:
        return True
    return _token(actual_ax) == _token(wanted)

"""Registry contract: 49 names and Swift-matching annotations."""

from __future__ import annotations

import unittest

from agentcontroller_linux.registry import DESTRUCTIVE_TOOLS, READ_ONLY_TOOLS, ToolRegistry

EXPECTED = {
    "list_apps",
    "launch_app",
    "quit_app",
    "activate_app",
    "hide_app",
    "unhide_app",
    "get_frontmost_app",
    "open_url",
    "reset_app_state",
    "snapshot",
    "describe_screen",
    "get_element_tree",
    "find_elements",
    "get_element_attributes",
    "get_focused_element",
    "wait_for_element",
    "assert_visible",
    "assert_not_visible",
    "assert_value",
    "read_text",
    "read_all_text",
    "click",
    "double_click",
    "right_click",
    "type_text",
    "send_shortcut",
    "scroll",
    "scroll_until_visible",
    "swipe",
    "drag_drop",
    "list_windows",
    "get_window_bounds",
    "set_window_bounds",
    "minimize_window",
    "restore_window",
    "screenshot_window",
    "screenshot_element",
    "screenshot_screen",
    "start_recording",
    "stop_recording",
    "navigate_menu",
    "get_menu_structure",
    "get_clipboard",
    "set_clipboard",
    "run_steps",
    "save_flow",
    "list_flows",
    "run_saved_flow",
    "check_permissions",
}


class RegistryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.registry = ToolRegistry()

    def test_forty_nine_names(self) -> None:
        names = self.registry.names()
        self.assertEqual(len(names), 49)
        self.assertEqual(names, EXPECTED)

    def test_annotations_match_swift_sets(self) -> None:
        listed = {tool["name"]: tool["annotations"] for tool in self.registry.list_tools()}
        for name, annotations in listed.items():
            self.assertEqual(annotations["openWorldHint"], False)
            self.assertEqual(annotations["destructiveHint"], name in DESTRUCTIVE_TOOLS)
            if name in READ_ONLY_TOOLS:
                self.assertTrue(annotations.get("readOnlyHint"))
            else:
                self.assertNotIn("readOnlyHint", annotations)


if __name__ == "__main__":
    unittest.main()

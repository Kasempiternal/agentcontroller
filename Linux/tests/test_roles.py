"""AT-SPI role names map onto AX aliases used by the desktop selectors."""

from __future__ import annotations

import unittest

from agentcontroller_linux.roles import ax_alias, roles_match


class RoleAliasTests(unittest.TestCase):
    def test_common_aliases(self) -> None:
        self.assertEqual(ax_alias("push button"), "AXButton")
        self.assertEqual(ax_alias("entry"), "AXTextField")
        self.assertEqual(ax_alias("password text"), "AXSecureTextField")
        self.assertEqual(ax_alias("label"), "AXStaticText")
        self.assertEqual(ax_alias("static"), "AXStaticText")
        self.assertEqual(ax_alias("check box"), "AXCheckBox")
        self.assertEqual(ax_alias("radio button"), "AXRadioButton")
        self.assertEqual(ax_alias("frame"), "AXWindow")
        self.assertEqual(ax_alias("scroll pane"), "AXScrollArea")
        self.assertEqual(ax_alias("menu item"), "AXMenuItem")
        self.assertEqual(ax_alias("page tab"), "AXTab")
        self.assertEqual(ax_alias("combo box"), "AXComboBox")

    def test_already_ax(self) -> None:
        self.assertEqual(ax_alias("AXButton"), "AXButton")

    def test_roles_match_ax_and_native(self) -> None:
        self.assertTrue(roles_match("AXButton", "AXButton"))
        self.assertTrue(roles_match("AXButton", "Button"))
        self.assertTrue(roles_match("AXButton", "push button"))
        self.assertTrue(roles_match("AXTextField", "entry"))
        self.assertTrue(roles_match("AXTextField", "Edit"))
        self.assertTrue(roles_match("AXStaticText", "StaticText"))
        self.assertTrue(roles_match("AXStaticText", "label"))
        self.assertFalse(roles_match("AXButton", "AXTextField"))


if __name__ == "__main__":
    unittest.main()

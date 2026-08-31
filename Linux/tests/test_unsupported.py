"""The three tools that cannot be honest on Linux return MCP isError."""

from __future__ import annotations

import unittest

from agentcontroller_linux.registry import ToolRegistry


class UnsupportedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.registry = ToolRegistry()

    def test_reset_app_state(self) -> None:
        result = self.registry.call("reset_app_state", {"app": "x"})
        self.assertTrue(result["isError"])
        self.assertIn(
            "reset_app_state is unsupported on Linux because Linux applications do not share one safe data-container model.",
            result["content"][0]["text"],
        )

    def test_start_recording(self) -> None:
        result = self.registry.call("start_recording", {"app": "x"})
        self.assertTrue(result["isError"])
        self.assertIn(
            "start_recording is not implemented on Linux yet; use screenshot_window for evidence.",
            result["content"][0]["text"],
        )

    def test_stop_recording(self) -> None:
        result = self.registry.call("stop_recording", {})
        self.assertTrue(result["isError"])
        self.assertIn("stop_recording is not implemented on Linux yet.", result["content"][0]["text"])


if __name__ == "__main__":
    unittest.main()

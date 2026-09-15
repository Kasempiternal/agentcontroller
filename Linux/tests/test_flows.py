"""Flows persist under AGENTCONTROLLER_FLOW_DIR (XDG override)."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

from agentcontroller_linux.registry import ToolRegistry


class FlowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        os.environ["AGENTCONTROLLER_FLOW_DIR"] = self.tmpdir.name
        self.addCleanup(os.environ.pop, "AGENTCONTROLLER_FLOW_DIR", None)
        self.registry = ToolRegistry()

    def test_save_list_run(self) -> None:
        steps = [{"tool": "check_permissions", "arguments": {}}]
        saved = self.registry.call("save_flow", {"name": "perm-check", "steps": steps})
        self.assertFalse(saved["isError"])
        payload = json.loads(saved["content"][0]["text"])
        self.assertTrue(payload["saved"])
        self.assertTrue(Path(payload["path"]).is_file())

        listed = self.registry.call("list_flows", {})
        self.assertFalse(listed["isError"])
        names = json.loads(listed["content"][0]["text"])["flows"]
        self.assertIn("perm-check", names)

        ran = self.registry.call("run_saved_flow", {"name": "perm-check"})
        self.assertFalse(ran["isError"])
        body = json.loads(ran["content"][0]["text"])
        self.assertEqual(body["passed"], 1)
        self.assertEqual(body["executed"], 1)
        self.assertFalse(body["results"][0]["isError"])

    def test_recursive_flows_rejected(self) -> None:
        result = self.registry.call(
            "run_steps",
            {"steps": [{"tool": "run_steps", "arguments": {"steps": []}}]},
        )
        self.assertTrue(result["isError"])
        self.assertIn("Recursive", result["content"][0]["text"])

    def test_missing_flow(self) -> None:
        result = self.registry.call("run_saved_flow", {"name": "no-such-flow"})
        self.assertTrue(result["isError"])
        self.assertIn("Flow not found", result["content"][0]["text"])


if __name__ == "__main__":
    unittest.main()

"""Headless protocol tests: initialize, tools/list, ping."""

from __future__ import annotations

import json
import unittest

from agentcontroller_linux.protocol import StdioMcpServer
from agentcontroller_linux.registry import ToolRegistry


class ProtocolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.server = StdioMcpServer(ToolRegistry())

    def _call(self, payload: dict) -> dict:
        raw = self.server.handle_line(json.dumps(payload))
        self.assertIsNotNone(raw)
        return json.loads(raw)

    def test_initialize(self) -> None:
        response = self._call(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"protocolVersion": "2025-06-18"},
            }
        )
        result = response["result"]
        self.assertEqual(result["protocolVersion"], "2025-06-18")
        self.assertEqual(result["serverInfo"]["name"], "agentcontroller-linux")
        self.assertEqual(result["serverInfo"]["version"], "2.5.0")
        self.assertIn("tools", result["capabilities"])

    def test_initialize_unknown_version_falls_back(self) -> None:
        response = self._call(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"protocolVersion": "nope"},
            }
        )
        self.assertEqual(response["result"]["protocolVersion"], "2025-06-18")

    def test_ping(self) -> None:
        response = self._call({"jsonrpc": "2.0", "id": 2, "method": "ping", "params": {}})
        self.assertEqual(response["result"], {})

    def test_tools_list(self) -> None:
        response = self._call({"jsonrpc": "2.0", "id": 3, "method": "tools/list", "params": {}})
        tools = response["result"]["tools"]
        self.assertEqual(len(tools), 49)
        names = [tool["name"] for tool in tools]
        self.assertEqual(names, sorted(names))

    def test_notification_has_no_response(self) -> None:
        self.assertIsNone(self.server.handle_line('{"jsonrpc":"2.0","method":"ping"}'))

    def test_unknown_method(self) -> None:
        response = self._call({"jsonrpc": "2.0", "id": 9, "method": "nope"})
        self.assertEqual(response["error"]["code"], -32601)

    def test_parse_error(self) -> None:
        raw = self.server.handle_line("{")
        self.assertIsNotNone(raw)
        response = json.loads(raw)
        self.assertEqual(response["error"]["code"], -32700)


if __name__ == "__main__":
    unittest.main()

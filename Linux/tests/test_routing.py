"""Identity classification and blender framing — no desktop session required."""

from __future__ import annotations

import json
import os
import tempfile
import unittest

from agentcontroller_linux.backends import blender as blender_backend
from agentcontroller_linux.backends.cdp import compact_elements, flatten_ax
from agentcontroller_linux.registry import ToolRegistry
from agentcontroller_linux.routing import classify, parse_identity, probe
from agentcontroller_linux.tools.flows import _compact_step_result


class IdentityTests(unittest.TestCase):
    def test_url(self) -> None:
        ident = parse_identity("https://example.com/app")
        self.assertEqual(ident.kind, "url")
        self.assertTrue(ident.is_http)

    def test_udid_and_pid(self) -> None:
        self.assertEqual(parse_identity("booted").kind, "iosSimulator")
        self.assertEqual(parse_identity("12345").kind, "processID")
        self.assertEqual(parse_identity("com.apple.TextEdit").kind, "application")

    def test_classify(self) -> None:
        self.assertEqual(classify(parse_identity("https://x.test")).backend, "cdp")
        self.assertEqual(classify(parse_identity("org.blenderfoundation.blender")).backend, "bpy-lab")
        self.assertEqual(classify(parse_identity("chrome")).backend, "cdp")
        self.assertEqual(classify(parse_identity("firefox")).backend, "ax")
        self.assertEqual(classify(parse_identity("gedit")).backend, "ax")


class BlenderFramingTests(unittest.TestCase):
    def test_lab_roundtrip(self) -> None:
        encoded = blender_backend.encode_lab("result={'ok': True}")
        self.assertTrue(encoded.endswith(b"\0"))
        decoded = blender_backend.decode_lab(encoded)
        self.assertEqual(decoded["type"], "execute")
        self.assertTrue(blender_backend.is_lab_success({"status": "ok", "result": {"ok": True}}))


class CDPFlattenTests(unittest.TestCase):
    def test_interactive_only(self) -> None:
        nodes = [
            {
                "ignored": False,
                "role": {"value": "button"},
                "name": {"value": "Save"},
                "backendDOMNodeId": 42,
            },
            {
                "ignored": False,
                "role": {"value": "generic"},
                "name": {"value": "layout"},
                "backendDOMNodeId": 7,
            },
        ]
        refs = flatten_ax(nodes, interactive_only=True, session_key="https://x")
        self.assertEqual(len(refs), 1)
        self.assertEqual(refs[0]["backendNodeId"], 42)
        elements = compact_elements(["e1"], refs)
        self.assertEqual(elements[0]["label"], "Save")


class ProbeAndToolsTests(unittest.TestCase):
    def test_inspect_text_app(self) -> None:
        registry = ToolRegistry()
        result = registry.call("inspect_capabilities", {"target": "gedit"})
        self.assertFalse(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["backend"], "ax")

    def test_inspect_url_without_chrome_is_honest(self) -> None:
        os.environ["AGENTCONTROLLER_CHROME"] = "/no/such/chrome"
        self.addCleanup(os.environ.pop, "AGENTCONTROLLER_CHROME", None)
        record = probe(parse_identity("https://example.invalid"))
        self.assertEqual(record.ask, "missing-addon")
        registry = ToolRegistry()
        result = registry.call("snapshot", {"app": "https://example.invalid"})
        self.assertTrue(result["isError"])

    def test_inspect_blender_without_socket_falls_to_ax(self) -> None:
        record = probe(parse_identity("org.blenderfoundation.blender"))
        self.assertEqual(record.backend, "ax")
        self.assertEqual(record.ask, "missing-addon")
        registry = ToolRegistry()
        result = registry.call("inspect_capabilities", {"target": "Blender"})
        self.assertFalse(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["backend"], "ax")

    def test_run_app_code_native_errors(self) -> None:
        registry = ToolRegistry()
        result = registry.call("run_app_code", {"app": "gedit", "code": "print(1)", "consent": True})
        self.assertTrue(result["isError"])
        self.assertIn("No in-process backend", result["content"][0]["text"])

    def test_consent_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "consent.json")
            os.environ["AGENTCONTROLLER_CONSENT_PATH"] = path
            self.addCleanup(os.environ.pop, "AGENTCONTROLLER_CONSENT_PATH", None)
            from agentcontroller_linux.routing import code_exec_granted, grant_code_exec

            self.assertFalse(code_exec_granted("bpy"))
            grant_code_exec("bpy")
            self.assertTrue(code_exec_granted("bpy"))


class CompactStepsTests(unittest.TestCase):
    def test_omits_images(self) -> None:
        result = {
            "content": [{"type": "image", "data": "aGVsbG8=", "mimeType": "image/jpeg"}],
            "isError": False,
        }
        compact = _compact_step_result(result, False)
        self.assertTrue(compact["nestedMediaOmitted"])
        self.assertNotIn("aGVsbG8=", compact["content"][0]["text"])


if __name__ == "__main__":
    unittest.main()

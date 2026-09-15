"""compileall the Linux package as a headless unittest."""

from __future__ import annotations

import compileall
import unittest
from pathlib import Path


class CompileTests(unittest.TestCase):
    def test_src_compiles(self) -> None:
        src = Path(__file__).resolve().parents[1] / "src"
        self.assertTrue(compileall.compile_dir(str(src), quiet=1))


if __name__ == "__main__":
    unittest.main()

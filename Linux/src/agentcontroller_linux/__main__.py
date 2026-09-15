"""Console entry: python3 -m agentcontroller_linux and agentcontroller-linux."""

from __future__ import annotations

import sys

from .protocol import StdioMcpServer
from .registry import ToolRegistry


def main() -> int:
    try:
        if hasattr(sys.stdin, "reconfigure"):
            sys.stdin.reconfigure(encoding="utf-8")
        if hasattr(sys.stdout, "reconfigure"):
            sys.stdout.reconfigure(encoding="utf-8")
        if hasattr(sys.stderr, "reconfigure"):
            sys.stderr.reconfigure(encoding="utf-8")
        StdioMcpServer(ToolRegistry()).run()
        return 0
    except Exception as exc:
        print(f"agentcontroller-linux fatal: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

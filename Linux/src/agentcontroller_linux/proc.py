"""Child-process helpers. Always argv lists, never a shell string."""

from __future__ import annotations

import shutil
import subprocess
from typing import Sequence


def which(*names: str) -> str | None:
    for name in names:
        found = shutil.which(name)
        if found:
            return found
    return None


def run_argv(
    argv: Sequence[str],
    *,
    timeout: float = 20,
    stdin_bytes: bytes | None = None,
    check: bool = False,
) -> subprocess.CompletedProcess[bytes]:
    completed = subprocess.run(
        list(argv),
        check=False,
        capture_output=True,
        timeout=timeout,
        input=stdin_bytes,
    )
    if check and completed.returncode != 0:
        stderr = completed.stderr.decode("utf-8", "replace").strip()
        stdout = completed.stdout.decode("utf-8", "replace").strip()
        detail = stderr or stdout or f"exit {completed.returncode}"
        raise RuntimeError(f"{argv[0]} failed: {detail}")
    return completed


def decode_out(completed: subprocess.CompletedProcess[bytes]) -> str:
    return completed.stdout.decode("utf-8", "replace")

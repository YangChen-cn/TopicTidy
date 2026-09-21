from __future__ import annotations

import plistlib
import re
import subprocess
from pathlib import Path


def source_urls(path: Path) -> list[str]:
    try:
        raw = subprocess.run(
            ["xattr", "-p", "com.apple.metadata:kMDItemWhereFroms", str(path)],
            check=True, capture_output=True, timeout=3,
        ).stdout
        value = plistlib.loads(raw)
        if isinstance(value, list):
            return [str(item) for item in value if str(item).startswith(("http://", "https://"))]
    except (subprocess.SubprocessError, OSError, plistlib.InvalidFileException):
        pass
    try:
        result = subprocess.run(
            ["mdls", "-raw", "-name", "kMDItemWhereFroms", str(path)],
            check=True, capture_output=True, text=True, timeout=3,
        ).stdout
        return re.findall(r'"(https?://[^"\\]+)', result)
    except (subprocess.SubprocessError, OSError):
        return []


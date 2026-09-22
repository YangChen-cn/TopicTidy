#!/usr/bin/env python3
"""Conservatively remove build/install tooling from the embedded GUI runtime."""
from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path


CLI_ONLY_PACKAGES = (
    "click",
    "markdown_it",
    "mdurl",
    "pygments",
    "rich",
    "shellingham",
    "typer",
    "watchdog",
    "_watchdog_fsevents",
)


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    elif path.is_dir():
        shutil.rmtree(path)


def tree_bytes(root: Path) -> int:
    return sum(path.stat().st_size for path in root.rglob("*") if path.is_file() and not path.is_symlink())


def prune(runtime: Path) -> dict[str, int]:
    runtime = runtime.resolve()
    python = runtime / "bin/python3"
    stdlib = runtime / "lib/python3.12"
    site_packages = stdlib / "site-packages"
    if runtime.name != "python" or not python.exists() or not site_packages.is_dir():
        raise ValueError(f"拒绝裁剪非 TopicTidy Python runtime：{runtime}")

    before = tree_bytes(runtime)
    for relative in (
        "include",
        "share",
        "lib/pkgconfig",
        "lib/python3.12/config-3.12-darwin",
        "lib/python3.12/ensurepip",
        "lib/python3.12/idlelib",
        "lib/python3.12/lib2to3",
        "lib/python3.12/pydoc_data",
        "lib/python3.12/tkinter",
        "lib/python3.12/turtledemo",
        "lib/python3.12/unittest",
        "lib/python3.12/__phello__",
        "lib/tk9.0",
        "lib/tcl9.0",
        "lib/tcl9",
        "lib/thread3.0.6",
        "lib/itcl4.3.8",
        "lib/libtcl9.0.dylib",
        "lib/libtcl9tk9.0.dylib",
    ):
        remove_path(runtime / relative)

    for path in tuple((runtime / "bin").iterdir()):
        if "config" in path.name or not path.name.startswith("python"):
            remove_path(path)

    for pattern in ("_tkinter*.so",):
        for path in stdlib.glob(f"lib-dynload/{pattern}"):
            remove_path(path)

    for package in CLI_ONLY_PACKAGES:
        for path in site_packages.glob(f"{package}*"):
            remove_path(path)
    for package in ("pip", "setuptools", "pkg_resources", "_distutils_hack"):
        for path in site_packages.glob(f"{package}*"):
            remove_path(path)

    for path in sorted(runtime.rglob("*"), key=lambda item: len(item.parts), reverse=True):
        if path.is_dir() and path.name in {"__pycache__", "tests", "test"}:
            remove_path(path)
        elif path.is_file() and path.suffix in {".pyc", ".pyo"}:
            remove_path(path)
        elif path.is_file() and path.name in {"RECORD", "INSTALLER", "REQUESTED", "direct_url.json"}:
            remove_path(path)
    after = tree_bytes(runtime)
    return {"before_bytes": before, "after_bytes": after, "saved_bytes": before - after}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    result = prune(parser.parse_args().runtime)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()

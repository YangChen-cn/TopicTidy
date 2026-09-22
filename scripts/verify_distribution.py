#!/usr/bin/env python3
"""Validate the CLI wheel metadata and install it into a clean environment."""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


def metadata_file(archive: zipfile.ZipFile, filename: str) -> str:
    matches = [name for name in archive.namelist() if name.endswith(f".dist-info/{filename}")]
    if len(matches) != 1:
        raise RuntimeError(f"wheel 中找不到唯一的 {filename}")
    return archive.read(matches[0]).decode("utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("wheel", type=Path)
    parser.add_argument("--python", type=Path, default=Path(sys.executable),
                        help="Python 3.12+ interpreter used to create the clean environment")
    args = parser.parse_args()
    wheel = args.wheel.resolve()
    with zipfile.ZipFile(wheel) as archive:
        entry_points = metadata_file(archive, "entry_points.txt")
        metadata = metadata_file(archive, "METADATA")
    for command in ("tt", "downloads-organizer"):
        if f"{command} = downloads_organizer.cli:app" not in entry_points:
            raise RuntimeError(f"wheel 缺少 {command} entry point")
    for dependency in ("typer", "rich", "watchdog"):
        matching = [line for line in metadata.splitlines()
                    if line.lower().startswith(f"requires-dist: {dependency}")]
        if not matching or not any("extra == 'cli'" in line or 'extra == "cli"' in line for line in matching):
            raise RuntimeError(f"{dependency} 缺少 cli extra")
        if any("extra ==" not in line for line in matching):
            raise RuntimeError(f"{dependency} 不得成为 Core 的无条件依赖")

    with tempfile.TemporaryDirectory(prefix="topictidy-wheel-") as directory:
        environment = Path(directory)
        subprocess.run([str(args.python), "-m", "venv", str(environment)], check=True)
        python = environment / "bin/python"
        subprocess.run(
            [str(python), "-m", "pip", "install", f"{wheel}[cli]"],
            check=True,
            env={**os.environ, "ARCHFLAGS": "-arch arm64"},
            stdout=subprocess.DEVNULL,
        )
        for command in ("tt", "downloads-organizer"):
            result = subprocess.run(
                [str(environment / f"bin/{command}"), "--help"],
                check=True,
                capture_output=True,
                text=True,
            )
            if "Downloads" not in result.stdout:
                raise RuntimeError(f"{command} --help 输出异常")
    print(f"PASS: {wheel.name}; entry points + clean install + CLI help")


if __name__ == "__main__":
    main()

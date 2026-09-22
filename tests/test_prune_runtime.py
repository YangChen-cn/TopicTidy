from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest


SCRIPT = Path(__file__).parents[1] / "macos/scripts/prune_runtime.py"
SPEC = importlib.util.spec_from_file_location("prune_runtime", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def test_prune_runtime_removes_tooling_and_keeps_core_packages(tmp_path):
    runtime = tmp_path / "python"
    site_packages = runtime / "lib/python3.12/site-packages"
    (runtime / "bin").mkdir(parents=True)
    (runtime / "bin/python3").write_text("python")
    (runtime / "bin/python3-config").write_text("config")
    (runtime / "include").mkdir()
    for name in ("pip", "typer", "rich", "watchdog", "docx", "pypdf"):
        package = site_packages / name
        package.mkdir(parents=True)
        (package / "__init__.py").write_text(name)
    tests = site_packages / "docx/tests"
    tests.mkdir()
    (tests / "test_sample.py").write_text("assert True")
    cache = site_packages / "docx/__pycache__"
    cache.mkdir()
    (cache / "module.pyc").write_bytes(b"cache")
    metadata = site_packages / "python_docx-1.2.0.dist-info"
    metadata.mkdir()
    (metadata / "METADATA").write_text("Name: python-docx")
    (metadata / "RECORD").write_text("unused")
    licenses = metadata / "licenses"
    licenses.mkdir()
    (licenses / "LICENSE").write_text("license terms")

    result = MODULE.prune(runtime)

    assert result["after_bytes"] < result["before_bytes"]
    assert (site_packages / "docx/__init__.py").is_file()
    assert (site_packages / "pypdf/__init__.py").is_file()
    assert (metadata / "METADATA").is_file()
    assert (licenses / "LICENSE").is_file()
    assert not (metadata / "RECORD").exists()
    assert not (runtime / "include").exists()
    assert not (site_packages / "pip").exists()
    assert not (site_packages / "typer").exists()
    assert not tests.exists()
    assert not cache.exists()


def test_prune_runtime_rejects_unexpected_directory(tmp_path):
    with pytest.raises(ValueError, match="拒绝裁剪"):
        MODULE.prune(tmp_path)

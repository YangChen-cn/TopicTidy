from __future__ import annotations

import json

from typer.testing import CliRunner

from downloads_organizer.cli import app

from conftest import put


def test_propose_json_keeps_topic_identity_and_structured_evidence(tmp_path, monkeypatch):
    downloads = tmp_path / "Downloads"
    downloads.mkdir()
    put(downloads, "ELEC6008 Lecture 1.md", "power electronics converters")
    put(downloads, "ELEC6008 Lecture 2.md", "power electronics inverters")
    monkeypatch.setenv("DOWNLOADS_ORGANIZER_DOWNLOADS", str(downloads))
    monkeypatch.setenv("DOWNLOADS_ORGANIZER_HOME", str(tmp_path / "state"))
    runner = CliRunner()

    assert runner.invoke(app, ["scan"]).exit_code == 0
    result = runner.invoke(app, ["propose", "--json", "--no-semantic"])

    assert result.exit_code == 0
    payload = json.loads(result.stdout)
    assert payload["groups"][0]["topic_id"] == "course:ELEC6008"
    evidence = {item["kind"]: item for item in payload["groups"][0]["evidence"]}
    assert "semantic_similarity" in evidence
    assert "semantic_cross_language" in evidence
    assert payload["translation_backend_used"] is None


def test_config_commands_expose_machine_readable_preferences(tmp_path, monkeypatch):
    downloads = tmp_path / "Downloads"
    downloads.mkdir()
    state = tmp_path / "state"
    destination = tmp_path / "Organized Elsewhere"
    monkeypatch.setenv("DOWNLOADS_ORGANIZER_DOWNLOADS", str(downloads))
    monkeypatch.setenv("DOWNLOADS_ORGANIZER_HOME", str(state))
    runner = CliRunner()

    assert runner.invoke(app, ["config", "destination", str(destination)]).exit_code == 0
    assert runner.invoke(
        app, ["config", "auto-confirm", "--enable", "--threshold", "0.94"]
    ).exit_code == 0
    result = runner.invoke(app, ["config", "show", "--json"])

    assert result.exit_code == 0
    payload = json.loads(result.stdout)
    assert payload == {
        "destination": str(destination.resolve()),
        "auto_confirm_enabled": True,
        "auto_confirm_threshold": 0.94,
    }

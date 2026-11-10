"""Routing regression tests: registry-first, explicit region, no remote SQL."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from analysis import db


ROOT = Path(__file__).resolve().parents[1]


def _projects() -> list[dict]:
    return json.loads((ROOT / "games.json").read_text(encoding="utf-8"))["games"]


def test_every_registered_project_has_an_explicit_route_or_file_boundary():
    """Every registry row is either cloud-routable or explicitly local-only."""
    for project in _projects():
        key = project["key"]
        route = db._external_route("SELECT 1", project_key=key)
        if project.get("source_type") == "local_backup":
            assert route[0] == "local_backup"
            assert project.get("region")
        else:
            assert route == (
                project["client_engine"],
                project["client_region"],
            ), key


def test_mock_routing_never_executes_remote_sql(monkeypatch):
    calls: list[tuple[str, str, str]] = []

    def fake_fetch(sql: str, *, engine: str, region: str):
        calls.append((sql, engine, region))
        import pandas as pd

        return pd.DataFrame({"ok": [1]})

    monkeypatch.setattr("integrations.fivecross_client.fetch", fake_fetch)
    cloud_projects = [p for p in _projects() if p.get("source_type") != "local_backup"]
    for project in cloud_projects:
        db.run_raw_sql(None, "SELECT 1", project_key=project["key"])

    assert len(calls) == len(cloud_projects)
    assert {(engine, region) for _, engine, region in calls} == {
        (p["client_engine"], p["client_region"]) for p in cloud_projects
    }


def test_event19_requires_project_and_keeps_registered_project_context():
    sql = 'SELECT "#account_id" FROM ta.v_event_19'
    with pytest.raises(ValueError, match="显式传入 project_key"):
        db._external_route(sql)

    assert db._external_route(sql, project_key="saint_seiya_tw") == ("ta", "global")
    assert db._external_route(sql, project_key="saint_seiya_sea") == ("ta", "global")
    assert db._external_route(sql, project_key="three_kingdoms") == ("ta", "global")
    assert db._external_route(sql, project_key="captain_tsubasa") == ("ta", "global")


def test_unknown_sql_and_unknown_project_fail_closed():
    with pytest.raises(ValueError, match="显式传入 project_key"):
        db._external_route("SELECT arbitrary_column FROM arbitrary_table")
    with pytest.raises(ValueError, match="未知项目"):
        db._external_route("SELECT 1", project_key="pf_not_registered")


def test_local_backup_cannot_be_sent_to_cloud_client(monkeypatch):
    def forbidden(*_args, **_kwargs):
        raise AssertionError("local backup reached cloud fetch")

    monkeypatch.setattr("integrations.fivecross_client.fetch", forbidden)
    with pytest.raises(RuntimeError, match="本地备份.*不可.*云端"):
        db.run_raw_sql(None, "SELECT 1", project_key="saint_seiya_tw_backup")

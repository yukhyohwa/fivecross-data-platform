from pathlib import Path

import pytest


def test_settings_uses_platform_root_env_only():
    from backend.ide_app.core.settings import Settings

    env_file = str(Settings.model_config["env_file"]).replace("\\", "/")
    assert env_file.endswith("/fivecross-data-platform/.env")
    assert "/sql-ide/" not in env_file
    assert not {"MYSQL_MAIN_PASSWORD", "STARROCKS_PASSWORD"}.intersection(Settings.model_fields)


def test_legacy_schema_rebuild_is_fail_closed():
    from backend.services import table_schema_gen

    with pytest.raises(RuntimeError, match="disabled"):
        table_schema_gen.rebuild_table_schema()


def test_schema_loader_rejects_legacy_json(tmp_path, monkeypatch):
    from backend.services import table_schema

    path = tmp_path / "table_schema.json"
    path.write_text('{"source": "joytools", "tables": [{"name": "pf_bad"}]}', encoding="utf-8")
    monkeypatch.setattr(table_schema, "_SCHEMA_JSON", path)
    table_schema.invalidate()
    assert table_schema.query_tables("pf_bad") == []


def test_bootstrap_content_gate_allows_authoritative_prefixes_and_rejects_legacy(tmp_path):
    from scripts import bootstrap_fivecross_sources as bootstrap

    good = tmp_path / "pf_dwd_metric.sql"
    good.write_text("SELECT dwd_user_id FROM pf_game.dwd_metric", encoding="utf-8")
    bad = tmp_path / "old.sql"
    bad.write_text("SELECT * FROM joydata_wh.some_table", encoding="utf-8")
    assert bootstrap._reason(good) is None
    assert bootstrap._reason(bad).startswith("rejected marker: joydata")

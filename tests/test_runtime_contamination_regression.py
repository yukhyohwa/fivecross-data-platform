"""Runtime guardrails: no legacy company schema is embedded in active prompts."""
from pathlib import Path

from analysis.sql_explain import explain_sql
from analysis.sql_gen import build_messages
from analysis.sql_rewriter import build_rewrite_messages
from backend.services.agent_deep import build_agent_system_prompt
from backend.services import games

ROOT = Path(__file__).resolve().parents[1]

def test_sql_prompts_require_authoritative_schema():
    generated = build_messages("ta.v_event_19: paidamount, currencycode", "统计收入")
    rewritten = build_rewrite_messages("SELECT paidamount FROM ta.v_event_19", [], None, "paidamount DOUBLE")
    text = "\\n".join(m["content"] for m in generated + rewritten)
    assert "price_cny_from_api" not in text
    assert "price_usd_from_api" not in text
    assert "当前项目真实表结构" in text or "当前项目提供的真实表结构" in text

def test_sql_explainer_does_not_assume_amount_column():
    text = explain_sql("SELECT SUM(paidamount) AS revenue FROM ta.v_event_19 GROUP BY currencycode")
    assert "paidamount" in text
    assert "price_cny_from_api" not in text

def test_source_hint_preserves_local_backup_boundary():
    game = next(g for g in games.get_games() if g.get("source_type") == "local_backup")
    hint = games.active_view_tz_hint(game["db"])
    assert "本地备份" in hint
    assert "pf_" not in hint

def test_archived_manifest_and_pure_assets_exist():
    archive = ROOT.parent / "backup" / "fivecross-data-platform-legacy-knowledge" / "runtime-field-contamination"
    manifest = archive / "MANIFEST.json"
    assert manifest.exists()
    assert (archive / "analysis" / "currency.py").exists()
    assert (archive / "code" / "ltv.sql").exists()

"""Regression boundary: external web search removed; local retrieval and LLM retained."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def test_search_service_and_dependencies_removed():
    assert not (ROOT / "backend/services/web_search.py").exists()
    forbidden = re.compile(r"\b(?:web_search|search_web|search_analysis_methods)\b")
    hits = []
    for path in (ROOT / "backend").rglob("*.py"):
        if forbidden.search(path.read_text(encoding="utf-8-sig")):
            hits.append(str(path.relative_to(ROOT)))
    assert hits == [], hits


def test_no_search_ui_or_routes():
    for folder, pattern in (("frontend", "*.js"), ("backend/routers", "*.py")):
        for path in (ROOT / folder).rglob(pattern):
            text = path.read_text(encoding="utf-8-sig")
            assert not re.search(r"search_web|/search-usage|联网(?:搜索|检索|搜)", text), str(path)


def test_search_configuration_removed():
    keys = {"SEARCH_API_KEY", "TAVILY_API_KEY", "SERPER_API_KEY", "BING_SEARCH_API_KEY",
            "SEARCH_API_URL", "SEARCH_CACHE_TTL", "SEARCH_CACHE_MAX", "SEARCH_PROVIDERS"}
    for name in (".env", ".env.example"):
        path = ROOT / name
        if path.exists():
            configured = set(re.findall(r"^\s*(?:export\s+)?([A-Z_]+)\s*=", path.read_text(encoding="utf-8-sig"), re.M))
            assert not (configured & keys), sorted(configured & keys)


def test_llm_usage_and_local_retrieval_retained():
    tools = (ROOT / "backend/services/agent_tools.py").read_text(encoding="utf-8-sig")
    assert "search_knowledge" in tools
    assert "query_database" in tools
    assert (ROOT / "backend/services/llm.py").exists()
    assert (ROOT / "backend/services/usage.py").exists()
    ui = (ROOT / "frontend/app.js").read_text(encoding="utf-8-sig")
    assert "renderUsageStats" in ui
    assert "sessionUsage.tokens" in ui and "sessionUsage.cost.toFixed(4)" in ui


def test_catalog_and_runtime_routes(app_env, monkeypatch):
    from backend.services import agent_tools, tool_catalog
    from backend.main import app
    monkeypatch.setattr(tool_catalog.ide_bridge.db_service, "get_tool_metas", lambda: {})
    assert "search_web" not in {item["name"] for item in tool_catalog.build_catalog()}
    assert "search_web" not in agent_tools._HANDLERS
    assert all("search-usage" not in route.path and "web-search" not in route.path for route in app.routes)

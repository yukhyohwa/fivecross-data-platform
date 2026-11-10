# -*- coding: utf-8 -*-
"""convert_sql_to_flexsql agent 工具回归（不连外部库）：
挂载 / 短模板内联 / 序列化边界（JSON 转义膨胀不得越界截断）/ 长模板文件交付（防 4000 字符
回喂截断）/ 失败传播 / deliver_text 落盘保真 / 下载端点 .sql 扩展名白名单 + 无头请求隔离 /
统一目录保留 MCP 侧独立执行面的同名行。
"""
import pytest

import backend.services.agent_tools as at
import backend.services.export_artifacts as ea


class _FakeFlexsql:
    def __init__(self, out=None, err=None):
        self._out = out
        self._err = err
        self.calls = []

    def to_flexsql(self, sql, user=None, model=None):
        self.calls.append({"sql": sql, "user": user, "model": model})
        if self._err:
            raise self._err
        return self._out


def _ctx(user=None):
    return {"game": {"key": "rooc", "db": "pf_rooc"}, "engine": None, "user": user}


# ---- 挂载 ----

def test_mounted():
    names = [t["function"]["name"] for t in at.TOOL_SCHEMAS]
    assert "convert_sql_to_flexsql" in names
    assert at._HANDLERS["convert_sql_to_flexsql"] is at.convert_sql_to_flexsql


# ---- 短模板：内联，不走文件 ----

def test_short_template_inline(monkeypatch):
    fake = _FakeFlexsql(out="SELECT 1")
    monkeypatch.setattr(at, "_flexsql", fake)
    captured = {}
    monkeypatch.setattr(at, "deliver_text", lambda *a, **k: captured.update(a=a, k=k))
    r = at.convert_sql_to_flexsql(_ctx({"id": "u1"}), sql="SELECT 1")
    assert r == {"template": "SELECT 1", "chars": 8}
    assert not captured  # 短模板不落文件
    assert fake.calls[0]["user"] == {"id": "u1"}  # per-user Key 路由透传
    assert fake.calls[0]["model"] is None


def test_short_template_model_passthrough(monkeypatch):
    fake = _FakeFlexsql(out="t")
    monkeypatch.setattr(at, "_flexsql", fake)
    at.convert_sql_to_flexsql(_ctx(), sql="SELECT 1", model="deepseek-v4-pro")
    assert fake.calls[0]["model"] == "deepseek-v4-pro"


# ---- 内联阈值：按实际序列化大小判定（对抗审查发现 1：JSON 转义膨胀可越界拦腰截断）----

def _serialized(template):
    """与 tool_result_to_str 回喂完全一致的序列化（dispatch_tool 补 ok=True，ensure_ascii=False）。"""
    import json
    return json.dumps({"template": template, "chars": len(template), "ok": True}, ensure_ascii=False)


def test_dense_template_inline_stays_under_budget(monkeypatch):
    # 高转义密度但序列化后仍放得下 → 内联，且回喂序列化必须 < 4000（不会被硬截断）
    tpl = '"' * 1300 + "x" * 1300  # 原始 2600（≤ 旧阈值 3000），转义后 ~3942
    monkeypatch.setattr(at, "_flexsql", _FakeFlexsql(out=tpl))
    r = at.convert_sql_to_flexsql(_ctx({"id": "u1"}), sql="SELECT 1")
    assert "template" in r and r["template"] == tpl
    assert len(_serialized(tpl)) < 4000


def test_dense_template_over_budget_goes_to_file(monkeypatch):
    # 原始长度低于旧阈值、但转义后越界 → 必须走文件（旧逻辑会内联后被拦腰截断且无读回路径）
    tpl = '"' * 2600  # 原始 2600，序列化 ~5242 > 4000
    monkeypatch.setattr(at, "_flexsql", _FakeFlexsql(out=tpl))
    delivered = {}
    monkeypatch.setattr(
        at, "deliver_text",
        lambda *a, **k: delivered.update(text=a[0])
        or {"empty": False, "file_name": "f.sql", "download_url": "/dl", "chars": len(a[0])})
    r = at.convert_sql_to_flexsql(_ctx({"id": "u1"}), sql="SELECT 1")
    assert "template" not in r  # 全文不回喂模型
    assert delivered["text"] == tpl  # 文件整份保真
    assert r["download_url"] == "/dl"


# ---- 长模板：文件交付，全文保真 ----

def test_long_template_file_delivery(monkeypatch):
    long_sql = "SELECT " + "x, " * 3000  # 序列化远超 4000 回喂预算 → 走文件
    fake = _FakeFlexsql(out=long_sql)
    monkeypatch.setattr(at, "_flexsql", fake)
    delivered = {}

    def fake_deliver(text, subject="", owner_key="anonymous", fmt="sql"):
        delivered["text"] = text
        delivered["subject"] = subject
        delivered["owner"] = owner_key
        return {"empty": False, "file_name": "flexsql报表模板_20261017.sql",
                "download_url": "/api/agent/artifacts/abc123/download", "artifact_id": "abc123",
                "chars": len(text), "format": fmt}

    monkeypatch.setattr(at, "deliver_text", fake_deliver)
    r = at.convert_sql_to_flexsql(_ctx({"id": "u7"}), sql="SELECT 1")
    assert r["file_name"].endswith(".sql")
    assert r["download_url"] == "/api/agent/artifacts/abc123/download"
    assert r["chars"] == len(long_sql)
    assert r["head"] == long_sql[:800]
    # note 是数据不是指令（审计 P1-19：工具结果里的指令模型会忽略，引导语在工具描述里）
    assert "完整内容已原样存为 .sql 文件" in r["note"]
    assert "请你" not in r["note"] and "请引导" not in r["note"]
    assert delivered["text"] == long_sql  # 完整原文进文件，无任何截断
    assert delivered["owner"] == "u7"
    assert "template" not in r  # 全文不回喂模型


# ---- 失败传播 ----

def test_failure_propagates(monkeypatch):
    from backend.services.llm import LLMNotConfigured
    monkeypatch.setattr(at, "_flexsql", _FakeFlexsql(err=LLMNotConfigured("未配置个人 Key")))
    with pytest.raises(LLMNotConfigured):
        at.convert_sql_to_flexsql(_ctx(), sql="SELECT 1")
    monkeypatch.setattr(at, "_flexsql", _FakeFlexsql(err=ValueError("flexSQL 转换结果未通过校验：x")))
    with pytest.raises(ValueError, match="未通过校验"):
        at.convert_sql_to_flexsql(_ctx(), sql="SELECT 1")


# ---- dispatch_tool 集成（ok 强制 / 异常转 ok=False）----

def test_dispatch_ok_forced(monkeypatch):
    monkeypatch.setattr(at, "_flexsql", _FakeFlexsql(out="tpl"))
    r = at.dispatch_tool("convert_sql_to_flexsql", {"sql": "SELECT 1"}, _ctx())
    assert r["ok"] is True and r["template"] == "tpl"


def test_dispatch_failure_ok_false(monkeypatch):
    monkeypatch.setattr(at, "_flexsql", _FakeFlexsql(err=ValueError("坏")))
    r = at.dispatch_tool("convert_sql_to_flexsql", {"sql": "SELECT 1"}, _ctx())
    assert r == {"ok": False, "error": "坏"}


# ---- deliver_text 落盘（文件系统级，临时目录）----

def test_deliver_text_writes_full_content(tmp_path, monkeypatch):
    monkeypatch.setattr(ea, "EXPORT_ROOT", tmp_path)
    text = "WITH a AS (SELECT 1)\nSELECT * FROM a\n" * 100
    r = ea.deliver_text(text, subject="测试模板", owner_key="u9")
    assert r["empty"] is False
    # deliver_text 对尾部空白做 rstrip（模板尾随换行无意义），文件内容与 rstrip 后一致
    assert r["chars"] == len(text.rstrip())
    path = tmp_path / "u9" / (r["artifact_id"] + ".sql")
    assert path.read_text(encoding="utf-8") == text.rstrip()
    assert (tmp_path / "u9" / (r["artifact_id"] + ".meta.json")).is_file()


def test_deliver_text_empty_and_bad_fmt(tmp_path, monkeypatch):
    monkeypatch.setattr(ea, "EXPORT_ROOT", tmp_path)
    assert ea.deliver_text("   ", owner_key="u") == {
        "empty": True, "file_name": "", "download_url": "", "chars": 0, "format": "sql"}
    with pytest.raises(ValueError, match="格式"):
        ea.deliver_text("x", owner_key="u", fmt="pdf")


# ---- 下载端点：.sql 进扩展名白名单、同用户可取 ----

def test_download_sql_artifact(client, seeded, tmp_path, monkeypatch):
    import backend.routers.agent as agent_router

    # 路由与交付层必须落在同一 EXPORT_ROOT，否则一个写一个找
    monkeypatch.setattr(agent_router, "EXPORT_ROOT", tmp_path)
    monkeypatch.setattr(ea, "EXPORT_ROOT", tmp_path)
    text = "SELECT [st] FROM t"
    art = ea.deliver_text(text, subject="flexsql报表模板", owner_key=seeded["admin"]["id"])
    token = client.post("/api/auth/login",
                        json={"username": "admin", "password": "admin123"}).json()["access_token"]
    r = client.get(art["download_url"], headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    assert r.content.decode("utf-8") == text
    assert r.headers["content-type"].startswith("text/plain")
    # 原文件名（中文 subject）从 meta.json 取回
    assert "flexsql" in r.headers.get("content-disposition", "")


def test_download_sql_artifact_cross_user_404(client, seeded, tmp_path, monkeypatch):
    import backend.routers.agent as agent_router

    monkeypatch.setattr(agent_router, "EXPORT_ROOT", tmp_path)
    monkeypatch.setattr(ea, "EXPORT_ROOT", tmp_path)
    art = ea.deliver_text("SELECT 1", subject="模板", owner_key=seeded["admin"]["id"])
    token = client.post("/api/auth/login",
                        json={"username": "alice", "password": "alice123"}).json()["access_token"]
    r = client.get(art["download_url"], headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 404  # 他人目录不可见


def test_download_sql_artifact_without_auth_header_anonymous(client, seeded, tmp_path, monkeypatch):
    import backend.routers.agent as agent_router

    # 对抗审查发现 2 的后端侧钉子：浏览器裸 <a> 导航不带 Authorization（JWT 只在 auth.js 的
    # window.fetch 补丁里附），无头请求落 anonymous（AUTH_ENABLED=false）或被拒（true）——
    # 两种结局都拿不到写在真实用户目录里的产物，绝不能 200。
    # 前端 deepDownloadLink 已改为带 JWT 的 fetch+blob 下载，这里钉死后端行为。
    monkeypatch.setattr(agent_router, "EXPORT_ROOT", tmp_path)
    monkeypatch.setattr(ea, "EXPORT_ROOT", tmp_path)
    art = ea.deliver_text("SELECT [st] FROM t", subject="模板", owner_key=seeded["admin"]["id"])
    r = client.get(art["download_url"])  # 不带 Authorization 头（模拟裸导航）
    assert r.status_code in (401, 404)


# ---- 统一目录：MCP 侧独立执行面的同名工具必须保留 mcp:: 行（对抗审查发现 3）----

def test_catalog_keeps_mcp_row_for_independent_tool(monkeypatch):
    import backend.services.tool_catalog as tc

    class _NoDb:
        class db_service:
            @staticmethod
            def get_tool_metas():
                return {}

    monkeypatch.setattr(tc, "ide_bridge", _NoDb)
    keys = {item["key"] for item in tc.build_catalog()}
    # convert_sql_to_flexsql 的 MCP handler（tools_flexsql）直调 services/flexsql.py、不委托
    # chatbi handler，且行为不同（永远内联全文 vs 超长落文件）→ 两行都必须可见、可分别编辑
    assert "chatbi::convert_sql_to_flexsql" in keys
    assert "mcp::convert_sql_to_flexsql" in keys
    # 委托型同名工具仍以 chatbi 为唯一来源（审计 P1-11 政策不变）
    assert "chatbi::query_database" in keys
    assert "mcp::query_database" not in keys

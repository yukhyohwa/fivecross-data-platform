"""记忆重组（2026-10-23 用户拍板）回归测试。

背景：术语和口径回归系统级（AI配置 → 术语与口径页，glossary.md/metrics.json 唯一来源），
记忆回归纯个人留档。改动：
1. 移除 /api/memory/import-glossary 一次性迁移端点（术语不再复制进个人记忆）；
2. 启动清理幂等删除历史 category='术语'&source='glossary' 记忆副本（只删迁移产物）；
3. 深度分析 system prompt 直接注入 glossary.md（不再绕记忆副本，全部用户通用）。
"""
from backend.ide_app.migrations import cleanup_glossary_memories


def test_import_glossary_endpoint_removed(client, seeded):
    """import-glossary 迁移端点已移除：调用返回 404，不再复制术语表进记忆。"""
    token = client.post("/api/auth/login",
                        json={"username": "admin", "password": "admin123"}).json()["access_token"]
    r = client.post("/api/memory/import-glossary",
                    headers={"Authorization": f"Bearer {token}"})
    # 端点已删：FastAPI 对残留路径可能给出 404（无路由）或 405（被
    # /api/memory/{memory_id} 的 PUT/DELETE 路径模式兜住、方法不匹配），
    # 两者都证明 POST 处理器已不存在。
    assert r.status_code in (404, 405)


def test_cleanup_removes_only_legacy_glossary_rows(seeded):
    """启动清理：只删 source='glossary' 的术语行；用户手建术语行与普通记忆不动。"""
    from backend.ide_app.services import db_service

    uid = seeded["alice"]["id"]
    legacy = db_service.create_memory(user_id=uid, scope="global", category="术语",
                                      content="日期 → date", source="glossary")
    manual = db_service.create_memory(user_id=uid, scope="private", category="术语",
                                      content="手建术语行", source="manual")
    normal = db_service.create_memory(user_id=uid, scope="private", category="data_note",
                                      content="日常记忆", source="agent")

    cleanup_glossary_memories()

    remaining = db_service.get_memories(user_id=uid, scope="global", category="术语")
    assert all(m["id"] != legacy for m in remaining)
    assert db_service.get_memory_by_id(manual) is not None
    assert db_service.get_memory_by_id(normal) is not None


def test_deep_agent_prompt_injects_glossary_directly(app_env, monkeypatch):
    """深度分析 system prompt 直接注入术语表（framed），不再依赖记忆副本。"""
    import analysis.glossary as glossary_mod
    from backend.services import agent_deep
    from backend.services import games as games_svc

    monkeypatch.setattr(glossary_mod, "glossary_hint",
                        lambda: "\n\n# 业务术语表\n\n账号ID → vopenid\n")
    prompt = agent_deep.build_agent_system_prompt(game=games_svc.resolve("kof"))
    assert "业务术语表（系统级，口语→列名映射参考）" in prompt
    assert "账号ID → vopenid" in prompt


def test_deep_agent_prompt_ok_without_glossary(app_env, monkeypatch):
    """术语表为空/缺失时不注入、不阻断。"""
    import analysis.glossary as glossary_mod
    from backend.services import agent_deep
    from backend.services import games as games_svc

    monkeypatch.setattr(glossary_mod, "glossary_hint", lambda: "")
    prompt = agent_deep.build_agent_system_prompt(game=games_svc.resolve("kof"))
    assert "业务术语表（系统级" not in prompt

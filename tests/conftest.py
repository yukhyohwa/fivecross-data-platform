"""pytest 基线（审计 P1-24）：隔离环境——临时 ide_data.db + 强制鉴权开 + 关共享令牌网关。

关键隔离点：backend.main 的 lifespan 会连真实 StarRocks/MySQL 并迁移真实 ide_data.db，
故测试不用 TestClient 的 context manager（跳过 lifespan），由 fixture 手动 init_db 建临时库。
"""
import sys
import threading
from pathlib import Path

import pytest

# data_ai 根目录进 sys.path，使 `import backend.*` / `import analysis.*` 可用
# （pytest 默认只把 tests/ 目录加入；analysis 包已物理合并到 data_ai 根）
PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))


@pytest.fixture(autouse=True)
def isolate_model_store(tmp_path, monkeypatch):
    """全测试隔离模型槽位 store（model_config.json）与老 report_config.json：
    防止真实 data_ai 根的模型管理配置污染任务选型断言；需要控制 store 的用例再自行 patch。"""
    import backend.config as cfg

    monkeypatch.setattr(cfg, "MODEL_CONFIG_PATH", tmp_path / "model_config.json")
    monkeypatch.setattr(cfg, "REPORT_CONFIG_PATH", tmp_path / "report_config.json")


@pytest.fixture()
def app_env(tmp_path, monkeypatch):
    """临时 ide_data.db + 鉴权开 + 网关令牌关（防 .env 里 AUTH_TOKEN 拦测试请求）。"""
    monkeypatch.setenv("AUTH_ENABLED", "true")
    monkeypatch.setenv("AUTH_TOKEN", "")
    import backend.ide_app.services.db_service as dbs

    monkeypatch.setattr(dbs, "DB_PATH", tmp_path / "ide_test.db")
    monkeypatch.setattr(dbs, "_local", threading.local())  # 防残留连接指向真实库
    dbs.init_db()  # 建表；P1-22 backup_db 此时 DB 尚不存在 → 跳过
    return dbs


@pytest.fixture()
def seeded(app_env):
    """admin（role=admin → dev_admin 全量权限）+ alice（普通用户 → default 身份）。"""
    from backend.ide_app.core.auth import hash_password
    from backend.ide_app.services import permissions
    from backend.ide_app.services.db_service import _conn, create_user

    admin = create_user("admin", hash_password("admin123"))
    alice = create_user("alice", hash_password("alice123"))
    c = _conn()
    c.execute("UPDATE users SET role='admin' WHERE username='admin'")
    c.commit()
    permissions.seed_identities()  # 幂等种身份，并把 role=admin 归到 dev_admin
    return {"admin": admin, "alice": alice}


@pytest.fixture()
def client(seeded):
    """无 lifespan 的 TestClient：库已由 seeded 手动建好，跳过 ide_startup 的真实外部连接。"""
    from fastapi.testclient import TestClient

    from backend.main import app

    return TestClient(app)

"""桥接 sql-ide（已迁入 backend/ide_app）的 service 层，供 data_ai 侧 P4 融合复用。

ide_app 的 db_service 连接 data_ai/ide_data.db，与 /api 各融合接口共享同一份数据
（用户/记忆/指标/远程 MCP/shared_items 全在这一库里）。

本模块统一导出常用 service 引用。data_ai 侧的 P4 router 与深度分析 Agent 从这里 import，
避免散落 `from backend.ide_app.*` 绝对导入。
"""
from backend.ide_app.services import db_service  # noqa: E402
from backend.ide_app.services.memory_manager import MemoryManager  # noqa: E402

__all__ = ["db_service", "MemoryManager"]


def anonymous_uid(user: dict) -> str:
    """data_ai 的 get_current_user 匿名时无 id 字段；落到 user_id 时统一映射。

    匿名用户数据与真实用户隔离（user_id='anonymous'），升级登录后不互相污染。
    """
    uid = (user or {}).get("id")
    return uid or "anonymous"

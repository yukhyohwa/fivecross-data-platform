"""进程内指标缓存（从退役的 agent_service 中迁出，供 logout 清理）。

原 sql-ide UnifiedAgent 会在会话里把匹配到的指标缓存进内存；退役后该缓存不再写入，
仅保留 clear_user_cache 供 /api/auth/logout 清理历史会话残留。
"""

_indicator_cache: dict[str, list[dict]] = {}


def cache_indicators(user_id: str, indicators: list[dict]):
    _indicator_cache[user_id] = indicators


def get_cached_indicators(user_id: str) -> list[dict]:
    return _indicator_cache.get(user_id, [])


def clear_user_cache(user_id: str):
    _indicator_cache.pop(user_id, None)

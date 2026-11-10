"""SQL 生成结果进程内短 TTL 缓存（审计 P2-15）。

背景：chat.py / generate_flow.py / refine.py 三处对重复问题会全量重新调用 LLM 生成 SQL，
既慢又费 token。本模块提供进程内缓存，只缓存「SQL 生成结果」（LLM 输出的 SQL 文本与元信息），
绝不缓存 SQL 执行结果——执行链路不变，仍走既有只读闸门（guard_readonly_sql 已下沉在 run_raw_sql）。

设计要点：
- 键：sha256(归一化 question + game_key + schema 指纹 + 调用点额外上下文摘要)。
  归一化仅 strip 首尾空白（语义精确优先，不做大小写/标点归一）；
  schema 指纹取调用点已有的 schema 上下文字符串摘要（无则用占位串）；
  额外上下文摘要由调用点传入会实质影响生成结果的输入（模型名、历史、参考口径全文、底稿 SQL 等），
  任一输入变化即自然换键，避免命中旧结果。
- 值：(sql, meta) 元组，meta 由调用点定义；命中路径与未命中路径的返回结构完全一致。
- TTL 300 秒；上限 200 条，超限先清过期项、仍超限按写入时间淘汰最旧一半（简单 LRU 式淘汰）。
- 单进程 uvicorn 部署，dict + threading.Lock 足够；进程重启即自然清空。
- invalidate(game_key)：底层 SQL/知识库/专项资产写盘成功后按 game 清空该游戏全部生成缓存，
  保证资产变更后不再命中旧结果（按 game 清，简单可靠）。
"""
from __future__ import annotations

import hashlib
import logging
import threading
import time

logger = logging.getLogger(__name__)

_TTL_SECONDS = 300  # 短 TTL：生成结果只复用 5 分钟
_MAX_ENTRIES = 200  # 条目上限，防止无界增长

_lock = threading.Lock()
_cache: dict[str, dict] = {}  # key -> {"game": str, "ts": float, "value": tuple}

# 简单统计，便于观察命中率（get/put 均在锁内更新）
_stats = {"hit": 0, "miss": 0, "put": 0, "invalidated": 0}


def _normalize_question(question: str) -> str:
    """归一化问题：仅 strip 首尾空白，不做大小写/标点归一（保持语义精确）。"""
    return (question or "").strip()


def _schema_fingerprint(schema_text: str | None) -> str:
    """schema 上下文指纹：调用点已有 schema 上下文字符串则直接摘要；无则用占位串。"""
    if not schema_text:
        return "noschema"
    return hashlib.sha256(schema_text.strip().encode("utf-8", errors="replace")).hexdigest()[:16]


def context_digest(*parts) -> str:
    """调用点额外上下文摘要：把会实质影响生成结果的输入拼起来做 sha256 摘要。

    parts 可为字符串，或 (name, text) 元组列表（如参考口径 ref_pairs、few-shot 示例等），
    统一转文本参与哈希。
    """
    h = hashlib.sha256()
    for p in parts:
        if p is None:
            continue
        if isinstance(p, (list, tuple)):
            for item in p:
                if isinstance(item, (list, tuple)):
                    h.update(str(item[0]).encode("utf-8", errors="replace"))
                    h.update(b"\x1f")
                    h.update(str(item[1]).encode("utf-8", errors="replace"))
                else:
                    h.update(str(item).encode("utf-8", errors="replace"))
                h.update(b"\x1e")
        else:
            h.update(str(p).encode("utf-8", errors="replace"))
        h.update(b"\x1d")
    return h.hexdigest()[:16]


def make_key(question: str, game_key: str, schema_text: str | None = None, extra_context: str = "") -> str:
    """构造缓存键：sha256(归一化 question + game_key + schema 指纹 + 额外上下文摘要)。"""
    payload = "\x1f".join([
        _normalize_question(question),
        game_key or "",
        _schema_fingerprint(schema_text),
        extra_context or "",
    ])
    return hashlib.sha256(payload.encode("utf-8", errors="replace")).hexdigest()


def get(key: str) -> tuple | None:
    """命中返回 (sql, meta)，未命中或过期返回 None。"""
    now = time.time()
    with _lock:
        _prune_expired(now)
        entry = _cache.get(key)
        if entry is None or now - entry["ts"] > _TTL_SECONDS:
            if entry is not None:
                _cache.pop(key, None)
            _stats["miss"] += 1
            return None
        _stats["hit"] += 1
        return entry["value"]


def put(key: str, value: tuple, game_key: str = "") -> None:
    """写入缓存 value=(sql, meta)；同时记录 game，供资产写盘后按 game 失效。"""
    now = time.time()
    with _lock:
        _prune_expired(now)
        if key not in _cache and len(_cache) >= _MAX_ENTRIES:
            # 超限：按写入时间淘汰最旧一半（简单 LRU 式淘汰，避免整库清空误伤近期热点）
            oldest = sorted(_cache.items(), key=lambda kv: kv[1]["ts"])[:_MAX_ENTRIES // 2]
            for k, _e in oldest:
                _cache.pop(k, None)
        _cache[key] = {"game": game_key or "", "ts": now, "value": value}
        _stats["put"] += 1


def invalidate(game_key: str) -> None:
    """按 game 清空该游戏的生成缓存（SQL/知识库/专项资产写盘成功后调用，按 game 清简单可靠）。"""
    if not game_key:
        return
    with _lock:
        removed = [k for k, e in _cache.items() if e.get("game") == game_key]
        for k in removed:
            _cache.pop(k, None)
        if removed:
            _stats["invalidated"] += len(removed)
            logger.info("「审计 P2-15」SQL 生成缓存已按 game=%s 失效 %d 条", game_key, len(removed))


def _prune_expired(now: float) -> None:
    """清掉已过期的条目（在锁内调用）。"""
    expired = [k for k, e in _cache.items() if now - e["ts"] > _TTL_SECONDS]
    for k in expired:
        _cache.pop(k, None)


def stats() -> dict:
    """缓存规模与命中统计（调试用）。"""
    with _lock:
        return {"size": len(_cache), **_stats}

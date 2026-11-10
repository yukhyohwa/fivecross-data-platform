"""已确认指标（ide_data.db indicators）→ SQL 生成上下文注入（审计 P1-1）。

用户在指标管理页确认（status=active）的指标，此前对主对话零作用——SQL 生成只注入
knowledge/metrics.json 的全局指标层（schema_context.metrics_hint），两套指标口径并存。
这里把「确认指标」作为主链路口径源：按问题命中（名称/别名子串，与 metrics.py 同口径）后，
把 definition + canonical_sql 注入 schema_context，优先于 metrics.json；无命中/无用户/
库不可用时返回空，完全回退旧行为（metrics.json 兜底）。
"""
import logging
import re

_HINT_LIMIT = 5          # 单次最多注入的指标数
_SQL_MAX_CHARS = 600     # canonical_sql 注入上限（口径提示，不必全文）

log = logging.getLogger("indicator_hint")


def _norm(s) -> str:
    return (s or "").strip().lower()


def _cross_game(ind: dict, game_key: str | None) -> bool:
    """该指标是否绑定到别的游戏（不同家族）——跨游戏口径不能注入当前游戏的 SQL 生成上下文。

    list_indicators 对「本人/分享给我」的指标不做游戏过滤（管理页语义：任何入口都能看到
    自己全部指标），但注入链路必须按游戏收口（对抗审查：newly-live 轮）：
    - 有 source_sql 且层级为 项目/个人：按家族键（family_key）与当前游戏比对，不同族拦截；
    - 层级为 通用：跨游戏共享是设计语义，放行；
    - 无 source_sql（手工/聊天指标）或判定失败：无法判定游戏归属，放行（宁可多注入不可误伤）。
    """
    if not game_key:
        return False
    src = (ind.get("source_sql") or "").strip()
    if not src:
        return False
    try:
        from .ide_bridge import db_service
        level, meta_game = db_service._sql_scope(src)
        if level == "通用":
            return False
        if meta_game:
            # games 导入与 db_service._sql_scope 同款兜底：analysis 包路径正常由 backend/config.py
            # 注入，独立 import 场景（如进程内直测）这里再注入一次，不依赖隐式 sys.path 全局状态
            import sys as _sys
            from pathlib import Path as _P
            _ga = _P(__file__).resolve().parents[2]
            if str(_ga) not in _sys.path:
                _sys.path.insert(0, str(_ga))
            from analysis import games as _games
            if _games.family_key(meta_game) != _games.family_key(game_key):
                return True
        else:
            # 项目/个人层指标但来源 SQL 无游戏归属（源被改名/删除）——放行但留痕，
            # 避免护栏因内容漂移长期静默失效
            log.warning("_cross_game 无法判定游戏归属（放行）：source_sql=%s game=%s", src, game_key)
    except Exception as exc:  # noqa: BLE001 —— 判定失败不拦截，回退全量注入
        # 护栏失效必须可见（games 包缺失/字段漂移等都会走到这里），只放行不静默
        log.warning(
            "_cross_game 判定失败（放行）：source_sql=%s game=%s exc=%s", src, game_key, exc
        )
        return False
    return False


def confirmed_indicators(user: dict | None, game_key: str | None = None) -> list[dict]:
    """当前用户可见的已确认（active）指标；匿名/库异常返回 []。

    list_indicators 会把「分享给我」的指标与「层级共享」（来源 SQL 通用/项目，指标打通）
    的指标并入（不分页限制小集合），这里统一再按 status=active 过滤一遍，保证注入的只有
    已确认口径（不含 draft/已废弃）；并拦掉绑定到其他游戏（不同家族）的指标。
    """
    uid = (user or {}).get("id")
    if not uid:
        return []
    try:
        from .ide_bridge import db_service
        items, _ = db_service.list_indicators(uid, status="active", size=50, game=game_key)
    except Exception:  # noqa: BLE001 —— 库不可用时回退 metrics.json，不阻断
        return []
    return [
        i for i in items
        if isinstance(i, dict) and i.get("status") == "active" and not _cross_game(i, game_key)
    ]


def match_indicators(question: str, user: dict | None, game_key: str | None = None) -> list[dict]:
    """按名称/别名子串命中指标（与 metrics.metrics_hint 相同的口语命中口径）。"""
    inds = confirmed_indicators(user, game_key)
    if not inds or not question:
        return []
    q = _norm(question)
    hits = []
    for ind in inds:
        name = ind.get("metric_name") or ""
        alias = ind.get("metric_alias") or ""
        mid = ind.get("metric_id") or ""
        # metric_id（形如 sql_xxx 的机器名）也参与命中，与任务「按 metric_id/alias 匹配提问」对齐
        tokens = [t for t in re.split(r"[,，/、\s]+", f"{name} {alias} {mid}") if t]
        # 空别名会让空 token 恒真命中；过滤后按子串匹配（与 metrics.py._aliases 同规则）
        if tokens and any(_norm(t) in q for t in tokens):
            hits.append(ind)
    return hits[:_HINT_LIMIT]


def indicator_hint(question: str | None, user: dict | None, game_key: str | None = None) -> str:
    """渲染已确认指标口径注入（定义 + canonical_sql），供 schema_context 优先于 metrics.json。"""
    if not question:
        return ""
    hits = match_indicators(question, user, game_key)
    if not hits:
        return ""
    lines = ["# 已确认业务指标口径（指标库人工确认，优先于内置指标定义，公式与字段以此为准）", ""]
    for ind in hits:
        name = ind.get("metric_name") or ind.get("metric_id") or ""
        lines.append(f"- {name}")
        alias = ind.get("metric_alias")
        if alias:
            lines.append(f"    别名：{alias}")
        definition = ind.get("definition")
        if definition:
            lines.append(f"    定义：{definition}")
        sql = (ind.get("canonical_sql") or "").strip()
        if sql:
            lines.append(f"    规范 SQL：{sql[:_SQL_MAX_CHARS]}")
        if ind.get("granularity"):
            lines.append(f"    粒度：{ind['granularity']}")
    return "\n\n" + "\n".join(lines) + "\n"

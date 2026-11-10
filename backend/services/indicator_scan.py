"""指标自动生成（Task E 前端融合配套）：扫描 SQL 库 → 生成 draft 指标；生成新 SQL 后联动检索。

两种能力：
1. `scan_sqls_to_draft(user_id)`：手动扫描 `analysis/sql_store` 全部 SQL，逐条复用
   `indicator_service.analyze_sql_indicator` 解析成指标，`status='draft'` 待人工确认。
2. `match_and_draft_for_sql(user_id, question, final_sql)`：data_ai 生成新 SQL 后联动——
   先 `match_indicators_by_llm` 检索已有指标，无高置信匹配才新建 draft，避免重复堆草稿。

按 `metric_id`（`sql_<文件名主干>`）去重，同名 SQL 重复扫描不重复建。
"""
from __future__ import annotations

import asyncio
import json
import re
import sys
from pathlib import Path

from .ide_bridge import db_service

# analysis.* 由 backend/config.py 注入 sys.path（data_ai 根）；这里兜底再注入一次，
# 让本模块被单独 import（如测试脚本）也能找到 analysis 包。
_GA_ROOT = Path(__file__).resolve().parents[2]
if str(_GA_ROOT) not in sys.path:
    sys.path.insert(0, str(_GA_ROOT))


def _indicator_service():
    from backend.ide_app.services import indicator_service
    return indicator_service


def _sql_store():
    from analysis import sql_store
    return sql_store


async def scan_sqls_to_draft(user_id: str, names: list[str] | None = None, game: str | None = None) -> dict:
    """扫描 SQL 库 *.sql → 逐个「一拆多」成 draft 子指标（按 metric_id=sql_<主干>_<列> 去重）。

    `names` 传指定文件名列表时只扫这些文件，否则扫全部。
    `game` 传当前游戏 key 时只扫「当前用户可见」的 SQL 集（list_sql_files(game) 已按
    通用/项目同族/个人归属过滤）——避免把他人个人级 SQL 的内容扫进自己的指标（隐私泄漏），
    也避免把无权限的项目级 SQL 生成共享指标。
    """
    store = _sql_store()
    all_names = store.list_sql_files(game)
    if names is None:
        names = all_names
    else:
        # 只处理确实存在的文件（避免对不存在文件报错），并保持传入顺序；
        # 传 game 时 all_names 已含可见性过滤，交集即「可见且被点名」的文件
        names = [n for n in names if n in all_names]
    result = {"scanned": len(names), "created": 0, "updated": 0, "skipped": 0, "failed": 0, "preview": []}
    for name in names:
        sql_text = store.read_sql(name)
        if not (sql_text or "").strip():
            continue
        r = await _split_file(user_id, name, sql_text)
        if r.get("error"):
            result["failed"] += 1
            result["preview"].append({"sql_name": name, "metric_name": "", "error": r["error"]})
        else:
            result["created"] += r.get("created", 0)
            result["updated"] += r.get("updated", 0)
            result["skipped"] += r.get("skipped", 0)
            result["preview"].extend(r.get("indicators", []))
    return result


async def generate_from_sql(user_id: str, sql_name: str, game: str | None = None) -> dict:
    """SQL数据页「一键生成/更新指标」：对单个 SQL 文件做「一拆多」。

    - AI 拆分该 SQL 为 N 个单指标（复用「数据指标知识库」indicator_split.md prompt + data_ai 侧 ai_client）。
    - 删除旧的 sql_<主干> 复合 draft 指标（用户拍板）；active 复合保留避免误删已上线口径。
    - 每个子指标按 metric_id=sql_<主干>_<列名> 去重：无则建 draft、有且同 user 则同步重解析；
      来源 SQL 为 通用/项目 级时跨用户共建（更新同一行，见 _split_file）。
    """
    store = _sql_store()
    if sql_name not in store.list_sql_files(game):
        return {"sql_name": sql_name, "error": "SQL 文件不存在或当前不可见"}
    sql_text = store.read_sql(sql_name) or ""
    if not sql_text.strip():
        return {"sql_name": sql_name, "error": "SQL 文件为空"}
    return await _split_file(user_id, sql_name, sql_text)


def _child_metric_id(stem: str, column: str, idx: int) -> str:
    """子指标 metric_id：sql_<主干>_<列名>（列名非法则回退序号 m<idx>）。"""
    col = (column or "").strip()
    if col and re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", col):
        return f"sql_{stem}_{col}"
    return f"sql_{stem}_m{idx}"


def _norm_expr(sql_expr: str) -> str:
    """归一化 SQL 表达式（去空白 + 小写），用作同一指标跨拆分的稳定去重键。

    LLM 对同一指标的 column 命名会漂移（如 sales vs sales_cny），仅按 metric_id 去重
    会重复建；SQL 表达式是 SQL 里的客观原文，跨调用稳定得多。
    """
    return re.sub(r"\s+", "", sql_expr or "").lower()


def _extract_json(text: str) -> str:
    """从 LLM 输出中提取 JSON（容忍 markdown 代码围栏与前后杂音）。"""
    text = (text or "").strip()
    if text.startswith("```"):
        text = text[3:].strip()
        if text.startswith("json"):
            text = text[4:].strip()
        if text.endswith("```"):
            text = text[:-3].strip()
    starts = [i for i in (text.find("{"), text.find("[")) if i != -1]
    ends = [i for i in (text.rfind("}"), text.rfind("]")) if i != -1]
    if starts and ends:
        s, e = min(starts), max(ends)
        if e > s:
            return text[s:e + 1]
    return text


def _split_sql_parts(sql_text: str, user_id: str | None = None) -> list[dict]:
    """用 data_ai 侧 ai_client（本仓库根 .env 的 LLM key，与深度分析 Agent 同源）拆分多指标 SQL。

    复用 ide_backend 的 indicator_split.md prompt；LLM 不可用/解析失败返回空列表。
    """
    from .. import config
    from .llm import complete
    from analysis import ai_client

    prompt_file = Path(__file__).resolve().parents[1] / "ide_app" / "prompts" / "indicator_split.md"
    if not prompt_file.exists():
        return []
    text = prompt_file.read_text(encoding="utf-8")
    user_tpl = ""
    if "---user---" in text:
        user_tpl = text.split("---user---", 1)[1].strip()
    elif "---system---" in text:
        user_tpl = text.split("---system---", 1)[1].strip()
    if not user_tpl:
        return []

    sql = sql_text[:6000] if len(sql_text) > 6000 else sql_text
    try:
        user_prompt = user_tpl.format(sql=sql)
    except (KeyError, IndexError):
        return []

    try:
        model = config.task_model("split")
        result_str = complete(
            model,
            [{"role": "user", "content": user_prompt}],
            user={"id": user_id} if user_id else None,
            max_tokens=4096,
            timeout=(60, 120),
            **ai_client.reasoning_off(model),
        )
        data = json.loads(_extract_json(result_str))
        indicators = data.get("indicators") if isinstance(data, dict) else data
        if not isinstance(indicators, list):
            return []
        return [i for i in indicators if isinstance(i, dict) and (i.get("metric_name") or i.get("column"))]
    except Exception:
        return []


async def _split_file(user_id: str, sql_name: str, sql_text: str) -> dict:
    """把一个 SQL 文件拆成多个单指标 draft（一拆多核心）。"""
    stem = sql_name[:-4] if sql_name.endswith(".sql") else sql_name
    composite_metric_id = f"sql_{stem}"
    store = _sql_store()

    # 1. AI 拆分（复用「数据指标知识库」：data_ai 侧 ai_client，与深度分析 Agent 同源）
    parts = await asyncio.to_thread(_split_sql_parts, sql_text, user_id)
    if not parts:
        return {"sql_name": sql_name, "error": "AI 拆分失败（请确认已配置 LLM Key，见右上角用户菜单 → LLM配置 或本仓库根 .env）"}

    # 2. 删除旧复合指标（仅 draft/deprecated；active 保留避免误删已上线口径）。
    #    旧「一文件一指标」复合草稿是历史遗留，用户拍板被一拆多取代后删除，不要求 owner 匹配
    #    （匿名拆分也要能清理），active 复合绝不误删。
    removed_composite = False
    composite = db_service.get_indicator_by_metric_id(composite_metric_id)
    if composite and composite.get("status") in ("draft", "deprecated"):
        db_service.delete_indicator(composite.get("id"))
        removed_composite = True

    created = updated = skipped = 0
    indicators = []
    seen_columns = set()
    # 来源 SQL 的层级对齐：通用/项目级 SQL 的派生指标全局共享、跨用户共建（更新同一行，
    # 不再「首扫者独占」）；个人级 SQL 的派生指标仍按 owner 隔离。
    scope_level, _scope_game = store.sql_scope(sql_name)
    level_shared = scope_level in ("通用", "项目")
    # 按「SQL 表达式归一化」建立已拆子指标索引：column 命名会漂移（sales vs sales_cny），
    # 仅按 metric_id 去重会重复建，以表达式为准更稳。
    existing_by_expr = {}
    for ind in db_service.get_indicators_by_source_sql(sql_name):
        frags = ind.get("sql_fragments") or []
        first = frags[0] if isinstance(frags, list) and frags and isinstance(frags[0], dict) else None
        expr = (first.get("sql") or "") if first else ""
        if expr:
            existing_by_expr[_norm_expr(expr)] = ind
    for idx, p in enumerate(parts, 1):
        metric_name = (p.get("metric_name") or "").strip() or (p.get("column") or "").strip() or f"指标{idx}"
        column = (p.get("column") or "").strip() or f"m{idx}"
        base = column
        n = 2
        while column in seen_columns:  # 列名去重（LLM 可能给重复 column）
            column = f"{base}_{n}"
            n += 1
        seen_columns.add(column)
        metric_id = _child_metric_id(stem, column, idx)
        fragment = {"name": metric_name, "sql": (p.get("sql_expression") or "").strip()}
        summary = {
            "sql_name": sql_name, "metric_id": metric_id, "metric_name": metric_name,
            "domain": p.get("domain", ""), "definition": p.get("definition", ""),
        }
        existing = db_service.get_indicator_by_metric_id(metric_id)
        if not existing:
            existing = existing_by_expr.get(_norm_expr(p.get("sql_expression") or ""))
        if existing:
            # 他人所有：仅当来源 SQL 为 通用/项目 级（层级共享）时才共建更新同一行；
            # 个人级派生指标保持 owner 隔离（skip）。
            if str(existing.get("user_id") or "") != str(user_id) and not level_shared:
                skipped += 1
                summary.update({"owned_by_other": True, "status": existing.get("status", "")})
                indicators.append(summary)
                continue
            data = {
                "canonical_sql": sql_text,
                "metric_name": metric_name,
                "definition": p.get("definition") or existing.get("definition", ""),
                "domain": p.get("domain") or existing.get("domain", ""),
                "category": p.get("category") or existing.get("category", ""),
                "tags": p.get("tags") or existing.get("tags") or [metric_name],
                "aggregation_type": p.get("aggregation_type") or existing.get("aggregation_type", ""),
                "granularity": p.get("granularity") or existing.get("granularity", ""),
                "sql_fragments": [fragment],
                "source_sql": sql_name,
            }
            # 按表达式命中的旧指标 metric_id 可能与本次 column 漂移后的不同，summary 以实际命中为准
            if existing.get("metric_id") and existing.get("metric_id") != metric_id:
                summary["metric_id"] = existing.get("metric_id")
            item = db_service.update_indicator(existing.get("id"), data)
            updated += 1
            summary.update({
                "updated": True, "status": item.get("status", existing.get("status", "")),
                "level_shared": level_shared, "source_level": scope_level,
            })
            indicators.append(summary)
        else:
            data = {
                "metric_id": metric_id,
                "metric_name": metric_name,
                "metric_alias": "",
                "canonical_sql": sql_text,
                "definition": p.get("definition", ""),
                "domain": p.get("domain", ""),
                "category": p.get("category", ""),
                "tags": p.get("tags") or [metric_name],
                "aggregation_type": p.get("aggregation_type", ""),
                "granularity": p.get("granularity", ""),
                "sql_fragments": [fragment],
                "source_sql": sql_name,
                "status": "draft",
            }
            item = db_service.create_indicator(user_id, data)
            created += 1
            summary.update({
                "created": True, "status": "draft",
                "level_shared": level_shared, "source_level": scope_level,
            })
            indicators.append(summary)
    return {
        "sql_name": sql_name, "split": True, "removed_composite": removed_composite,
        "created": created, "updated": updated, "skipped": skipped, "indicators": indicators,
    }


async def match_and_draft_for_sql(user_id: str, question: str, final_sql: str, game_key: str | None = None) -> dict:
    """生成新 SQL 后联动：检索已有指标，无高置信匹配才新建 draft（失败静默，由调用方 try/except）。

    `game_key` 传入时检索范围含该游戏族可见的层级共享指标（通用/项目同族），避免重复堆草稿。
    """
    svc = _indicator_service()
    indicators, _total = db_service.list_indicators(user_id, page=1, size=200, game=game_key)
    if not indicators:
        item = await _draft_from_sql(svc, user_id, question, final_sql)
        return {"created": True, "indicator": item, "matched": []}
    try:
        match = await svc.match_indicators_by_llm(question, indicators, user_id)
    except Exception:
        match = {"matched": [], "reasoning": ""}
    matched = match.get("matched") or []
    if matched:
        return {
            "created": False,
            "matched": [m.get("metric_name", "") for m in matched],
            "reasoning": match.get("reasoning", ""),
        }
    item = await _draft_from_sql(svc, user_id, question, final_sql)
    return {"created": True, "indicator": item, "matched": []}


async def _draft_from_sql(svc, user_id: str, question: str, final_sql: str) -> dict:
    metric_name = _metric_name_from_question(question)
    try:
        analysis = await svc.analyze_sql_indicator(metric_name, final_sql, [], user_id)
    except Exception:
        analysis = {}
    data = {
        "metric_name": metric_name,
        "metric_alias": "",
        "canonical_sql": final_sql,
        "definition": analysis.get("definition", ""),
        "domain": analysis.get("domain", ""),
        "category": analysis.get("category", ""),
        "tags": analysis.get("tags") or [metric_name],
        "status": "draft",
    }
    return db_service.create_indicator(user_id, data)


def _metric_name_from_question(question: str) -> str:
    q = (question or "").strip()
    if not q:
        return "未命名指标"
    # 去掉常见语气词，避免把整句问题塞进指标名
    return q[:40]

"""对话「生成」编排（能力 1）：扫描 → 生成 → 关联 → 改造 → 冻结，产出草稿供前端确认保存。

三个入口对应三种工件，都只产出草稿、**不落盘**（生成即写意图 → 一律先草稿卡、人点保存才写）：
- generate_sql_flow：默认扫所有知识库，生成 SQL（SQL 头部注释标注用到的知识库）；
- generate_model_flow：扫所有 SQL + 知识库，识别关联 → 生成模型代码 + 判断改造 → 生成专属修改 SQL；
- generate_skill_flow：扫所有 SQL + 知识库 + 模型，生成方法说明 + 阶段二改造/冻结（快照内容仅备好，不写盘）。

统一返回 {kind, name, draft, associations, transforms, sources, provenance?}。
"""
from __future__ import annotations

import logging
import re

from analysis import kb_gen, knowledge_store as ks, model_gen, snapshot, sql_store

from . import forecast, schema_context, skill_bundle, sql_cache

logger = logging.getLogger(__name__)

_ILLEGAL = re.compile(r'[\\/:*?"<>|]')
_KIND_SUFFIX = re.compile(r"(生成|创建|新建|写|一个|一条|份)?\s*(SQL|查询|取数|模型|预测|算法|专项|分析方法|报告模板|模板)\s*$")


def _default_name(description: str, kind: str) -> str:
    """从描述推导默认工件名（去掉动词/工件类型词，截断到合理长度）。"""
    text = _KIND_SUFFIX.sub("", (description or "").strip())
    text = re.sub(r"(帮我|请|麻烦|来|生成|写一个|写|创建一个|创建|建一个|新建|一个|一条|一份|一下)", "", text)
    text = _ILLEGAL.sub("_", text).strip(" _").strip()
    if not text:
        text = {"sql": "AI生成的SQL", "model": "AI生成的模型", "skill": "AI生成的专项"}[kind]
    return text[:30]


def generate_sql_flow(model: str, description: str, game: dict, engine) -> dict:
    """默认扫所有知识库生成 SQL，并在 SQL 头部注释标注实际用到的知识库。"""
    game_key = game["key"]
    db = game["db"]
    schema_text, ctx_docs, src = schema_context.build_sql_context(engine, db, game_key, question=description)

    # 默认扫所有知识库：自动识别的表结构/口径文档之外，把其余文档全量作为参考口径
    seen = {name for name, _ in ctx_docs}
    ref_pairs = list(ctx_docs)
    for d in ks.list_docs(game_key):
        if d in seen:
            continue
        text = ks.read_doc(d)
        if text.strip():
            ref_pairs.append((d, text))
            seen.add(d)

    # 审计 P2-15：SQL 生成短 TTL 缓存——重复提问同 game（表结构/口径上下文一致）直接复用上次
    # 生成结果，跳过 LLM 全量重生成。参考口径全文进 extra 摘要：口径文档一变即自然换键，
    # 不会命中旧结果（SQL/知识库资产写盘另有 invalidate(game_key) 兜底）。
    cache_key = sql_cache.make_key(
        description, game_key, schema_text,
        extra_context=sql_cache.context_digest(model, ref_pairs),
    )
    cached = sql_cache.get(cache_key)
    if cached is not None:
        sql, _cache_meta = cached
        logger.info("「审计 P2-15」generate_sql_flow 缓存命中：question=%r game=%s", description, game_key)
    else:
        try:
            from analysis import sql_gen
            sql, _raw = sql_gen.generate_sql(model, schema_text, description, ref_pairs)
        except Exception as exc:
            raise ValueError(f"SQL 生成失败：{exc}")
        sql_cache.put(cache_key, (sql, {"source": "generate_sql_flow"}), game_key=game_key)

    sources = [snapshot.provenance_entry("doc", name, text) for name, text in ref_pairs if text.strip()]
    return {
        "kind": "sql",
        "name": _default_name(description, "sql"),
        "draft": sql,
        "associations": {"docs": [name for name, _ in ref_pairs]},
        "transforms": {},
        "sources": sources,
        "schema_source": src,
    }


def _looks_monthly(description: str, bound_sqls: list[str]) -> bool:
    """据描述 + 绑定 SQL 头部注释判断是否为月粒度。"""
    if "月" in (description or ""):
        return True
    from analysis.artifact import sql_header_comment
    for n in bound_sqls:
        if "月" in sql_header_comment(sql_store.read_sql(n)):
            return True
    return False


def generate_model_flow(model: str, description: str, game: dict, engine) -> dict:
    """扫所有 SQL + 知识库：识别关联 → 生成模型代码 → 判断/生成专属修改 SQL。"""
    game_key = game["key"]
    sql_names = sql_store.list_sql_files(game_key)
    doc_names = ks.list_docs(game_key)

    # 识别关联（标记关联到的 SQL / 文档）
    assoc = kb_gen.suggest_associations(model, description, sql_names, doc_names)
    bound_sqls = assoc["sqls"]
    bound_docs = assoc["docs"]

    result = model_gen.generate_model(model, description, bound_sqls, bound_docs)

    # 取数 SQL 默认取首个绑定 SQL；粒度/窗口给默认值，用户可在「算法模型」页再精调
    sql_name = bound_sqls[0] if bound_sqls else ""
    granularity = "month" if _looks_monthly(description, bound_sqls) else "day"
    manifest = {"input": "sql", "sql": sql_name, "granularity": granularity}
    if granularity == "month":
        manifest.update({"hist_months": 24, "horizon_months": 6})
    else:
        manifest.update({"hist_days": 84, "horizon_days": 28})

    return {
        "kind": "model",
        "name": _default_name(description, "model"),
        "draft": result["code"],
        "problems": result["problems"],
        "manifest": manifest,
        "associations": {"sqls": bound_sqls, "docs": bound_docs},
        "transforms": {"sqls": result["transformed_sqls"]},
        "sources": result["sources"],
    }


def generate_skill_flow(model: str, description: str, game: dict, engine) -> dict:
    """扫所有 SQL + 知识库 + 模型：生成方法说明 + 阶段二改造/冻结（快照内容仅备好，不写盘）。"""
    game_key = game["key"]
    sql_names = sql_store.list_sql_files(game_key)
    doc_names = ks.list_docs(game_key)
    fcaps = [c for c in forecast.visible_capabilities(game_key) if c.get("input") == "sql"]

    # 阶段一：方法说明 + 建议关联
    res = kb_gen.summarize_skill(model, description, sql_names, doc_names, forecast_caps=fcaps)
    content = res["content"]
    bound_sqls = res["sqls"]
    bound_docs = res["docs"]
    forecast_binding = res.get("forecast")

    # 阶段二：改造 + 冻结 + 溯源（仅备好快照，不 write_skill_bundle，保存时才落盘）
    sqls, prov_sql = skill_bundle.build_sql_snapshots(model, bound_sqls, content)
    knowledge, prov_knowledge = skill_bundle.build_knowledge_snapshots(model, bound_docs)
    models, prov_models, pred_sql = skill_bundle.build_model_snapshot(forecast_binding)
    if pred_sql and pred_sql not in sqls:
        psql, pprov = skill_bundle.build_sql_snapshots(model, [pred_sql], content)
        sqls.update(psql)
        prov_sql.update(pprov)

    provenance = {"sql": prov_sql, "models": prov_models, "knowledge": prov_knowledge}
    return {
        "kind": "skill",
        "name": res.get("title") or _default_name(description, "skill"),
        "draft": content,
        "associations": {"sqls": bound_sqls, "docs": bound_docs, "forecast": forecast_binding},
        "transforms": {"sqls": sqls, "knowledge": knowledge, "models": models},
        "sources": [],
        "provenance": provenance,
    }

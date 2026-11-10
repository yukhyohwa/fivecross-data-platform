"""专项打包（阶段二）：把「选定的 SQL / 文档 / 预测能力」按专项要求改写后冻结进专项目录，并记录来源指纹。

与四工件独立 / 快照方案对齐：
- SQL：按专项方法说明改写（日期占位/口径对齐）后冻结，记原始来源名 + 指纹；
- 知识库：精简为核心口径/字段/计算规则后冻结，记源；
- 算法模型：外部能力整段代码冻结；内置能力随应用版本（不冻结代码），但取数 SQL 一并冻结；
- 改写错误可经对话 refine / 合并流程再改（不自动）。

阶段一（方法说明 + 选定 sqls/docs/forecast）仍在 analysis.kb_gen.summarize_skill；本模块只做阶段二。
"""
from __future__ import annotations

import contextvars
from concurrent.futures import ThreadPoolExecutor

from analysis import code_store, knowledge_store as ks, sql_store
from analysis.kb_gen import extract_binding, summarize
from analysis.snapshot import fingerprint
from analysis.sql_gen import generate_sql
from analysis.sql_rewriter import restamp_header, rewrite_sql
from analysis.usage_tracker import clone_context

from . import forecast

_SQL_ADAPT_PROMPT = (
    "按专项方法说明调整该 SQL：日期范围用 current_date() 相对表达式"
    "（若原 SQL 已含 {开始日期}/{结束日期} 占位符则原样保留，勿改动），"
    "输出列名与粒度与专项步骤保持一致，其余逻辑尽量保留。"
)

# 快照构建里各 SQL/文档的改写彼此独立，串行跑 N 次 LLM 是「刷新快照」慢的主因；
# 这里并发度取 4，兼顾提速与不压垮内网 LiteLLM 网关。
_MAX_WORKERS = 4


def build_sql_snapshots(model: str, sql_names: list[str], skill_text: str, rewrite: bool = True) -> tuple[dict, dict]:
    """对选定 SQL 改写后冻结。返回 (sqls{key:text}, prov{key:{source,fingerprint}})。

    rewrite=False 时跳过 LLM 改写，直接冻结原始 SQL（仅重盖章头部注释），
    用于「保存」这种必须即时、确定性落盘的高频路径；LLM 适配改由 /refresh、/plan 显式触发。
    rewrite=True 时对多个 SQL 并发改写（彼此独立，互不依赖）。
    """
    sqls: dict[str, str] = {}
    prov: dict[str, dict] = {}
    bindings = extract_binding(skill_text or "")

    def _build_one(name: str):
        original = sql_store.read_sql(name)
        if not original.strip():
            return name, None, None
        adapted = original
        if rewrite:
            try:
                adapted, _ = rewrite_sql(model, original, [_SQL_ADAPT_PROMPT], skill_text or None)
            except Exception:
                adapted = original
        b = bindings.get(name) or {}
        adapted = restamp_header(adapted, step=b.get("step", ""), section=b.get("section", ""))
        return name, adapted, {"source": name, "fingerprint": fingerprint(original),
                               "mode": "follow", "content_fingerprint": fingerprint(adapted)}

    if rewrite and len(sql_names) > 1:
        # 审计 P2-7：并行 worker 线程不继承 contextvars，显式带入当前上下文（含
        # usage_tracker 用量桶），并发改写的 token 用量才能记回本请求。
        # 注意：不能并发调用同一个 Context.run（不可重入，会抛 already entered），
        # 每个 worker 各自 clone_context 一份再 run。
        ctx = contextvars.copy_context()
        with ThreadPoolExecutor(max_workers=_MAX_WORKERS) as ex:
            results = list(ex.map(lambda name: clone_context(ctx).run(_build_one, name), sql_names))
    else:
        results = [_build_one(name) for name in sql_names]

    for name, adapted, prov_entry in results:
        if adapted is not None:
            sqls[name] = adapted
            prov[name] = prov_entry
    return sqls, prov


def build_knowledge_snapshots(model: str, doc_names: list[str], rewrite: bool = True) -> tuple[dict, dict]:
    """对选定文档精简为核心内容后冻结。返回 (knowledge{doc:text}, prov{doc:{source,fingerprint}})。

    rewrite=False 时跳过 LLM 精简，直接冻结原文，避免「保存」被大模型调用拖慢。
    rewrite=True 时对多个文档并发精简。
    """
    knowledge: dict[str, str] = {}
    prov: dict[str, dict] = {}

    def _build_one(d: str):
        original = ks.read_doc(d)
        if not original.strip():
            return d, None, None
        core = original
        if rewrite:
            try:
                core, _ = summarize(
                    model, [{"name": d, "content": original}],
                    extra="提炼为本专项直接相关的核心口径/字段/计算规则，去除无关内容，控制在 600 字以内",
                )
            except Exception:
                core = original
        return d, core, {"source": d, "fingerprint": fingerprint(original),
                         "mode": "follow", "content_fingerprint": fingerprint(core)}

    if rewrite and len(doc_names) > 1:
        # 审计 P2-7：同上，显式把当前上下文（含 usage_tracker 用量桶）带给并行 worker。
        # 同样不能并发调用同一个 Context.run，每个 worker 各自 clone_context 一份。
        ctx = contextvars.copy_context()
        with ThreadPoolExecutor(max_workers=_MAX_WORKERS) as ex:
            results = list(ex.map(lambda d: clone_context(ctx).run(_build_one, d), doc_names))
    else:
        results = [_build_one(d) for d in doc_names]

    for d, core, prov_entry in results:
        if core is not None:
            knowledge[d] = core
            prov[d] = prov_entry
    return knowledge, prov


def _forecast_method(binding) -> str | None:
    if isinstance(binding, str):
        return binding
    if isinstance(binding, dict):
        return binding.get("method")
    return None


def build_model_snapshot(binding) -> tuple[dict, dict, str | None]:
    """冻结预测能力。返回 (models{method:code}, prov{method:{source,fingerprint}}, 预测取数 SQL 名)。

    - 外部能力：整段代码冻结；
    - 内置能力：不冻结代码（随应用版本、无漂移），但返回其取数 SQL 名，供一并冻结 SQL。
    """
    models: dict[str, str] = {}
    prov: dict[str, dict] = {}
    method = _forecast_method(binding)
    if not method:
        return models, prov, None
    cap = forecast.PREDICTION_CAPABILITIES.get(method)
    if cap is None:
        return models, prov, None
    pred_sql = cap.get("sql") if cap.get("input") == "sql" else None
    if forecast.is_builtin(method):
        return models, prov, pred_sql
    code = code_store.read_code(method)
    if code.strip():
        models[method] = code
        prov[method] = {"source": method, "fingerprint": fingerprint(code),
                        "mode": "follow", "content_fingerprint": fingerprint(code)}
    return models, prov, pred_sql


def _gen_question(s: dict) -> str:
    """把规划条目拼成给 sql_gen.generate_sql 的取数描述（步骤名/章节/要求）。"""
    parts = []
    step = (s.get("step") or "").strip()
    section = (s.get("section") or "").strip()
    brief = (s.get("brief") or "").strip()
    if step:
        parts.append(f"步骤名（图表名）：{step}")
    if section:
        parts.append(f"归属章节：{section}")
    if brief:
        parts.append(f"取数要求：{brief}")
    return "；".join(parts) if parts else s.get("name", "")


def build_planned_snapshot(model: str, skill_text: str, plan_sqls: list[dict], schema_text: str,
                           ref_docs: list[tuple[str, str]], doc_names: list[str],
                           forecast_binding, embedded_sqls: dict[str, str] | None = None) -> dict:
    """执行「快照方案」：已有 SQL 改写、缺失 SQL 从零生成、知识精简、模型冻结。

    plan_sqls 为 skill_plan.plan_skill 产出的 [{name, status, step, section, brief}]。
    doc_names 仅含「已有」文档（缺失文档只提示、不生成）。
    embedded_sqls：本专项内嵌快照（名 → 内容），供「源不在全局 SQL 库」的 existing 键
    冻结（只重盖章、不 LLM 改写——内嵌件本身就是已适配产物，避免从零生成/无效 churn）。
    多条步骤 SQL 的改写/生成彼此独立，并发 4 执行（与保存/刷新路径 build_sql_snapshots 对齐；
    2026-10-28 前此路径串行，是「自动生成快照」慢的主因）。
    返回：{sqls, knowledge, models, provenance, pred_sql}（全部草稿，不落盘）。
    """
    sqls: dict[str, str] = {}
    prov_sql: dict[str, dict] = {}
    embedded_sqls = embedded_sqls or {}

    def _build_one(s: dict):
        """改写/生成单条步骤 SQL，返回 (name, 文本, 溯源)。彼此独立，可并发。"""
        name = s["name"]
        step = s.get("step") or ""
        section = s.get("section") or ""
        if s.get("status") == "existing":
            original = sql_store.read_sql(name)
            if not original.strip() and embedded_sqls.get(name, "").strip():
                # 对抗审查（frozen-save 轮）：源只存在于内嵌快照——按内嵌件冻结（仅重盖章）
                original = embedded_sqls[name]
                adapted = restamp_header(original, step=step, section=section)
                return name, adapted, {"source": name, "fingerprint": fingerprint(original),
                                       "mode": "follow", "content_fingerprint": fingerprint(adapted)}
            if original.strip():
                try:
                    adapted, _ = rewrite_sql(model, original, [_SQL_ADAPT_PROMPT], skill_text or None)
                except Exception:
                    adapted = original
                adapted = restamp_header(adapted, step=step, section=section)
                return name, adapted, {"source": name, "fingerprint": fingerprint(original),
                                       "mode": "follow", "content_fingerprint": fingerprint(adapted)}
            return name, "", {"source": "", "fingerprint": "", "mode": "follow", "content_fingerprint": ""}
        try:
            generated, _ = generate_sql(model, schema_text, _gen_question(s), ref_docs)
        except Exception:
            generated = ""
        generated = restamp_header(generated, step=step, section=section)
        return name, generated, {"source": "", "fingerprint": "", "mode": "pin",
                                 "content_fingerprint": fingerprint(generated) if generated.strip() else ""}

    if len(plan_sqls) > 1:
        # 审计 P2-7 同款：并行 worker 线程不继承 contextvars，显式带入当前上下文（含
        # usage_tracker 用量桶），并发改写/生成的 token 用量才能记回本请求。
        # 注意：不能并发调用同一个 Context.run（不可重入），每个 worker 各自 clone_context 一份。
        ctx = contextvars.copy_context()
        with ThreadPoolExecutor(max_workers=_MAX_WORKERS) as ex:
            results = list(ex.map(lambda s: clone_context(ctx).run(_build_one, s), plan_sqls))
    else:
        results = [_build_one(s) for s in plan_sqls]

    for name, text, prov_entry in results:
        sqls[name] = text
        prov_sql[name] = prov_entry

    knowledge, prov_knowledge = build_knowledge_snapshots(model, doc_names)
    models, prov_models, pred_sql = build_model_snapshot(forecast_binding)
    # 预测取数 SQL 一并冻结（独立于常规步骤 SQL），镜像 _write_bundle 的行为
    if pred_sql and pred_sql not in sqls:
        psql, pprov = build_sql_snapshots(model, [pred_sql], skill_text)
        sqls.update(psql)
        prov_sql.update(pprov)

    return {
        "sqls": sqls,
        "knowledge": knowledge,
        "models": models,
        "provenance": {"sql": prov_sql, "models": prov_models, "knowledge": prov_knowledge},
        "pred_sql": pred_sql,
    }

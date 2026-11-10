"""跨源统一检索：判断用户问题命中 SQL / 知识库 / 专项 / 算法模型 的哪个（对话 5 步流第②步）。

不再由单一 intent 锁死单一通道：把四条通道「是否命中」都取出来——
命中 1 个 → 直接执行（快路径）；命中 ≥2 个 → 出候选卡让用户选；0 个 → SQL 兜底（AI 现写）。
复用既有单通道匹配器（它们已含时间/指标对齐等防误判逻辑），本模块只做跨源汇总与歧义判定。
"""
import contextvars
import re
from concurrent.futures import ThreadPoolExecutor

from analysis import retrieval as vec_retrieval
from analysis.usage_tracker import clone_context

from . import indicator_hint, model_run, skill_match, sql_match

# 模型通道仅在问题明显是「预测/建模」时参与，避免普通取数被模型候选干扰
_MODEL_HINT = re.compile(r"预测|预估|测算|建模|估算|未来|下月|下周|明年|流水预测")

# 知识库检索分数下限：低于此视为「没真正命中口径文档」，避免弱相关文档被算成候选造成误确认
_DOC_SCORE_FLOOR = 0.15


def _skill_hit(model, question, game_key, user=None):
    try:
        name = skill_match.match_skill(model, question, game_key, user)
    except Exception:
        name = None
    if not name:
        return None
    return {
        "type": "skill", "name": name, "label": "专项",
        "summary": skill_match.summarize_skill_text(name),
    }


def _sql_hit(model, question, game_key, user=None):
    try:
        name = sql_match.match_sql(model, question, game_key, user)
    except Exception:
        name = None
    if not name:
        return None
    return {"type": "sql", "name": name, "label": "SQL", "summary": ""}


def _model_hit(model, question, game_key, user=None):
    if not _MODEL_HINT.search(question or ""):
        return None
    try:
        name = model_run.match_model(model, question, game_key, user)
    except Exception:
        name = None
    if not name:
        return None
    return {"type": "model", "name": name, "label": "算法模型", "summary": ""}


def _doc_hit(question, game_key):
    try:
        rs = vec_retrieval.query(question, ["doc"], k=1, game=game_key)
    except Exception:
        rs = []
    if not rs or float(rs[0].get("score", 0)) < _DOC_SCORE_FLOOR:
        return None
    r = rs[0]
    return {
        "type": "doc", "name": r["id"], "label": "知识库",
        "summary": r.get("summary", ""),
    }


def _indicator_hits(question, user, game_key=None):
    """指标通道（审计 P1-1）：命中「已确认指标」仅作信息展示，不进候选执行流。

    指标不是可执行工件（执行的是 SQL/专项/模型），命中的指标口径经
    schema_context.build_sql_context 注入 SQL 生成上下文；这里只把命中清单返回给
    调用方做过程展示（如「命中指标口径：充值金额」），避免误入 best 执行分支。
    game_key 让层级共享指标（通用/项目同族）参与命中。
    """
    try:
        inds = indicator_hint.match_indicators(question, user, game_key)
    except Exception:
        inds = []
    return [
        {"type": "indicator", "name": i.get("metric_name") or i.get("metric_id") or "",
         "label": "指标口径", "summary": (i.get("definition") or "")[:80]}
        for i in inds
    ]


def retrieve_candidates(model, question, game_key, needs_confirm=False, intent="query", user=None):
    """返回 {candidates, best, ambiguous, indicators}。

    - candidates：命中的候选短名单（按 专项/SQL/模型/知识库 优先序）；
    - best：唯一命中的候选（仅 1 个命中且不歧义时才有）；
    - ambiguous：是否需出候选卡让用户确认（≥2 个命中 或 needs_confirm）。
      0 命中时 best=None、ambiguous=False，由调用方走 SQL 兜底。
    - indicators：命中的已确认指标口径（审计 P1-1，仅信息展示，不参与 best/歧义判定）。

    intent=query 时，知识库文档不作为「唯一命中 best」——口径问答走独立 knowledge 通道，
    doc 只作为候选出现在多命中确认卡里，避免把「查数据」误降级成「知识库问答」。
    """
    # 四条通道彼此独立（各自一次 LLM / 向量检索），并行跑，把「检索」延迟从串行求和压到单次最长
    # 审计 P2-7：ThreadPoolExecutor 不自动传播 contextvars，这里把当前上下文（含 usage_tracker
    # 用量桶）显式带给 worker 线程，并行 LLM 调用的 token 用量才能记回本请求的桶。
    # 注意：同一 Context 不能并发 run（不可重入，会抛 already entered），每个 submit 各自
    # clone_context 一份再 run。
    ctx = contextvars.copy_context()
    with ThreadPoolExecutor(max_workers=5) as ex:
        f_skill = ex.submit(clone_context(ctx).run, _skill_hit, model, question, game_key, user)
        f_sql = ex.submit(clone_context(ctx).run, _sql_hit, model, question, game_key, user)
        f_model = ex.submit(clone_context(ctx).run, _model_hit, model, question, game_key, user)
        f_doc = ex.submit(clone_context(ctx).run, _doc_hit, question, game_key)
        f_ind = ex.submit(clone_context(ctx).run, _indicator_hits, question, user, game_key)
        # 各 _*_hit 内部已捕获异常并返回 None，result() 不会抛出
        hits = [r for r in (f_skill.result(), f_sql.result(), f_model.result(), f_doc.result()) if r is not None]
        indicators = f_ind.result()
    best = None
    if len(hits) == 1:
        h = hits[0]
        if not (intent == "query" and h["type"] == "doc"):
            best = h
    ambiguous = needs_confirm or len(hits) >= 2
    return {"candidates": hits, "best": best, "ambiguous": ambiguous, "indicators": indicators}

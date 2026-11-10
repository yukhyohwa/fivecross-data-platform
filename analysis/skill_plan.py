"""专项「快照方案」规划：读专项文本 → 判断每个报告步骤需要哪些 SQL，区分
「已有（需改写）」「缺失（需生成）」，并产出可人审的规划清单 + 修好绑定表的专项文本。

只做「读 + 规划 + 分类」（纯 LLM，零副作用）；分类状态在 Python 侧确定性兜底
（池内 = existing、池外 = missing，不信任 LLM 的 status）。实际的改写/生成/冻结在
data_ai/backend/services/skill_bundle.build_planned_snapshot 里做。
"""
from __future__ import annotations

from analysis.ai_client import chat_completion_with_fallback, reasoning_off
from analysis import sql_store
from analysis.kb_gen import _extract_json, _retrieval_candidates, _sql_brief

_PLAN_SYSTEM = (
    "你是资深游戏数据分析方法专家。下面会给你一份「专项（分析方法）说明」全文，"
    "以及候选清单（已有 SQL 文件名 + 头部注释、已有知识库文档名、候选预测能力）。\n"
    "你的任务：\n"
    "1. 通读专项文本，识别报告里的每个分析步骤（= 图表）需要哪一条取数 SQL；\n"
    "2. 对每条所需 SQL，判断候选清单里是否已有能直接复用的——有就【逐字】复制其文件名"
    "（含 .sql 后缀，不要改字、不要去掉后缀）；确实没有对应 SQL 的，才新起一个文件名"
    "（以 .sql 结尾、不与候选清单重名），并在 brief 里写清取数要求（粒度、关键输出列、口径）；\n"
    "3. step 必须与专项文本『绑定对照表』里『步骤名』列逐字一致（新增步骤则用图表名）；\n"
    "4. 列出本专项实际绑定的知识库文档（必须是候选文档里的真实名）与预测能力"
    "（必须是候选能力里的真实 id，没有则 null）。\n"
    "最终只输出一个 JSON 对象，键名固定为：\n"
    "sqls（数组，每项 {step, section, name, brief}：step=步骤名/图表名，section=归属章节，"
    "name=最终 SQL 文件名，brief=缺失 SQL 的取数描述，已有 SQL 可留空串）、"
    "docs（数组，每项 {name}）、forecast（预测能力 id 或 null）。\n"
    "不要输出 JSON 以外的任何内容（无需复述专项文本全文，系统会自行修正绑定表）。"
)


def _norm_sql(name: str) -> str:
    """SQL 文件名归一化（去 .sql 后缀、小写），供「池内/池外」确定性判定。"""
    n = (name or "").strip().lower()
    return n[:-4] if n.endswith(".sql") else n


def _fix_binding_table(text: str, sqls: list[dict]) -> str:
    """把专项文本『绑定对照表』里每个步骤的「绑定 SQL 文件名」列改成规划后的最终文件名。

    只改绑定表内的 SQL 文件名单元格，其余文本一字不动；找不到绑定表或步骤则原样返回。
    这样「快照方案」不必让模型逐字复述全文，输出短、生成快，也能避免模型偷偷改动正文。
    """
    if not text or not sqls:
        return text
    step_to_name = {}
    for s in sqls:
        step = (s.get("step") or "").strip()
        name = (s.get("name") or "").strip()
        if step and name and step not in step_to_name:
            step_to_name[step] = name
    if not step_to_name:
        return text

    lines = text.split("\n")
    out = []
    in_table = False
    for line in lines:
        s = line.strip()
        if s.startswith("##") and "绑定对照表" in s:
            in_table = True
            out.append(line)
            continue
        if in_table and (s.startswith("##") or s.startswith("#")):
            in_table = False
            out.append(line)
            continue
        if in_table and s.startswith("|") and "|" in s.strip("|"):
            cells = [c.strip() for c in s.strip("|").split("|")]
            changed = False
            for i, cell in enumerate(cells):
                if cell in step_to_name and i + 1 < len(cells):
                    new_name = step_to_name[cell]
                    if cells[i + 1] != new_name:
                        cells[i + 1] = new_name
                        changed = True
                    break
            if changed:
                out.append("| " + " | ".join(cells) + " |")
                continue
        out.append(line)
    return "\n".join(out)


def plan_skill(model: str, skill_text: str, sql_names: list[str], doc_names: list[str],
               forecast_caps: list[dict] | None = None,
               bound_sqls: dict[str, str] | None = None) -> dict:
    """读专项文本规划 SQL。返回 {content, sqls, docs, forecast}（状态已确定性重判）。

    bound_sqls：本专项内嵌快照里「源不在全局 SQL 库」的 SQL（名 → 内容）。这些键
    不参与候选检索截断、恒定计为 existing——否则会被误判 missing 从零生成
    （对抗审查：frozen-save 轮确认的内嵌快照重生成问题）。
    """
    sql_names, doc_names = _retrieval_candidates(skill_text, sql_names, doc_names, sql_top=40, doc_top=15)
    bound_sqls = bound_sqls or {}
    bound_names = [n for n in bound_sqls if (n or "").strip()]
    sql_pool = set(sql_names) | set(bound_names)
    sql_pool_norm = {_norm_sql(n): n for n in sql_pool}
    doc_pool = set(doc_names)
    fc_ids = {c.get("id") for c in (forecast_caps or [])}

    user_parts = ["### 专项文本\n\n" + (skill_text or "").strip()]
    sql_lines = []
    seen_sql = set()
    for n in list(sql_names) + [b for b in bound_names if b not in sql_names]:
        if n in seen_sql:
            continue
        seen_sql.add(n)
        text = sql_store.read_sql(n) if n in sql_names else bound_sqls.get(n, "")
        brief = _sql_brief(text)
        sql_lines.append(f"- {n}" + (f"：{brief.replace(chr(10), '；')}" if brief else ""))
    user_parts.append(
        "### 候选已有 SQL（文件名 + 头部注释）\n\n" + ("\n".join(sql_lines) if sql_lines else "（无）")
    )
    user_parts.append(
        "### 候选知识库文档\n\n" + ("\n".join("- " + n for n in doc_names) if doc_names else "（无）")
    )
    if forecast_caps:
        user_parts.append(
            "### 候选预测能力\n\n"
            + "\n".join(f"- {c.get('id')}（{c.get('name', '')}）：{c.get('desc', '')}" for c in forecast_caps)
        )
    user_parts.append("请输出规划 JSON。")

    raw, _ = chat_completion_with_fallback(
        model=model,
        messages=[
            {"role": "system", "content": _PLAN_SYSTEM},
            {"role": "user", "content": "\n\n".join(user_parts)},
        ],
        # 规划要一次产出「修正后的专项全文 + sqls/docs/forecast」，输出长；主动关推理 + 给足
        # 正文空间，并靠 with_fallback 在推理模型空返回时兜底到 ai_client._FALLBACK_MODEL
        #（deepseek-v4-pro）（审计 P2-14：兜底模型早已从 flash 升级为 pro）。
        max_tokens=16384,
        **reasoning_off(model),
    )
    data = _extract_json(raw)

    sqls, seen = [], set()
    for s in (data.get("sqls") or []):
        if not isinstance(s, dict):
            continue
        name = (s.get("name") or "").strip()
        if not name:
            continue
        status = "existing" if name in sql_pool else "missing"
        if status == "missing":
            norm = _norm_sql(name)
            if norm in sql_pool_norm:
                name = sql_pool_norm[norm]
                status = "existing"
        if name in seen:
            continue
        seen.add(name)
        sqls.append({
            "name": name,
            "status": status,
            "step": (s.get("step") or name).strip(),
            "section": (s.get("section") or "").strip(),
            "brief": (s.get("brief") or "").strip(),
        })

    docs = []
    for d in (data.get("docs") or []):
        dn = d.get("name") if isinstance(d, dict) else d
        dn = (dn or "").strip()
        if not dn:
            continue
        docs.append({"name": dn, "status": "existing" if dn in doc_pool else "missing"})

    forecast = None
    f = data.get("forecast")
    if isinstance(f, dict):
        f = f.get("method") or f.get("id")
    if isinstance(f, str) and f in fc_ids:
        forecast = {"method": f, "status": "existing"}
    elif f:
        forecast = {"method": str(f), "status": "missing"}

    content = _fix_binding_table(skill_text, sqls)
    return {"content": content, "sqls": sqls, "docs": docs, "forecast": forecast}

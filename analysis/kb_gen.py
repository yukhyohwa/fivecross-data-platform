"""知识库「AI 汇总生成」：把多份原始资料汇总成一份文档草稿。

移植自 game_analytics/webapp/pages/2_知识库.py 的 render_ai_summarize_tab 逻辑，
并扩展了「聊天记录 → 知识库 / 专项 / SQL / 订阅报告」四种生成。
"""
import json
import re

from analysis.ai_client import chat_completion_with_fallback, reasoning_off, INTERACTIVE_MAX_TOKENS, structured_json
from analysis.sql_rewriter import extract_sql, validate_sql
from analysis import sql_store

_SYSTEM = (
    "你是一名游戏行业的知识管理专家，负责把用户提供的多份原始资料整理汇总成一份"
    "结构清晰、适合放入内部知识库的说明文档。要求：提炼关键信息、去除重复和无关内容、"
    "保持业务口径准确；输出使用 Markdown 格式，正文以一个 `# 标题` 开头。"
)


def extract_title(draft: str, default: str = "AI汇总文档") -> str:
    for line in (draft or "").splitlines():
        line = line.strip()
        if line.startswith("#"):
            title = line.lstrip("#").strip()
            if title:
                return title
            break
    return default


def summarize(model: str, sources: list[dict], extra: str = "", existing: str = "") -> tuple[str, str]:
    """sources: [{name, content}]。返回 (草稿全文, 建议标题)。

    existing 为已有文档内容（用户当前编辑中）；非空时在其基础上修改完善，而不是推倒重来。
    """
    user_parts = [f"### 资料来源：{s['name']}\n\n{s['content']}" for s in sources]
    if existing and existing.strip():
        user_parts.append(
            "### 已有文档内容（请在其基础上修改完善：保留合理内容，结合新资料增删改，不要推倒重来）\n\n"
            + existing.strip()
        )
    if extra and extra.strip():
        user_parts.append(f"### 额外要求\n\n{extra.strip()}")
    if existing and existing.strip():
        user_parts.append("请基于以上全部资料并结合「已有文档内容」，综合生成改进后的知识库文档。")
    else:
        user_parts.append("请基于以上全部资料，汇总生成一份知识库文档。")
    draft, _ = chat_completion_with_fallback(
        model=model,
        messages=[
            {"role": "system", "content": _SYSTEM},
            {"role": "user", "content": "\n\n---\n\n".join(user_parts)},
        ],
        **reasoning_off(model),
    )
    return draft, extract_title(draft)


_CHAT_SYSTEM = (
    "你是一名游戏行业的数据分析知识管理专家。下面是一段「用户提问 → AI 查询数据库」的对话记录，"
    "请把它提炼成一份可复用的知识库条目：归纳业务问题、关键指标口径、查询思路（保留关键的 SQL 片段）"
    "与注意事项，去除寒暄和冗余。输出 Markdown，正文以一个 `# 标题` 开头。"
)


def _transcript_parts(messages: list[dict]) -> list[str]:
    """把对话记录格式化成若干段文本。"""
    parts = []
    for m in messages:
        role = m.get("role")
        if role == "user":
            parts.append(f"【用户提问】{m.get('text', '').strip()}")
        else:
            answer = (m.get("answer") or m.get("text") or "").strip()
            sql = (m.get("sql") or "").strip()
            block = f"【AI 回复】\n{answer}" if answer else "【AI 回复】（无文字解读）"
            if sql:
                block += f"\n\n【执行的 SQL】\n```sql\n{sql}\n```"
            parts.append(block)
    return parts


def summarize_chat(model: str, messages: list[dict], kind: str = "docs", extra: str = "") -> tuple[str, str]:
    """把一段对话记录提炼为知识库条目。kind: docs | skills。返回 (草稿, 标题)。"""
    parts = _transcript_parts(messages)
    if extra and extra.strip():
        parts.append(f"【额外要求】{extra.strip()}")
    target = "分析方法 Skill" if kind == "skills" else "知识库文档"
    parts.append(f"请基于以上对话，生成一份{target}。")
    draft = structured_json(
        model=model,
        system=_CHAT_SYSTEM,
        user_content="\n\n---\n\n".join(parts),
    )
    return draft, extract_title(draft)


_SQL_SYSTEM = (
    "你是资深数据仓库 SQL 专家（StarRocks / MySQL）。下面是一段对话记录，"
    "请提炼出其中最关键的一条可执行【只读 SELECT】查询 SQL："
    "若对话里已出现 SQL 则优先保留它；否则根据问题从零写一条合理 SQL。"
    "在 SQL 最前面输出结构化头部注释（每行以 `-- ` 开头），格式固定为：\n"
    "-- ============================================================\n"
    "-- 【步骤名】<简短名称，即图表名>\n"
    "-- 【归属章节】<所属报告章节，如 📊 概览 / 🔍 明细下钻 / 🔮 预测>\n"
    "-- 【粒度】<日/周/月，或维度>\n"
    "-- 【输出列】<逗号分隔的关键输出列名>\n"
    "-- 【图表】折线|柱状|堆叠柱状|饼图|表格（五选一，时间序列默认折线，占比/构成默认饼图，分周/分维度对比用柱状或堆叠柱状）\n"
    "-- 【右轴】<需放右轴的数值列名，逗号分隔；无则省略此行>\n"
    "-- ============================================================\n"
    "然后紧跟 SQL 正文，全部包在一个 markdown 代码块里：\n```sql\n...\n```\n不得使用写语句。"
)


def summarize_to_sql(model: str, messages: list[dict], extra: str = "") -> str:
    """从对话提炼一条可执行 SQL（复用 extract_sql/validate_sql 解析校验）。"""
    parts = _transcript_parts(messages)
    if extra and extra.strip():
        parts.append(f"【额外要求】{extra.strip()}")
    parts.append("请输出查询 SQL。")
    raw = structured_json(
        model=model,
        system=_SQL_SYSTEM,
        user_content="\n\n---\n\n".join(parts),
    )
    return validate_sql(extract_sql(raw))


_FIELDS_SYSTEM = (
    "你是数据分析助手。给定一条 SQL 和它的输出列清单，为每个列写一句简短的中文含义说明。"
    "要求：10 字以内；金额/流水类列要标币种（人民币/CNY、美金/USD）；"
    "带上口语关键词（如 流水、收入、目标、达成率、DAU、ARPU、留存、付费 等），方便按自然语言问题匹配。"
    "只输出一个 JSON 对象：{\"desc\": {\"列名\": \"说明\", ...}}，键必须严格等于清单里的列名。"
)


def _extract_desc_map(raw: str) -> dict:
    try:
        data = json.loads(raw)
        if isinstance(data, dict) and isinstance(data.get("desc"), dict):
            return data["desc"]
    except (json.JSONDecodeError, TypeError):
        pass
    m = re.search(r'"desc"\s*:\s*(\{.*\})', raw or "", re.S)
    if m:
        try:
            data = json.loads(m.group(1))
            if isinstance(data, dict):
                return data
        except json.JSONDecodeError:
            pass
    return {}


def annotate_fields(model: str, sql_text: str, fields: list[dict]) -> list[dict]:
    """为 fields 的每列生成一句中文 desc（AI 单次调用，保存 SQL 时用，不影响查询）。

    失败/无结果返回原 fields（desc 保持空），不抛异常。
    """
    if not fields:
        return fields
    cols = [f.get("col") for f in fields if isinstance(f, dict) and f.get("col")]
    if not cols:
        return fields
    try:
        raw = structured_json(
            model=model,
            system=_FIELDS_SYSTEM,
            user_content=f"# SQL\n```sql\n{(sql_text or '')[:4000]}\n```\n\n# 输出列\n" + "、".join(cols),
        )
        desc = _extract_desc_map(raw)
    except Exception:
        desc = {}
    if not desc:
        return fields
    for f in fields:
        if isinstance(f, dict) and f.get("col") and desc.get(f["col"]):
            f["desc"] = desc[f["col"]]
    return fields


_SUB_SYSTEM = (
    "你是数据分析助手。下面是一段对话记录，请把它提炼成一个「订阅报告」配置。"
    "只输出一个 JSON 对象，键名固定为："
    "name（订阅名，简短）、skill（关联的专项名，没有则 null）、"
    "sqls（涉及的 SQL 文件名数组，没有则 []）、docs（涉及的知识库文档名数组，没有则 []）、"
    "extra_prompt（额外分析要求，没有则空字符串）。不要输出 JSON 以外的内容。"
)


def _extract_json(raw: str) -> dict:
    try:
        data = json.loads(raw)
        if isinstance(data, dict):
            return data
    except (json.JSONDecodeError, TypeError):
        pass
    m = re.search(r"\{.*\}", raw, flags=re.DOTALL)
    if m:
        try:
            data = json.loads(m.group(0))
            if isinstance(data, dict):
                return data
        except json.JSONDecodeError:
            pass
    return {}


def _coerce_forecast(forecast, fc_ids: set) -> str | None:
    """把 LLM 返回的 forecast 归一化为命中候选的单一 id。

    兼容字符串 / 数组 / null（模型偶尔把 forecast 输出成数组，直接 `x in fc_ids` 会
    因 list 不可哈希而抛 TypeError）。
    """
    if isinstance(forecast, list):
        return next((f for f in forecast if isinstance(f, str) and f in fc_ids), None)
    if isinstance(forecast, str) and forecast in fc_ids:
        return forecast
    return None


def summarize_to_subscription(model: str, messages: list[dict]) -> dict:
    """从对话提炼订阅配置 {name, skill, sqls, docs, extra_prompt}。"""
    parts = _transcript_parts(messages)
    parts.append("请输出订阅报告配置 JSON。")
    raw = structured_json(
        model=model,
        system=_SUB_SYSTEM,
        user_content="\n\n---\n\n".join(parts),
    )
    data = _extract_json(raw)
    return {
        "name": str(data.get("name") or "AI订阅").strip()[:80],
        "skill": data.get("skill") or None,
        "sqls": data.get("sqls") or [],
        "docs": data.get("docs") or [],
        "extra_prompt": data.get("extra_prompt") or "",
    }


# 报告正文默认四层结构：标题锚定词必须保留，前端据此按章节自动排版（概览→成因结论→明细下钻→预测）
_DEFAULT_STRUCTURE_HEADINGS = (
    "## 📊 概览 —— 整体核心指标与一句话结论\n"
    "## 🎯 成因结论 —— 结构化归因\n"
    "## 🔍 明细下钻 —— 按维度分项展开\n"
    "## 🔮 预测 —— 后续走向与风险提示"
)

# 兜底注入用的「报告结构」章节：当生成结果漏写时，保证前端仍能识别结构
_DEFAULT_STRUCTURE_BLOCK = (
    "## 报告结构（正文二级标题严格照抄，顺序固定）\n\n"
    "报告正文用 Markdown 二级标题（`## `）组织成以下 4 个小节，标题文字逐字照抄、"
    "不要改写、不要增删小节、不要改用一级或三级标题：\n\n"
    "```\n"
    + _DEFAULT_STRUCTURE_HEADINGS +
    "\n```\n\n"
    "各小节内容要求：\n"
    "- **概览**：一句话结论（关键数字加粗）+ 核心指标与环比/达成率；\n"
    "- **成因结论**：当前结果的主要驱动 / 拖累因素归因；\n"
    "- **明细下钻**：按时间 / 地区 / 人群 / 商品等维度分项展开，每条结论附数据支撑；\n"
    "- **预测**：基于历史趋势预判后续走向与风险提示（数据不足以预测时可省略）。"
)


_SKILL_SYSTEM = (
    "你是资深游戏数据分析方法专家。下面会给你一段用户描述（想分析什么、怎么分析），"
    "请把它写成一份可复用的「专项（分析方法）」说明：说清分析角度、关键指标口径、"
    "计算逻辑与注意事项；输出 Markdown，正文以一个 `# 标题` 开头。\n"
    "\n"
    "【正文结构（严格按此顺序逐节写，共 6 节，不要增删或改序）】\n"
    "第 1 节「报告结构」：规定分析报告正文的固定小节——用 Markdown 二级标题 `## ` 组织、"
    "顺序固定、标题文字逐字照抄（不要改写、不要增删小节、不要改用一级或三级标题），"
    "并把这四个标题原样写进一个 markdown 代码块：\n"
    "```\n"
    + _DEFAULT_STRUCTURE_HEADINGS +
    "\n```\n"
    "标题锚定词必须保留：第一节含「概览」、第二节含「成因」或「结论」、第三节含「明细」或「下钻」、"
    "第四节含「预测」；`——` 之后的分句可按具体分析微调。若该专项确实不涉及预测（且未关联预测能力），"
    "可省略「预测」小节，其余三节必须保留。该节内再补一小段「各小节内容要求」，逐条说明每个小节写什么结论、对应哪些图/数据。\n"
    "第 2 节「绑定对照表（SQL · 知识库 · 预测能力）」：先用 Markdown 表格把「报告章节 | 步骤名（= 图表名）| 绑定 SQL 文件名 | 粒度 | 关键输出列」一一对应列清楚。"
    "其中「粒度」「关键输出列」直接从下方「候选取数代码」每条 SQL 的头部注释抄录（无头部注释的按文件名与用户描述推断）；"
    "「绑定 SQL 文件名」必须是候选清单里的真实文件名、且与最终输出的 sqls 数组一致；「步骤名」与第 1/3 节里提到的图名保持一致。"
    "表格之后再补两条：**知识库文档绑定**——从「候选知识库文档」里挑出与本专项口径/字段/计算规则直接相关的文档（如《指标口径说明》），说明每个文档用于哪部分口径/字段/计算依据；"
    "**预测能力绑定**——若分析需要预测未来趋势，写明绑定「候选预测能力」里的哪个能力，并说明预测结果由该能力预先计算注入、报告预测层直接引用、不要自行另估数字。\n"
    "第 3 节「各小节内容与展示要求」：逐条说明每个小节的结论要点、对应图表、展示顺序。\n"
    "第 4 节「关键指标口径」：逐条列出本专项涉及的指标口径与字段（与关联文档保持一致）。\n"
    "第 5 节「计算逻辑」：逐条说明计算步骤与公式。\n"
    "第 6 节「注意事项」：逐条说明易错点、边界与风险。\n"
    "\n"
    "最终只输出一个 JSON 对象，键名固定为："
    "title（专项名称，简短）、content（方法说明 Markdown 全文）、"
    "sqls（建议关联的 SQL 文件名数组）、docs（建议关联的知识库文档名数组）、"
    "forecast（绑定的预测能力 id 或 null）、"
    "note（「专项笔记」增量：从用户描述与已有方法说明中提炼的可复用口径、经验、已知数据坑"
    "（如币种/时区/过滤条件/易错表字段等），分条简短列出；本次用户描述里新增的口径、约束、坑"
    "（哪怕细小）都要列入 note；已出现在「已有专项笔记」里的内容"
    "不要重复输出，若没有新的值得沉淀内容则输出空字符串 \"\"；不要复述方法说明本身）。"
    "描述中点名写出的 SQL 文件/文档（如「复用《买量投放KPI》资产」「口径见《指标口径说明》」）"
    "必须视为直接相关并列入 sqls/docs。"
    "不要输出 JSON 以外的任何内容。"
)


def _local_rank(desc: str, names: list[str], top: int) -> list[str]:
    """按描述与文件名/标题的 2-gram 重叠度本地排序并截断（零依赖、确定性，不跨工件检索）。

    - 候选数不超过阈值时原样返回（零回归）；
    - 超过阈值时把最相关的排前、截断到 top-N；未命中的按原顺序补尾（保证不丢任何可选绑定）。
    """
    if len(names) <= top:
        return names
    grams = {desc[i:i + 2] for i in range(len(desc) - 1)} if len(desc) >= 2 else set()

    def score(name: str) -> int:
        stem = name[:-4] if name.endswith(".sql") else name
        return sum(1 for g in grams if g in stem)

    hit = [n for n in names if score(n) > 0]
    miss = [n for n in names if score(n) == 0]
    return (hit + miss)[:top]


def _retrieval_candidates(description: str, sql_names: list[str], doc_names: list[str], sql_top: int = 20, doc_top: int = 15) -> tuple[list[str], list[str]]:
    """候选过多时按描述相关性本地排序并截断，避免「全部候选塞给 LLM」。

    先用本地 2-gram 预筛（文件名与描述的重叠），再用跨工件 TF-IDF 检索（retrieval.query）
    把 2-gram 漏掉的相关 SQL / 文档补进候选（只增不减，最终仍由 LLM 定夺）；
    候选不多时全量交给 LLM。
    """
    desc = (description or "").strip()
    if not desc:
        return list(sql_names), list(doc_names)
    sql_ranked = _local_rank(desc, sql_names, sql_top)
    doc_ranked = _local_rank(desc, doc_names, doc_top)
    # 语义召回补充：2-gram 只按文件名/标题字面重叠，会漏掉描述里没写文件名的相关工件。
    # 用 TF-IDF 检索把这些漏项插到排名前部，使它们在「截断到 top-N」时能存活（只增不减）。
    # 注意 retrieval 的 canonical id 是裸名（SQL 去 .sql 后缀），比较时先归一，返回时再映射回原名。
    try:
        from analysis import retrieval
        sql_bare = {n[:-4] if n.endswith(".sql") else n: n for n in sql_names}
        doc_bare = {n[:-3] if n.endswith(".md") else n: n for n in doc_names}
        sql_ranked_bare = [n[:-4] if n.endswith(".sql") else n for n in sql_ranked]
        doc_ranked_bare = [n[:-3] if n.endswith(".md") else n for n in doc_ranked]
        sem_sql = [r.get("id") for r in retrieval.query(desc, kinds=["sql"], k=sql_top)]
        sem_doc = [r.get("id") for r in retrieval.query(desc, kinds=["doc"], k=doc_top)]
        sql_ranked = [sql_bare[n] for n in sem_sql if n in sql_bare and n not in sql_ranked_bare] + sql_ranked
        doc_ranked = [doc_bare[n] for n in sem_doc if n in doc_bare and n not in doc_ranked_bare] + doc_ranked
    except Exception:
        pass
    return sql_ranked[:sql_top], doc_ranked[:doc_top]


# 「否定语境」标记：出现在工件名之前的同句窗口内时，该次出现不算正向点名。
# 收紧为直接绑定否定词——「排除/对比/仅作参考」类宽词会误杀「《买量投放KPI》口径…
# （排除 kof campaign）」这种正向点名+无关排除的句子（投放效果分析/skill.md:97 实测存在）。
_NEGATION_MARKERS = (
    "不使用", "不采用", "不纳入", "不关联", "不绑定", "不复用", "不用",
    "未纳入", "弃用", "作废", "已下线", "不建议",
)
_NEGATION_RE = re.compile("|".join(map(re.escape, _NEGATION_MARKERS)))


def _literal_mentions(description: str, names: list[str]) -> list[str]:
    """描述里点名写出的工件名（主干作为子串出现，如「《买量投放KPI》」命中 买量投放KPI.sql）。

    确定性通道：用户「专项里写了指定的 SQL 就应该关联上」的口径不依赖 LLM 提名，
    也不受候选截断（top-N）影响，因此对完整清单匹配。三道闸门防误伤：
    - 主干过短（<4 字符）不匹配，避免「KPI」「留存」等常见词误伤大量文件；
    - 词边界：主干后必须是「非名称字符」（》/标点/行尾），否则前缀同族文件会被连带命中
      （点名《流水达成_分周》时，流水达成 后跟 _ 是词内字符，不再命中 流水达成.sql）；
    - 否定语境：该次出现之前同句窗口（≤12 字符、不跨 。；\\n）内若带直接绑定否定词
      （不复用/不用/弃用…），该次出现不算正向点名；至少一次出现不在否定语境才算命中
      （2026-10-26 对抗审查：「不复用《X》」等反面表述不得强制绑定）。
    """
    desc = description or ""
    hits = []
    for n in names:
        stem = n
        if stem.lower().endswith(".sql"):
            stem = stem[:-4]
        elif stem.lower().endswith(".md"):
            stem = stem[:-3]
        if len(stem) < 4:
            continue
        kept = False
        for m in re.finditer(re.escape(stem) + r"(?![\w])", desc):
            # 同句窗口：该次出现向前最多 12 字符，且不超过上一个句读（。；换行），
            # 防止上一句的否定词跨句误伤下一句的正向点名
            before = desc[max(desc.rfind("\n", 0, m.start()), desc.rfind("。", 0, m.start()),
                              desc.rfind("；", 0, m.start())) + 1: m.start()][-12:]
            if _NEGATION_RE.search(before):
                continue
            kept = True
            break
        if kept:
            hits.append(n)
    return hits


def _sql_brief(text: str, max_lines: int = 12) -> str:
    """抽取 SQL 头部注释块作为简短说明，供生成专项时理解每个 SQL 的用途/粒度/输出列。"""
    lines = []
    for ln in (text or "").splitlines():
        s = ln.strip()
        if not s:
            if lines:
                break  # 头部注释块结束（遇到空行）
            continue
        if s.startswith("--"):
            lines.append(s.lstrip("- ").strip())
        else:
            break  # 遇到非注释行，说明头部注释块结束
        if len(lines) >= max_lines:
            break
    return "\n".join(lines)


def summarize_skill(model: str, description: str, sql_names: list[str], doc_names: list[str], existing: str = "", forecast_caps: list[dict] | None = None, existing_notes: str = "") -> dict:
    """据描述生成专项方法说明 + 建议关联的 SQL/文档/预测能力。返回 {title, content, sqls, docs, forecast, note}。

    existing 为已有专项方法说明（用户当前编辑中）；非空时在其基础上修改完善，而不是推倒重来。
    forecast_caps 为候选预测能力 [{id, name, desc}]；为空表示不启用预测绑定。
    existing_notes 为已沉淀的专项笔记；非空时 note 只输出「新增」要点（已有内容不重复、不改写），
    无新增则输出空串——供生成/调整专项时增量沉淀到专项笔记槽（报告时随方法说明注入）。
    """
    # 截断前先留完整清单：点名匹配走全量、不受候选 top-N 截断影响
    full_sqls = list(sql_names)
    full_docs = list(doc_names)
    sql_names, doc_names = _retrieval_candidates(description, sql_names, doc_names)
    # 描述中点名的工件即使被截断切出候选，也插回候选头部让 LLM 看到
    # （与 suggest_associations 确定性通道同源：2026-10-26 点名资产关联不到问题）
    for s in _literal_mentions(description, full_sqls):
        if s not in sql_names:
            sql_names.insert(0, s)
    for d in _literal_mentions(description, full_docs):
        if d not in doc_names:
            doc_names.insert(0, d)
    user_parts = ["### 用户描述\n\n" + (description or "").strip()]
    if existing and existing.strip():
        user_parts.append(
            "### 已有专项方法说明（请在其基础上修改完善：保留合理内容，按新描述增删改，不要推倒重来）\n\n"
            + existing.strip()
        )
    sql_lines = []
    for n in sql_names:
        brief = _sql_brief(sql_store.read_sql(n))
        sql_lines.append(f"- {n}" + (f"：{brief.replace(chr(10), '；')}" if brief else ""))
    user_parts.append(
        "### 候选取数代码（SQL 文件名 + 头部注释）\n\n" + ("\n".join(sql_lines) if sql_lines else "（无）")
    )
    user_parts.append(
        "### 候选知识库文档\n\n" + ("\n".join("- " + n for n in doc_names) if doc_names else "（无）")
    )
    if forecast_caps:
        fc_lines = [
            f"- {c.get('id')}（{c.get('name', '')}）：{c.get('desc', '')}" for c in forecast_caps
        ]
        user_parts.append("### 候选预测能力\n\n" + "\n".join(fc_lines))
    if existing_notes and existing_notes.strip():
        user_parts.append(
            "### 已有专项笔记（已沉淀内容）\n\n" + existing_notes.strip()
            + "\n\nnote 只输出已有笔记中没有的新要点；已覆盖的内容不要重复输出、不要改写，无新增则输出空字符串。"
            + "本次描述相对已有内容新增/改变的口径、约束、坑（哪怕细小）都属于新要点，必须输出。"
        )
    if existing and existing.strip():
        user_parts.append("请结合用户描述与已有方法说明，综合生成改进后的专项方法说明与建议关联。")
    else:
        user_parts.append("请生成专项方法说明与建议关联。")
    raw, _ = chat_completion_with_fallback(
        model=model,
        messages=[
            {"role": "system", "content": _SKILL_SYSTEM},
            {"role": "user", "content": "\n\n".join(user_parts)},
        ],
        # 交互式生成专项方法说明：保留推理 + 给足「思考 + 正文」空间（32k）提升准确度。
        # 若推理过久仍被截断，chat_completion 内部会关推理重试兜底，不会产出半截结果。
        max_tokens=INTERACTIVE_MAX_TOKENS,
    )
    data = _extract_json(raw)
    sqls = [s for s in (data.get("sqls") or []) if s in sql_names]
    docs = [d for d in (data.get("docs") or []) if d in doc_names]
    # 确定性兜底：描述中点名的工件（对完整清单匹配、不受截断影响）强制纳入，
    # 与 suggest_associations 同通道——LLM 可能把点名资产当「口径参考」而不提名
    for s in _literal_mentions(description, full_sqls):
        if s not in sqls:
            sqls.append(s)
    for d in _literal_mentions(description, full_docs):
        if d not in docs:
            docs.append(d)
    fc_ids = {c.get("id") for c in (forecast_caps or [])}
    forecast = _coerce_forecast(data.get("forecast"), fc_ids)
    content = str(data.get("content") or raw).strip()
    title = str(data.get("title") or "").strip() or extract_title(content)
    if not content.startswith("#"):
        content = f"# {title}\n\n{content}"
    # 兜底：若模型漏写「报告结构」，注入默认四层结构，保证前端能识别章节排版
    if "报告结构" not in content:
        m = re.match(r"#[^\n]*", content)
        if m:
            head = content[: m.end()]
            rest = content[m.end():].lstrip("\n")
            content = head + "\n\n" + _DEFAULT_STRUCTURE_BLOCK + ("\n\n" + rest if rest else "")
        else:
            content = _DEFAULT_STRUCTURE_BLOCK + "\n\n" + content
    # note 只接受字符串：模型偶尔输出数组（分条列点），换行 join；dict 等其它类型直接丢弃，
    # 不做 str() 强转——否则 Python repr 文本（如 "['口径A', '口径B']"）会进入笔记槽并
    # 随 existing_notes 回流提示词、随方法说明注入报告。
    note_raw = data.get("note")
    if isinstance(note_raw, list):
        note_raw = "\n".join(str(x).strip() for x in note_raw if str(x).strip())
    elif not isinstance(note_raw, str):
        note_raw = ""
    return {"title": title, "content": content, "sqls": sqls, "docs": docs, "forecast": forecast,
            "note": note_raw.strip()}


def extract_binding(content: str) -> dict[str, dict]:
    """从专项方法说明的「绑定对照表」解析 {SQL文件名: {step, section}}。

    表头约定「报告章节 | 步骤名（= 图表名）| 绑定 SQL 文件名 | 粒度 | 关键输出列」，
    取第 1/2/3 列作为 section/step/sql（SQL 文件名统一补 .sql 后缀）。解析不到返回
    空 dict，调用方按「不覆写」处理，保证降级安全（快照头部沿用全局默认）。
    """
    mapping: dict[str, dict] = {}
    if not content:
        return mapping
    for ln in content.splitlines():
        s = ln.strip()
        if not s.startswith("|") or not s.endswith("|"):
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        # 跳过分隔行（| --- | --- |）
        if cells and all(re.fullmatch(r":?-+:?", c) for c in cells):
            continue
        # 跳过表头行（含「报告章节」「步骤名」「绑定 SQL」等列名）
        if any("步骤名" in c or "报告章节" in c or "绑定 SQL" in c for c in cells):
            continue
        if len(cells) < 3:
            continue
        section = cells[0].strip("`*").strip()
        step = cells[1].strip("`*").strip()
        sql = cells[2].strip("`*").strip()
        if not sql:
            continue
        if not sql.lower().endswith(".sql"):
            sql += ".sql"
        mapping[sql] = {"step": step, "section": section}
    return mapping


_ASSOC_SYSTEM = (
    "你是资深游戏数据分析方法专家。下面会给你一段用户描述（想分析什么、怎么分析），"
    "以及一份候选清单（SQL 文件名 + 头部注释、知识库文档名、预测能力）。"
    "请只输出一个 JSON 对象，键名固定为："
    "sqls（与描述直接相关的 SQL 文件名数组，必须是候选清单里的真实文件名）、"
    "docs（与描述直接相关的知识库文档名数组，必须是候选清单里的真实文档名）、"
    "forecast（绑定的预测能力 id 或 null）。"
    "描述中点名写出的 SQL 文件/文档（如「复用《买量投放KPI》资产」「口径见《指标口径说明》」）"
    "必须视为直接相关并列入 sqls/docs。"
    "不要输出 JSON 以外的任何内容。"
)


def suggest_associations(
    model: str,
    description: str,
    sql_names: list[str],
    doc_names: list[str],
    forecast_caps: list[dict] | None = None,
    existing_sqls: list[str] | None = None,
    existing_docs: list[str] | None = None,
) -> dict:
    """据描述就地建议关联（不改方法说明）。返回 {sqls, docs, forecast}。"""
    # 截断前先留完整清单：点名匹配走全量、不受候选 top-N 截断影响
    full_sqls = list(sql_names)
    full_docs = list(doc_names)
    sql_names, doc_names = _retrieval_candidates(description, sql_names, doc_names)
    user_parts = ["### 用户描述\n\n" + (description or "").strip()]
    sql_lines = []
    for n in sql_names:
        brief = _sql_brief(sql_store.read_sql(n))
        sql_lines.append(f"- {n}" + (f"：{brief.replace(chr(10), '；')}" if brief else ""))
    user_parts.append(
        "### 候选取数代码（SQL 文件名 + 头部注释）\n\n" + ("\n".join(sql_lines) if sql_lines else "（无）")
    )
    user_parts.append(
        "### 候选知识库文档\n\n" + ("\n".join("- " + n for n in doc_names) if doc_names else "（无）")
    )
    if forecast_caps:
        fc_lines = [f"- {c.get('id')}（{c.get('name', '')}）：{c.get('desc', '')}" for c in forecast_caps]
        user_parts.append("### 候选预测能力\n\n" + "\n".join(fc_lines))
    if existing_sqls or existing_docs:
        existing_sql = "、".join(existing_sqls or []) or "无"
        existing_doc = "、".join(existing_docs or []) or "无"
        user_parts.append("### 已有选择（自动关联只增不减：以下将全部保留，可在此基础上补充）\n\n已有 SQL：" + existing_sql + "\n已有文档：" + existing_doc)
    user_parts.append("请输出建议关联 JSON。")
    raw, _ = chat_completion_with_fallback(
        model=model,
        messages=[
            {"role": "system", "content": _ASSOC_SYSTEM},
            {"role": "user", "content": "\n\n".join(user_parts)},
        ],
        # 同 summarize_skill：主动关推理 + 给足正文空间，推理模型空返回时兜底到
        # ai_client._FALLBACK_MODEL（deepseek-v4-pro）（审计 P2-14：兜底模型早已从 flash 升级为 pro）。
        max_tokens=16384,
        **reasoning_off(model),
    )
    data = _extract_json(raw)
    sqls = [s for s in (data.get("sqls") or []) if s in sql_names]
    docs = [d for d in (data.get("docs") or []) if d in doc_names]
    # 描述中点名写出的 SQL/文档（对完整清单匹配、不受候选截断影响）强制纳入。
    # 用户「专项里写了指定的 SQL 就应该关联上」的确定性通道：LLM 常把点名资产
    # 当「口径参考」而不提名——2026-10-26 投放效果分析《买量投放KPI》自动关联不到。
    for s in _literal_mentions(description, full_sqls):
        if s not in sqls:
            sqls.append(s)
    for d in _literal_mentions(description, full_docs):
        if d not in docs:
            docs.append(d)
    fc_ids = {c.get("id") for c in (forecast_caps or [])}
    forecast = _coerce_forecast(data.get("forecast"), fc_ids)
    # 自动关联只增不减（人治）：已有绑定全部保留，候选集外/LLM 未提名的也不丢。
    # 否则前端用返回结果整体替换 meta.sqls 保存时，专项内嵌快照绑定（源不在全局
    # SQL 库的融合导入 SQL 等）会被静默清掉——2026-10-21「投放效果分析」9 个内嵌
    # SQL 绑定被自动关联整体刷掉事件。要移除绑定只能走手动关联弹窗。
    for s in (existing_sqls or []):
        if s not in sqls:
            sqls.append(s)
    for d in (existing_docs or []):
        if d not in docs:
            docs.append(d)
    return {"sqls": sqls, "docs": docs, "forecast": forecast}


"""自然语言 → 只读 SQL 生成。

复用 analysis/sql_rewriter 里的 extract_sql（解析 code fence）与 validate_sql（只读校验）。
与 sql_rewriter 的区别：这里没有「原始 SQL」，而是依据表结构 + 用户问题从零生成查询。
"""
from analysis.ai_client import chat_completion_with_fallback, INTERACTIVE_MAX_TOKENS
from analysis.prompts import frame_ref
from analysis.sql_rewriter import extract_sql, validate_sql

_SYSTEM_PROMPT = """你是资深数据仓库 SQL 专家，精通 StarRocks / MySQL 语法。
用户会给一份数据库表结构（库、表、字段）和一个自然语言问题。你的任务：
1. 根据表结构，编写一条能回答该问题的只读 SELECT 查询；
2. 表名/字段名必须严格使用结构里给出的真实名称，不要臆造；引用表时写全限定名 `库名.表名`；库名是 `pf_<产品代码>` 形式，直接沿用表结构里给出的库名即可，执行时系统会按用户当前选择的游戏自动替换库名，不要自行改成其他游戏的库名；
3. 涉及时间范围时默认分析最近 7 天，用 `date >= date_sub(current_date(), interval 7 day) AND date < current_date()` 或等价的相对范围；日期范围必须写成相对时间表达式（current_date()/now()），严禁硬编码具体日期字面量（如 `date >= '2026-07-01'`、`date between 20260701 and 20260801`）——日期要能被专项/对话动态调整；`{开始日期}`/`{结束日期}` 占位符仅预测取数 SQL 使用，普通取数 SQL 不要使用；
4. 只输出【一条】完整可执行的 SQL，包在 markdown 代码块里：
```sql
...完整 SQL...
```
5. 不得使用 INSERT / UPDATE / DELETE / DROP / ALTER / TRUNCATE / CREATE / GRANT / CALL / REPLACE / MERGE 等写语句。
6. 在 SQL 代码块最前面输出结构化头部注释（每行以 `-- ` 开头），供系统识别用途与默认展示方式，格式固定为：
-- ============================================================
-- 【步骤名】<简短名称，即图表名>
-- 【归属章节】<所属报告章节，如 📊 概览 / 🔍 明细下钻 / 🔮 预测>
-- 【粒度】<日/周/月，或维度>
-- 【输出列】<逗号分隔的关键输出列名>
-- 【图表】折线|柱状|堆叠柱状|饼图|表格（五选一，时间序列默认折线，占比/构成默认饼图，分周/分维度对比用柱状或堆叠柱状）
-- 【右轴】<需放右轴的数值列名，逗号分隔；无则省略此行>
-- 【参考知识库】<实际用到的知识库文档名，逗号分隔；确实没用到则省略此行>
-- ============================================================
头部注释之后紧跟 SQL 正文。
7. 若参考了用户提供的「参考业务口径」知识库文档，必须在头部注释里用 `-- 【参考知识库】` 一行列出你实际用到的文档名（逗号分隔）；没有用到任何文档则省略该行，不要臆造。
8. 数据源路由与表名：严格服从当前项目注册表和提供的表结构。ThinkingData 项目必须使用对应的 `ta.v_event_*` 事件表及其真实字段，禁止臆造 `pf_*`、`dwd_*` 或参考公司视图；阿里云项目只能使用当前项目表结构中实际存在的 ODPS 表；本地备份只能使用已明确登记的备份文件口径，不得伪装成云端表。
9. 时区、金额和币种：严格依据当前项目真实表结构和业务口径。只使用结构中实际存在的字段；不得套用其它项目或参考资料的字段、视图、时区规则。金额输出列名必须带已确认币种后缀；无法确认时不得猜测。"""


def build_messages(
    schema_text: str, question: str, doc_texts: list[tuple[str, str]] | None = None,
    history: str | None = None, existing: str | None = None,
) -> list[dict]:
    """构造生成 SQL 的消息列表。doc_texts 为 [(文档名, 全文)]，作为业务口径参考；
    history 为已格式化的对话历史文本（供多轮追问引用上一轮 SQL/结论）；
    existing 为已有 SQL（编辑既有 SQL 时回传，供在其基础上修改完善）。"""
    parts = ["# 表结构", "", schema_text.strip()]
    if history and history.strip():
        parts += ["", history.strip()]
    parts += ["", "# 用户问题", "", question.strip()]
    if existing and existing.strip():
        parts.append(
            f"# 已有 SQL（请在其基础上修改完善：保留合理部分，按新需求调整，不要推倒重来）\n\n```sql\n{existing.strip()}\n```"
        )
    for name, text in doc_texts or []:
        if text and text.strip():
            # 知识库检索文档属外部存储内容，包防注入 framing（审计 P1-19）
            parts.append(frame_ref(f"# 参考业务口径：{name}", text))
    parts.append("请输出查询 SQL。")
    return [
        {"role": "system", "content": _SYSTEM_PROMPT},
        {"role": "user", "content": "\n\n".join(parts)},
    ]


def generate_sql(
    model: str,
    schema_text: str,
    question: str,
    doc_texts: list[tuple[str, str]] | None = None,
    history: str | None = None,
    existing: str | None = None,
) -> tuple[str, str]:
    """调用 AI 生成 SQL。返回 (SQL, AI 原始输出)；解析失败/非法时抛 ValueError。"""
    messages = build_messages(schema_text, question, doc_texts, history, existing)
    raw = chat_completion_with_fallback(model=model, messages=messages, max_tokens=INTERACTIVE_MAX_TOKENS)[0]
    sql = validate_sql(extract_sql(raw))
    return sql, raw

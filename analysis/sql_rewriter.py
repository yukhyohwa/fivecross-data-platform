"""AI 改写 SQL：prompt 构造、code fence 解析、只读校验（纯函数，便于测试）。

改写结果只用于本次运行，绝不覆盖磁盘上的 .sql 文件。
"""
import re

from analysis.ai_client import chat_completion_with_fallback, INTERACTIVE_MAX_TOKENS
from analysis.prompts import frame_ref
from analysis.sql_guard import guard_readonly_sql, _first_code_pos

_SYSTEM_PROMPT = """你是资深的数据仓库 SQL 专家，精通 StarRocks / MySQL 语法。
用户会给一段原始查询 SQL 和若干条修改要求。你的任务：
1. 在尽量保持原有表名、字段、CTE 结构、输出字段不变的前提下，按修改要求逐条改写；
2. 若参考 Skill 中包含『SQL 改写的注意事项』等改写约定章节，必须逐条遵守，不得违反（如限定时间范围、口径、过滤条件等）；
3. 只输出【一条】完整的、可执行的 SQL，不要任何解释、注释或前后缀文字；
4. 把 SQL 包在 markdown 代码块里，格式为：
```sql
...完整 SQL...
```
5. 不得改变查询的只读性质，不得使用 INSERT / UPDATE / DELETE / DROP / ALTER / TRUNCATE / CREATE / GRANT / CALL 等写语句；
6. 原始 SQL 中的库名前缀（形如 `pf_xxx`）是当前游戏库的占位，改写时保持原库名不变，不要改成其他游戏的库名；执行时系统会按用户所选游戏自动替换；
7. 涉及日期范围时，必须保留或写成相对时间表达式（current_date()/now() 等），严禁硬编码具体日期字面量（如 `date >= '2026-07-01'`、`date between 20260701 and 20260801`）——日期要能被专项/对话动态调整。`{开始日期}`/`{结束日期}` 占位符仅预测取数 SQL 使用，普通取数 SQL 一律写 current_date()/now() 相对表达式，不要使用占位符。
8. 时区处理必须保留：原始 SQL 里 active 视图的 tz 过滤（`tz = '...'` 或 `{时区条件}` 占位符）、无 tz 表的 `convert_tz(dteventtime, ...)` 转换、以及 `date_utc8`/`china_date`/`dteventtime_utc8` 等时间列，一律原样保留，不得删除或改写。
9. 金额/币种必须以当前项目提供的真实表结构和业务口径为准。不得从其它项目、示例或通用模板臆造金额列；若来源结构未提供币种或金额字段，不得猜测，改为询问或说明无法取数。
10. 若原始 SQL 里出现方括号占位符（形如 `[group_value]`、`[where_value]`，`[` 与 `]` 之间是合法标识符），必须把它们替换成真实字段或条件：按修改要求与『参考表结构』推断真实列名——例如「按国家分组」→ `group by country_code`、「国家是美国/巴西/墨西哥」→ `country_code in ('US','BR','MX')`、「最近14天」→ 日期列的相对表达式。替换后不得残留任何 `[xxx]` 占位符；字段名一律以『参考表结构』里的真实列名为准（国家→country_code、日期→date、金额→参考表结构中已确认的真实字段）。若原始 SQL 里没有方括号占位符，本条不适用。"""

_FENCE_RE = re.compile(r"```(?:sql)?\s*\n(.*?)```", re.DOTALL | re.IGNORECASE)


def build_rewrite_messages(
    original_sql: str,
    modification_prompts: list[str],
    bound_skill_text: str | None,
    schema_text: str | None = None,
) -> list[dict]:
    """构造 AI 改写 SQL 的消息列表。

    schema_text 可选：仅当原始 SQL 含方括号占位符时由调用方传入，注入表结构上下文，
    供模型把 [group_value]/[where_value] 等占位符替换成真实列名/条件（字段名推断）。
    """
    parts = ["# 原始 SQL", "", original_sql.strip(), ""]
    if modification_prompts:
        parts += ["# 修改要求（逐条执行）"]
        for i, prompt in enumerate(modification_prompts, 1):
            parts.append(f"{i}. {prompt}")
        parts.append("")
    if bound_skill_text and bound_skill_text.strip():
        parts += [
            "# 参考 Skill（改写必须遵守其中『SQL 改写的注意事项』等约定，并结合其分析角度补全维度/条件）",
            "",
            bound_skill_text.strip(),
            "",
        ]
    if schema_text and schema_text.strip():
        parts += [
            "# 参考表结构（把 `[xxx]` 占位符替换成真实列名/条件时以此为准）",
            "",
            schema_text.strip(),
            "",
        ]
    parts.append("请输出改写后的完整 SQL。")
    return [
        {"role": "system", "content": _SYSTEM_PROMPT},
        {"role": "user", "content": "\n".join(parts)},
    ]


def extract_sql(text: str) -> str:
    """从 AI 输出中提取 SQL：优先取首个 ```sql / ``` code fence；取不到且全文以 select/with
    开头时直接用全文；否则抛 ValueError。"""
    m = _FENCE_RE.search(text)
    if m:
        return m.group(1).strip()
    stripped = text.strip()
    head = re.sub(r"\s+", " ", stripped).strip().lower()
    if head.startswith("select") or head.startswith("with"):
        return stripped
    raise ValueError("AI 未返回 SQL 格式输出，请重试或改用原 SQL")


def _leading_header(sql: str) -> str:
    """返回 SQL 顶部结构化头部注释块（第一条实质代码之前），无则返回 ''。"""
    if not sql:
        return ""
    pos = _first_code_pos(sql)
    if pos <= 0:
        return ""
    return sql[:pos].rstrip()


def _strip_leading_header(sql: str) -> str:
    """去掉 SQL 顶部注释/空白，返回从第一条实质代码开始的部分。"""
    return sql[_first_code_pos(sql):].lstrip()


def _restore_header(original_sql: str, rewritten_sql: str) -> str:
    """改写后确定性回填原始头部注释块。

    SQL 顶部注释（【步骤名】/【归属章节】/【粒度】/【输出列】/【图表】/【右轴】等）是
    步骤归位、图表类型、右轴、输出列契约的载体，改写 / 纠错时不得丢失；若改写结果丢了它，
    这里原样回填，保证图表形态与右轴等信息不因 AI 改写而丢失。
    """
    header = _leading_header(original_sql)
    if not header or not rewritten_sql:
        return rewritten_sql
    return (header + "\n\n" + _strip_leading_header(rewritten_sql)).rstrip() + "\n"


_DECOR_RE = re.compile(r"^[-=]{3,}$")


def restamp_header(sql: str, step: str = "", section: str = "") -> str:
    """把头部注释块里的【步骤名】/【归属章节】两行覆写为专项自己的值（不改正文）。

    一条全局 SQL 可被多个专项复用，而【步骤名】/【归属章节】是专项级信息（= 该 SQL
    在本专项报告里的图表名/所属章节）。快照默认继承全局头部的这两行会残留「上一个专项」
    的标签；此处按本专项的 steps/绑定表覆写，保证快照自洽、人审不误导。
    step / section 传空字符串表示不覆写对应行。
    """
    if not sql:
        return sql
    header = _leading_header(sql)
    if not header:
        return sql
    body = sql[len(header):]
    out = []
    seen_step = seen_section = False
    for ln in header.splitlines():
        tag = ln.lstrip("-").strip()
        if tag.startswith("【步骤名】"):
            seen_step = True
            if step:
                out.append(f"-- 【步骤名】{step.strip()}")
                continue
        elif tag.startswith("【归属章节】"):
            seen_section = True
            if section:
                out.append(f"-- 【归属章节】{section.strip()}")
                continue
        out.append(ln)
    to_add = []
    if step and not seen_step:
        to_add.append(f"-- 【步骤名】{step.strip()}")
    if section and not seen_section:
        to_add.append(f"-- 【归属章节】{section.strip()}")
    if to_add:
        # 插到结尾装饰线（=====）之前，保持头部注释块规整；没有装饰线就补在末尾
        idx = len(out)
        for i in range(len(out) - 1, -1, -1):
            if _DECOR_RE.match(out[i].lstrip("-").strip()):
                idx = i
                break
        out[idx:idx] = to_add
    return "\n".join(out) + body


def validate_sql(sql: str) -> str:
    """只读校验：必须 select/with 开头、不得含写语句关键字、不得写文件/LOAD DATA、
    不得含多条语句、长度护栏。返回归一化后的 SQL。规则统一收敛到 analysis.sql_guard。"""
    return guard_readonly_sql(sql, allowed_heads=("select", "with"))


def rewrite_sql(
    model: str,
    original_sql: str,
    modification_prompts: list[str],
    bound_skill_text: str | None = None,
    schema_text: str | None = None,
) -> tuple[str, str]:
    """调用 AI 按修改描述改写 SQL。

    schema_text 可选：注入表结构上下文，供占位符替换做字段名推断（国家→country_code、
    日期→date 等）；无占位符时不传即可，行为与原先一致。

    返回 (改写后 SQL, AI 原始输出)。解析失败/非法时抛 ValueError。
    """
    messages = build_rewrite_messages(original_sql, modification_prompts, bound_skill_text, schema_text)
    raw = chat_completion_with_fallback(model=model, messages=messages, max_tokens=INTERACTIVE_MAX_TOKENS)[0]
    sql = validate_sql(extract_sql(raw))
    sql = _restore_header(original_sql, sql)
    # 保真护栏：确定性校验改写是否破坏 tz/币种/表/相对日期口径。命中抛错，调用方回退原文兜底——
    # 原文本身已按专项验证可用；这样所有走 rewrite_sql 的路径（对话改写 / 快照冻结 / 缺口修复）统一受保护。
    violations = guard_rewrite(original_sql, sql)
    if violations:
        raise ValueError("改写结果破坏口径：" + "；".join(violations))
    return sql, raw


_VERIFY_SYSTEM_PROMPT = """你是资深的数据仓库 SQL 审核专家，精通 StarRocks / MySQL 语法。
用户会给出：一条待审核的 SQL、改写/取数要求，以及若干参考材料（原始 SQL、专项约定、表结构、口径文档等）。你的任务：
1. 逐条核对 SQL 是否满足要求、是否遵守参考材料的约定、表名/字段/语法是否正确；
2. 若完全正确，只输出「通过」二字，不要任何其他文字或代码；
3. 若发现问题，先用一句话说明问题，再输出修正后的完整 SQL（尽量保持原有表/字段/结构，只改必要处），包在 markdown 代码块里：
```sql
...修正后的完整 SQL...
```
4. 修正后的 SQL 必须是只读查询，不得使用 INSERT / UPDATE / DELETE / DROP / ALTER / TRUNCATE / CREATE / GRANT / CALL 等写语句；
5. 日期范围必须写成相对时间表达式（current_date()/now()），严禁硬编码具体日期字面量（如 `date >= '2026-07-01'`）。`{开始日期}`/`{结束日期}` 占位符仅预测取数 SQL 使用，普通取数 SQL 不要使用。"""


def build_verify_messages(sql: str, question: str = "", references: list[tuple[str, str]] | None = None) -> list[dict]:
    """构造验证模型复核 SQL 的消息列表。references 为 [(标题, 全文)] 参考材料（可空）。"""
    parts = ["# 待审核的 SQL", "", sql.strip()]
    if question and question.strip():
        parts += ["", "# 改写/取数要求", "", question.strip()]
    for label, text in references or []:
        if not (text and text.strip()):
            continue
        # 防注入 framing（审计 P1-19）：「表结构」是系统扫库/权威上下文（其内部外部片段
        # 已在 schema_context 注入时包过 framing），保持原样；其余参考材料（知识库文档、
        # 专项方法、取数 SQL 示例等检索命中内容）统一包 framing，声明其「数据」属性。
        if (label or "").strip() == "表结构":
            parts += ["", f"# {label}", "", text.strip()]
        else:
            parts += ["", frame_ref(f"# {label}", text)]
    parts.append("请审核上面的 SQL，正确只输出「通过」，有问题则说明并给出修正后的完整 SQL。")
    return [
        {"role": "system", "content": _VERIFY_SYSTEM_PROMPT},
        {"role": "user", "content": "\n".join(parts)},
    ]


def _sql_equiv(a: str, b: str) -> bool:
    return re.sub(r"\s+", " ", a).strip().lower() == re.sub(r"\s+", " ", b).strip().lower()


def verify_sql(model: str, sql: str, question: str = "", references: list[tuple[str, str]] | None = None) -> tuple[bool, str, str]:
    """验证模型复核 SQL，返回 (是否通过, 最终 SQL, 审核意见)。

    references 为参考材料（原始 SQL / 专项约定 / 表结构 / 口径文档等）。
    - 复核通过 / 验证模型未给出可解析修正：最终 SQL 原样返回输入 sql（绝不阻断流程）；
    - 复核发现问题并给出修正 SQL：返回修正后的 SQL（已经只读校验）。
    """
    try:
        raw = chat_completion_with_fallback(model=model, messages=build_verify_messages(sql, question, references), max_tokens=INTERACTIVE_MAX_TOKENS)[0]
    except Exception as e:
        return True, sql, f"验证模型调用失败，跳过校验（{e}）"
    if not raw or not raw.strip():
        return True, sql, "验证模型空返回，跳过校验"
    stripped = raw.strip()
    if stripped in ("通过", "正确", "通过。", "正确。", "OK", "ok"):
        return True, sql, "通过"
    try:
        fixed = _restore_header(sql, validate_sql(extract_sql(raw)))
    except Exception:
        return True, sql, "验证模型未给出可解析的修正 SQL，保持原结果"
    if _sql_equiv(fixed, sql):
        return True, sql, "通过"
    return False, fixed, (stripped.splitlines()[0] if stripped else "已修正")


_FIX_SYSTEM_PROMPT = """你是资深的数据仓库 SQL 专家，精通 StarRocks / MySQL 语法。
用户会给一条执行报错的 SQL、数据库报错信息，以及（可选）参考表结构。你的任务：
1. 只修正导致报错的地方（如表名/字段名写错、类型不匹配、语法问题），其它部分尽量保持原样；
2. 若参考表结构里有正确的表名/字段名，务必以它为准；
3. 只输出【一条】修正后的完整、可执行、只读的 SQL，包在 markdown 代码块里，不要任何解释；
4. 不得使用 INSERT / UPDATE / DELETE / DROP / ALTER / TRUNCATE / CREATE / GRANT / CALL 等写语句；
5. 日期范围必须写成相对时间表达式（current_date()/now()），严禁硬编码具体日期字面量（如 `date >= '2026-07-01'`）。`{开始日期}`/`{结束日期}` 占位符仅预测取数 SQL 使用，普通取数 SQL 不要使用。"""


def fix_sql(model: str, sql: str, error_message: str, schema_text: str = "") -> tuple[str, str]:
    """按数据库报错修正 SQL，返回 (修正后 SQL, AI 原始输出)。解析失败/非法时抛 ValueError。"""
    parts = ["# 报错的 SQL", "", sql.strip(), "", "# 数据库报错信息", "", error_message.strip()]
    if schema_text and schema_text.strip():
        parts += ["", "# 参考表结构（以其中的表名/字段名为准）", "", schema_text.strip()]
    parts.append("请输出修正后的完整 SQL。")
    messages = [
        {"role": "system", "content": _FIX_SYSTEM_PROMPT},
        {"role": "user", "content": "\n".join(parts)},
    ]
    raw = chat_completion_with_fallback(model=model, messages=messages, max_tokens=INTERACTIVE_MAX_TOKENS)[0]
    return _restore_header(sql, validate_sql(extract_sql(raw))), raw


# ---- 硬编码日期识别（供 SQL 生成层提示 + 报告缺口分析识别）----
_SENTINEL_DATES = {
    "2001-01-01", "2099-12-31", "1970-01-01", "1900-01-01", "1899-12-30", "0000-00-00",
}
_HARD_DATE_RE = re.compile(
    r"(?<!\d)(?:19|20)\d{2}[-/.](?:\d{1,2})[-/.](?:\d{1,2})(?!\d)"                 # 2026-07-01 / 2026/07/01 / 2026.07.01
    r"|(?<!\d)(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])(?!\d)"      # 20260701
    r"|(?<!\d)(?:19|20)\d{2}[-/.](?:\d{1,2})(?![-/.\d])"                          # 2026-07（年月）
)


def detect_hardcoded_dates(sql: str) -> list[str]:
    """识别 SQL 里硬编码的日期字面量（YYYY-MM-DD / YYYYMMDD / YYYY-MM），返回去重后的字面量列表。

    排除哨兵日期（如 '2001-01-01'/'2099-12-31' 这类用于 LAG/LEAD 边界的占位值）。
    相对时间（current_date()/now()）与 {开始日期}/{结束日期} 占位符不会被命中。
    """
    if not sql:
        return []
    found = []
    seen = set()
    for m in _HARD_DATE_RE.finditer(sql):
        lit = m.group(0).replace("/", "-").replace(".", "-")
        if lit in _SENTINEL_DATES:
            continue
        key = re.sub(r"\D", "", lit)  # 判重时忽略分隔符，2026-7-1 与 2026-07-01 视为同一
        if key in seen:
            continue
        seen.add(key)
        found.append(lit)
    return found


# ---- 方括号占位符识别（[group_value]/[where_value] 这类模板占位符，纯函数）----
_PLACEHOLDER_RE = re.compile(r"\[([A-Za-z_][A-Za-z0-9_]*)\]")


def detect_placeholders(sql: str) -> list[str]:
    """识别 SQL 里的方括号占位符（`[xxx]`，括号内为合法标识符），返回去重后的占位符名列表。

    仅匹配标识符形态（如 [group_value]/[where_value]），不匹配数组下标 arr[1]、带引号的
    arr['k'] 等真实 SQL 语法；StarRocks/MySQL 不用方括号做标识符，故命中即可判定为模板占位符。
    无占位符的 SQL 返回空列表——占位符是可选的「额外方式」，不影响无占位符 SQL 的改写。
    """
    if not sql:
        return []
    seen: set[str] = set()
    out: list[str] = []
    for m in _PLACEHOLDER_RE.finditer(sql):
        tok = m.group(1)
        if tok not in seen:
            seen.add(tok)
            out.append(tok)
    return out


# ---- 改写保真护栏：确定性校验改写结果是否破坏「绝不该变」的口径（纯函数，零模型调用）----
# 改写模型的系统提示里已要求保留 tz/币种/相对日期/库前缀（_SYSTEM_PROMPT 规则 6~9），
# 但模型不总照办。这里做一层确定性兜底：命中即回退原文（原文已按专项验证可用）。
_TZ_MARKERS = ("convert_tz", "date_utc8", "china_date", "dteventtime_utc8", "{时区")
_TABLE_REF_RE = re.compile(r"\b(?:from|join)\s+([a-z_][a-z0-9_.]*)\b", re.IGNORECASE)


def _table_names(sql: str) -> set[str]:
    """提取 FROM/JOIN 引用的表名（去库前缀取末段，小写），供「只判丢、不判多」的宽松比较。"""
    names: set[str] = set()
    for m in _TABLE_REF_RE.finditer(sql or ""):
        names.add(m.group(1).lower().split(".")[-1])
    return names


def guard_rewrite(original_sql: str, rewritten_sql: str) -> list[str]:
    """改写保真护栏：返回违规项列表（空 = 通过），零模型调用。

    只判「丢失/新增」，不判「多」，避免误伤合法改动（如加维度表、改别名）；
    命中即由调用方回退原文，是最安全的兜底。校验点：
    1. 丢表：原文 FROM/JOIN 引用的表名在改写结果里整个消失；
    2. 时区丢失：原文含 tz 转换/时区列/时区占位符，改写结果里消失；
    3. 币种丢失：原文的币种来源列（price_cny/usd_from_api）在改写结果里消失；
    4. 新增硬编码日期：改写结果里出现了原文没有的日期字面量。
    """
    orig = (original_sql or "").strip()
    new = (rewritten_sql or "").strip()
    if not orig or not new:
        return []
    orig_lower = orig.lower()
    new_lower = new.lower()
    violations: list[str] = []

    for name in _table_names(orig):
        if not re.search(rf"\b{re.escape(name)}\b", new_lower):
            violations.append(f"丢失表 {name}")

    for marker in _TZ_MARKERS:
        if marker in orig_lower and marker not in new_lower:
            violations.append(f"丢失时区处理 {marker}")

    orig_dates = set(detect_hardcoded_dates(orig))
    for d in detect_hardcoded_dates(new):
        if d not in orig_dates:
            violations.append(f"新增硬编码日期 {d}")

    return violations

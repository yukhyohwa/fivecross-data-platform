"""算法模型 agent：AI 生成可执行预测/算法模型代码 + 静态安全预检。

生成产物是「预测能力模块」，人审后才落盘并动态注册进 forecast.PREDICTION_CAPABILITIES：
- 固定签名 `def run(df_hist: pd.DataFrame, pred_end, **params) -> dict`，返回
  `{"tables": [{"name","df","display"}], "meta": {...}}`（与 forecast.py 内置能力一致）；
- 输入列以绑定 SQL 的头部注释 + 知识库口径文档为准，不臆造；
- 只允许导入白名单库，禁文件/网络/进程/eval/exec —— precheck_code 静态校验。

安全边界：generate_model 只产出文本，不落盘、不执行；落盘由 routers/models.py 在
precheck_code 通过后经人审确认才 write_code。
"""
from __future__ import annotations

import ast
import json
import re

from . import knowledge_store, sql_store, sql_rewriter
from .ai_client import chat_completion_with_fallback, reasoning_off, INTERACTIVE_MAX_TOKENS, structured_json
from .artifact import sql_header_comment
from .snapshot import fingerprint

# 允许导入的顶层模块（纯计算/数据处理）；time 为纯时钟/日期标准库，
# datetime.date.today() / pd.Timestamp(datetime.date) 会传递依赖 import time。
_ALLOWED_IMPORTS = {"numpy", "pandas", "math", "datetime", "json", "re", "time"}
# 禁止使用/访问的内置名（即便不 import 也能逃逸沙箱）
_BANNED_BUILTINS = {
    "open", "eval", "exec", "compile", "__import__", "input", "breakpoint",
    "globals", "locals", "vars", "memoryview", "getattr", "setattr", "delattr",
    "hasattr", "type", "object", "super", "classmethod", "staticmethod", "__builtins__",
}
# 禁止访问的属性/方法名：封死经 numpy/pandas 内部对象逃逸（如 pd.io.common.os）与文件 IO
# （pd.read_csv / pd.read_pickle / np.load / json.load …）。纯计算方法（to_datetime/to_numeric/json.loads）不在内。
_BANNED_ATTRS = {
    # 经第三方库内部可达的逃逸模块名
    "os", "sys", "subprocess", "shutil", "pathlib", "pickle", "socket", "ctypes",
    "importlib", "builtins", "marshal", "requests", "urllib", "http", "ftplib",
    "multiprocessing", "threading", "resource", "platform", "inspect", "base64",
    # pandas / numpy 文件 IO 与代码执行
    "read_pickle", "read_csv", "read_excel", "read_html", "read_json", "read_hdf",
    "read_feather", "read_parquet", "read_orc", "read_stata", "read_sas", "read_sql",
    "read_sql_query", "read_sql_table", "read_gbq", "read_fwf", "read_clipboard",
    "to_pickle", "to_csv", "to_excel", "to_json", "to_hdf", "to_feather", "to_parquet",
    "to_sql", "to_gbq", "to_clipboard", "to_html", "to_latex", "to_markdown", "to_stata",
    "load", "save", "savez", "savetxt", "loadtxt", "genfromtxt", "fromfile", "tofile",
    "dump",
}

_FENCE_RE = re.compile(r"```(?:python|py)?\s*\n(.*?)```", re.DOTALL | re.IGNORECASE)


def precheck_code(code: str) -> list[str]:
    """静态安全预检：返回违规项列表（空 = 通过）。只做静态分析，不执行代码。"""
    if not (code or "").strip():
        return ["代码为空"]
    try:
        tree = ast.parse(code)
    except SyntaxError as exc:
        return [f"代码语法错误：{exc}"]

    problems: list[str] = []

    # 1) 必须定义顶层 run(df_hist, pred_end, ...)
    has_run = False
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == "run":
            args = [a.arg for a in node.args.args]
            if len(args) >= 2 and args[0] == "df_hist":
                has_run = True
    if not has_run:
        problems.append("缺少固定签名 def run(df_hist, pred_end, **params) -> dict")

    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                if a.name.split(".")[0] not in _ALLOWED_IMPORTS:
                    problems.append(f"禁止导入模块：{a.name}")
        elif isinstance(node, ast.ImportFrom):
            if node.level == 0:
                mod_root = (node.module or "").split(".")[0]
                if mod_root not in _ALLOWED_IMPORTS:
                    problems.append(f"禁止导入模块：{node.module}")
                else:
                    # 顶层模块虽在白名单，导入的具体符号也必须安全：
                    # `from pandas import read_csv` / `from numpy import load` 会把危险符号
                    # 直接变成普通名字（绕过下方 ast.Attribute 检查），须在此拦。
                    for a in node.names:
                        if a.name == "*":
                            problems.append(f"禁止星号导入：from {node.module} import *")
                        elif a.name.startswith("__") or a.name in _BANNED_ATTRS:
                            problems.append(f"禁止导入符号：{node.module}.{a.name}")
            else:
                problems.append(f"禁止相对导入：{node.module}")
        elif isinstance(node, ast.Name):
            if node.id in _BANNED_BUILTINS:
                problems.append(f"禁止使用内置名：{node.id}")
        elif isinstance(node, ast.Attribute):
            if node.attr.startswith("__"):
                problems.append(f"禁止访问双下划线属性：.{node.attr}")
            elif node.attr in _BANNED_ATTRS:
                problems.append(f"禁止访问属性：.{node.attr}")

    # 去重保序
    seen: set[str] = set()
    out: list[str] = []
    for p in problems:
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out


def _extract_code(text: str) -> str:
    m = _FENCE_RE.search(text or "")
    if m:
        return m.group(1).strip()
    stripped = (text or "").strip()
    if stripped.startswith(("def ", "import ", "from ")):
        return stripped
    raise ValueError("AI 未返回 Python 代码块，请重试")


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


_TRANSFORM_SYSTEM = """你是资深的数据仓库 SQL 专家。用户会给一段算法模型的需求描述、模型代码，以及若干绑定取数 SQL 的全文。你要判断：每条绑定 SQL 是否需要「为这个模型改造」成专属取数 SQL。

需要改造的情形：原 SQL 的输出列/粒度/时间范围不能直接喂给模型（缺模型需要的输入列、粒度不一致、时间窗口不匹配、需要额外维度或过滤等）。不需要改造时，模型可直接复用原 SQL。

只输出一个 JSON 对象，键为 SQL 名，值为：
- null：无需改造；
- 字符串：一段明确的改造要求（模型需要的输入列、粒度、时间窗口、过滤条件等）。
不要输出 JSON 以外的内容。"""


def transform_bound_sqls(
    model: str,
    description: str,
    code: str,
    bound_sql_names: list[str],
    doc_names: list[str] | None = None,
) -> dict[str, str | None]:
    """判断每条绑定取数 SQL 是否需为模型改造，需要则生成该模型的专属修改 SQL。

    返回 {sql名: 改造后 SQL | None}；None = 无需改造（直接用原取数 SQL）。
    单条判断/改写失败时回退 None，绝不阻断模型生成。
    """
    names = [n for n in (bound_sql_names or []) if n]
    if not names:
        return {}
    sql_texts = {n: sql_store.read_sql(n) for n in names}

    parts = ["# 模型需求描述\n\n" + (description or "").strip()]
    parts.append("# 模型代码\n\n```python\n" + (code or "").strip() + "\n```")
    for n in names:
        parts.append(f"# 绑定取数 SQL：{n}\n\n```sql\n" + (sql_texts[n] or "").strip() + "\n```")
    parts.append("请判断每条绑定 SQL 是否需要为模型改造，并输出 JSON。")

    try:
        raw = structured_json(
            model=model,
            system=_TRANSFORM_SYSTEM,
            user_content="\n\n".join(parts),
        )
    except Exception:
        return {n: None for n in names}
    decision = _extract_json(raw)

    out: dict[str, str | None] = {}
    for n in names:
        req = decision.get(n)
        if not req or not sql_texts[n].strip():
            out[n] = None
            continue
        try:
            sql, _ = sql_rewriter.rewrite_sql(model, sql_texts[n], [str(req)])
            out[n] = sql
        except Exception:
            out[n] = None
    return out


_MODEL_SYSTEM = """你是资深的数据科学 / 预测建模专家。用户会给：一段模型需求描述、若干绑定取数 SQL 的头部注释（说明输入列与粒度）、若干知识库口径文档。请生成一个**只读、纯计算**的 Python 预测/算法模型模块，严格遵守：

1. 只定义一个顶层函数，固定签名（不要写 __main__、不要执行任何代码）：
```python
def run(df_hist, pred_end, **params):
    ...
    return {"tables": [{"name": "<表名>", "df": <DataFrame>, "display": True}], "meta": {"method": "<方法名>", ...}}
```
   - df_hist 是历史数据 DataFrame，输入列以「绑定 SQL 头部注释」列出的为准，不要臆造列名；
   - pred_end 是预测截止日期，按需使用；
   - 返回 tables 里每个 DataFrame 都是最终展示/引用数据（列名用中文清晰命名），meta 放方法名与关键参数。
2. 只允许 `import numpy / pandas / math / datetime / json / re`（或其子模块/别名），禁止任何文件读写、网络、进程、eval/exec 操作。
3. 数值口径参考「知识库口径文档」，保持可解释；不确定的假设在 meta 里注明。
4. 只输出模块源码，全部包在一个 ```python 代码块里，不要任何解释文字。"""


def generate_model(
    model: str,
    description: str,
    bound_sql_names: list[str],
    doc_names: list[str],
    existing: str = "",
) -> dict:
    """AI 生成模型代码。返回 {code, problems}（problems 为静态预检结果，仅供人审参考，不阻断生成）。"""
    parts = ["# 模型需求描述\n\n" + (description or "").strip()]
    if existing and existing.strip():
        parts.append(
            "# 已有代码（请在其基础上修改完善：保留合理部分，按新需求调整，不要推倒重来）\n\n"
            "```python\n" + existing.strip() + "\n```"
        )
    sql_lines = []
    for n in bound_sql_names:
        brief = sql_header_comment(sql_store.read_sql(n))
        sql_lines.append(f"- {n}" + (f"：{brief.replace(chr(10), '；')}" if brief else ""))
    parts.append(
        "# 绑定取数 SQL（头部注释 = 输入列/粒度/输出）\n\n"
        + ("\n".join(sql_lines) if sql_lines else "（无）")
    )
    for d in doc_names:
        doc = knowledge_store.read_doc(d)
        if doc.strip():
            parts.append(f"# 参考口径：{d}\n\n{doc.strip()}")
    parts.append("请输出模型模块源码。")
    raw, _ = chat_completion_with_fallback(
        model=model,
        messages=[
            {"role": "system", "content": _MODEL_SYSTEM},
            {"role": "user", "content": "\n\n".join(parts)},
        ],
        # 生成最长的模型 Python 代码：主动关推理防止推导占满预算、代码被截断
        # （finish_reason=length），同时给足 32k「正文」输出空间，长代码也能一次产出。
        max_tokens=INTERACTIVE_MAX_TOKENS,
        **reasoning_off(model),
    )
    code = _extract_code(raw)
    # 溯源：记录借用的绑定 SQL 与知识库文档（原样指纹），供模型页漂移检测 + 手动更新
    sources = []
    for n in bound_sql_names:
        orig = sql_store.read_sql(n)
        if orig.strip():
            sources.append({"kind": "sql", "name": n, "fingerprint": fingerprint(orig)})
    for d in doc_names:
        orig = knowledge_store.read_doc(d)
        if orig.strip():
            sources.append({"kind": "doc", "name": d, "fingerprint": fingerprint(orig)})
    transformed_sqls = transform_bound_sqls(model, description, code, bound_sql_names, doc_names)
    return {
        "code": code,
        "problems": precheck_code(code),
        "sources": sources,
        "transformed_sqls": transformed_sqls,
    }


_ASSOCIATE_SYSTEM = """你是数据仓库建模专家。用户会给一段算法模型需求描述，以及若干候选取数 SQL 的名称与头部注释（说明输入列/粒度/输出）。你要：选择最匹配的取数 SQL 作为该模型的自动取数来源，并推断模型的调度与窗口参数。

规则：
- 若描述明确是「离线上传数据」或「没有现成取数 SQL 可用」，sql 返回空串 ""。
- granularity：日粒度取 "day"，月粒度取 "month"。
- hist_days / hist_months：历史回看窗口（二选一，与粒度对应）；horizon_days / horizon_months：预测展望期（二选一）。
- desc：一句话中文显示名（模型简称）。
- 数字字段用 int；不适用用 null。

只输出一个 JSON 对象，键为 sql、granularity、hist_days、hist_months、horizon_days、horizon_months、desc。不要输出 JSON 以外的内容。"""


def associate_model(model: str, description: str, sql_names: list[str]) -> dict:
    """据描述：挑最匹配的取数 SQL + 推断调度/窗口参数。

    返回 {sql, granularity, hist_days, hist_months, horizon_days, horizon_months, desc}。
    候选为空或 AI 失败时回退安全默认，绝不抛错。
    """
    fallback = {
        "sql": "",
        "granularity": "day",
        "hist_days": None,
        "hist_months": None,
        "horizon_days": None,
        "horizon_months": None,
        "desc": (description or "").strip()[:60],
    }
    names = [n for n in (sql_names or []) if n]
    if not names:
        return fallback

    lines = []
    for n in names:
        brief = sql_header_comment(sql_store.read_sql(n))
        lines.append(f"- {n}" + (f"：{brief.replace(chr(10), '；')}" if brief else ""))
    parts = ["# 算法模型需求描述\n\n" + (description or "").strip()]
    parts.append(
        "# 候选取数 SQL（名称：头部注释 = 输入列/粒度/输出）\n\n"
        + ("\n".join(lines) if lines else "（无）")
    )
    parts.append("请选择最匹配的取数 SQL 并推断参数，输出 JSON。")

    try:
        raw = structured_json(
            model=model,
            system=_ASSOCIATE_SYSTEM,
            user_content="\n\n".join(parts),
        )
    except Exception:
        return fallback
    data = _extract_json(raw)
    if not data:
        return fallback

    out = dict(fallback)
    for key in ("sql", "granularity", "desc"):
        if isinstance(data.get(key), str):
            out[key] = data[key]
    for key in ("hist_days", "hist_months", "horizon_days", "horizon_months"):
        v = data.get(key)
        if isinstance(v, int) and v > 0:
            out[key] = v
        elif isinstance(v, (float, str)):
            try:
                num = int(v)
                if num > 0:
                    out[key] = num
            except (ValueError, TypeError):
                pass
    # sql 必须是候选之一，否则置空（防止 AI 编造 SQL 名）
    if out["sql"] and out["sql"] not in names:
        out["sql"] = ""
    return out

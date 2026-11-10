"""预测/算法能力注册表（供专项 skill 按名绑定调用）。

预测实现已「外部化」到 code/ 目录（code/<名>.py + code/<名>.py.json），本文件只保留：
- 能力注册表 PREDICTION_CAPABILITIES（初始为空，外部能力启动时动态合并进来）；
- 外部能力动态加载（load_external_capabilities / _load_model_func / load_func_from_code）；
- 预测展示粒度/展望期的确定性解析（parse_forecast_hint）；
- 展示辅助（list_capabilities / list_builtin_capabilities / is_builtin）。

【新增/修改一个算法能力】直接落 code/ 目录，无需再改本文件：
1. code/<名>.py：实现 `def run(df_hist, pred_end, **params) -> {"tables": [...], "meta": {...}}`
   （input=upload 的离线上传型可为占位实现，仅注册展示/绑定）；
2. code/<名>.py.json：注册元数据（键同能力项，去 func；level/game 为存储作用域、不并入能力项）
   - input=sql：需 sql（取数 SQL 名）+ 可加载的 run，供自动取数；
   - input=upload：无 func，运行时报「暂不支持自动取数」。

【能力项字段】
- 通用：name（中文名）、desc、input（"sql" 自动取数 | "upload" 离线上传）、func（实现函数，upload 型无）
- sql 型调度键：granularity（day|month）、sql（取数 SQL 名）、hist_days/hist_months、horizon_days/horizon_months
- 方法参数：其余键（如 window）会透传给 func

已外部化的能力：
    dau_arpu_roll        分日流水预测（滚动平均+群组留存，源自 22_线上游戏分日流水预测）
    mau_monthly_roll     分月流水预测（NUU/RUU 对数线性拟合 + OUU 留存递推，源自 12_线上游戏分月流水预测）
    prelaunch_monthly    未上线游戏分月流水预测（离线上传型占位，源自 10_未上线游戏分月流水预测）
    ltv                  LTV 预测（分日留存 × 留存ARPU 递推，源自 19_LTV预测工具 / 买量投放KPI 改写）
"""
from __future__ import annotations

import re
import types
from datetime import date, timedelta

# 预测/算法能力注册表：内置实现已外部化，初始为空；load_external_capabilities() 把 code/ 条目合并进来。
PREDICTION_CAPABILITIES: dict[str, dict] = {}


def _days_to_end_of_next_month(today: date) -> int:
    """今天到下个月最后一天（含当天）的天数，供「下个月」按日粒度推算 pred_end。"""
    y, m = today.year, today.month
    m += 1
    if m == 13:
        y, m = y + 1, 1
    nxt = date(y, m + 1, 1) if m < 12 else date(y + 1, 1, 1)
    last = nxt - timedelta(days=1)
    return (last - today).days + 1


def parse_forecast_hint(question: str) -> dict:
    """从问题里确定性解析预测的「展示粒度」与「展望期」，返回 _run_forecast 的覆盖项。

    - display_granularity：day（用户要「每天/逐日」，改展示分日表）；缺省不覆盖（保持周/月默认）。
    - horizon_days / horizon_months：明确的展望期长度；「下个月」按能力粒度各给一份。
    无法确定的键不返回（_run_forecast 用能力注册表默认值）。
    """
    q = question or ""
    hint: dict = {}

    # 展示粒度：分日能力默认展示「未来4周」，用户明确要「每天」时改展示分日表
    if re.search(r"(每\s*天|逐\s*日|按\s*日|每日|每天|日\s*维度)", q):
        hint["display_granularity"] = "day"

    m = re.search(r"(?:未来|接下来|往后|之后)\s*(\d+)\s*(天|日)", q)
    if m:
        hint["horizon_days"] = int(m.group(1))
    m = re.search(r"(?:未来|接下来|往后|之后)\s*(\d+)\s*个?\s*月", q)
    if m:
        hint["horizon_months"] = int(m.group(1))

    # 「下个月/下月」：日粒度覆盖到下个月最后一天；月粒度则下月（1 个月）
    if re.search(r"下\s*个?\s*月|下月", q):
        hint.setdefault("horizon_months", 1)
        hint.setdefault("horizon_days", _days_to_end_of_next_month(date.today()))

    # 币种：用户要美金/美元预测时覆盖为 USD（默认 CNY）
    if re.search(r"(美金|美元|美刀|\bUSD\b)", q, re.IGNORECASE):
        hint["currency"] = "USD"

    return hint


# 裸「N月/N月份」（未写年份）
_MONTH_BARE_RE = re.compile(r"(?<!\d)(\d{1,2})月(?:份)?(?!\d)")
# 显式年份（2026年/2026-2026.）或 今年/去年/明年
_YEAR_HINT_RE = re.compile(r"(?<!\d)(?:20\d{2})[-/.年]|今年|去年|明年")


def parse_forecast_period(question: str, today: date | None = None) -> dict | None:
    """检测「预测一个已发生 / 指定时间段」的请求，返回周期信息，否则 None。

    返回三类周期（由调用方决定二次确认还是直接跑）：
    - 已发生（past=True）：指定时间段起点在今天之前（预测已发生的流水，需先确认）；
    - 年份模糊（year_ambiguous=True）：裸「N月/N月份」未写年份（需与用户确认年份）；
    - 未来指定段（future=True）：明确带年份且起点在今天之后（如「2026年10月~12月」），
      无需二次确认，直接预测到 end。

    返回：
      start/end  YYYY-MM-DD；year/month；label 可读标签；
      year_ambiguous bool；past bool；future bool；years 候选年份（year_ambiguous 时前端可下拉选）。
    未解析出具体时间段（如「下个月」「未来30天」）返回 None，交给默认未来预测。
    """
    from analysis.time_range import parse_time_range

    q = (question or "").strip()
    if not q:
        return None
    today = today or date.today()

    start_s, end_s = parse_time_range(q, today)
    if not start_s:
        return None
    start = date.fromisoformat(start_s)
    end = date.fromisoformat(end_s)

    year_ambiguous = bool(_MONTH_BARE_RE.search(q) and not _YEAR_HINT_RE.search(q))
    past = start < today
    future = (not year_ambiguous) and (not past)

    month = start.month if (start.year == end.year and start.month == end.month) else None
    years = sorted({today.year, today.year - 1}, reverse=True)
    label = f"{start.year}年{start.month}月" if month else f"{start_s} 至 {end_s}"

    return {
        "start": start_s,
        "end": end_s,
        "year": start.year,
        "month": month,
        "year_ambiguous": year_ambiguous,
        "past": past,
        "future": future,
        "label": label,
        "years": years,
    }


def list_capabilities() -> list[dict]:
    """列出所有已注册能力（去掉不可序列化的 func），供文档/前端/后台展示。"""
    return [
        {"id": mid, **{k: v for k, v in cap.items() if k != "func"}}
        for mid, cap in PREDICTION_CAPABILITIES.items()
    ]


def list_builtin_capabilities() -> list[dict]:
    """仅列出内置能力（不含 code/ 外部加载），供算法模型页与外部能力区分展示。"""
    return [
        {"id": mid, **{k: v for k, v in cap.items() if k != "func"}}
        for mid, cap in PREDICTION_CAPABILITIES.items()
        if mid not in _EXTERNAL_KEYS
    ]


def is_builtin(method: str) -> bool:
    """是否内置能力（forecast.py 硬编码，非 code/ 外部加载）。内置能力不可在算法模型页删除/覆盖。"""
    return method in PREDICTION_CAPABILITIES and method not in _EXTERNAL_KEYS


def can_run_capability(method: str, game_key: str | None = None) -> bool:
    """运行时可见性闸门（审计 P0-12）：外部能力按其 meta 的 level/game/owner 校验当前
    用户/游戏；内置恒 True。

    此前运行时执行直接走全局 PREDICTION_CAPABILITIES，任何人可按名运行他人的「个人」
    模型（如聊天里直接点名触发预测），与选择面 visible_capabilities 的隔离不一致；
    _run_forecast 在解析能力后先过此闸门，个人模型不会被他人生效执行。
    """
    if method not in _EXTERNAL_KEYS:
        return True
    from analysis import code_store
    from analysis.games import visible_to, current_owner_key

    meta = code_store.read_code_meta(method) or {}
    return visible_to(meta.get("level"), meta.get("game"), game_key, meta.get("owner"), current_owner_key())


def visible_capabilities(game_key: str | None = None) -> list[dict]:
    """仅返回当前游戏/用户可见的能力（内置全可见；外部按 level/game/owner 过滤）。

    与 list_capabilities 的差别：外部（code/）能力按其 meta 的 level/game/owner 做跨游戏/跨用户隔离，
    个人模型只对归属用户可见。供「关联预测能力」下拉与 AI 生成/关联/缺口修复等选择面使用；
    运行时执行仍走全局 PREDICTION_CAPABILITIES（绑定后的专项/模型快照可直接按名运行）。
    """
    from analysis import code_store
    from analysis.games import visible_to, current_owner_key

    out: list[dict] = []
    for mid, cap in PREDICTION_CAPABILITIES.items():
        if mid not in _EXTERNAL_KEYS:
            out.append({"id": mid, **{k: v for k, v in cap.items() if k != "func"}})
            continue
        meta = code_store.read_code_meta(mid)
        if visible_to(meta.get("level"), meta.get("game"), game_key, meta.get("owner"), current_owner_key()):
            out.append({"id": mid, **{k: v for k, v in cap.items() if k != "func"}})
    return out


# ---------------------------------------------------------------------------
# 外部能力动态加载：code/<名>.py + code/<名>.py.json → 合并进 PREDICTION_CAPABILITIES
# 新增算法 = 落一个 .py（实现 run）+ 同名 .py.json（注册元数据），无需再改本文件。
# ---------------------------------------------------------------------------

# 本次启动已从 code/ 加载的外部能力键（用于 /reload 时先清理再重扫，避免删文件后残留）
_EXTERNAL_KEYS: set[str] = set()


def load_func_from_code(name: str, code: str):
    """从给定代码文本加载 run 函数（先静态预检，再受限 exec）；失败返回 None。

    供两类调用：code/ 库（_load_model_func）与专项包内冻结代码（chat._run_forecast）。
    防御性预检：未通过 model_gen.precheck_code 的一律拒绝执行。

    运行时再补一层：exec 只注入受限内置（去 open/eval/exec/__import__/getattr/type/object 等），
    import 经 _safe_import 只放行 numpy/pandas/math/datetime/json/re，其余模块直接 ImportError。
    即便静态预检漏了，运行时也拿不到任意内置与任意 import。
    """
    from analysis.model_gen import precheck_code
    try:
        if not (code or "").strip():
            return None
        if precheck_code(code):
            return None
        module = types.ModuleType(f"_model_{name}")
        module.__dict__["__builtins__"] = _SAFE_BUILTINS
        exec(compile(code, f"<model:{name}>", "exec"), module.__dict__)
        func = getattr(module, "run", None)
        return func if callable(func) else None
    except Exception:
        return None


# 仅放行的顶层导入根：模型代码只做纯计算，允许 numpy/pandas/math/datetime/json/re。
# time 为纯时钟/日期标准库（无文件/网络/进程/eval 能力），datetime.date.today() 与
# pd.Timestamp(datetime.date) 在运行时经 C 层传递 import time，不放行会导致预测报错。
_ALLOWED_IMPORT_ROOTS = {"numpy", "pandas", "math", "datetime", "json", "re", "time"}
_real_import = __import__


def _safe_import(name, globals=None, locals=None, fromlist=(), level=0):
    """受限 import：根模块不在白名单则拒绝；白名单内委托真实 __import__。"""
    root = (name or "").split(".")[0]
    if root not in _ALLOWED_IMPORT_ROOTS:
        raise ImportError(f"禁止导入模块：{name}")
    return _real_import(name, globals, locals, fromlist, level)


# 受限内置：只留纯计算/容器/异常，去掉可逃逸的 open/eval/exec/__import__/getattr/type/object/vars 等。
_SAFE_BUILTINS = {
    "__import__": _safe_import,
    "abs": abs, "all": all, "any": any, "bool": bool, "bytearray": bytearray,
    "bytes": bytes, "chr": chr, "complex": complex, "dict": dict, "divmod": divmod,
    "enumerate": enumerate, "filter": filter, "float": float, "format": format,
    "frozenset": frozenset, "hash": hash, "int": int, "isinstance": isinstance,
    "issubclass": issubclass, "iter": iter, "len": len, "list": list, "map": map,
    "max": max, "min": min, "next": next, "ord": ord, "pow": pow, "print": print,
    "property": property, "range": range, "repr": repr, "reversed": reversed,
    "round": round, "set": set, "slice": slice, "sorted": sorted, "str": str,
    "sum": sum, "tuple": tuple, "zip": zip,
    "classmethod": classmethod, "staticmethod": staticmethod,
    "Exception": Exception, "ValueError": ValueError, "TypeError": TypeError,
    "KeyError": KeyError, "IndexError": IndexError, "AttributeError": AttributeError,
    "ZeroDivisionError": ZeroDivisionError, "ArithmeticError": ArithmeticError,
    "AssertionError": AssertionError, "StopIteration": StopIteration,
    "RuntimeError": RuntimeError, "NotImplementedError": NotImplementedError,
    "ImportError": ImportError, "True": True, "False": False, "None": None,
}


def _load_model_func(name: str):
    """加载 code/<名>.py 里的 run 函数；静态预检不过、import 失败或缺 run 时返回 None。

    防御性预检：即便文件是手工放入 code/ 的，未通过 model_gen.precheck_code 也拒绝执行。
    """
    from analysis import code_store
    return load_func_from_code(name, code_store.read_code(name))


def load_external_capabilities() -> dict[str, dict]:
    """扫描 code/ 目录的外部模型能力，合并进 PREDICTION_CAPABILITIES（幂等，返回本次加载的外部能力）。

    外部能力约定：
    - code/<名>.py：实现 `def run(df_hist, pred_end, **params) -> dict`（离线上传型可为占位实现）；
    - code/<名>.py.json：注册元数据（键同能力项，去 func；level/game 为存储作用域、不并入能力项）。
      · input=sql：需 sql + 可加载的 run，注册进能力表供自动取数；
      · input=upload：注册为离线上传型（无 func），供模型页展示/绑定，运行时报「暂不支持自动取数」。
    任一条目加载失败仅跳过，不影响其它条目。
    """
    global _EXTERNAL_KEYS
    from analysis import code_store

    for key in _EXTERNAL_KEYS:
        PREDICTION_CAPABILITIES.pop(key, None)
    _EXTERNAL_KEYS = set()

    loaded: dict[str, dict] = {}
    for fname in code_store.list_code_manifests():
        bare = fname[:-3] if fname.endswith(".py") else fname
        meta = code_store.read_code_meta(bare)
        if not isinstance(meta, dict):
            continue
        entry = {k: v for k, v in meta.items() if k not in ("level", "game", "owner", "func")}
        if meta.get("input") == "upload":
            PREDICTION_CAPABILITIES[bare] = entry
            _EXTERNAL_KEYS.add(bare)
            loaded[bare] = entry
            continue
        if not meta.get("sql"):
            continue
        func = _load_model_func(bare)
        if func is None:
            continue
        entry["func"] = func
        PREDICTION_CAPABILITIES[bare] = entry
        _EXTERNAL_KEYS.add(bare)
        loaded[bare] = entry
    return loaded


# 模块导入即加载一次外部能力（无 code/ 条目时为空操作）
load_external_capabilities()

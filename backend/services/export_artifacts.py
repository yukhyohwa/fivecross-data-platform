# -*- coding: utf-8 -*-
"""xlsx/csv 交付层（JoyTools 迁移）：把一组已算好的表格式结果写成一个产物文件。

移植自 streamlit/common/joytools/services/export/（deliver.py / formats.py / contracts.py /
naming.py），按 data_ai 的需要瘦身：输入从 pandas DataFrame 换成普通 dict sheet
（ResultStore 里 query_database 的 columns/rows 已是 JSON 安全值，不需要 pandas 参与）。

公式样式文本（= + - @ 开头）与源同口径，不改变交付数据：xlsx 由
strings_to_formulas=False 保证原样写入（不加撇号前缀），CSV 保留原始文本、
检测到公式样式文本时在信封加 caveat（formats.csv_has_formula_text / deliver caveat 移植）。

**安全不变量（本模块的契约）：**
- 本模块吃「已过只读闸门的数据」——即 ResultStore 里的 query_database 执行结果
  （columns + rows），不执行任何 SQL、不接收任何 SQL 文本；
- 只依赖标准库 + xlsxwriter，不 import pandas / 业务模块；
- 产物只落在 EXPORT_ROOT/<owner_key>/ 下，owner_key 由调用方（agent_tools）给出，
  下载端点（routers/agent.py）按同一归属键查找，调用方无从指定任意路径。
"""
from __future__ import annotations

import csv
import io
import json
import math
import os
import re
import time
import uuid
from concurrent import futures
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Context, Decimal
from pathlib import Path

import xlsxwriter

# ---- 产物根与命名 ----
# data_ai/runtime/exports（backend/services/export_artifacts.py 上两级 = data_ai 根）
EXPORT_ROOT = Path(__file__).resolve().parents[2] / "runtime" / "exports"
DOWNLOAD_URL_PREFIX = "/api/agent/artifacts/"
MIME_BY_FORMAT = {
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "csv": "text/csv",
    "sql": "text/plain",
    "txt": "text/plain",
}

# Windows 禁用的字符 + 控制字符（Linux 允许，但产物可能被拷回 Windows 打开），
# 移植自 joytools naming.sanitize。
_NAME_ILLEGAL = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
MAX_NAME_CHARS = 80
FALLBACK_SUBJECT = "取数结果"
_TIMESTAMP_FORMAT = "%Y%m%d_%H%M%S"

# 工作表名清洗（Excel 限制）：≤31 字符，[]:*?/\ 替换为 _（表名常含「19:00~22:00」这类时段）。
SHEET_NAME_LIMIT = 31
_SHEET_ILLEGAL = re.compile(r"[\[\]:*?/\\]")

# ---- 容量双闸（行数 + 格数，两条都要过）----
# 数值沿用 joytools 在同配置服务器上的实测标定（contracts.py）：xlsx 10 万行 / 100 万格，
# csv 20 万行 / 1000 万格，两种格式按「约 8 秒写入代价」定口径；可再实测调。
# 只卡行数会漏判窄表、只卡格数会漏判宽表，所以必须双闸。
XLSX_MAX_ROWS = 100_000
XLSX_MAX_CELLS = 1_000_000
CSV_MAX_ROWS = 200_000
CSV_MAX_CELLS = 10_000_000


@dataclass(frozen=True)
class _Budget:
    rows: int
    cells: int


BUDGETS = {
    "xlsx": _Budget(rows=XLSX_MAX_ROWS, cells=XLSX_MAX_CELLS),
    "csv": _Budget(rows=CSV_MAX_ROWS, cells=CSV_MAX_CELLS),
}

# ---- TTL 惰性清扫 ----
_TTL_SECONDS = 24 * 3600
_SWEEP_SCAN_LIMIT = 200   # 每目录最多扫 200 个条目防拖慢
_SWEEP_DELETE_MAX = 50    # 超过 200 个时只处理最旧的 50 个

# ---- 精度防丢 ----
# Excel 只存 15 位有效数字；|int| ≥ 1e15 写成数值会丢位，改文本（formats.py 移植）。
_EXCEL_INT_THRESHOLD = 10 ** 15
# xlsxwriter 对超长字符串只打警告并静默截断（不抛异常），32767 上限必须自己预检。
EXCEL_MAX_TEXT_CHARS = 32_767
EXCEL_MAX_ROWS = 1_048_576
EXCEL_MAX_COLUMNS = 16_384
_CENT = Decimal("0.01")
_DECIMAL_CONTEXT = Context(prec=60)
# 公式样式文本前缀：= + - @ 在电子表格软件里会被当公式执行。xlsx 由
# strings_to_formulas=False 挡住；csv 保留原文、检测到后在信封加 caveat。
_FORMULA_PREFIXES = ("=", "+", "-", "@")
_WRITER_OPTIONS = {"strings_to_formulas": False, "strings_to_urls": False, "in_memory": True}

# xlsx 写入超时（秒）：线程池只是让 GIL 在切换间有机会调度别的线程，不是提速手段。
_XLSX_TIMEOUT = 120

_OWNER_ILLEGAL = re.compile(r"[^A-Za-z0-9_-]")


def sanitize_owner(owner) -> str:
    """把用户归属键削成安全目录名（防路径穿越）；空值兜底 anonymous。"""
    return _OWNER_ILLEGAL.sub("_", str(owner or "")) or "anonymous"


def _sheet_base(name: str) -> str:
    # 首尾的单引号 Excel 也不收。
    cleaned = _SHEET_ILLEGAL.sub("_", str(name)).strip("'")
    return cleaned[:SHEET_NAME_LIMIT].strip("'") or "Sheet1"


def _unique_sheet_names(names) -> list[str]:
    """截断后按 Excel 大小写不敏感规则去重；重名加 (2)/(3)… 后缀。"""
    used: set[str] = set()
    output: list[str] = []
    for original in names:
        base = _sheet_base(original)
        name, number = base, 1
        while name.casefold() in used:
            number += 1
            suffix = f"({number})"
            name = base[:SHEET_NAME_LIMIT - len(suffix)] + suffix
        used.add(name.casefold())
        output.append(name)
    return output


def _sanitize_stem(subject: str) -> str:
    """把 subject 削成可在 Windows/Linux 落地的文件名主干（naming.sanitize 移植）。"""
    cleaned = _NAME_ILLEGAL.sub("_", (subject or "").strip())
    # 先截断再去尾，否则截断后可能又露出结尾空格或点。
    return cleaned[:MAX_NAME_CHARS].rstrip(" .")


def _artifact_filename(subject: str, fmt: str) -> str:
    """`{清洗后主干}_{时间戳}.{后缀}`；subject 为空用「取数结果」。"""
    slug = _sanitize_stem(subject) or FALLBACK_SUBJECT
    stamp = time.strftime(_TIMESTAMP_FORMAT)
    return f"{slug}_{stamp}.{fmt}"


# ---- 精度防丢三规则（写单元格前逐值处理）----

def _is_numeric_kind(value) -> bool:
    """数值类单元格：bool/int/float/Decimal 都算（Excel 里都参与 SUM）。"""
    return isinstance(value, (bool, int, float, Decimal))


def _mixed_columns(rows: list, width: int) -> list[bool]:
    """③ 同列混型检测：数值与文本混杂的列整列转文本，防 Excel SUM 静默跳过文本格。"""
    flags = []
    for idx in range(width):
        has_num = has_text = False
        for row in rows:
            if idx >= len(row):
                continue
            value = row[idx]
            if value is None:
                continue
            if isinstance(value, float) and math.isnan(value):
                continue
            if _is_numeric_kind(value):
                has_num = True
            elif isinstance(value, str):
                has_text = True
            if has_num and has_text:
                break
        flags.append(has_num and has_text)
    return flags


def _significant_digits(value: Decimal) -> int:
    """有限 Decimal 的有效数字位数（去掉尾随零）。移植自 joytools results.significant_digits。"""
    digits = value.as_tuple().digits
    significant = len(digits)
    while significant > 1 and digits[significant - 1] == 0:
        significant -= 1
    return significant


def _decimal_needs_text(value: Decimal) -> bool:
    """② Decimal 精度判定：能安全走到「分」才写数值，否则写文本。

    先按 round-half-up 取分（cents），再做双舍入校验：模拟写盘（.16G 有效数字）与
    读回（float 15 位）两次舍入后到分的值不变才走数值路径——两次舍入各自看似安全、
    组合后改变到分结果的情况正是这里要拦的（formats._decimal_needs_text 移植）。
    """
    if not value.is_finite():
        return False
    if value.copy_abs() >= _EXCEL_INT_THRESHOLD:
        return True
    cents = value.quantize(_CENT, rounding=ROUND_HALF_UP, context=_DECIMAL_CONTEXT)
    if _significant_digits(cents) > 15:
        return True
    written = Decimal(format(cents, ".16G"))
    readback = Decimal(format(float(written), ".15g"))
    return any(
        number.quantize(_CENT, rounding=ROUND_HALF_UP, context=_DECIMAL_CONTEXT) != cents
        for number in (written, readback)
    )


def _text_repr(value) -> str:
    """混型列转文本时的字符串形式（Decimal 用 f 格式避免科学计数法）。"""
    if isinstance(value, Decimal):
        return format(value, "f")
    if isinstance(value, float):
        if value.is_integer():
            return str(int(value))
        return repr(value)
    return str(value)


def _csv_has_formula_text(columns: list, prepared: list) -> bool:
    """CSV 保留原始文本；找出可能被电子表格软件当公式解释的格（csv_has_formula_text 移植）。

    只用于 csv 的信封提示：不改数据、不加引号前缀，与源策略一致。
    """
    if any(name.lstrip().startswith(_FORMULA_PREFIXES) for name in columns):
        return True
    for row in prepared:
        for cell in row:
            if cell is not None and cell[0] == "str" and cell[1].lstrip().startswith(_FORMULA_PREFIXES):
                return True
    return False


def _prepare_value(value, mixed: bool):
    """把单个单元格规整成 (kind, value) 或 None；kind="num" 写数值、kind="str" 强制写文本。

    None → 空单元格；NaN → 空、±Inf → 文本（xlsxwriter 拒写 ±inf，与查询信封一致）。
    """
    if value is None:
        return None
    if isinstance(value, float):
        if math.isnan(value):
            return None
        if math.isinf(value):
            return ("str", "inf" if value > 0 else "-inf")
    if isinstance(value, Decimal):
        if value.is_nan():
            return None
        if value.is_infinite():
            return ("str", "inf" if value > 0 else "-inf")
    if mixed:
        # ③ 混型列：整列转文本
        return ("str", _text_repr(value))
    if isinstance(value, str):
        return ("str", value)
    # ① 大整数 → 文本（含整值 float，64 位装不下的整数会以整值 float 出现）
    if isinstance(value, int) and not isinstance(value, bool) and abs(value) >= _EXCEL_INT_THRESHOLD:
        return ("str", str(value))
    if isinstance(value, float) and value.is_integer() and abs(value) >= _EXCEL_INT_THRESHOLD:
        return ("str", str(int(value)))
    # ② Decimal → 保留 2 位（分）；双舍入校验不过才落文本
    if isinstance(value, Decimal) and _decimal_needs_text(value):
        return ("str", format(value, "f"))
    if isinstance(value, Decimal):
        return ("num", value.quantize(_CENT, rounding=ROUND_HALF_UP, context=_DECIMAL_CONTEXT))
    if _is_numeric_kind(value):
        return ("num", value)
    # 其他非标量兜底转文本（与 ResultStore 的 _safe_value 口径一致）
    return ("str", str(value))


def _prepare_sheet(sheet: dict) -> tuple:
    """把 dict sheet 规整成 (columns, prepared_rows)；prepared_rows 的格是 (kind, value) 或 None。

    文本格保留原值：xlsx 由 strings_to_formulas=False 保证公式样式文本原样写入（不加撇号
    前缀），csv 保留原始文本、由 deliver_artifact 检测公式样式文本并在信封加 caveat。
    """
    columns = [str(c) for c in sheet["columns"]]
    rows = list(sheet["rows"])
    mixed = _mixed_columns(rows, len(columns))
    prepared = []
    for row in rows:
        out = []
        for idx in range(len(columns)):
            value = row[idx] if idx < len(row) else None
            out.append(_prepare_value(value, mixed[idx]))
        prepared.append(out)
    return columns, prepared


# ---- 容量与硬上限预检 ----

def _check_budgets(sheets: list, fmt: str) -> tuple:
    """落盘前把行数/格数双闸拦住（超限即抛 ValueError，什么都不写）。

    预算沿用 joytools contracts 标定；换格式的建议只对 xlsx 成立——csv 已经是便宜的那一个。
    """
    data_rows = sum(len(s["rows"]) for s in sheets)
    cells = sum(len(s["rows"]) * max(len(s["columns"]), 1) for s in sheets)
    budget = BUDGETS[fmt]
    hint = "请缩小范围或改用 csv" if fmt == "xlsx" else "请缩小范围"
    if data_rows > budget.rows:
        raise ValueError(f"超出导出上限：结果合计 {data_rows} 行，超过 {fmt} 导出的 {budget.rows} 行上限，{hint}")
    if cells > budget.cells:
        raise ValueError(f"超出导出上限：合计 {cells} 个单元格，超过 {fmt} 导出的 {budget.cells} 格上限，{hint}")
    return data_rows, cells


def _check_excel_limits(columns: list, rows: list) -> None:
    """④ Excel 硬上限预检（表头占一行）；超限在写入前报错，而不是被静默丢数据。

    含单格 32767 字符上限（formats._check_excel_frame 移植）：xlsxwriter 对超长字符串
    只警告并静默截断，覆盖表头与所有文本格。
    """
    if len(rows) + 1 > EXCEL_MAX_ROWS or len(columns) > EXCEL_MAX_COLUMNS:
        raise ValueError("数据超过 Excel 的行数或列数硬上限，请改用 CSV 导出。")
    for c, name in enumerate(columns, 1):
        if len(name) > EXCEL_MAX_TEXT_CHARS:
            raise ValueError(f"第 {c} 列的表头超过 Excel 的 {EXCEL_MAX_TEXT_CHARS:,} 字符上限，"
                             "请改用 CSV 导出以保留完整内容。")
    for r, row in enumerate(rows, 2):
        for c, cell in enumerate(row, 1):
            if cell is not None and cell[0] == "str" and len(cell[1]) > EXCEL_MAX_TEXT_CHARS:
                raise ValueError(f"第 {r} 行、第 {c} 列超过 Excel 的 "
                                 f"{EXCEL_MAX_TEXT_CHARS:,} 字符上限，请改用 CSV 导出以保留完整内容。")


# ---- 渲染（纯字节生成，无磁盘）----

def _render_xlsx(sheet_specs: list) -> bytes:
    """xlsx 写入（在 worker 线程里跑）：表头加粗、列宽 15，与 joytools 统一样式对齐。"""
    buf = io.BytesIO()
    with xlsxwriter.Workbook(buf, _WRITER_OPTIONS) as wb:
        header_fmt = wb.add_format({"bold": True})
        for name, columns, rows in sheet_specs:
            ws = wb.add_worksheet(name)
            for c, col in enumerate(columns):
                ws.write_string(0, c, str(col), header_fmt)
            for r, row in enumerate(rows, start=1):
                for c, cell in enumerate(row):
                    if cell is None:
                        continue
                    kind, value = cell
                    # str 一律 write_string：strings_to_formulas=False 下 = + - @ 开头也原样写入
                    if kind == "str":
                        ws.write_string(r, c, value)
                    else:
                        ws.write(r, c, value)
            ws.set_column(0, max(len(columns) - 1, 0), 15)
    return buf.getvalue()


# xlsx 写入是 GIL 密集的（xlsxwriter 纯 Python）：单 worker 后端里在请求线程直接写，
# 0.5 秒的 SSE 心跳会被饿住、拖慢当时在线的每一个会话（joytools 实测结论）。
# 提交到独立线程池让解释器在 GIL 切换之间有机会调度别的线程，future.result 超时兜底。
_XLSX_POOL: ThreadPoolExecutor | None = None


def _xlsx_pool() -> ThreadPoolExecutor:
    global _XLSX_POOL
    if _XLSX_POOL is None:
        _XLSX_POOL = ThreadPoolExecutor(max_workers=2, thread_name_prefix="export-xlsx")
    return _XLSX_POOL


def _render_xlsx_in_pool(sheet_specs: list) -> bytes:
    future = _xlsx_pool().submit(_render_xlsx, sheet_specs)
    try:
        return future.result(timeout=_XLSX_TIMEOUT)
    except futures.TimeoutError:
        # 取消还没开始排队的任务（已在跑的 xlsxwriter 纯 Python 写入不可中断，但会自行结束）。
        # 不 cancel 的话，超时的任务继续占住 worker，池满后后续 xlsx 导出只能排队等各自的超时。
        future.cancel()
        raise ValueError(f"xlsx 写入超时（{_XLSX_TIMEOUT}s），请缩小结果范围或改用 csv")


def _csv_text(value) -> str:
    if isinstance(value, Decimal):
        return format(value, "f")
    if isinstance(value, float):
        return repr(value)
    return str(value)


def _render_csv(sheet: dict, columns: list, prepared: list) -> bytes:
    """CSV 渲染：utf-8-sig（带 BOM，Excel 双击打开中文不乱码）。单 sheet。"""
    buf = io.StringIO()
    writer = csv.writer(buf, lineterminator="\r\n")
    writer.writerow(columns)
    for row in prepared:
        writer.writerow(["" if cell is None else _csv_text(cell[1]) for cell in row])
    return buf.getvalue().encode("utf-8-sig")


# ---- TTL 惰性清扫 ----

def sweep_exports(now: float | None = None) -> None:
    """删除 mtime 超过 24h 的产物（<artifact_id>.* 连同 .meta.json），deliver 前调用。

    每目录最多扫 200 个条目防拖慢（scandir 惰性枚举，超大目录不全量读）；
    超过 200 个时只处理最旧的 50 个——长期积压说明导出量大，全量扫会拖慢交付本身。
    """
    if not EXPORT_ROOT.is_dir():
        return
    now = time.time() if now is None else now

    def mtime(path) -> float:
        try:
            return path.stat().st_mtime
        except OSError:
            return 0.0

    for owner_dir in EXPORT_ROOT.iterdir():
        if not owner_dir.is_dir():
            continue
        try:
            with os.scandir(owner_dir) as it:
                entries = []
                for entry in it:
                    entries.append(Path(entry.path))
                    if len(entries) >= _SWEEP_SCAN_LIMIT + 1:
                        break
        except OSError:
            continue
        if len(entries) > _SWEEP_SCAN_LIMIT:
            entries = sorted(entries, key=mtime)[:_SWEEP_DELETE_MAX]
        for path in entries:
            if now - mtime(path) > _TTL_SECONDS:
                try:
                    path.unlink()
                except OSError:
                    pass


# ---- 交付 ----

def deliver_artifact(sheets: list, fmt: str = "xlsx", subject: str = "",
                     owner_key: str = "anonymous") -> dict:
    """把 `sheets` 写成一个产物文件，返回引用而不是数据。

    sheets 每项 {"name": str, "columns": [str], "rows": [[...]]}（rows 为 JSON 安全值）。

    行为契约：
    - 空结果不落盘：全部 sheet 行数为 0 时返回 status=empty 语义的信封，回显第一个
      sheet 的列名，让模型知道「拿到了什么列但没数据」（joytools deliver 同款）。
    - BUDGETS 双闸（行数 + 格数）+ Excel 硬上限预检，超限抛 ValueError。
    - 精度防丢三规则（见 _prepare_value）；公式样式文本 xlsx 靠 strings_to_formulas=False
      原样写入、csv 保留原文并在信封加 caveat。
    - file_name = 清洗后的 subject + 时间戳 + 后缀；产物落 EXPORT_ROOT/<owner_key>/，
      同目录写 <artifact_id>.meta.json。
    - 每次交付前做一次 TTL 24h 惰性清扫。
    """
    if not sheets:
        raise ValueError("没有可导出的工作表")
    if fmt not in BUDGETS:
        raise ValueError("不支持的导出格式：" + fmt + "，只支持 " + "、".join(BUDGETS))
    if fmt == "csv" and len(sheets) > 1:
        # 不降级成「只导第一张」：交一份缺表的文件比报错糟得多，收到文件的人无从知道少了什么。
        listed = "、".join(str(s.get("name", "")) for s in sheets)
        raise ValueError(f"csv 只能装一张表，本次有 {len(sheets)} 张（{listed}），请改用 format=\"xlsx\"")
    sweep_exports()

    if not any(s.get("rows") for s in sheets):
        # 不落空文件：交一个 0 行的文件出去，agent 会照样说「已导出」，人打开才发现是空的，
        # 而那时已分不清是查询没数据还是导出坏了。列名照样回显。
        return {
            "empty": True,
            "empty_columns": [str(c) for c in sheets[0].get("columns", [])],
            "file_name": "",
            "download_url": "",
            "rows": 0,
            "cells": 0,
            "format": fmt,
        }

    data_rows, cells = _check_budgets(sheets, fmt)
    # 工作表名清洗去重（Excel 限制：≤31 字符、非法字符换 _、重名加 (2)）；CSV 单 sheet 忽略
    names = (
        _unique_sheet_names(s.get("name", "Sheet1") for s in sheets)
        if fmt == "xlsx" else [None] * len(sheets)
    )
    sheet_specs = []
    for name, sheet in zip(names, sheets):
        columns, prepared = _prepare_sheet(sheet)
        if fmt == "xlsx":
            _check_excel_limits(columns, prepared)
        sheet_specs.append((name or sheet.get("name", "Sheet1"), columns, prepared))

    caveats = []
    if fmt == "csv" and _csv_has_formula_text(sheet_specs[0][1], sheet_specs[0][2]):
        # 与 joytools deliver 同款：CSV 保留原始文本，不插入改变数据的引号前缀。
        caveats.append("CSV 保留原始文本；部分字段可能被电子表格软件解释为公式，请按文本方式导入。")

    if fmt == "xlsx":
        payload = _render_xlsx_in_pool(sheet_specs)
    else:
        # CSV 单 sheet，行内渲染（代价低，不走线程池）
        payload = _render_csv(sheets[0], sheet_specs[0][1], sheet_specs[0][2])

    owner_dir = EXPORT_ROOT / sanitize_owner(owner_key)
    try:
        owner_dir.mkdir(parents=True, exist_ok=True)
    except OSError:
        raise ValueError("产物目录不可写，导出失败")
    artifact_id = uuid.uuid4().hex[:12]
    file_name = _artifact_filename(subject, fmt)
    path = owner_dir / f"{artifact_id}.{fmt}"
    try:
        path.write_bytes(payload)
    except OSError:
        raise ValueError("产物写入失败")
    meta = {"file_name": file_name, "owner_key": sanitize_owner(owner_key), "mtime": time.time()}
    try:
        (owner_dir / f"{artifact_id}.meta.json").write_text(
            json.dumps(meta, ensure_ascii=False), encoding="utf-8")
    except OSError:
        pass  # meta 写失败不影响产物交付（下载时回落 artifact_id 作文件名）

    return {
        "empty": False,
        "empty_columns": [],
        "file_name": file_name,
        "download_url": DOWNLOAD_URL_PREFIX + artifact_id + "/download",
        "artifact_id": artifact_id,
        "rows": data_rows,
        "cells": cells,
        "format": fmt,
        "caveats": caveats,
    }


# ---- 纯文本交付（非表格文本产物）----

TEXT_MAX_CHARS = 200_000  # 文本产物字符上限（模板实际几千字符，此闸只是防滥用兜底）


def deliver_text(text: str, subject: str = "文本产物", owner_key: str = "anonymous",
                 fmt: str = "sql") -> dict:
    """把一段纯文本（如 SQL 文本模板）写成产物文件，返回引用信封。

    复用 deliver_artifact 同一条管线：owner 目录隔离 + TTL 24h 惰性清扫 + meta.json +
    下载端点（routers/agent.py 的 ext 白名单）。文本按原样落盘，绝不截断/转码（utf-8）。
    """
    if fmt not in ("sql", "txt"):
        raise ValueError("不支持的文本产物格式：" + fmt + "，只支持 sql、txt")
    content = (text or "").rstrip()
    if not content.strip():
        return {"empty": True, "file_name": "", "download_url": "", "chars": 0, "format": fmt}
    if len(content) > TEXT_MAX_CHARS:
        raise ValueError(f"文本超过 {TEXT_MAX_CHARS:,} 字符上限，无法交付")
    sweep_exports()

    owner_dir = EXPORT_ROOT / sanitize_owner(owner_key)
    try:
        owner_dir.mkdir(parents=True, exist_ok=True)
    except OSError:
        raise ValueError("产物目录不可写，导出失败")
    artifact_id = uuid.uuid4().hex[:12]
    file_name = _artifact_filename(subject, fmt)
    path = owner_dir / f"{artifact_id}.{fmt}"
    try:
        path.write_text(content, encoding="utf-8")
    except OSError:
        raise ValueError("产物写入失败")
    meta = {"file_name": file_name, "owner_key": sanitize_owner(owner_key), "mtime": time.time()}
    try:
        (owner_dir / f"{artifact_id}.meta.json").write_text(
            json.dumps(meta, ensure_ascii=False), encoding="utf-8")
    except OSError:
        pass  # meta 写失败不影响产物交付（下载时回落 artifact_id 作文件名）

    return {
        "empty": False,
        "file_name": file_name,
        "download_url": DOWNLOAD_URL_PREFIX + artifact_id + "/download",
        "artifact_id": artifact_id,
        "chars": len(content),
        "format": fmt,
    }

"""数据库连接与原始 SQL 执行。"""
import os
import json
import re
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv
from sqlalchemy import create_engine, text
from pymysql.constants import FIELD_TYPE
from urllib.parse import quote_plus

from analysis.sql_guard import guard_readonly_sql

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SQL_DIR = PROJECT_ROOT / "sql"

# 流式分批拉取时每批读取的行数
_FETCH_CHUNK = 10000

# DB 元数据里认作"整数类型"的 pymysql FIELD_TYPE 集合（TINY/SHORT/LONG/INT24/LONGLONG）：
# 只有这些列才参与大整数精度还原，真实浮点列（FLOAT/DOUBLE/DECIMAL 等）一律不碰
_INT_FIELD_TYPES = frozenset(
    {FIELD_TYPE.TINY, FIELD_TYPE.SHORT, FIELD_TYPE.LONG, FIELD_TYPE.INT24, FIELD_TYPE.LONGLONG}
)


def build_engine():
    load_dotenv(PROJECT_ROOT / ".env")
    host = os.environ["DB_HOST"]
    port = os.environ.get("DB_PORT", "9030")
    name = os.environ["DB_NAME"]
    user = os.environ["DB_USER"]
    password = os.environ["DB_PASSWORD"]
    url = f"mysql+pymysql://{quote_plus(user)}:{quote_plus(password)}@{host}:{port}/{name}"
    return create_engine(url, pool_pre_ping=True)


def _load_projects() -> list[dict]:
    """Load the project registry without inventing a route on parse failure."""
    registry = PROJECT_ROOT / "games.json"
    try:
        payload = json.loads(registry.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"项目注册表不可用，拒绝路由: {registry}") from exc
    projects = payload.get("games")
    if not isinstance(projects, list):
        raise RuntimeError("项目注册表缺少 games 列表，拒绝路由")
    return projects


def _external_route(sql_text: str, project_key: str | None = None) -> tuple[str, str]:
    """Resolve one explicit/uniquely identifiable project route.

    There is deliberately no ODPS/China fallback.  Shared event19 requires a
    project key because the physical table contains four products.  A local
    backup gets a sentinel route so the execution layer can reject it before
    invoking the cloud client.
    """
    low = sql_text.lower()
    if "information_schema" in low:
        raise ValueError("外部项目不支持 information_schema；请使用项目权威 schema")
    projects = _load_projects()
    by_key = {str(item.get("key", "")).lower(): item for item in projects}

    if project_key is not None:
        key = str(project_key).strip().lower()
        project = by_key.get(key)
        if project is None:
            raise ValueError(f"未知项目 {project_key!r}，拒绝猜测数据源")
    else:
        candidates: list[dict] = []
        for project in projects:
            key = str(project.get("key", "")).lower()
            if key and re.search(rf"\bpf_{re.escape(key)}\b", low):
                candidates.append(project)
        event_matches = re.findall(r"\bta\.v_event_(\d+)\b", low)
        if event_matches:
            event_numbers = set(event_matches)
            candidates.extend(
                project for project in projects
                if str(project.get("event_table", "")).lower().removeprefix("ta.v_event_") in event_numbers
            )
        # Keep only one registry identity; event19 intentionally remains
        # ambiguous and must be selected by project_key.
        unique = {str(item.get("key", "")).lower(): item for item in candidates}
        if len(unique) != 1:
            raise ValueError("SQL 未明确唯一注册项目；请显式传入 project_key，拒绝猜测数据源")
        project = next(iter(unique.values()))

    source_type = str(project.get("source_type") or "").lower()
    if source_type == "local_backup":
        return "local_backup", str(project.get("region") or "unknown")
    engine = project.get("client_engine")
    region = project.get("client_region")
    if not engine or not region:
        raise ValueError(f"项目 {project.get('key')!r} 未登记明确引擎/区域，拒绝路由")
    return str(engine), str(region)


def run_raw_sql(
    engine,
    sql_text: str,
    max_rows: int | None = None,
    max_scanned: int | None = None,
    *,
    project_key: str | None = None,
) -> pd.DataFrame:
    """Execute read-only SQL through the selected engine.

    ``project_key`` is required whenever SQL cannot identify exactly one
    registered project (notably shared event19). Unknown SQL never falls back
    to ODPS/China. Callers that currently omit it are reported by the routing
    regression tests for explicit follow-up; this patch does not edit them.
    """
    sql_text = guard_readonly_sql(sql_text)
    if engine is None:
        route = _external_route(sql_text, project_key=project_key)
        if route[0] == "local_backup":
            raise RuntimeError("本地备份是文件源，不可通过云端 SQL 执行")
        if sql_text.lstrip().upper().startswith("EXPLAIN "):
            return pd.DataFrame()
        from integrations.fivecross_client import fetch
        if max_rows is not None and int(max_rows) <= 0:
            raise ValueError(f"max_rows 必须为正整数，收到 {max_rows}；已拦截")
        routed = fetch(sql_text, engine=route[0], region=route[1])
        if max_rows is not None and len(routed) > int(max_rows):
            raise ValueError(f"查询结果超过 {max_rows} 行上限，已拦截；请缩小查询范围")
        return routed
    if max_rows is None:
        with engine.connect() as conn:
            return pd.read_sql(text(sql_text), conn)
    max_rows = int(max_rows)
    if max_rows <= 0:
        raise ValueError(f"max_rows 必须为正整数，收到 {max_rows}；已拦截")
    return _run_limited(engine, sql_text, max_rows, max_scanned)


def _run_limited(engine, sql_text: str, max_rows: int, max_scanned: int | None) -> pd.DataFrame:
    """流式分批拉取查询结果，防止大结果集撑爆 Python 内存。

    max_rows 为结果行数上限，max_scanned 为扫描行数护栏（None 关闭），
    超出任一上限即断开连接并抛 ValueError，报错文案与旧实现保持一致。
    """
    with engine.connect() as conn:
        result = conn.execution_options(stream_results=True).execute(text(sql_text))
        int_col_flags = _int_col_flags(result.cursor.description)
        rows, scanned = [], 0
        scanned_cap = int(max_scanned) if max_scanned else 0
        while True:
            chunk = result.fetchmany(_FETCH_CHUNK)
            if not chunk:
                break
            scanned += len(chunk)
            if scanned_cap and scanned > scanned_cap:
                conn.invalidate()
                raise ValueError(f"查询扫描行数超过上限（{scanned_cap}），已拦截；请缩小查询范围")
            rows.extend(chunk)
            if len(rows) > max_rows:
                conn.invalidate()
                raise ValueError(f"查询结果超过 {max_rows} 行上限，已拦截；请缩小查询范围")
        df = pd.DataFrame(rows, columns=list(result.keys()))
        return _fix_bigint_cols(df, rows, int_col_flags)


def _int_col_flags(description) -> list:
    """按列位置返回"DB 侧类型码是否为整数类型"的布尔列表（与 cursor.description 对齐）。

    只认 pymysql 元数据声明为整型的列（_INT_FIELD_TYPES），真实浮点列即使取值
    恰好全是整数也不参与还原；description 为空（理论上不会发生）返回空列表，
    _fix_bigint_cols 会整体跳过。
    """
    if not description:
        return []
    return [d[1] in _INT_FIELD_TYPES for d in description]


def _fix_bigint_cols(df: pd.DataFrame, rows: list, int_col_flags: list) -> pd.DataFrame:
    """修复整型列的精度：pandas 把含 NULL 的整型列读成 float64 时，>2^53 的 64 位整数
    已被浮点舍入，靠"浮点转回 int"只会固化错误值——须用 fetchmany 拿到的原始 Python int
    行值重建（DBAPI 返回的 Python int 不受 64 位浮点精度限制，本身无舍入）。

    只处理 DB 元数据（cursor.description 类型码）确认为整数类型的 float64 列：
    真实浮点列（如汇率 7.0、占比 25.0 这类恰好全是整值的 FLOAT/DOUBLE 列）一律跳过，
    避免误转改变 dtype/JSON 类型语义；已保持整型 dtype 的列也不参与转换。
    转换时空值兜底为 None、其余 int(v)，列 dtype 显式 object——直接赋 list 会被 pandas
    按列原 float64 dtype 强转（None 又变回 NaN），须显式指定；下游 _df_preview / to_json
    均可安全处理。
    """
    if not int_col_flags:
        return df
    for i, c in enumerate(df.columns):
        if not int_col_flags[i] or df[c].dtype != "float64":
            continue
        converted = [None if v is None else int(v) for v in (row[i] for row in rows)]
        df[c] = pd.Series(converted, dtype=object)
    return df

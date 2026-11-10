"""全量表结构 JSON 的表级检索（TF-IDF 余弦，零外部依赖）。

SQL 生成时按问题从 704 张同名表里检索 top-k 相关表，把它们的结构（含字段字典）拼进
schema 上下文——替代「把整个表结构文档全文塞 prompt」的做法，避免 2MB 文档撑爆上下文。

数据源：仅接受带有 ``source_type=FiveCross`` 的已验证 schema manifest。
"""
from __future__ import annotations

import json
import logging
import math
import re
import threading
from collections import Counter

from analysis.games import family_key

from .. import config

logger = logging.getLogger(__name__)

_SCHEMA_JSON = config.DATA_AI_ROOT / "knowledge" / "table_schema" / "table_schema.json"

_CJK = re.compile(r"[一-鿿]")
_WORD = re.compile(r"[a-z0-9]+")

_lock = threading.Lock()
_cache: dict | None = None


def _tokenize(text: str) -> list[str]:
    text = (text or "").lower()
    tokens = _WORD.findall(text)
    cjk = "".join(_CJK.findall(text))
    tokens += [cjk[i : i + 2] for i in range(len(cjk) - 1)]
    tokens += list(cjk)
    return tokens


def _table_text(tb: dict) -> str:
    """表检索文本：表名/中文名/用途权重最高，字段名与描述/字典次之。"""
    head = " ".join([tb.get("name", ""), tb.get("cn", ""), tb.get("use", "")])
    field_bits = []
    for f in tb.get("fields", []):
        field_bits.append(" ".join([f.get("name", ""), f.get("desc", ""), f.get("dict", "")]))
    return head + " " + " ".join(field_bits)


def _ensure() -> dict:
    global _cache
    with _lock:
        if _cache is not None:
            return _cache
        try:
            data = json.loads(_SCHEMA_JSON.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as e:
            logger.warning("table_schema.json 读取/解析失败，回退空表结构：%s", e)
            _cache = {"tables": [], "toks": [], "vecs": []}
            return _cache
        if data.get("source_type") != "FiveCross" or not data.get("manifest_version"):
            logger.warning("拒绝加载非 FiveCross 表结构来源")
            _cache = {"tables": [], "toks": [], "vecs": []}
            return _cache
        tables = data.get("tables") or []
        docs = [_table_text(tb) for tb in tables]
        toks = [_tokenize(d) for d in docs]
        df = Counter()
        for ts in toks:
            for t in set(ts):
                df[t] += 1
        n = max(len(tables), 1)
        idf = {t: math.log((n + 1) / (df[t] + 1)) + 1.0 for t in df}

        def vec(ts: list[str]) -> dict:
            c = Counter(ts)
            total = max(sum(c.values()), 1)
            v = {t: (cnt / total) * idf.get(t, 0.0) for t, cnt in c.items() if t in idf}
            norm = math.sqrt(sum(x * x for x in v.values())) or 1.0
            return {t: x / norm for t, x in v.items()}

        _cache = {"tables": tables, "toks": toks, "vecs": [vec(ts) for ts in toks]}
        return _cache


def invalidate() -> None:
    global _cache
    with _lock:
        _cache = None


def query_tables(q: str, game_key: str | None = None, k: int = 10) -> list[dict]:
    """按问题检索 top-k 相关表，返回表对象列表（含 fields）。game_key 非空时按其 family 过滤。"""
    if not _SCHEMA_JSON.exists():
        return []
    idx = _ensure()
    qvec = None
    try:
        qts = _tokenize(q)
        c = Counter(qts)
        total = max(sum(c.values()), 1)
        idf = {t: 1.0 for t in c}  # 查询侧 idf 简化为 1（仅靠余弦方向）
        qv = {t: (cnt / total) for t, cnt in c.items()}
        norm = math.sqrt(sum(x * x for x in qv.values())) or 1.0
        qvec = {t: x / norm for t, x in qv.items()}
    except Exception:
        return []

    gk = family_key(game_key) if game_key else None
    scored = []
    for tb, vec in zip(idx["tables"], idx["vecs"]):
        if gk is not None and gk not in tb.get("families", []):
            continue
        s = sum(qvec.get(t, 0.0) * w for t, w in vec.items())
        if s > 0:
            scored.append((s, tb))
    scored.sort(key=lambda x: x[0], reverse=True)
    return [tb for _, tb in scored[:k]]


def get_table_fields(name: str) -> dict | None:
    """按裸表名精确查一张表的字段定义（中文表名/用途/字段描述与字典）。未收录返回 None。"""
    idx = _ensure()
    for tb in idx["tables"]:
        if tb.get("name") == name:
            return {"cn": tb.get("cn", ""), "use": tb.get("use", ""), "fields": tb.get("fields") or []}
    return None


def tables_to_text(tables: list[dict], target_db: str, max_fields_per_table: int = 200) -> str:
    """把检索到的表拼成紧凑 schema 文本，供 SQL 生成 prompt 使用（字段写全限定名）。"""
    if not tables:
        return ""
    lines = [f"数据库 `{target_db}` 的相关表结构（来自已验证 FiveCross schema manifest）：", ""]
    for tb in tables:
        cols = []
        for f in tb.get("fields", [])[:max_fields_per_table]:
            name, typ = f.get("name", ""), f.get("type", "")
            desc = f.get("desc", "")
            dic = f.get("dict", "")
            extra = f"{desc}；字典:{dic}" if dic else desc
            cols.append(f"{name}:{typ}" + (f"({extra})" if extra else ""))
        col_str = ", ".join(cols)
        cn = tb.get("cn", "")
        lines.append(f"- {target_db}.{tb['name']} {('【' + cn + '】') if cn else ''} ({col_str})")
    return "\n".join(lines)

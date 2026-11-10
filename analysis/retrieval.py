"""检索索引层：让「知识库 / SQL / 模型 / 专项」之间快速对应、检索，供下游 agent/报告快速取上下文。

单一数据源 = 文件（stores），避免双写不一致；内存缓存 + 文件 mtime 失效，写入后 `invalidate()` 可强刷。

三层：
1. 显式 deps 图（来自 manifest：skill.sqls/docs、model manifest 的 sqls/docs）→ deps/dependents/downstream；
2. 关键词/稀疏向量检索（纯 Python TF-IDF 余弦，确定性、零外部依赖）→ query；
3. 稠密向量：预留 embedder 接口，不可用时自动降级 TF-IDF（保证不出错）。
"""
from __future__ import annotations

import math
import re
from collections import Counter, defaultdict
from pathlib import Path

from . import knowledge_store
from . import sql_store
from . import code_store
from .games import family_key

_CJK = re.compile(r"[一-鿿]")
_WORD = re.compile(r"[a-z0-9]+")

_DOCS_DIR = knowledge_store.DOCS_DIR
_SKILLS_DIR = knowledge_store.SKILLS_DIR
_INDEX_DIRS = (_DOCS_DIR, _SKILLS_DIR, sql_store.SQL_DIR, code_store.CODE_DIR)

_cache: dict = {}


# ---------------------------------------------------------------------------
# 记录构建
# ---------------------------------------------------------------------------

def _first_heading(text: str) -> str:
    for ln in (text or "").splitlines():
        s = ln.strip()
        if s.startswith("#"):
            return s.lstrip("#").strip() or s
    return ""


def _first_para(text: str, limit: int = 240) -> str:
    buf: list[str] = []
    for ln in (text or "").splitlines():
        s = ln.strip()
        if s.startswith("#") or s.startswith("---"):
            if buf:
                break
            continue
        if not s:
            if buf:
                break
            continue
        buf.append(s)
        if sum(len(x) for x in buf) >= limit:
            break
    return " ".join(buf)[:limit]


def _sql_step_name(text: str) -> str:
    """从 SQL 头部注释抽取「步骤名」（= 图表名），作为检索标题；缺失回空。"""
    for ln in (text or "").splitlines():
        s = ln.strip()
        if s.startswith("【步骤名】"):
            return s.replace("【步骤名】", "").strip()
        if s and not s.startswith("--"):
            break
    return ""


def _sql_brief_text(text: str, max_lines: int = 12) -> str:
    """抽取 SQL 头部注释块作为简短说明（供独立 SQL 建索引）。"""
    lines: list[str] = []
    for ln in (text or "").splitlines():
        s = ln.strip()
        if not s:
            if lines:
                break
            continue
        if s.startswith("--"):
            lines.append(s.lstrip("- ").strip())
        else:
            break
        if len(lines) >= max_lines:
            break
    return "\n".join(lines)


def _build_records() -> list[dict]:
    """从 stores 全量扫描构建记录（canonical id = 裸名）。"""
    records: list[dict] = []

    for name in knowledge_store.list_docs():
        content = knowledge_store.read_doc(name)
        meta = knowledge_store.read_doc_meta(name)
        records.append({
            "kind": "doc", "id": name,
            "title": _first_heading(content) or name,
            "summary": str(meta.get("summary") or _first_para(content)),
            "text": content,
            "deps": [],
            "level": meta.get("level"), "game": meta.get("game"),
        })

    for name in knowledge_store.list_skills():
        content = knowledge_store.read_skill(name)
        meta = knowledge_store.read_skill_meta(name)
        # 专项层：把内嵌的 SQL / 模型 / 知识一并并入可检索文本，便于按专项整体召回
        parts = [content]
        for s in (meta.get("sqls") or []):
            t = knowledge_store.read_skill_sql(name, s)
            if t and t.strip():
                parts.append(t)
        for d in (meta.get("docs") or []):
            t = knowledge_store.read_skill_knowledge(name, d)
            if t and t.strip():
                parts.append(t)
        method = meta.get("forecast")
        if isinstance(method, dict):
            method = method.get("method")
        if method:
            t = knowledge_store.read_skill_model(name, str(method))
            if t and t.strip():
                parts.append(t)
        deps = [("sql", s[:-4] if s.endswith(".sql") else s) for s in (meta.get("sqls") or [])]
        deps += [("doc", d) for d in (meta.get("docs") or [])]
        records.append({
            "kind": "skill", "id": name,
            "title": _first_heading(content) or name,
            "summary": _first_para(content),
            "text": "\n\n".join(parts),
            "deps": deps,
            "level": meta.get("level"), "game": meta.get("game"),
        })

    # 独立 SQL 建索引：让「尚未被任何专项绑定」的全局 SQL 也能被语义召回，
    # 供规划/关联阶段在专项文本没写死文件名时发现相关取数代码。
    # id 用裸名（去 .sql 后缀），与 skill deps、artifact.py 的 canonical id 保持一致。
    for name in sql_store.list_sql_files():
        text = sql_store.read_sql(name)
        if not text.strip():
            continue
        meta = sql_store.read_sql_meta(name)
        records.append({
            "kind": "sql", "id": name[:-4] if name.endswith(".sql") else name,
            "title": _sql_step_name(text) or name,
            "summary": _sql_brief_text(text) or name,
            "text": text,
            "deps": [],
            "level": meta.get("level"), "game": meta.get("game"),
        })

    # 独立模型能力建索引：外部算法能力（code/<名>.py.json manifest）按 desc+代码可检索，
    # 供规划/关联阶段语义召回候选预测能力。
    for fname in code_store.list_code_manifests():
        stem = fname[:-3] if fname.endswith(".py") else fname
        meta = code_store.read_code_meta(stem)
        code = code_store.read_code(stem)
        text = "\n\n".join(x for x in (str(meta.get("desc") or ""), code) if x.strip())
        if not text.strip():
            continue
        records.append({
            "kind": "model", "id": stem,
            "title": str(meta.get("name") or stem),
            "summary": str(meta.get("desc") or ""),
            "text": text,
            "deps": [],
            "level": meta.get("level"), "game": meta.get("game"),
        })

    return records


# ---------------------------------------------------------------------------
# 向量/关键词索引（TF-IDF 余弦）
# ---------------------------------------------------------------------------

def _tokenize(text: str) -> list[str]:
    text = (text or "").lower()
    tokens = _WORD.findall(text)
    cjk = "".join(_CJK.findall(text))
    tokens += [cjk[i:i + 2] for i in range(len(cjk) - 1)]
    tokens += list(cjk)  # 单字兜底，提高短查询召回
    return tokens


def _field_tokens(rec: dict) -> list[str]:
    return _tokenize(rec["title"]) * 3 + _tokenize(rec["summary"]) * 2 + _tokenize(rec["text"])


def _idf(records: list[dict]) -> dict[str, float]:
    df: Counter = Counter()
    for rec in records:
        for t in set(_field_tokens(rec)):
            df[t] += 1
    n = max(len(records), 1)
    return {t: math.log((n + 1) / (df[t] + 1)) + 1.0 for t in df}


def _norm_vec(tokens: list[str], idf: dict[str, float]) -> dict[str, float]:
    c = Counter(tokens)
    total = max(sum(c.values()), 1)
    vec = {t: (cnt / total) * idf.get(t, 0.0) for t, cnt in c.items() if t in idf}
    norm = math.sqrt(sum(x * x for x in vec.values())) or 1.0
    return {t: x / norm for t, x in vec.items()}


def _dot(a: dict[str, float], b: dict[str, float]) -> float:
    if len(a) > len(b):
        a, b = b, a
    return sum(a[t] * b.get(t, 0.0) for t in a)


# ---------------------------------------------------------------------------
# 缓存 + 签名
# ---------------------------------------------------------------------------

def _signature() -> tuple:
    sig: list[tuple] = []
    for d in _INDEX_DIRS:
        if not d.exists():
            continue
        for p in sorted(d.rglob("*")):
            if not p.is_file() or p.suffix.lower() not in (".md", ".sql", ".py", ".json"):
                continue
            try:
                sig.append((str(p), p.stat().st_mtime_ns))
            except OSError:
                pass
    return tuple(sig)


def invalidate() -> None:
    """强制失效缓存（写入后调用可立即生效；不调用则靠 mtime 自动失效）。"""
    _cache.clear()


def _ensure() -> dict:
    sig = _signature()
    if _cache.get("signature") == sig and "records" in _cache:
        return _cache
    records = _build_records()
    idf = _idf(records)
    vecs = [_norm_vec(_field_tokens(r), idf) for r in records]
    dependents: dict[tuple, list[tuple]] = defaultdict(list)
    for rec in records:
        for dk, di in rec["deps"]:
            dependents[(dk, di)].append((rec["kind"], rec["id"]))
    _cache.clear()
    _cache.update({
        "signature": sig, "records": records, "vecs": vecs, "idf": idf,
        "dependents": dict(dependents),
    })
    return _cache


# ---------------------------------------------------------------------------
# 公开 API
# ---------------------------------------------------------------------------

def _parse_ref(kind: str, name: str) -> tuple[str, str]:
    """把 name 归一成 (kind, 裸名)。也支持 name 形如 'kind:id'。"""
    if ":" in name:
        k, _, n = name.partition(":")
        return k, n
    return kind, name


def query(q: str, kinds: list[str] | None = None, k: int = 5, game: str | None = None) -> list[dict]:
    """按关键词检索 top-k 工件，返回 [{kind, id, title, summary, score}]。

    kinds 为空表示全部；game 非空时按层级过滤（通用 + 家族匹配），与 stores 隔离规则一致。
    """
    idx = _ensure()
    qvec = _norm_vec(_tokenize(q), idx["idf"])
    gk = family_key(game) if game else None
    scored = []
    for rec, vec in zip(idx["records"], idx["vecs"]):
        if kinds and rec["kind"] not in kinds:
            continue
        if gk is not None:
            if rec["level"] not in (None, "通用") and family_key(rec["game"]) != gk:
                continue
        score = _dot(qvec, vec)
        if score > 0:
            scored.append((score, rec))
    scored.sort(key=lambda x: x[0], reverse=True)
    out = []
    for score, rec in scored[:k]:
        out.append({
            "kind": rec["kind"], "id": rec["id"], "title": rec["title"],
            "summary": rec["summary"], "score": round(score, 4),
        })
    return out


def deps(kind: str, name: str) -> list[tuple[str, str]]:
    """某工件的直接上游引用 [(kind, id)]。"""
    kind, name = _parse_ref(kind, name)
    idx = _ensure()
    for rec in idx["records"]:
        if rec["kind"] == kind and rec["id"] == name:
            return list(rec["deps"])
    return []


def dependents(kind: str, name: str) -> list[tuple[str, str]]:
    """直接依赖某工件的下游 [(kind, id)]。"""
    kind, name = _parse_ref(kind, name)
    idx = _ensure()
    return list(idx["dependents"].get((kind, name), []))


def downstream(kind: str, name: str) -> list[tuple[str, str]]:
    """某工件的传递下游（BFS，含间接依赖），供「改一个工件只重跑其下游」使用。"""
    kind, name = _parse_ref(kind, name)
    idx = _ensure()
    seen = {(kind, name)}
    frontier = [(kind, name)]
    order: list[tuple[str, str]] = []
    while frontier:
        nxt: list[tuple[str, str]] = []
        for node in frontier:
            for dep in idx["dependents"].get(node, []):
                if dep not in seen:
                    seen.add(dep)
                    order.append(dep)
                    nxt.append(dep)
        frontier = nxt
    return order


def records() -> list[dict]:
    """返回全部记录（供自检/调试，不含向量）。"""
    idx = _ensure()
    return [{"kind": r["kind"], "id": r["id"], "title": r["title"],
             "summary": r["summary"], "deps": r["deps"],
             "level": r["level"], "game": r["game"]} for r in idx["records"]]

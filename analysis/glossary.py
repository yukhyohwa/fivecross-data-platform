"""业务术语 / 同义词 → 表名、列名的单一来源，注入 SQL 生成上下文做 schema linking。

术语表维护在 knowledge/glossary.md（纯文本，每行「术语/同义词 → 对应列或表」）。
文件不存在或为空时返回空串，完全不影响现有行为（零配置即用）。

运行期「术语候选」自记录：data_ai 产出 SQL 后，把 SQL 里出现、术语表尚未收录的列，
按表结构里的中文描述（国家代码→country_code 这类）追加进 knowledge/glossary.candidates.md，
供后台 admin 面板人工确认后并入术语表（避免自投喂污染 schema linking）。
"""
from __future__ import annotations

import json
import re
import time
from pathlib import Path

from analysis import versioning

GLOSSARY_PATH = Path(__file__).resolve().parent.parent / "knowledge" / "glossary.md"
CANDIDATES_PATH = Path(__file__).resolve().parent.parent / "knowledge" / "glossary.candidates.md"
_TABLE_SCHEMA_PATH = Path(__file__).resolve().parent.parent / "knowledge" / "table_schema" / "table_schema.json"

# 「术语 → 列名」行解析：取 → 后第一个合法标识符当列名，其余（如「（人民币 CNY）」）忽略；
# 右侧以中文开头的行（如「→ 库 pf_kof」的表映射、纯同义词行）不会命中，恰好排除表名/非列映射。
_MAP_LINE = re.compile(r"^\s*(.+?)\s*→\s*([A-Za-z_][A-Za-z0-9_.]*)")
# 候选行解析：术语可为空（待人工填），列名后可选「# 来源」注释。
_CAND_LINE = re.compile(r"^\s*(.*?)\s*→\s*([A-Za-z_][A-Za-z0-9_.]*)\s*(?:#\s*(.*))?$")

_CANDIDATES_HEADER = "# 术语候选（运行期自动记录，待人工确认后并入术语表）"


def glossary_text() -> str:
    """读取术语表全文；缺失/异常返回空串。"""
    try:
        return GLOSSARY_PATH.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def glossary_hint() -> str:
    """术语表注入提示：有内容时返回带标题的一段，否则返回空串。"""
    t = glossary_text()
    if not t:
        return ""
    return "\n\n# 业务术语表 / 同义词（优先按此映射理解问题并选对列）\n\n" + t + "\n"


def _map_pairs(text: str) -> list[tuple[str, str]]:
    """解析术语表正文里的「术语 → 列名」行，返回 [(术语, 列名)]（跳过标题/注释/空行）。"""
    pairs = []
    for ln in (text or "").splitlines():
        s = ln.strip()
        if not s or s.startswith("#") or s.startswith("<!--"):
            continue
        m = _MAP_LINE.match(s)
        if m and m.group(1).strip():
            pairs.append((m.group(1).strip(), m.group(2)))
    return pairs


def glossary_columns() -> set[str]:
    """术语表已映射到的列名集合（小写、去库前缀取末段），供候选去重。"""
    return {col.lower().split(".")[-1] for _, col in _map_pairs(glossary_text())}


def save_glossary(content: str) -> None:
    """版本化写回术语表（覆盖前自动备份到 _versions/）。"""
    versioning.write_text(
        GLOSSARY_PATH,
        (content or "").replace("\r\n", "\n").rstrip() + "\n",
        encoding="utf-8",
        newline="\n",
    )


# ---- 术语候选（运行期自记录）----

def list_candidates() -> list[dict]:
    """读候选文件，返回 [{term, column, source}]（source 可为空）。"""
    try:
        text = CANDIDATES_PATH.read_text(encoding="utf-8")
    except OSError:
        return []
    out = []
    for ln in text.splitlines():
        s = ln.strip()
        if not s or s.startswith("#") or s.startswith("<!--"):
            continue
        m = _CAND_LINE.match(s)
        if not m:
            continue
        out.append({
            "term": m.group(1).strip(),
            "column": m.group(2),
            "source": (m.group(3) or "").strip(),
        })
    return out


def _write_candidates(cands: list[dict]) -> None:
    """把候选列表（已去重）写回候选文件（版本化写）。"""
    lines = [_CANDIDATES_HEADER]
    for c in cands:
        col = (c.get("column") or "").strip()
        if not col:
            continue
        term = (c.get("term") or "").strip()
        src = (c.get("source") or "").strip()
        lines.append(f"{term} → {col}" + (f"  # {src}" if src else ""))
    versioning.write_text(CANDIDATES_PATH, "\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def append_candidates(entries: list[tuple[str, str]], source: str = "") -> int:
    """把候选映射追加进候选文件（去重：已在术语表或候选文件的跳过）。

    entries: [(术语, 列名)]，术语可为空（待人工填）。返回实际新增条数。
    """
    existing = glossary_columns() | {c["column"].lower() for c in list_candidates()}
    ts = time.strftime("%Y-%m-%d %H:%M")
    new_lines = []
    for term, col in entries:
        col = (col or "").strip()
        if not col:
            continue
        key = col.lower().split(".")[-1]
        if key in existing:
            continue
        existing.add(key)
        term = (term or "").strip()
        src = f"{source} {ts}".strip()
        new_lines.append(f"{term} → {col}" + (f"  # {src}" if src else ""))
    if not new_lines:
        return 0
    try:
        text = CANDIDATES_PATH.read_text(encoding="utf-8") if CANDIDATES_PATH.exists() else ""
    except OSError:
        text = ""
    text = text.rstrip()
    if not text.strip():
        text = _CANDIDATES_HEADER + "\n"
    else:
        text += "\n"
    text += "\n".join(new_lines) + "\n"
    versioning.write_text(CANDIDATES_PATH, text, encoding="utf-8", newline="\n")
    return len(new_lines)


_CONFIRM_SECTION = "# 运行期并入（由术语候选确认，可自由增删）"


def _section_entry_col(ln: str) -> str:
    """取一行「术语 → 列名」的列名（小写、去库前缀末段）；非该形态返回空串。"""
    m = _MAP_LINE.match((ln or "").strip())
    return m.group(2).lower().split(".")[-1] if m else ""


def _append_confirm_lines(text: str, new_lines: list[str]) -> str:
    """把新确认行追加进术语表的『运行期并入』分区（无则新建在末尾），返回新正文。

    分区始终以 _CONFIRM_SECTION 头开始；已存在时把新行插到该分区末尾（下一条顶层
    '# ' 分区头之前，没有就在文件末尾），不会重复分区头、也不会挪动其它分区。
    """
    lines = (text or "").rstrip().splitlines()
    header_idx = None
    for i, ln in enumerate(lines):
        if ln.strip() == _CONFIRM_SECTION:
            header_idx = i
            break
    if header_idx is None:
        base = (text or "").rstrip()
        if base:
            return (base + "\n\n" + _CONFIRM_SECTION + "\n" + "\n".join(new_lines)).rstrip() + "\n"
        return (_CONFIRM_SECTION + "\n" + "\n".join(new_lines)).rstrip() + "\n"
    insert_at = len(lines)
    for j in range(header_idx + 1, len(lines)):
        s = lines[j].strip()
        if s.startswith("#") and s != _CONFIRM_SECTION:
            insert_at = j
            break
    while insert_at > header_idx + 1 and not lines[insert_at - 1].strip():
        insert_at -= 1
    lines[insert_at:insert_at] = new_lines
    return "\n".join(lines).rstrip() + "\n"


def confirm_candidates(entries: list[dict]) -> dict:
    """把候选确认并入术语表：追加「术语 → 列名」行（归入『运行期并入』分区），
    并从候选文件移除对应列。

    entries: [{term, column}]（term 已由人填好）。返回 {added, removed}。
    """
    remove_cols = set()
    new_pairs = []
    for e in entries:
        term = (e.get("term") or "").strip()
        col = (e.get("column") or "").strip()
        if not term or not col:
            continue
        key = col.lower().split(".")[-1]
        if key in remove_cols:
            continue
        remove_cols.add(key)
        new_pairs.append((term, col))
    if not new_pairs:
        return {"added": 0, "removed": 0}

    before = list_candidates()
    gtext = glossary_text().rstrip()
    # 与术语表里已有的映射按列去重（含此前已并入的分区行），避免重复映射
    existing_cols = {_section_entry_col(ln) for ln in (gtext or "").splitlines()}
    new_lines = []
    for t, c in new_pairs:
        if c.lower().split(".")[-1] in existing_cols:
            continue
        new_lines.append(f"{t} → {c}")
        existing_cols.add(c.lower().split(".")[-1])
    if not new_lines:
        return {"added": 0, "removed": 0}

    if not gtext:
        gtext = "# 术语表 / 同义词映射（口语 → 列名）"
    save_glossary(_append_confirm_lines(gtext, new_lines))

    kept = [c for c in before if (c.get("column") or "").lower().split(".")[-1] not in remove_cols]
    _write_candidates(kept)
    return {"added": len(new_lines), "removed": len(before) - len(kept)}


# ---- 运行期候选自记录（列名 → 中文描述 反向索引 + 从 SQL 抽取）----

_desc_index: dict[str, str] | None = None
_desc_index_mtime: float | None = None


def _field_desc_index() -> dict[str, str]:
    """从 table_schema.json 构建「列名 → 中文描述」反向索引（首个非空描述胜出，按文件 mtime 缓存）。

    缓存带上 table_schema.json 的 mtime：表结构刷新后（后台重生成 table_schema.json）索引会自动
    重建，避免进程常驻时长期用旧描述打候选。
    """
    global _desc_index, _desc_index_mtime
    try:
        mtime = _TABLE_SCHEMA_PATH.stat().st_mtime
    except OSError:
        _desc_index, _desc_index_mtime = {}, None
        return {}
    if _desc_index is not None and _desc_index_mtime == mtime:
        return _desc_index
    idx: dict[str, str] = {}
    try:
        data = json.loads(_TABLE_SCHEMA_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        _desc_index, _desc_index_mtime = idx, mtime
        return idx
    for tb in (data.get("tables") or []):
        for f in (tb.get("fields") or []):
            name = (f.get("name") or "").strip().lower()
            desc = (f.get("desc") or "").strip()
            if name and desc and name not in idx:
                idx[name] = desc
    _desc_index, _desc_index_mtime = idx, mtime
    return idx


def capture_sql_candidates(sql: str, source: str = "", limit: int = 12) -> int:
    """从一条已产出的 SQL 抽取「列名不在术语表」的字段，按表结构中文描述生成候选并入队。

    纯确定性、零额外模型调用：把 SQL 小写后按词边界切出标识符 token，命中表结构字段名
    且未被术语表收录的，用该字段中文描述当术语（国家代码 → country_code）追加为候选，供人审。
    """
    sql_lower = (sql or "").lower()
    if not sql_lower:
        return 0
    idx = _field_desc_index()
    if not idx:
        return 0
    known = glossary_columns()
    entries = []
    seen = set()
    for tok in re.findall(r"[a-z_][a-z0-9_]*", sql_lower):
        if tok in seen:
            continue
        seen.add(tok)
        if tok in known or tok not in idx:
            continue
        desc = idx[tok].strip()
        if not desc:
            continue
        entries.append((desc, tok))
        known.add(tok)
        if len(entries) >= limit:
            break
    return append_candidates(entries, source)

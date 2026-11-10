"""游戏项目（game）配置与库名映射。

游戏清单权威来源：data_ai/games.json（可手工编辑，格式：
{"games": [{"key": "ro_hmt", "name": "…", "region": "…", "short_name": "…",
            "description": "…", "db": "pf_ro_hmt"}, …]}）。

首次访问时若无该文件，会从知识库「欢乐游戏项目信息」文档的「产品代码」列自动
预填一份（key=产品代码，db=pf_<产品代码>），之后以 games.json 为准，不再自动扫描库。
"""
import json
import logging
import re
import threading

from .. import config
from analysis.games import family_key

_lock = threading.Lock()
_cache: list[dict] | None = None

_GAMES_DOC_NAME = "欢乐游戏项目信息"


# ---- 首次从知识库文档预填 ----

def _split_md_row(line: str) -> list[str]:
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    return [c.strip() for c in s.split("|")]


def _is_separator(cells: list[str]) -> bool:
    return bool(cells) and all(set(c) <= set("-: ") for c in cells)


def _parse_games_doc(text: str) -> list[dict]:
    """解析「欢乐游戏项目信息」文档，抽取「产品代码」列的 {key, name, region}（按出现顺序去重）。"""
    entries: list[dict] = []
    seen: set[str] = set()
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if not line.startswith("|"):
            i += 1
            continue
        cells = _split_md_row(line)
        # 仅识别「表头行」：含「产品代码」列且下一行是分隔符（---），
        # 避免把「字段口径说明」表里值等于「产品代码」的数据行误判为表头。
        if "产品代码" not in cells:
            i += 1
            continue
        if i + 1 >= len(lines) or not _is_separator(_split_md_row(lines[i + 1].strip())):
            i += 1
            continue
        idx_code = cells.index("产品代码")
        idx_name = cells.index("游戏名称") if "游戏名称" in cells else -1
        idx_region = cells.index("地区") if "地区" in cells else -1
        j = i + 1
        while j < len(lines):
            r = lines[j].strip()
            if not r.startswith("|"):
                break
            rcells = _split_md_row(r)
            if _is_separator(rcells):
                j += 1
                continue
            code = rcells[idx_code] if idx_code < len(rcells) else ""
            if code and code not in seen:
                name = rcells[idx_name] if 0 <= idx_name < len(rcells) else ""
                region = rcells[idx_region] if 0 <= idx_region < len(rcells) else ""
                entries.append({"key": code, "name": name or code, "region": region})
                seen.add(code)
            j += 1
        i = j
    return entries


def _seed_entries() -> list[dict]:
    doc_path = config.DATA_AI_ROOT / "knowledge" / "docs" / f"{_GAMES_DOC_NAME}.md"
    if not doc_path.exists():
        return []
    try:
        text = doc_path.read_text(encoding="utf-8")
    except OSError:
        return []
    games = []
    for p in _parse_games_doc(text):
        games.append({
            "key": p["key"],
            "name": p["name"],
            "region": p["region"],
            "short_name": p["key"],
            "description": "",
            "db": f"pf_{p['key']}",
        })
    return games


# ---- games.json 读写 ----

def _load_file() -> list[dict] | None:
    if not config.GAMES_PATH.exists():
        return None
    try:
        data = json.loads(config.GAMES_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if isinstance(data, dict):
        data = data.get("games")
    return data if isinstance(data, list) else None


def _write_file(games: list[dict]) -> None:
    config.GAMES_PATH.write_text(
        json.dumps({"games": games}, ensure_ascii=False, indent=2),
        encoding="utf-8",
        newline="\n",
    )


def _normalize_entry(e: dict) -> dict | None:
    key = (e.get("key") or "").strip()
    if not key:
        return None
    db = (e.get("db") or "").strip() or f"pf_{key}"
    return {
        "key": key,
        "name": e.get("name") or key,
        "region": e.get("region") or "",
        "short_name": e.get("short_name") or key,
        "description": e.get("description") or "",
        "aliases": [str(x).strip() for x in (e.get("aliases") or []) if str(x).strip()],
        "db": db,
        # Optional routing to the canonical fivecross-data-client.
        "client_engine": e.get("client_engine"),
        "client_region": e.get("client_region") or e.get("region_key"),
        "source_group": e.get("source_group") or "",
        "source_type": e.get("source_type") or "",
        "event_table": e.get("event_table") or "",
        "game_id": e.get("game_id") or "",
    }


def ensure(engine=None) -> list[dict]:
    """返回游戏列表（进程级缓存）；首次无 games.json 时从知识库文档预填。"""
    global _cache
    with _lock:
        if _cache is not None:
            return _cache
        games = _load_file()
        if not games:
            games = _seed_entries()
            if games:
                _write_file(games)
        _cache = [n for n in (_normalize_entry(e) for e in games) if n]
        return _cache


def get_games(engine=None) -> list[dict]:
    return ensure(engine)


def default_key() -> str:
    import os

    env = os.environ.get("CHAT_DEFAULT_GAME", "").strip()
    if env:
        return env
    # 优先用 DEFAULT_TARGET_DB 的后缀（历史默认游戏 rooc_am），否则退回首个游戏
    preferred = config.DEFAULT_TARGET_DB
    if preferred.startswith("pf_"):
        preferred = preferred[len("pf_"):]
    if _cache:
        keys = {g["key"] for g in _cache}
        if preferred in keys:
            return preferred
        return _cache[0]["key"]
    return preferred or "rooc_am"


def resolve(key, engine=None) -> dict:
    """把请求里的游戏 key 解析成游戏 dict；缺省/未知时回退默认游戏。"""
    games = ensure(engine)
    key = (key or "").strip()
    for g in games:
        if g["key"] == key:
            return g
    dk = default_key()
    for g in games:
        if g["key"] == dk:
            return g
    if games:
        return games[0]
    return {"key": dk, "name": dk, "region": "", "short_name": dk, "description": "", "db": f"pf_{dk}"}


def apply_db(sql: str, db: str) -> str:
    """把 SQL 里任意 `pf_xxx.` 库名前缀替换成目标库 `db.`。

    仅替换「代码区」：跳过单引号字符串字面量（含 ``''`` 转义）、``--`` 行注释与
    ``/* */`` 块注释，避免误改字符串/注释里出现的 ``pf_xxx.``。
    """
    if not sql or not db:
        return sql
    pattern = re.compile(r"\bpf_[A-Za-z0-9_]+\.", re.UNICODE)

    def sub(s: str) -> str:
        return pattern.sub(lambda _m: db + ".", s)

    out: list[str] = []
    i = 0
    n = len(sql)
    code_start = 0
    while i < n:
        c = sql[i]
        nxt = sql[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "*":  # 块注释
            out.append(sub(sql[code_start:i]))
            j = sql.find("*/", i + 2)
            if j == -1:
                out.append(sql[i:])
                return "".join(out)
            out.append(sql[i:j + 2])
            i = j + 2
            code_start = i
            continue
        if c == "-" and nxt == "-":  # 行注释（到行尾，不含换行符）
            out.append(sub(sql[code_start:i]))
            j = sql.find("\n", i + 2)
            if j == -1:
                out.append(sql[i:])
                return "".join(out)
            out.append(sql[i:j])
            i = j
            code_start = i
            continue
        if c == "'":  # 单引号字符串字面量
            out.append(sub(sql[code_start:i]))
            j = i + 1
            while j < n:
                if sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'":
                        j += 2  # '' 为转义单引号
                        continue
                    break
                j += 1
            if j >= n:  # 未闭合字符串：剩余全部按字面量原样保留
                out.append(sql[i:])
                return "".join(out)
            out.append(sql[i:j + 1])
            i = j + 1
            code_start = i
            continue
        i += 1
    out.append(sub(sql[code_start:n]))
    return "".join(out)


_ACTIVE_VIEW_RE = re.compile(r"\bdwd_all_games_active_i_rt_view\b", re.IGNORECASE)
_TZ_PLACEHOLDER = "{时区条件}"


_HARDCODED_SERVER_TZ = {"pf_rooc": "utc7", "pf_rooc_am": "utc-4"}

# tz 标签 ↔ SQL offset 对照（供 convert_tz 的 from/to 参数与口径提示使用）
_TZ_TO_OFFSET = {
    "utc0": "+00:00",
    "utc7": "+07:00",
    "utc8": "+08:00",
    "utc-4": "-04:00",
    "utc-5": "-05:00",
    "utc-8": "-08:00",
}

_tz_map_cache: dict[str, str] | None = None
_tz_map_lock = threading.Lock()


def tz_offset(label: str) -> str:
    """把 tz 标签（utc7 / utc-4 …）转成 SQL offset（+07:00 / -04:00 …）；未知返回空串。"""
    return _TZ_TO_OFFSET.get((label or "").strip().lower(), "")


def _load_server_tz_map() -> dict[str, str]:
    """从 public_analyst.dim_gameperiod_info 读取各游戏服务器时区（obt 节点优先，其次最新 start_date）。

    进程级缓存，一次性查询；失败回退空表（不阻断）。
    """
    global _tz_map_cache
    if _tz_map_cache is not None:
        return _tz_map_cache
    with _tz_map_lock:
        if _tz_map_cache is not None:  # 双重检查：并发冷启动只查一次库
            return _tz_map_cache
        mapping: dict[str, str] = {}
        try:
            from ..deps import get_engine  # 懒加载，避免与 deps 的循环导入
            from analysis.db import run_raw_sql
            df = run_raw_sql(
                get_engine(),
                "SELECT game_code, svr_timezone FROM ("
                "  SELECT game_code, svr_timezone,"
                "    ROW_NUMBER() OVER (PARTITION BY game_code"
                "      ORDER BY CASE WHEN node = 'obt' THEN 0 ELSE 1 END, start_date DESC) AS rn"
                "  FROM public_analyst.dim_gameperiod_info"
                "  WHERE svr_timezone IS NOT NULL AND svr_timezone <> ''"
                ") t WHERE rn = 1",
            )
            for _, r in df.iterrows():
                v = str(r["svr_timezone"]).strip()
                if v:
                    mapping[str(r["game_code"]).strip()] = v
        except Exception as e:
            logging.getLogger(__name__).warning(
                "加载服务器时区表 dim_gameperiod_info 失败，active 视图 tz 过滤将失效：%s", e
            )
        _tz_map_cache = mapping
        return mapping


def server_tz(db: str) -> str | None:
    """当前游戏库的服务器时区标签（如 utc7 / utc-4）。

    硬编码表优先（已知正确），缺失时回退查 public_analyst.dim_gameperiod_info
    （「先确认 timezone 里的时区」），仍无则 None（不过滤）。
    """
    if not db:
        return None
    if db in _HARDCODED_SERVER_TZ:
        return _HARDCODED_SERVER_TZ[db]
    key = db[len("pf_"):] if db.startswith("pf_") else db
    return _load_server_tz_map().get(key)


def active_view_tz(db: str) -> str | None:
    """dwd_all_games_active_i_rt_view 的 tz 过滤值（= 服务器时区）。

    具有多时区记录的项目必须按其真实 schema 和业务规则确认时区过滤，避免重复计数。
    """
    return server_tz(db)


def active_view_tz_hint(db: str) -> str:
    """给 SQL 生成/改写上下文追加当前项目真实数据源口径。"""
    for game in ensure():
        if game.get("db") != db:
            continue
        if game.get("client_engine") == "ta":
            event_table = game.get("event_table") or "ta.v_event_*"
            return (
                f"【数据源口径】当前项目为 ThinkingData/数数，必须使用真实事件表 `{event_table}` "
                "及其可确认字段。禁止使用参考公司 `pf_*`、`dwd_*` 视图或 MySQL/StarRocks 表；"
                "不要套用其它项目的流水表结构。"
            )
        if game.get("source_type") == "local_backup":
            return (
                "【数据源口径】当前项目为本地备份文件。禁止生成或改写为未登记的云端视图；"
                "只能依据该备份项目已登记的文件和字段口径回答。"
            )
        break
    tz = active_view_tz(db)
    offset = tz_offset(tz) if tz else ""
    lines: list[str] = []
    if tz:
        lines.append(f"【时区口径】当前项目已登记服务器时区为 {tz}（offset {offset}）；仅对 schema 中实际存在的时区字段应用过滤。")
    else:
        lines.append("【时区口径】时区字段与转换规则必须从当前项目真实 schema/业务文档确认，未确认时不得猜测。")
    lines.append(
        "【时间口径·无 tz 字段的表】dwd_all_games_purchase_i_rt_view 等流水表没有 tz 字段，"
        "但有 dteventtime（服务器时区的原始事件时间，无时区信息）与 date（已按服务器时区分桶）。"
        "要改时区时用 convert_tz(dteventtime, '<服务器offset>', '<目标offset>') 转换，"
        f"或直接用现成的北京时间列 date_utc8 / china_date / dteventtime_utc8"
        f"（服务器 offset 本库为 {offset or '<服务器offset>'}；北京时间 = utc8 / +08:00）。"
    )
    lines.append("【金额口径】金额字段与币种必须以当前项目真实 schema 和业务文档为准；未确认时不得猜测。")
    return "\n".join(lines)


_ACTIVE_FROM_WHERE_RE = re.compile(
    r"(\bFROM\s+(?:\w+\.)?dwd_all_games_active_i_rt_view\b"
    r"(?:\s+(?:AS\s+)?[A-Za-z_][A-Za-z0-9_]*)?\s+WHERE\s+)",
    re.IGNORECASE,
)


def _inject_active_tz(sql: str, tz: str) -> str:
    """在每处 `FROM ..._active_i_rt_view [别名] WHERE ` 的 WHERE 后注入 tz 过滤（best-effort）。

    仅处理 FROM 与 WHERE 之间无注释/无其他关键字的直接形态；找不到匹配则原样保留，
    交由 {时区条件} 占位符路径兜底。
    """
    return _ACTIVE_FROM_WHERE_RE.sub(lambda m: m.group(1) + f"tz = '{tz}' AND ", sql)


def _fill_tz_placeholder(sql: str, tz: str | None) -> str:
    """把 {时区条件} 占位符替换成 active 视图的 tz 过滤。

    占位符在 WHERE 里既可能是「紧跟 WHERE/( 的首个条件」，也可能是「尾随在其它 AND 条件之后的
    独立条件」——两种写法都要生成合法 SQL，故：
    - 前面紧贴 WHERE/(/AND/OR/HAVING 时不补前导 AND（避免「WHERE AND / ( AND / AND AND」）；
    - 其余位置（尾随独立条件）补前导 AND。
    tz 为 None（当前库无 tz 映射）时占位符整体替换成恒真条件 `1=1`，而非空串——
    模型常写成 `WHERE date >= ... AND {时区条件}`，替换成空串会留下悬空的 `... AND ` 或 `WHERE `（语法错误）。
    """
    ph = re.escape(_TZ_PLACEHOLDER)
    replacement = f"tz = '{tz}'" if tz else "1=1"
    sql = re.sub(
        rf"(?i)(\b(?:where|and|or|having)\s*|\(\s*){ph}",
        lambda m: m.group(1) + replacement,
        sql,
    )
    return sql.replace(_TZ_PLACEHOLDER, f"AND {replacement}")


def fill_active_tz(sql: str, db: str) -> str:
    """把 SQL 里的 {时区条件} 占位符替换成 active 视图的 tz 过滤，并对漏写过滤的视图兜底注入。

    - db 映射到 tz：{时区条件} -> tz 过滤条件；若 SQL 引用了 active 视图却既无占位符
      也无任何 tz 过滤，则在每处 `FROM ..._active_i_rt_view [别名] WHERE` 注入 "tz = '<tz>' AND"。
    - db 无 tz 映射：{时区条件} -> ""，不注入。
    """
    tz = active_view_tz(db)
    had_placeholder = _TZ_PLACEHOLDER in sql
    sql = _fill_tz_placeholder(sql, tz)
    if not tz:
        return sql
    if had_placeholder:
        return sql
    if not _ACTIVE_VIEW_RE.search(sql):
        return sql
    if re.search(r"\btz\s*=", sql, re.IGNORECASE):
        return sql
    return _inject_active_tz(sql, tz)


def apply_sql(sql: str, db: str) -> str:
    """apply_db + 注入 active 视图 tz 过滤。所有「按游戏库执行 SQL」的地方统一走这里。"""
    return fill_active_tz(apply_db(sql, db), db)


def _game_keywords(g: dict) -> list[str]:
    """提取一个游戏的可识别关键词：完整名称/简称/代码 + 按分隔符拆出的片段。"""
    parts = [g.get("name", ""), g.get("short_name", ""), g.get("key", ""), *(g.get("aliases") or [])]
    region_only = {"tw", "kr", "jp", "cn", "sea", "gl", "global", "na", "lna", "am"}
    out: list[str] = []
    seen: set[str] = set()
    for p in parts:
        p = (p or "").strip()
        if not p:
            continue
        if p.lower() not in region_only and p not in seen:
            out.append(p)
            seen.add(p)
        # 拆出片段（如 "拳皇:冠军之路" -> "拳皇" "冠军之路"；"RO仙境傳說：愛如初見Classic" -> "RO仙境傳說" "愛如初見Classic"）
        for seg in re.split(r"[：:/\\\-–—|、,，\s]+", p):
            seg = seg.strip()
            if seg and len(seg) >= 2 and seg.lower() not in region_only and seg not in seen:
                out.append(seg)
                seen.add(seg)
    return out


def _ascii_keyword_hits(text_low: str, kw_low: str) -> bool:
    """纯 ASCII 关键词按「词边界」匹配：命中片段前后不得是 ASCII 字母/数字。

    对抗审查 2026-10-23：games.json 存在 key="act"（街机三国），纯子串匹配会把
    「active 用户」「contact」「exact」误指向 act 并（direct 直查）静默查错库；
    同理 "ro" 会误命中 "promotion"。CJK 关键词不适用此规则（中文无词分隔符），
    由调用方走子串匹配。
    """
    start = 0
    while True:
        i = text_low.find(kw_low, start)
        if i < 0:
            return False
        before = text_low[i - 1] if i > 0 else ""
        after = text_low[i + len(kw_low)] if i + len(kw_low) < len(text_low) else ""
        if not (before and before.isascii() and before.isalnum()) and \
           not (after and after.isascii() and after.isalnum()):
            return True
        start = i + 1


def match_game_in_text(text: str) -> dict | None:
    """从用户文本识别其指向的游戏（名称/简称/代码 匹配，取最长命中）；返回游戏 dict 或 None。

    匹配规则（对抗审查 2026-10-23 收口）：纯 ASCII 关键词（游戏代码/英文简称）按词边界
    匹配；含 CJK 的关键词（中文名/中英混合名）仍用子串匹配（中文无词分隔符）。
    """
    text_low = (text or "").lower()
    best: dict | None = None
    best_len = 0
    for g in ensure():
        for kw in _game_keywords(g):
            kw_low = kw.lower()
            if len(kw_low) < 2:
                continue
            hit = (_ascii_keyword_hits(text_low, kw_low) if kw_low.isascii()
                   else kw_low in text_low)
            if hit and len(kw_low) > best_len:
                best = g
                best_len = len(kw_low)
    return best


# 常见地区服后缀：用于把「同一游戏的多地区服」归到一个家族（如 kof / kof_sea -> kof）。
# family_key 统一由 analysis.games 提供，保证 skills/docs/sql 的项目级绑定与对话侧家族归一一致。


def family_members(game: dict, engine=None) -> list[dict]:
    """返回与 game 同「家族」（同一游戏不同地区服）的全部游戏，规范成员（无地区后缀）排最前。

    单地区服游戏返回仅含自身的列表。
    """
    fk = family_key(game.get("key", ""))
    members = [g for g in ensure(engine) if family_key(g.get("key", "")) == fk]
    if not members:
        return [game]
    members.sort(key=lambda g: 0 if family_key(g.get("key", "")) == g.get("key", "").strip().lower() else 1)
    return members


def region_label(game: dict) -> str:
    """给一个地区服起个可读标签，如「CN（kof）」「PH（kof_sea）」，用于合并结果里的「地区」列。"""
    region = (game.get("region") or "").strip()
    key = (game.get("key") or "").strip()
    if region and region.lower() != key.lower():
        return f"{region}（{key}）"
    return region or key

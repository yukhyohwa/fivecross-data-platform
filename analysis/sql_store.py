"""SQL 查询文件与元数据（AI 修改描述列表等）的文件系统 CRUD。

sql/*.sql 是查询文件本体；sql/*.sql.json 是同名元数据文件。删除 SQL 时两者一起删，
列表只暴露 *.sql，天然隔离 .sql.json。元数据缺失或损坏时返回默认结构，不抛异常，
保证历史 .sql 文件（无 json）也能正常运行。
"""
import json
import os
import re
import uuid
from pathlib import Path

from analysis.games import visible_to, current_owner_key
from analysis import versioning

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SQL_DIR = PROJECT_ROOT / "sql"

SQL_DIR.mkdir(parents=True, exist_ok=True)

META_VERSION = 1
DEFAULT_META = {"version": META_VERSION, "modifications": [], "level": None, "game": None, "fields": []}

# ---- SQL 层级（通用 / 项目 / 个人）----

SQL_LEVELS = ["通用", "项目", "个人"]
DEFAULT_SQL_LEVEL = "通用"

_INVALID_NAME_CHARS = re.compile(r'[\\/:*?"<>|]')


def _validate_name(name: str) -> str:
    name = (name or "").strip()
    if not name:
        raise ValueError("名称不能为空")
    if _INVALID_NAME_CHARS.search(name) or name in (".", ".."):
        raise ValueError(f"名称包含非法字符：{name}")
    return name


def list_sql_files(game: str | None = None) -> list[str]:
    """按文件名（含 .sql 后缀）排序返回；传 game 时按隔离规则过滤（通用 + 绑定该游戏的 项目/个人，个人再按当前用户归属）。"""
    names = sorted(p.name for p in SQL_DIR.glob("*.sql"))
    if game is None:
        return names
    owner = current_owner_key()
    return [n for n in names
            if visible_to(sql_level(n), read_sql_meta(n).get("game"), game,
                          read_sql_meta(n).get("owner"), owner)]


def read_sql(sql_name: str) -> str:
    """读取 .sql 文件文本；不存在返回空串。"""
    path = SQL_DIR / _validate_name(sql_name)
    return path.read_text(encoding="utf-8") if path.exists() else ""


def write_sql(sql_name: str, text: str) -> None:
    """写 .sql 文件（\r\n → \n 归一化）。"""
    path = SQL_DIR / _validate_name(sql_name)
    versioning.write_text(path, text.replace("\r\n", "\n"), encoding="utf-8", newline="\n")


def _sql_meta_path(sql_name: str) -> Path:
    return SQL_DIR / f"{_validate_name(sql_name)}.json"


def read_sql_meta(sql_name: str) -> dict:
    """读同名 .sql.json；缺文件/损坏时返回默认结构，不抛异常。

    返回结构：{"version": 1, "modifications": [{"id","name","prompt"}], "level": ..., "game": ...}
    """
    path = _sql_meta_path(sql_name)
    if not path.exists():
        return dict(DEFAULT_META)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return dict(DEFAULT_META)
    return {
        "version": data.get("version", META_VERSION),
        "modifications": data.get("modifications", []),
        "level": data.get("level"),
        "game": data.get("game"),
        "owner": data.get("owner"),
        "sources": data.get("sources", []),
        "fields": data.get("fields", []),
        "confidentiality": data.get("confidentiality"),
    }


def write_sql_meta(sql_name: str, meta: dict) -> None:
    """写元数据（utf-8，ensure_ascii=False，缩进 2，随版本化留痕）。"""
    path = _sql_meta_path(sql_name)
    versioning.write_text(
        path,
        json.dumps(meta, ensure_ascii=False, indent=2),
        encoding="utf-8",
        newline="\n",
    )


def fields_from_sql(text: str) -> list[dict]:
    """从 SQL 文本推导字段声明 [{"col": 列名, "desc": ""}]，供落盘时自动写入 .sql.json。

    优先解析头部注释 -- 【输出列】（AI 生成的关键输出列名）；再补全 SELECT 里的
    `as "别名"` / `AS "别名"` 列别名（含日期/国家等维度列），去重保序。
    """
    text = text or ""
    cols: list[str] = []
    m = re.search(r"【输出列】\s*(.+)", text)
    if m:
        cols = [c.strip() for c in re.split(r"[,，]", m.group(1)) if c.strip()]
    for c in re.findall(r'\bas\s+"([^"]+)"', text, flags=re.IGNORECASE):
        if c not in cols:
            cols.append(c)
    return [{"col": c, "desc": ""} for c in cols]


def normalize_sql_level(level: str) -> str:
    """把任意层级值规范化到 SQL_LEVELS，非法/空值回退「通用」。"""
    level = (level or "").strip()
    return level if level in SQL_LEVELS else DEFAULT_SQL_LEVEL


def sql_level(sql_name: str) -> str:
    """返回 SQL 层级，缺省或非法时回退「通用」。"""
    return normalize_sql_level(read_sql_meta(sql_name).get("level"))


def sql_scope(sql_name: str) -> tuple[str | None, str | None]:
    """返回 (level, game)：SQL 派生指标跟随来源 SQL 层级对齐用。

    文件不存在时返回 (None, None)——派生指标按个人隔离兜底（宁可隐藏，
    也不把已删文件的历史指标扩散成全局可见）。
    """
    if sql_name not in list_sql_files():
        return None, None
    meta = read_sql_meta(sql_name)
    return normalize_sql_level(meta.get("level")), meta.get("game")


def new_modification(name: str = "", prompt: str = "") -> dict:
    """生成一条新的修改描述条目，id 为 8 位 hex，作为稳定 widget key。"""
    return {"id": uuid.uuid4().hex[:8], "name": name, "prompt": prompt}


def delete_sql(sql_name: str) -> None:
    """同时删除 .sql 与同名 .sql.json（删除前自动进版本库，可回收站恢复），
    任何情况都不留孤儿元数据。"""
    name = _validate_name(sql_name)
    versioning.delete_text(SQL_DIR / name)
    versioning.delete_text(SQL_DIR / f"{name}.json")


def rename_sql(old: str, new: str) -> None:
    """原子重命名 SQL（审计建议 7）：主文件 + 元数据 json + _versions 镜像一并迁移，
    不再靠前端「存新名+删旧名」两段式丢版本历史。

    与 rename_skill/rename_doc 同构：先全量存在性检查（目标占用抛 ValueError），
    再逐项 os.replace（同卷原子），最后新名 snapshot 留痕。
    """
    old = _validate_name(old)
    new = _validate_name(new)
    if old == new:
        return
    if new in list_sql_files():
        raise ValueError(f"目标 SQL「{new}」已存在，请换一个名称")
    if not (SQL_DIR / old).exists():
        raise ValueError(f"SQL「{old}」不存在")
    vroot = versioning.VERSIONS_DIR / SQL_DIR.relative_to(versioning.PROJECT_ROOT)
    # 目标残留预检（对抗审查）：镜像目标被回收站残留占用时，磁盘改名已发生而镜像
    # os.replace 崩溃 → 半迁移。先拦，提示去回收站处理。
    for p in (SQL_DIR / f"{new}.json", vroot / new, vroot / f"{new}.json"):
        if p.exists():
            raise ValueError(
                f"目标 SQL「{new}」存在残留（元数据/回收站历史），请先在回收站恢复或彻底删除")
    for suffix in ("", ".json"):
        src, dst = SQL_DIR / f"{old}{suffix}", SQL_DIR / f"{new}{suffix}"
        if not src.exists():
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        os.replace(src, dst)
    # old 已含 .sql：镜像目录名是 <old> 与 <old>.json（与磁盘件 <name> / <name>.json 同构）
    for suffix in ("", ".json"):
        src, dst = vroot / f"{old}{suffix}", vroot / f"{new}{suffix}"
        if not src.exists():
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        os.replace(src, dst)
    versioning.snapshot(SQL_DIR / new)


def orphan_meta_files() -> list[str]:
    """自检：返回存在 .sql.json 但没有对应 .sql 的孤儿文件名（供编辑器页提示清理）。"""
    orphans = []
    for p in SQL_DIR.glob("*.sql.json"):
        if not (SQL_DIR / p.name[: -len(".json")]).exists():
            orphans.append(p.name)
    return sorted(orphans)

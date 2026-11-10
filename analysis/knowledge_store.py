"""Skill（分析方法说明）与知识库文档的文件系统 CRUD 工具。

每个 Skill / 文档就是 knowledge/skills/、knowledge/docs/ 下的一个 .md 文件，
文件名（去掉 .md 后缀）即展示名称，不需要额外的索引文件或数据库表。
"""
import json
import os
import re
from pathlib import Path

from analysis.games import visible_to, current_owner_key
from analysis import versioning

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SKILLS_DIR = PROJECT_ROOT / "knowledge" / "skills"
DOCS_DIR = PROJECT_ROOT / "knowledge" / "docs"

SKILLS_DIR.mkdir(parents=True, exist_ok=True)
DOCS_DIR.mkdir(parents=True, exist_ok=True)

_INVALID_NAME_CHARS = re.compile(r'[\\/:*?"<>|]')


def _validate_name(name: str) -> str:
    name = (name or "").strip()
    if not name:
        raise ValueError("名称不能为空")
    if _INVALID_NAME_CHARS.search(name) or name in (".", ".."):
        raise ValueError(f"名称包含非法字符：{name}")
    return name


def _list_names(directory: Path) -> list[str]:
    return sorted(p.stem for p in directory.glob("*.md"))


def _read(directory: Path, name: str) -> str:
    path = directory / f"{_validate_name(name)}.md"
    return path.read_text(encoding="utf-8") if path.exists() else ""


def _write(directory: Path, name: str, content: str) -> None:
    path = directory / f"{_validate_name(name)}.md"
    versioning.write_text(path, content.replace("\r\n", "\n"), encoding="utf-8", newline="\n")


def _delete(directory: Path, name: str) -> None:
    # 删除侧版本化（审计建议 1）：删除前自动快照，误删可从回收站/版本库恢复
    path = directory / f"{_validate_name(name)}.md"
    versioning.delete_text(path)


# ---- 专项目录打包（自包含快照）：knowledge/skills/<name>/ 目录 ----

def _skill_bundle_dir(name: str) -> Path:
    return SKILLS_DIR / _validate_name(name)


def _is_bundle(name: str) -> bool:
    """专项是否为目录打包形态（存在同名目录且含 skill.md）。

    只判目录存在会误把「残留的半截目录（无 skill.md）」当打包形态，导致 read_skill 读
    skill.md 抛 FileNotFoundError、read_skill_meta 漏读扁平同名 .json；须与 list_skills 一致判 skill.md。
    """
    return (_skill_bundle_dir(name) / "skill.md").exists()


def is_skill_bundle(name: str) -> bool:
    """专项是否为目录打包（自包含快照）形态（公开接口，供路由/前端判断内嵌快照有无）。"""
    return _is_bundle(name)


def skill_exists(name: str) -> bool:
    """专项是否存在（扁平 <名>.md 或目录打包 <名>/skill.md）。

    供缺口接口族等「按专项名直接读写」的入口先验存在性，防止对不存在（或仅残留
    run.json）的专项名写入注册文件产生垃圾落盘。名称非法时抛 ValueError（与
    _validate_name 同口径），调用方应转为 4xx。
    """
    b = _skill_bundle_dir(name)  # 先过 _validate_name（非法名抛 ValueError）
    return (b / "skill.md").exists() or (SKILLS_DIR / f"{b.name}.md").exists()


def list_skills(game: str | None = None) -> list[str]:
    """列出专项名；传 game 时按隔离规则过滤（通用 + 绑定该游戏的 项目/个人）。

    兼容两种形态：扁平 knowledge/skills/<名>.md 与目录打包 knowledge/skills/<名>/skill.md。
    """
    names = _list_names(SKILLS_DIR)
    for d in SKILLS_DIR.iterdir():
        if d.is_dir() and (d / "skill.md").exists():
            n = d.name
            if n not in names:
                names.append(n)
    names = sorted(names)
    if game is None:
        return names
    owner = current_owner_key()
    return [n for n in names
            if visible_to(skill_level(n), read_skill_meta(n).get("game"), game,
                          read_skill_meta(n).get("owner"), owner)]


def skill_online(name: str) -> bool:
    """专项是否「已上线」（对聊天/自由对话/Agent 可见）。meta.json 缺 online 字段按上线处理，
    向后兼容既有专项——不会让历史专项因新增字段突然全部下线。"""
    return bool(read_skill_meta(name).get("online", True))


def list_online_skills(game: str | None = None) -> list[str]:
    """列出「已上线」的专项名（聊天窗口下拉 / 自由对话点名 / Agent 专用候选）。

    下线中的专项（调试期暂不开放）一律不出现；专项管理侧列表仍用 list_skills 展示全部并标状态。
    """
    return [n for n in list_skills(game) if skill_online(n)]


def set_skill_online(name: str, online: bool) -> None:
    """设置专项上线/下线状态（读改写保留其它元数据字段，走版本化留痕）。"""
    data = _read_raw_skill_meta(name)
    data["online"] = bool(online)
    write_skill_meta(name, data)


def online_on_save(name: str) -> bool:
    """保存/刷新专项时 online 字段的取值：已存在专项保持现状，新建专项默认下线
    （刚创建通常还有 BUG，调试确认后再手动「上线」开放给用户）。"""
    return skill_online(name) if skill_exists(name) else False


def read_skill(name: str) -> str:
    b = _skill_bundle_dir(name)
    if _is_bundle(name):
        return (b / "skill.md").read_text(encoding="utf-8")
    return _read(SKILLS_DIR, name)


def write_skill(name: str, content: str) -> None:
    # 已是目录形态则写目录内 skill.md；否则保持扁平（新打包走 write_skill_bundle）
    b = _skill_bundle_dir(name)
    if _is_bundle(name):
        versioning.write_text(
            b / "skill.md", content.replace("\r\n", "\n"), encoding="utf-8", newline="\n"
        )
        return
    _write(SKILLS_DIR, name, content)


def _skill_meta_path(name: str) -> Path:
    return SKILLS_DIR / f"{_validate_name(name)}.json"


def read_skill_meta(name: str) -> dict:
    """读专项关联元数据（knowledge/skills/*.json）；缺文件/损坏时返回空结构。

    返回结构：{"sqls": [...], "docs": [...], "level": str|None, "game": str|None,
              "steps": [{"name", "sql", "required"}...], "forecast": str|dict|None,
              "summary": str|None, "online": bool}。
    - steps：专项的分析步骤（固定步骤 required=true + 可选下钻 required=false）；
      缺失时由 sqls 合成（全部 required，步骤名=SQL 文件名）。
    - sqls：由 steps 推导（去重），保持报告流水线等旧调用方继续可用。
    - forecast：绑定的预测/算法能力（字符串能力名，或 {"method": ..., ...覆盖项}），缺省为 None。
    - online：是否已上线（默认 True，兼容无该字段的历史专项）；下线专项对聊天/自由对话/Agent 不可见。
    """
    empty = {"sqls": [], "docs": [], "level": None, "game": None, "owner": None, "steps": [], "forecast": None, "summary": None, "online": True}
    path = _skill_bundle_dir(name) / "meta.json" if _is_bundle(name) else _skill_meta_path(name)
    if not path.exists():
        return dict(empty)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return dict(empty)
    raw_steps = data.get("steps")
    if not raw_steps:
        steps = [{"name": s, "sql": s, "required": True} for s in (data.get("sqls") or [])]
    else:
        steps = []
        for st in raw_steps:
            if not isinstance(st, dict):
                continue
            sql = (st.get("sql") or "").strip()
            if not sql:
                continue
            steps.append({
                "name": (st.get("name") or sql).strip(),
                "sql": sql,
                "required": bool(st.get("required", True)),
            })
    sqls = []
    for st in steps:
        if st["sql"] and st["sql"] not in sqls:
            sqls.append(st["sql"])
    return {
        "sqls": sqls,
        "docs": data.get("docs", []),
        "level": data.get("level"),
        "game": data.get("game"),
        "owner": data.get("owner"),
        "steps": steps,
        "forecast": data.get("forecast"),
        "summary": data.get("summary"),
        "online": data.get("online", True),
        "confidentiality": data.get("confidentiality"),
    }


def write_skill_meta(name: str, meta: dict) -> None:
    """写专项关联元数据（utf-8，ensure_ascii=False，缩进 2，随版本化留痕）。

    绑定表（sqls/docs/steps/forecast）是专项取数的核心契约，改动须像 skill.md 一样进版本库，
    否则「改专项留痕」只覆盖内容体、漏掉绑定侧（见 versioning 镜像规则）。
    """
    path = _skill_bundle_dir(name) / "meta.json" if _is_bundle(name) else _skill_meta_path(name)
    versioning.write_text(
        path,
        json.dumps(meta, ensure_ascii=False, indent=2),
        encoding="utf-8",
        newline="\n",
    )


def _read_raw_skill_meta(name: str) -> dict:
    """读专项 meta.json 原始内容（不归一化、不合成 steps），缺文件/损坏返回空 dict。"""
    path = _skill_bundle_dir(name) / "meta.json" if _is_bundle(name) else _skill_meta_path(name)
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    return data if isinstance(data, dict) else {}


def add_skill_sql(name: str, sql_key: str, step_name: str | None = None, required: bool = False) -> None:
    """把一条 SQL 追加到专项关联（meta.json），保留原有结构，不触碰其它字段。

    - sqls 追加 sql_key；steps 一并追加 {name, sql, required}（原始无 steps 时，由既有 sqls 合成全 required 后再追加）。
    - 已有同名 SQL 则跳过（幂等）。
    """
    data = _read_raw_skill_meta(name)
    sqls = data.get("sqls") if isinstance(data.get("sqls"), list) else []
    if sql_key in sqls:
        return
    if isinstance(data.get("steps"), list) and data["steps"]:
        steps = list(data["steps"])
    else:
        steps = [{"name": s, "sql": s, "required": True} for s in sqls]
    steps.append({"name": step_name or sql_key, "sql": sql_key, "required": bool(required)})
    data["sqls"] = [*sqls, sql_key]
    data["steps"] = steps
    write_skill_meta(name, data)


def add_skill_doc(name: str, doc: str) -> None:
    """把一篇知识库文档追加到专项关联 docs（meta.json），保留原有结构；已有则跳过。"""
    data = _read_raw_skill_meta(name)
    docs = data.get("docs") if isinstance(data.get("docs"), list) else []
    if doc in docs:
        return
    data["docs"] = [*docs, doc]
    write_skill_meta(name, data)


def delete_skill(name: str) -> None:
    _delete_skill_notes(name)
    if _is_bundle(name):
        _delete_bundle(name)
    else:
        # 删除侧版本化（审计建议 1）：逐件先快照再删，误删可恢复
        _delete(SKILLS_DIR, name)
    # 扁平残留统一清（打包形态也可能残留扁平 <名>.md/.json/.run.json——历史 save 扁平→打包
    # 未清，只删打包目录会让残留扁平件「复活」成同名专项，删除等于没删）。删除侧版本化，误删可回收。
    n = _validate_name(name)
    versioning.delete_text(SKILLS_DIR / f"{n}.md")
    versioning.delete_text(_skill_meta_path(n))
    versioning.delete_text(_skill_memory_path(n))


def _delete_bundle(name: str) -> None:
    """删除专项目录打包（含 sql/models/knowledge 子目录）：逐文件快照后整目录删。"""
    versioning.delete_tree(_skill_bundle_dir(name))


def _move_path(src: Path, dst: Path) -> None:
    """同卷原子改名：目标已存在时抛错（绝不静默覆盖），源不存在则跳过。

    对抗审查：此前 docstring 声称目标已存在抛错、实现却直接 os.replace（文件静默
    覆盖/目录非空崩溃）；补上检查——rename 系列已在上游做全量预检，这里兜底。"""
    if not src.exists():
        return
    if dst.exists():
        raise ValueError(f"目标已存在，无法改名：{dst.name}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    os.replace(src, dst)


def rename_skill(old: str, new: str) -> None:
    """原子重命名专项（审计 P1-15）：主文件/目录打包 + 扁平元数据/运行记忆 + 笔记 +
    _versions 版本库镜像一并迁移，不再靠「先存新名再删旧名」丢版本/快照历史。

    先做全部存在性检查，再逐项 os.replace（同卷原子，不会出现半迁移中间态）；
    目标名被占用或旧名不存在抛 ValueError，任何一步失败均不静默吞错。
    """
    old = _validate_name(old)
    new = _validate_name(new)
    if old == new:
        return
    if new in list_skills():
        raise ValueError(f"目标专项「{new}」已存在，请换一个名称")
    if not (_is_bundle(old) or (SKILLS_DIR / f"{old}.md").exists()):
        raise ValueError(f"专项「{old}」不存在")

    bundle = _is_bundle(old)
    vroot = versioning.VERSIONS_DIR / SKILLS_DIR.relative_to(versioning.PROJECT_ROOT)
    # 目标残留预检（对抗审查）：meta/run.json/笔记/版本镜像任一目标已被占用（曾删过
    # 同名工件、回收站未清）都在此拦截——os.replace 目录→非空目录在 Windows 抛
    # PermissionError，且此时磁盘改名已发生（半迁移），先拦让用户去回收站处理。
    # 打包/扁平两形态镜像都要查（改名可跨形态：旧打包→新扁平或反之）。
    checks = [
        _skill_meta_path(new), _skill_memory_path(new), _skill_notes_path(new),
        vroot / new, vroot / f"{new}.md", vroot / f"{new}.json", vroot / f"{new}.run.json",
        vroot / ".notes" / f"{new}.md",
    ]
    for p in checks:
        if p.exists():
            raise ValueError(
                f"目标专项「{new}」存在残留（元数据/笔记/回收站历史），请先在回收站恢复或彻底删除")
    # 1) 主工件：目录打包 → 整目录改名（skill.md/meta.json/run.json/内嵌快照一并带走）；
    #    扁平 → md + 关联元数据 + 运行记忆（缺口登记册也在 run.json 里，随迁）
    if bundle:
        _move_path(_skill_bundle_dir(old), _skill_bundle_dir(new))
        # 打包形态仍可能残留扁平 <旧名>.md/.json/.run.json（历史 save 扁平→打包未清、
        # 或早期数据遗留）：改名只搬打包目录，残留扁平件会被 list_skills 当「旧名复活」
        # 的第二个专项列出。这里一并删除侧版本化清掉（内容已在打包件/版本库，不丢数据）。
        for stale in (SKILLS_DIR / f"{old}.md", _skill_meta_path(old), _skill_memory_path(old)):
            if stale.is_file():
                versioning.delete_text(stale)
    else:
        _move_path(SKILLS_DIR / f"{old}.md", SKILLS_DIR / f"{new}.md")
        _move_path(_skill_meta_path(old), _skill_meta_path(new))
        _move_path(_skill_memory_path(old), _skill_memory_path(new))
    # 2) 专项笔记（knowledge/skills/.notes/<名>.md）
    _move_path(_skill_notes_path(old), _skill_notes_path(new))
    # 3) 版本库镜像：_versions/knowledge/skills/<旧名>* → <新名>*（目录打包的版本都在同名子目录下）；
    #    笔记的版本镜像（vroot/.notes/<名>.md）与打包形态无关，两分支都要迁，否则改名后
    #    笔记留痕链断裂（旧版本成孤儿、新名下从零建历史）
    if bundle:
        _move_path(vroot / old, vroot / new)
        _move_path(vroot / ".notes" / f"{old}.md", vroot / ".notes" / f"{new}.md")
    else:
        for suffix in (".md", ".json", ".run.json"):
            _move_path(vroot / f"{old}{suffix}", vroot / f"{new}{suffix}")
        _move_path(vroot / ".notes" / f"{old}.md", vroot / ".notes" / f"{new}.md")
    # 4) 留痕：新名当前内容进版本库（改名本身可溯源、可回滚）
    if bundle:
        versioning.snapshot(_skill_bundle_dir(new) / "skill.md")
    else:
        versioning.snapshot(SKILLS_DIR / f"{new}.md")


def rename_doc(old: str, new: str) -> None:
    """原子重命名知识库文档（审计建议 7）：主文件 + 元数据 json + _versions 镜像一并迁移，
    不再靠前端「存新名+删旧名」两段式丢版本历史。

    与 rename_skill 同构：先全量存在性检查（目标占用抛 ValueError），再逐项 os.replace，
    最后新名 snapshot 留痕。
    """
    old = _validate_name(old)
    new = _validate_name(new)
    if old == new:
        return
    if new in list_docs():
        raise ValueError(f"目标文档「{new}」已存在，请换一个名称")
    if not (DOCS_DIR / f"{old}.md").exists():
        raise ValueError(f"文档「{old}」不存在")
    vroot = versioning.VERSIONS_DIR / DOCS_DIR.relative_to(versioning.PROJECT_ROOT)
    # 目标残留预检（对抗审查）：镜像目标被回收站残留占用时，磁盘改名已发生而镜像
    # os.replace 崩溃 → 半迁移。先拦，提示去回收站处理。
    for p in (_doc_meta_path(new), vroot / f"{new}.md", vroot / f"{new}.json"):
        if p.exists():
            raise ValueError(
                f"目标文档「{new}」存在残留（元数据/回收站历史），请先在回收站恢复或彻底删除")
    _move_path(DOCS_DIR / f"{old}.md", DOCS_DIR / f"{new}.md")
    _move_path(_doc_meta_path(old), _doc_meta_path(new))
    for suffix in (".md", ".json"):
        _move_path(vroot / f"{old}{suffix}", vroot / f"{new}{suffix}")
    versioning.snapshot(DOCS_DIR / f"{new}.md")


def _prune_dir(dirpath: Path, keep_names: set[str]) -> None:
    """删除目录里不在 keep_names 中的文件（清理已解除关联的孤儿快照）。

    删除侧版本化（审计建议 1）：孤儿冻结件先快照再删——解绑属于隐式删除，
    同样进版本库可恢复。
    """
    if not dirpath.is_dir():
        return
    for p in dirpath.iterdir():
        if p.is_file() and p.name not in keep_names:
            versioning.delete_text(p)


# ---- 专项运行记忆（每个专项仅 1 份，覆盖保存最近一次运行过程/问题）----

def _skill_memory_path(name: str) -> Path:
    return SKILLS_DIR / f"{_validate_name(name)}.run.json"


def read_skill_memory(name: str) -> dict:
    """读专项最近一次运行记忆（knowledge/skills/*.run.json 或目录内 run.json）；缺文件/损坏返回空 dict。

    返回结构：{"skill", "updated_at", "drilldowns": [...], "problems": [...]}。
    """
    path = _skill_bundle_dir(name) / "run.json" if _is_bundle(name) else _skill_memory_path(name)
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    return data if isinstance(data, dict) else {}


def write_skill_memory(name: str, memory: dict) -> None:
    """写专项运行记忆（覆盖写，保证每专项只保留最近一次）。

    走 versioning.write_text（审计建议 3：run.json 进版本库）；写入前内容比对、
    相同则跳过——run.json 每次专项运行都会更新，避免无变化时产版本文件撑爆版本库。
    """
    path = _skill_bundle_dir(name) / "run.json" if _is_bundle(name) else _skill_memory_path(name)
    text = json.dumps(memory, ensure_ascii=False, indent=2)
    if path.is_file():
        try:
            if path.read_text(encoding="utf-8") == text:
                return
        except OSError:
            pass
    versioning.write_text(
        path,
        text,
        encoding="utf-8",
        newline="\n",
    )


# ---- 专项笔记（增补知识槽）：全局知识库之外、仅本专项生效的补充口径/经验 ----

def _skill_notes_dir() -> Path:
    d = SKILLS_DIR / ".notes"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _skill_notes_path(name: str) -> Path:
    return _skill_notes_dir() / f"{_validate_name(name)}.md"


def read_skill_notes(name: str) -> str:
    """读专项笔记（knowledge/skills/.notes/<名>.md）；不存在返回空串。

    笔记是「增补」而非「改写」：报告生成时与全局知识库 / 专项方法一起注入，
    用于沉淀本专项特有口径、踩坑经验、常见归因落点等，不影响全局库。
    """
    p = _skill_notes_path(name)
    return p.read_text(encoding="utf-8") if p.exists() else ""


def write_skill_notes(name: str, content: str) -> None:
    """写专项笔记（覆盖写；置空可清空）。"""
    versioning.write_text(
        _skill_notes_path(name), (content or "").replace("\r\n", "\n"), encoding="utf-8", newline="\n"
    )


def _delete_skill_notes(name: str) -> None:
    """删除专项笔记（走版本化删除：先快照进 _versions，误删可回收站恢复——
    对抗审查：此前裸 unlink，与删除侧版本化（审计建议 1）不一致，笔记留痕链断）。"""
    versioning.delete_text(_skill_notes_path(name))


# ---- 专项层级（通用 / 项目 / 个人）----

SKILL_LEVELS = ["通用", "项目", "个人"]
DEFAULT_SKILL_LEVEL = "通用"


def normalize_skill_level(level: str) -> str:
    """把任意层级值规范化到 SKILL_LEVELS，非法/空值回退「通用」。"""
    level = (level or "").strip()
    return level if level in SKILL_LEVELS else DEFAULT_SKILL_LEVEL


def skill_level(name: str) -> str:
    """返回专项层级，缺省或非法时回退「通用」。"""
    return normalize_skill_level(read_skill_meta(name).get("level"))


def list_docs(game: str | None = None) -> list[str]:
    """列出文档名；传 game 时按隔离规则过滤（通用 + 绑定该游戏的 项目/个人，个人再按当前用户归属）。"""
    names = _list_names(DOCS_DIR)
    if game is None:
        return names
    owner = current_owner_key()
    return [n for n in names
            if visible_to(doc_level(n), read_doc_meta(n).get("game"), game,
                          read_doc_meta(n).get("owner"), owner)]


def read_doc(name: str) -> str:
    return _read(DOCS_DIR, name)


def write_doc(name: str, content: str) -> None:
    _write(DOCS_DIR, name, content)


def delete_doc(name: str) -> None:
    # 删除侧版本化（审计建议 1）：md 与元数据 json 逐件先快照再删
    _delete(DOCS_DIR, name)
    versioning.delete_text(_doc_meta_path(name))


# ---- 文档层级（通用 / 项目 / 个人）----

DOC_LEVELS = ["通用", "项目", "个人"]
DEFAULT_DOC_LEVEL = "通用"


def _doc_meta_path(name: str) -> Path:
    return DOCS_DIR / f"{_validate_name(name)}.json"


def read_doc_meta(name: str) -> dict:
    """读文档元数据（knowledge/docs/*.json）；缺文件/损坏时返回空 dict。"""
    path = _doc_meta_path(name)
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    return data if isinstance(data, dict) else {}


def write_doc_meta(name: str, meta: dict) -> None:
    """写文档元数据（utf-8，ensure_ascii=False，缩进 2）。

    走 versioning.write_text（审计建议 3：配套 json 进版本库，与 write_skill_meta 一致）。
    """
    path = _doc_meta_path(name)
    versioning.write_text(
        path,
        json.dumps(meta, ensure_ascii=False, indent=2),
        encoding="utf-8",
        newline="\n",
    )


def doc_level(name: str) -> str:
    """返回文档层级，缺省或非法时回退「通用」。"""
    return normalize_level(read_doc_meta(name).get("level"))


def normalize_level(level: str) -> str:
    """把任意层级值规范化到 DOC_LEVELS，非法/空值回退「通用」。"""
    level = (level or "").strip()
    return level if level in DOC_LEVELS else DEFAULT_DOC_LEVEL


# ---- 专项目录打包：内嵌快照（SQL / 模型代码 / 知识库）+ 溯源 ----

def write_skill_bundle(
    name: str,
    content: str,
    meta: dict,
    sqls: dict[str, str] | None = None,
    models: dict[str, str] | None = None,
    knowledge: dict[str, str] | None = None,
    provenance: dict | None = None,
) -> None:
    """整包写入自包含专项：skill.md + meta.json + sql/<key>.sql + models/<m>.py + knowledge/<d>.md + provenance.json。

    - sqls: {key: 改写后冻结 SQL}（key 即 meta.steps[].sql）
    - models: {method: 完整算法代码}（外部模型）
    - knowledge: {doc 名: 精简后核心内容}
    - provenance: {sql:{key:{source,fingerprint}}, models:{...}, knowledge:{...}}
    """
    b = _skill_bundle_dir(name)
    b.mkdir(parents=True, exist_ok=True)
    versioning.write_text(b / "skill.md", (content or "").replace("\r\n", "\n"), encoding="utf-8", newline="\n")
    write_skill_meta(name, meta)

    (b / "sql").mkdir(parents=True, exist_ok=True)
    for key, text in (sqls or {}).items():
        safe = _validate_name(str(key))
        versioning.write_text(b / "sql" / safe, (text or "").replace("\r\n", "\n"), encoding="utf-8", newline="\n")

    (b / "models").mkdir(parents=True, exist_ok=True)
    for method, code in (models or {}).items():
        safe = _validate_name(str(method))
        versioning.write_text(b / "models" / safe, (code or "").replace("\r\n", "\n"), encoding="utf-8", newline="\n")

    (b / "knowledge").mkdir(parents=True, exist_ok=True)
    for doc, text in (knowledge or {}).items():
        safe = _validate_name(str(doc))
        safe = safe if safe.endswith(".md") else safe + ".md"
        versioning.write_text(b / "knowledge" / safe, (text or "").replace("\r\n", "\n"), encoding="utf-8", newline="\n")

    if provenance is not None:
        # 审计建议 3：provenance.json 进版本库（与 skill.md/meta.json 同等待遇）
        versioning.write_text(
            b / "provenance.json",
            json.dumps(provenance, ensure_ascii=False, indent=2), encoding="utf-8", newline="\n",
        )

    # 快照与关联项一一对应：清掉已解除关联的孤儿冻结件（sql/models/knowledge 只保留本次关联到的）
    _prune_dir(b / "sql", {_validate_name(str(k)) for k in (sqls or {})})
    _prune_dir(b / "models", {_validate_name(str(m)) for m in (models or {})})
    keep_knowledge = set()
    for d in (knowledge or {}):
        s = _validate_name(str(d))
        keep_knowledge.add(s if s.endswith(".md") else s + ".md")
    _prune_dir(b / "knowledge", keep_knowledge)

    # 扁平残留清理（改名「旧名复活」根因）：本函数把专项写成目录打包形态；若此前是
    # 扁平形态（<名>.md/.json/.run.json），这些扁平件已成孤儿——不与打包目录同级清掉，
    # 后续改名时会被 list_skills 当第二个专项列出（旧名与打包新名并存）。删除侧版本化，
    # 内容已在打包件中不丢，误删可回收。
    for stale in (SKILLS_DIR / f"{_validate_name(name)}.md", _skill_meta_path(name), _skill_memory_path(name)):
        if stale.is_file():
            versioning.delete_text(stale)


def read_skill_sql(name: str, key: str) -> str:
    """专项包内冻结 SQL；未快照（无目录/无该 key）回退独立 sql/ 库按名加载。"""
    if not key:
        return ""
    b = _skill_bundle_dir(name)
    if _is_bundle(name):
        try:
            p = b / "sql" / _validate_name(str(key))
        except ValueError:
            p = None
        if p is not None and p.exists():
            return p.read_text(encoding="utf-8")
    from . import sql_store
    return sql_store.read_sql(str(key))


def read_skill_model(name: str, method: str) -> str:
    """专项包内冻结算法代码；未快照回退 code/ 库按名加载。"""
    if not method:
        return ""
    b = _skill_bundle_dir(name)
    if _is_bundle(name):
        try:
            p = b / "models" / _validate_name(str(method))
        except ValueError:
            p = None
        if p is not None and p.exists():
            return p.read_text(encoding="utf-8")
    from . import code_store
    return code_store.read_code(str(method))


def read_skill_knowledge(name: str, doc: str) -> str:
    """专项包内冻结知识库核心内容；未快照回退 knowledge/docs/ 按名加载。"""
    if not doc:
        return ""
    b = _skill_bundle_dir(name)
    if _is_bundle(name):
        for suffix in (".md", ""):
            try:
                p = b / "knowledge" / (str(doc) + suffix)
            except ValueError:
                continue
            if p.exists():
                return p.read_text(encoding="utf-8")
    return read_doc(str(doc))


def write_skill_piece(name: str, kind: str, key: str, content: str) -> None:
    """就地写回单个冻结件（不改 provenance、不改其它冻结件）。kind ∈ {sql, model, knowledge}。"""
    b = _skill_bundle_dir(name)
    if not _is_bundle(name):
        raise ValueError("该专项不是目录打包形态，无法就地编辑快照")
    if kind == "sql":
        p = b / "sql" / _validate_name(str(key))
    elif kind == "model":
        p = b / "models" / _validate_name(str(key))
    elif kind == "knowledge":
        stem = str(key)
        if stem.endswith(".md"):
            stem = stem[:-3]
        p = b / "knowledge" / (_validate_name(stem) + ".md")
    else:
        raise ValueError(f"未知冻结件类型：{kind}")
    p.parent.mkdir(parents=True, exist_ok=True)
    versioning.write_text(p, (content or "").replace("\r\n", "\n"), encoding="utf-8", newline="\n")


def delete_skill_piece(name: str, kind: str, key: str) -> None:
    """删除单个冻结件及其溯源记录（不改 meta 关联；删除后运行回退到全局源）。"""
    b = _skill_bundle_dir(name)
    if not _is_bundle(name):
        raise ValueError("该专项不是目录打包形态，无法删除快照")
    if kind == "sql":
        p = b / "sql" / _validate_name(str(key))
        section = "sql"
    elif kind == "model":
        p = b / "models" / _validate_name(str(key))
        section = "models"
    elif kind == "knowledge":
        stem = str(key)
        if stem.endswith(".md"):
            stem = stem[:-3]
        p = b / "knowledge" / (_validate_name(stem) + ".md")
        section = "knowledge"
    else:
        raise ValueError(f"未知冻结件类型：{kind}")
    # 删除侧版本化（审计建议 1）：冻结件先快照再删，误删可恢复
    versioning.delete_text(p)
    # 同步删除溯源记录（无记录/键不存在则跳过写回）
    prov = read_skill_provenance(name)
    section_map = prov.get(section) if isinstance(prov.get(section), dict) else {}
    if key in section_map:
        del section_map[key]
        # 审计建议 3：provenance.json 回写进版本库
        versioning.write_text(
            b / "provenance.json",
            json.dumps(prov, ensure_ascii=False, indent=2), encoding="utf-8", newline="\n",
        )


def read_skill_provenance(name: str) -> dict:
    """读专项溯源（knowledge/skills/<名>/provenance.json）；缺失/损坏返回空 dict。

    结构：{"sql": {key: {source, fingerprint}}, "models": {...}, "knowledge": {...}}。
    """
    p = _skill_bundle_dir(name) / "provenance.json"
    if not p.exists():
        return {}
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    return data if isinstance(data, dict) else {}


def write_skill_provenance(name: str, prov: dict) -> None:
    """写专项溯源（knowledge/skills/<名>/provenance.json），整体覆盖。

    走 versioning.write_text（审计建议 3：provenance.json 进版本库）。
    """
    b = _skill_bundle_dir(name)
    if not _is_bundle(name):
        raise ValueError("该专项不是目录打包形态，无 provenance")
    b.mkdir(parents=True, exist_ok=True)
    versioning.write_text(
        b / "provenance.json",
        json.dumps(prov, ensure_ascii=False, indent=2), encoding="utf-8", newline="\n",
    )


def _current_source(kind: str, src: str) -> str:
    """读某类源工件的当前内容（供漂移比对）。"""
    if kind == "sql":
        from . import sql_store
        return sql_store.read_sql(src)
    if kind == "model":
        from . import code_store
        return code_store.read_code(src)
    return read_doc(src)


def _current_snapshot(kind: str, name: str, key: str) -> str:
    """读专项包内某冻结件的当前内容（供「本地改编」漂移比对）。"""
    if kind == "sql":
        return read_skill_sql(name, key)
    if kind == "model":
        return read_skill_model(name, key)
    return read_skill_knowledge(name, key)


def skill_drift(name: str) -> list[dict]:
    """返回专项快照里「源已改动需刷新」的条目 [{kind, name, key, state, mode}]。

    只把「源向前走了」（drifted/both）算漂移；纯「本地改编」（adapted）不在此列，
    交由 skill_snapshot_states 三态另行展示。空列表 = 全部最新。
    """
    from .snapshot import drift_state, normalize_mode
    prov = read_skill_provenance(name)
    out = []
    for section, kind in (("sql", "sql"), ("models", "model"), ("knowledge", "doc")):
        for key, entry in (prov.get(section) or {}).items():
            if not isinstance(entry, dict):
                continue
            src = entry.get("source")
            if not src:
                continue
            state = drift_state(entry, _current_source(kind, src), _current_snapshot(kind, name, key))
            if state in ("drifted", "both"):
                out.append({
                    "kind": kind, "name": src, "key": key,
                    "state": state, "mode": normalize_mode(entry.get("mode")),
                })
    return out


def skill_snapshot_states(name: str) -> dict:
    """三态快照状态：{section: {key: {state, mode, source}}}。

    section ∈ sql/models/knowledge；state ∈ clean/drifted/adapted/both/orphan。
    供前端区分「全局动了」「专项改了」「已锁定」「无外部源」，而非单一漂移布尔。
    """
    from .snapshot import drift_state, normalize_mode
    prov = read_skill_provenance(name)
    out: dict[str, dict] = {}
    for section, kind in (("sql", "sql"), ("models", "model"), ("knowledge", "doc")):
        sec: dict[str, dict] = {}
        for key, entry in (prov.get(section) or {}).items():
            if not isinstance(entry, dict):
                continue
            src = (entry.get("source") or "").strip()
            state = drift_state(
                entry,
                _current_source(kind, src) if src else None,
                _current_snapshot(kind, name, key),
            )
            sec[key] = {"state": state, "mode": normalize_mode(entry.get("mode")), "source": src}
        out[section] = sec
    return out


def mark_skill_piece_adapted(name: str, kind: str, key: str, content: str) -> None:
    """手工改编某冻结件后，把溯源标为 adapted 并刷新 content_fingerprint。

    这样三态漂移能区分「专项改了」（adapted）与「全局动了」（drifted），
    而非把本地改编淹没在「源更新」里。仅对目录打包专项生效。
    """
    b = _skill_bundle_dir(name)
    if not _is_bundle(name):
        return
    from .snapshot import fingerprint
    section_map = {"sql": "sql", "model": "models", "knowledge": "knowledge"}.get(kind)
    if not section_map:
        return
    prov = read_skill_provenance(name)
    section = prov.setdefault(section_map, {})
    entry = section.get(key)
    if isinstance(entry, dict):
        entry["mode"] = "adapted"
        entry["content_fingerprint"] = fingerprint(content)
    else:
        section[key] = {
            "source": key,
            "fingerprint": fingerprint(_current_source(kind, key)),
            "mode": "adapted",
            "content_fingerprint": fingerprint(content),
        }
    # 审计建议 3：provenance.json 回写进版本库
    versioning.write_text(
        b / "provenance.json",
        json.dumps(prov, ensure_ascii=False, indent=2), encoding="utf-8", newline="\n",
    )

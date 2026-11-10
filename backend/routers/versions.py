"""工件版本回滚接口：列出某工件最近版本 + 回滚到指定版本。

版本库由 analysis/versioning.py 在写文件时自动维护（保留最近 7 天）。
本路由把 kind+name 解析成目标文件，透传给 versioning.list_versions / restore。
"""
import json
import os
import re
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from ..deps import get_current_user, require_analysis_edit, require_analysis_delete
from analysis import code_store, knowledge_store, sql_store
from analysis import versioning
from analysis.games import owner_key

router = APIRouter(prefix="/api/admin/versions", tags=["versions"])


_INVALID_NAME_CHARS = re.compile(r'[\\/:*?"<>|]')


def _safe_name(name: str) -> str:
    """工件名路径安全校验：拒绝空名、路径分隔符与 . / ..，防 ../ 穿越到存储目录之外。"""
    name = (name or "").strip()
    if not name or _INVALID_NAME_CHARS.search(name) or name in (".", ".."):
        raise HTTPException(status_code=400, detail=f"非法工件名称：{name!r}")
    return name


def _safe_version_file(version_file: str) -> str:
    """版本文件名必须是裸文件名（无目录成分），防 ../../ 穿越读取任意文件。"""
    vf = (version_file or "").strip()
    if not vf or vf != Path(vf).name or vf in (".", ".."):
        raise HTTPException(status_code=400, detail=f"非法版本文件名：{vf!r}")
    return vf


def _target(kind: str, name: str):
    """把 kind+name 解析成目标文件路径（name 经路径安全校验）。"""
    name = _safe_name(name)
    if kind == "sql":
        return sql_store.SQL_DIR / name
    if kind == "model":
        return code_store.CODE_DIR / (name if name.endswith(".py") else name + ".py")
    if kind == "doc":
        return knowledge_store.DOCS_DIR / f"{name}.md"
    if kind == "skill":
        b = knowledge_store._skill_bundle_dir(name)
        return (b / "skill.md") if b.is_dir() else (knowledge_store.SKILLS_DIR / f"{name}.md")
    raise HTTPException(status_code=400, detail=f"未知工件类型：{kind}")


def _read_meta(kind: str, name: str) -> dict:
    """读工件 meta（不存在则返回空 dict）。"""
    try:
        if kind == "sql":
            return sql_store.read_sql_meta(name)
        if kind == "model":
            return code_store.read_code_meta(name)
        if kind == "doc":
            return knowledge_store.read_doc_meta(name)
        if kind == "skill":
            return knowledge_store.read_skill_meta(name)
    except (FileNotFoundError, OSError):
        pass
    return {}


def _check_ownership(kind: str, name: str, user: dict) -> None:
    """「个人」级工件归属校验：仅归属人本人可查看/回滚其版本；其余层级交给权限闸门。

    对抗审查：工件已删除（meta 随删、_read_meta 返回空）时，从 _versions 镜像里
    最后一份 meta 快照复核归属——防止他人经「已删工件的版本列表/diff」读到内容。
    """
    try:
        meta = _read_meta(kind, name)
    except (FileNotFoundError, OSError):
        meta = {}
    except ValueError:
        # 各 store 的名称校验与 _safe_name 同口径，但兜底防 500（如 code/knowledge store 自校验）
        raise HTTPException(status_code=400, detail=f"非法工件名称：{name!r}")
    if meta.get("level") == "个人" and owner_key(user) != meta.get("owner"):
        raise HTTPException(status_code=403, detail="仅归属人可访问「个人」级工件的版本")
    if not meta.get("level") and not _has_system(user):
        # meta 缺失（已删或从未建档）→ 读镜像快照复核归属，宁拦勿泄
        cands = _deleted_owner_candidates(_rel_for(kind, name))
        if kind == "skill":
            cands = cands + [f"knowledge/skills/{_safe_name(name)}/meta.json"]
        owner = _mirror_owner(cands)
        if owner and owner != owner_key(user):
            raise HTTPException(status_code=403, detail="仅归属人可访问「个人」级工件的版本")


def _has_system(user: dict) -> bool:
    from backend.ide_app.services.permissions import has_perm
    return bool(has_perm(user, "system"))


def _rel_for(kind: str, name: str) -> str:
    """kind+name → 主件相对 PROJECT_ROOT 的路径（供已删工件镜像归属回溯）。"""
    name = _safe_name(name)
    if kind == "sql":
        return f"sql/{name if name.endswith('.sql') else name + '.sql'}"
    if kind == "model":
        return f"code/{name if name.endswith('.py') else name + '.py'}"
    if kind == "doc":
        return f"knowledge/docs/{name if name.endswith('.md') else name + '.md'}"
    if kind == "skill":
        return f"knowledge/skills/{name}.md"
    raise HTTPException(status_code=400, detail=f"未知工件类型：{kind}")


def _deleted_owner_candidates(rel: str) -> list[str]:
    """已删工件归属的元数据镜像 rel 候选（依序尝试，第一个读到 owner 的生效）。

    元数据随主件一并删除，归属只能从 _versions 里最后一份 meta 快照读；
    候选按工件族映射：sql/<名>.sql→<名>.sql.json、code/<名>.py→<名>.py.json、
    code/<名>.sql→<名>.py.json、docs/<名>.md→<名>.json、扁平专项→<名>.json、
    bundle 内件→<名>/meta.json、笔记→专项 meta（扁平/bundle 双查）。
    """
    cands = [rel]
    if rel.startswith("sql/") and rel.endswith(".sql"):
        cands.append(rel + ".json")
    elif rel.startswith("code/"):
        if rel.endswith(".py"):
            cands.append(rel + ".json")
        elif rel.endswith(".sql"):
            cands.append(rel[: -len(".sql")] + ".py.json")
    elif rel.endswith(".md"):
        if "/docs/" in rel:
            cands.append(rel[: -len(".md")] + ".json")
        elif "/.notes/" in rel:
            name = rel[: -len(".md")].rsplit("/", 1)[-1]
            cands.append(f"knowledge/skills/{name}.json")
            cands.append(f"knowledge/skills/{name}/meta.json")
        elif rel.startswith("knowledge/skills/"):
            rest = rel[len("knowledge/skills/"):]
            if "/" in rest:
                name = rest.split("/")[0]  # bundle 内件
                cands.append(f"knowledge/skills/{name}/meta.json")
            else:
                cands.append(rel[: -len(".md")] + ".json")  # 扁平专项
    elif rel.startswith("knowledge/skills/") and rel.count("/") >= 3:
        # bundle 内非 .md 件（run.json/provenance.json/sql/…）→ 专项 meta
        name = rel.split("/")[2]
        cands.append(f"knowledge/skills/{name}/meta.json")
    return cands


def _mirror_owner(candidates: list[str]) -> str | None:
    """从版本镜像读已删工件的 owner（取每个候选镜像目录里最新一份快照的 owner 字段）。"""
    for rel in candidates:
        vdir = versioning.VERSIONS_DIR / Path(rel)
        if not vdir.is_dir():
            continue
        try:
            latest = sorted(
                (p for p in vdir.iterdir() if p.is_file()),
                key=lambda p: p.stat().st_mtime, reverse=True,
            )[0]
            data = json.loads(latest.read_text(encoding="utf-8"))
            owner = data.get("owner") if isinstance(data, dict) else None
        except (IndexError, OSError, ValueError):
            owner = None
        if owner:
            return owner
    return None


def _ensure_deleted_access(rel: str, user: dict) -> None:
    """回收站条目归属校验（对抗审查）：他人「个人」级工件仅归属人/管理员可恢复、
    彻底删除。读不到 owner（删除侧版本化上线前的历史遗留，无 owner 字段）按无主放行。"""
    owner = _mirror_owner(_deleted_owner_candidates(rel))
    if owner and owner != owner_key(user) and not _has_system(user):
        raise HTTPException(status_code=403, detail="仅归属人或管理员可操作该回收站条目")


@router.get("")
def list_versions(kind: str, name: str, user: dict = Depends(get_current_user)):
    """列出某工件的全部历史版本（时间倒序）。"""
    target = _target(kind, name)  # 名称/类型校验（400）前置，meta 读取才安全（对抗审查 LOW）
    _check_ownership(kind, name, user)
    return {"versions": versioning.list_versions(target)}


class RestoreReq(BaseModel):
    kind: str
    name: str
    version_file: str


@router.get("/diff")
def diff_version(kind: str, name: str, version_file: str, user: dict = Depends(get_current_user)):
    """「版本 vs 当前」统一 diff（P1-16）：只读对比，回滚才需 analysis_edit；归属校验同列表。"""
    target = _target(kind, name)  # 名称/类型校验（400）前置（对抗审查 LOW：穿越名须 400 而非 500）
    _check_ownership(kind, name, user)
    result = versioning.diff_version(target, _safe_version_file(version_file))
    if result is None:
        raise HTTPException(status_code=404, detail="版本不存在")
    text, truncated = result
    return {"diff": text, "truncated": truncated}


@router.post("/restore")
def restore_version(body: RestoreReq, user: dict = Depends(require_analysis_edit)):
    """把指定版本回滚到目标工件（回滚前自动备份当前，可再反悔）。需 analysis_edit + 归属校验。"""
    target = _target(body.kind, body.name)  # 校验前置，同 list/diff
    _check_ownership(body.kind, body.name, user)
    if not versioning.restore(target, _safe_version_file(body.version_file)):
        raise HTTPException(status_code=404, detail="版本不存在")
    return {"ok": True}


# ── 回收站（审计建议 8，2026-10-21）─────────────────────────────────
# 删除侧版本化后，已删工件的版本镜像留在 _versions（保留 30 天）。
# 本组端点把 versioning.list_deleted / restore / purge_versions 透出给管理端。

def _safe_rel(rel: str) -> Path:
    """回收站条目路径校验：必须是相对路径、无 .. / 绝对前缀，解析后仍落在 PROJECT_ROOT 内。

    rel 来自服务端 rglob 输出（相对 _versions 的路径），出现 .. 只可能是伪造输入；
    双重校验防 ../ 穿越把任意版本文件拷回任意位置。
    """
    rel = (rel or "").strip().replace("\\", "/")
    if not rel or rel.startswith("/") or "\x00" in rel:
        raise HTTPException(status_code=400, detail=f"非法路径：{rel!r}")
    parts = [p for p in rel.split("/") if p]
    if any(p in (".", "..") for p in parts) or not parts:
        raise HTTPException(status_code=400, detail=f"非法路径：{rel!r}")
    root = versioning.PROJECT_ROOT.resolve()
    target = (versioning.PROJECT_ROOT / rel).resolve()
    if not (str(target) + os.sep).startswith(str(root) + os.sep) and str(target) != str(root):
        raise HTTPException(status_code=400, detail=f"非法路径：{rel!r}")
    return target


@router.get("/deleted")
def list_deleted(user: dict = Depends(require_analysis_edit)):
    """回收站列表：源文件已删除、版本镜像仍在（30 天窗口）的工件。需 analysis_edit。

    对抗审查：他人「个人」级工件不进列表（owner 从镜像 meta 快照读，无主老工件放行）。
    """
    items = versioning.list_deleted()
    if not _has_system(user):
        me = owner_key(user)
        items = [
            it for it in items
            if _mirror_owner(_deleted_owner_candidates(it["rel"])) in (None, me)
        ]
    return {"items": items}


class DeletedRestore(BaseModel):
    rel: str
    version_file: str | None = None  # 缺省恢复最新版本


@router.post("/deleted/restore")
def restore_deleted(body: DeletedRestore, user: dict = Depends(require_analysis_delete)):
    """回收站恢复：把已删工件的某个版本（缺省最新）拷回原路径。需 analysis_delete。

    对抗审查：①归属校验同列表；②主件恢复联动恢复配套元数据（先 meta 后主件）——
    只恢复主件会让 level/owner 丢失，个人级工件回落「通用」全员可见（越权面扩大）。
    """
    target = _safe_rel(body.rel)
    _ensure_deleted_access(body.rel, user)
    vdir = versioning._versions_subdir(target)
    if body.version_file:
        vf = _safe_version_file(body.version_file)
        if not (vdir / vf).is_file():
            raise HTTPException(status_code=404, detail="版本不存在")
    else:
        if not vdir.is_dir():
            raise HTTPException(status_code=404, detail="回收站无此工件的可恢复版本")
        candidates = sorted(
            (p for p in vdir.iterdir() if p.is_file()),
            key=lambda p: p.stat().st_mtime, reverse=True,
        )
        if not candidates:
            raise HTTPException(status_code=404, detail="回收站无此工件的可恢复版本")
        vf = candidates[0].name
    # 配套元数据联动恢复（镜像无版本/源已在则跳过，不因 meta 失败阻断主件恢复）
    for meta_rel in _deleted_owner_candidates(body.rel)[1:]:
        mtarget = _safe_rel(meta_rel)
        mvdir = versioning._versions_subdir(mtarget)
        if not mvdir.is_dir() or mtarget.exists():
            continue
        mfiles = sorted(
            (p for p in mvdir.iterdir() if p.is_file()),
            key=lambda p: p.stat().st_mtime, reverse=True,
        )
        if not mfiles:
            continue
        mtarget.parent.mkdir(parents=True, exist_ok=True)
        versioning.restore(mtarget, mfiles[0].name)
    target.parent.mkdir(parents=True, exist_ok=True)
    if not versioning.restore(target, vf):
        raise HTTPException(status_code=404, detail="版本不存在")
    return {"ok": True}


class DeletedPurge(BaseModel):
    rel: str


@router.delete("/deleted")
def purge_deleted(body: DeletedPurge, user: dict = Depends(require_analysis_delete)):
    """彻底删除回收站条目（全部版本，不可恢复）。需 analysis_delete。

    对抗审查：①归属校验；②只允许删「回收站实际列出的条目」——防把在用工件的全部
    版本历史抹掉，也防 rel 指到中间镜像目录时整树误删（versioning.purge_versions
    对这两种情况本身也防御，路由层再兜一道）。
    """
    target = _safe_rel(body.rel)
    _ensure_deleted_access(body.rel, user)
    listed = {it["rel"] for it in versioning.list_deleted()}
    if body.rel not in listed:
        raise HTTPException(status_code=404, detail="回收站无此工件")
    n = versioning.purge_versions(target)
    if n == 0:
        raise HTTPException(status_code=404, detail="回收站无此工件")
    return {"ok": True, "removed": n}

"""元数据接口：模型列表、知识库、数据库 schema、游戏项目。（审计 P2-4：/preset_sqls、/agents 两端点零调用已删除）"""
from fastapi import APIRouter, Depends

from .. import config
from ..deps import get_current_user, get_engine, get_game
from ..services import games, schema as schema_svc
from analysis import knowledge_store as ks

router = APIRouter(prefix="/api", tags=["meta"])


@router.get("/games")
def game_list(user=Depends(get_current_user)):
    # 游戏库是平台本地配置，不需要连接欢乐互娱遗留 MySQL。
    all_games = games.get_games(None)
    # 游戏授权（RBAC）：只返回该用户有权限的游戏
    from backend.ide_app.services.permissions import effective_games
    allowed = effective_games(user)
    if "*" in allowed:
        return {"games": all_games, "default": games.default_key()}
    allowed_set = set(allowed)
    filtered = [g for g in all_games if g["key"] in allowed_set]
    return {"games": filtered, "default": filtered[0]["key"] if filtered else ""}


@router.get("/models")
def models(user=Depends(get_current_user)):
    ms = config.available_models()
    # 默认档跟随「主对话」槽位解析（模型管理 > 环境变量 > 系统默认）：聊天页下拉默认展示
    # 与生效模型一致；前端未显式改选时不回传 model，由后端按槽位解析（2026-10-26）
    default = config.task_model("chat") if ms else None
    return {"models": ms, "default": default}


@router.get("/knowledge")
def knowledge(game=Depends(get_game), user=Depends(get_current_user)):
    from backend.ide_app.services.permissions import can_use_asset
    docs = [
        d for d in ks.list_docs(game["key"])
        if can_use_asset(user, "kb", ks.read_doc_meta(d).get("confidentiality"))
    ]
    skills = [
        s for s in ks.list_online_skills(game["key"])
        if can_use_asset(user, "skill", ks.read_skill_meta(s).get("confidentiality"))
    ]
    return {
        "docs": docs,
        # 聊天窗口下拉/自由对话只暴露「已上线」专项；下线中（调试期）不出现。
        # 叠加使用权限点 + 机密档位过滤：无 skill_use / 档位不足的专项不出现。
        "skills": skills,
        "doc_levels": {n: ks.doc_level(n) for n in docs},
    }


@router.get("/schema")
def schema_overview(game=Depends(get_game)):
    """Return the selected source contract, never a fabricated pf_* database."""
    engine = (game.get("client_engine") or "").strip().lower()
    contract = {
        "engine": engine or "unconfigured",
        "region": game.get("region") or "",
        "project_id": game.get("game_id") or "",
        "event_table": game.get("event_table") or "",
        "status": "configured" if engine and game.get("game_id") and (engine != "ta" or game.get("event_table")) else "unconfigured",
    }
    return {
        "databases": [],
        "default_db": "",
        "tables": [],
        "sources": [contract],
        "source": "fivecross-data-client",
        "message": "当前项目按真实 engine/region/project/event_table 路由；不存在物理数据库名时标记为未配置。",
    }


@router.get("/schema/{db}/tables")
def schema_tables(db: str, user=Depends(get_current_user)):
    return {
        "db": db,
        "tables": [],
        "source": "fivecross-data-client",
        "message": "当前项目不通过遗留 MySQL/StarRocks 接口读取表清单。",
    }


@router.get("/schema/{db}/{table}")
def schema_columns(db: str, table: str, user=Depends(get_current_user)):
    return {
        "db": db,
        "table": table,
        "columns": [],
        "source": "fivecross-data-client",
        "message": "请使用项目知识库或对应 AliCloud/ThinkingData 查询验证字段。",
    }


@router.get("/version")
def version():
    """部署版本（无鉴权）：当前 git commit/branch + 工作树是否脏。

    自动部署闭环的「验证锚点」——服务器上 curl /api/version 与本地 git rev-parse 对比，
    即可确认服务器是否已更新到最新。版本号不算敏感信息，故不挂 get_current_user
    （部署验证时无需带 token）。git 信息不可得（zip 上传部署/非 git 环境）时返回
    {"available": false}，绝不伪造 commit/dirty。
    """
    import subprocess
    from pathlib import Path

    root = Path(__file__).resolve().parents[2]  # backend/routers -> 仓库根
    # 方案 A（clone）git 元数据在 root/.git；方案 B（post-receive 裸仓检出）
    # 元数据在仓库根同级的 data_ai.git（如 /opt/data_ai.git），逐个探测。
    git_dir_candidates = [root / ".git", root.parent / (root.name + ".git")]

    def _git(git_dir: Path, *args: str) -> tuple[int, str]:
        try:
            proc = subprocess.run(
                ["git", "--git-dir", str(git_dir), "--work-tree", str(root), *args],
                capture_output=True, text=True, timeout=5,
            )
            return proc.returncode, proc.stdout.strip()
        except Exception:
            return 1, ""

    for git_dir in git_dir_candidates:
        code, head = _git(git_dir, "rev-parse", "--short", "HEAD")
        if code != 0 or not head:
            continue
        _, branch = _git(git_dir, "branch", "--show-current")
        dirty_code, porcelain = _git(git_dir, "status", "--porcelain")
        return {
            "available": True,
            "commit": head,
            "branch": branch,
            "dirty": bool(dirty_code == 0 and porcelain),
        }
    return {"available": False}

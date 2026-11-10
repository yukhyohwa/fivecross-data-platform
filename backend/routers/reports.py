"""订阅报告接口：三模型报告流水线 + 订阅 CRUD + 三模型配置 + 历史报告浏览。"""
import json
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from .. import config
from ..deps import get_current_user, get_game
from ..services import report_config, sql_cache, subscriptions
from ..services.report import run_report_pipeline
from analysis.games import family_key, owner_key

router = APIRouter(prefix="/api/reports", tags=["reports"])

REPORTS_DIR = config.DATA_AI_ROOT / "reports"


def _sub_visible(rec_game: str | None, current_key: str) -> bool:
    """订阅跨游戏隔离：未标 game 的旧订阅视为通用；其余按家族键同族可见（kof/kof_sea 互见）。"""
    if not rec_game:
        return True
    return family_key(rec_game) == family_key(current_key)


def _report_visible(meta: dict, user: dict) -> bool:
    """历史报告归属隔离：无 owner 的旧报告兼容全可见；有 owner 的仅归属人可见（system 权限用户全可见）。"""
    owner = (meta or {}).get("owner")
    if not owner:
        return True
    from backend.ide_app.services.permissions import has_perm
    if has_perm(user, "system"):
        return True
    return owner == owner_key(user)


class ReportRunReq(BaseModel):
    sqls: list[str] = []
    mods: dict[str, list[str]] = {}
    skill: str | None = None
    docs: list[str] = []
    extra_prompt: str = ""
    model_gen: str | None = None
    model_ver: str | None = None
    model_sum: str | None = None
    start_date: str | None = None
    end_date: str | None = None
    subscription_id: str | None = None
    source: str | None = None
    deep_thinking: bool = False  # 深度思考：True=报告三模型开推理（耗时久、放宽超时）；False=关推理（快速档）


class SubscriptionReq(BaseModel):
    id: str | None = None
    name: str = ""
    skill: str | None = None
    sqls: list[str] = []
    docs: list[str] = []
    extra_prompt: str = ""
    source: str | None = None
    # 聊天里 AI 现写的 SQL（未落盘），先写 sql_store 再引用
    raw_sqls: list[dict] = []


class ReportConfigReq(BaseModel):
    model_gen: str
    model_ver: str
    model_sum: str




def _sse(payload: dict) -> str:
    return "data: " + json.dumps(payload, ensure_ascii=False) + "\n\n"


# ---- 三模型配置 ----

@router.get("/config")
def get_config(user=Depends(get_current_user)):
    return report_config.read_report_config()


@router.put("/config")
def put_config(req: ReportConfigReq, user=Depends(get_current_user)):
    from backend.ide_app.services.permissions import has_perm
    if not has_perm(user, "system"):
        raise HTTPException(status_code=403, detail="仅系统管理员可修改报告三模型配置")
    try:
        report_config.write_report_config(req.model_dump())
    except OSError as e:
        # 与 /api/admin/config/models 同口径：写盘失败清晰报错（对抗审查）
        raise HTTPException(status_code=500, detail=f"模型配置写盘失败：{e}")
    return report_config.read_report_config()


# ---- 订阅 CRUD ----

@router.get("/subscriptions")
def list_subs(user=Depends(get_current_user), game=Depends(get_game)):
    subs = [s for s in subscriptions.list_subscriptions(owner=owner_key(user)) if _sub_visible(s.get("game"), game["key"])]
    return {"subscriptions": subs}


@router.post("/subscriptions")
def create_sub(req: SubscriptionReq, user=Depends(get_current_user), game=Depends(get_game)):
    from analysis import sql_store
    from analysis import kb_gen

    data = req.model_dump()
    data["game"] = game["key"]
    # 处理聊天里 AI 现写的 SQL：落盘成 sql/*.sql 后再引用其文件名
    if data.pop("raw_sqls", None):
        resolved = list(data.get("sqls") or [])
        for item in req.raw_sqls:
            name = (item.get("name") or "").strip()
            sql_text = (item.get("sql") or "").strip()
            if not name or not sql_text:
                continue
            sql_store.write_sql(name, sql_text)
            # 审计 P2-15：聊天 AI 现写 SQL 落盘后按 game 失效生成缓存，避免重复提问命中旧结果
            sql_cache.invalidate(game["key"])
            _model = config.task_model("report_gen")
            fields = kb_gen.annotate_fields(_model, sql_text, sql_store.fields_from_sql(sql_text))
            sql_store.write_sql_meta(name, {"modifications": [], "level": "个人", "game": None, "fields": fields, "owner": owner_key(user)})
            if name not in resolved:
                resolved.append(name)
        data["sqls"] = resolved
    if data.get("id"):
        try:
            existing = subscriptions.get_subscription(data["id"], owner=owner_key(user))
        except FileNotFoundError:
            existing = None
        except PermissionError as exc:
            raise HTTPException(status_code=403, detail=str(exc))
        if existing and not _sub_visible(existing.get("game"), game["key"]):
            raise HTTPException(status_code=403, detail="该订阅属于其他游戏，无权覆盖")
    try:
        rec = subscriptions.save_subscription(data, owner=owner_key(user))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return rec


@router.post("/subscriptions/preview")
def preview_sub(req: SubscriptionReq, user=Depends(get_current_user), game=Depends(get_game)):
    """审计 P2-2：创建订阅前预览「聊天里 AI 现写的 SQL」清单，只读、不落盘。

    参数与创建订阅一致；仅过滤出有效的 raw_sqls 条目并返回名称 + SQL 前 300 字摘要，
    前端据此弹确认 UI，用户确认后才真正调用创建端点（create_sub）落盘。
    """
    items = []
    for item in req.raw_sqls:
        name = (item.get("name") or "").strip()
        sql_text = (item.get("sql") or "").strip()
        if not name or not sql_text:
            continue
        items.append({
            "name": name,
            "sql": sql_text[:300],
            "truncated": len(sql_text) > 300,
        })
    return {"raw_sqls": items}


@router.delete("/subscriptions/{sid}")
def delete_sub(sid: str, user=Depends(get_current_user), game=Depends(get_game)):
    try:
        existing = subscriptions.get_subscription(sid, owner=owner_key(user))
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="订阅不存在")
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc))
    if not _sub_visible(existing.get("game"), game["key"]):
        raise HTTPException(status_code=403, detail="该订阅属于其他游戏，无权删除")
    try:
        subscriptions.delete_subscription(sid, owner=owner_key(user))
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return {"ok": True}


@router.get("/subscriptions/{sid}")
def get_sub(sid: str, user=Depends(get_current_user), game=Depends(get_game)):
    try:
        rec = subscriptions.get_subscription(sid, owner=owner_key(user))
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="订阅不存在")
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc))
    if not _sub_visible(rec.get("game"), game["key"]):
        raise HTTPException(status_code=403, detail="该订阅属于其他游戏，无权访问")
    return rec


# ---- 报告流水线 ----

@router.post("/run")
def run_report(req: ReportRunReq, user=Depends(get_current_user), game=Depends(get_game)):
    def stream():
        try:
            params = req.model_dump()
            params["game"] = game
            params["user"] = user
            for ev in run_report_pipeline(params):
                yield _sse(ev)
        except Exception as exc:  # 兜底：把未捕获异常作为 error 事件推给前端
            yield _sse({"type": "error", "message": str(exc)})
        finally:
            yield _sse({"type": "done"})

    return StreamingResponse(stream(), media_type="text/event-stream")


# ---- 历史报告浏览 ----

@router.get("")
def list_reports(user=Depends(get_current_user)):
    reports = []
    if REPORTS_DIR.exists():
        dirs = [d for d in REPORTS_DIR.iterdir() if d.is_dir() and not d.name.startswith("smoke_")]
        dirs.sort(key=lambda d: d.stat().st_mtime, reverse=True)
        for d in dirs:
            meta = {}
            meta_path = d / "run_meta.json"
            if meta_path.exists():
                try:
                    meta = json.loads(meta_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    meta = {}
            if not _report_visible(meta, user):
                continue
            generated_at = meta.get("generated_at") or datetime.fromtimestamp(
                d.stat().st_mtime
            ).strftime("%Y-%m-%d %H:%M")
            reports.append(
                {
                    "id": d.name,
                    "generated_at": generated_at,
                    "models": meta.get("models", {}),
                    "skill": meta.get("skill"),
                    "sqls": meta.get("selected_sql", []),
                    "source": meta.get("source"),
                    "subscription_id": meta.get("subscription_id"),
                    "start_date": meta.get("start_date"),
                    "end_date": meta.get("end_date"),
                }
            )
    return {"reports": reports}


@router.get("/{report_id}")
def get_report(report_id: str, user=Depends(get_current_user)):
    if report_id in (".", "..") or "/" in report_id or "\\" in report_id:
        raise HTTPException(status_code=400, detail="非法报告 ID")
    base = REPORTS_DIR / report_id
    if not base.is_dir():
        raise HTTPException(status_code=404, detail="报告不存在")

    def _read(name: str) -> str:
        p = base / name
        return p.read_text(encoding="utf-8") if p.exists() else ""

    meta = {}
    meta_path = base / "run_meta.json"
    if meta_path.exists():
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            meta = {}
    if not _report_visible(meta, user):
        raise HTTPException(status_code=403, detail="该报告属于其他用户，无权查看")
    return {
        "id": report_id,
        "report_md": _read("report.md"),
        "generate_md": _read("generate.md"),
        "verify_md": _read("verify.md"),
        "meta": meta,
    }



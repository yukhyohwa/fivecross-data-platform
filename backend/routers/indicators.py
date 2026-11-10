"""指标知识库 API（P4 融合）：data_ai 侧一等公民接口，复用 ide_backend 的 indicators 表。

指标 = 结构化口径（metric_name / definition / canonical_sql / domain / tags 等），
与 data_ai 的知识库文档互补：文档是自然语言口径，指标是「可执行 SQL 的结构化口径」。
深度分析 Agent 通过 search_indicators / read_indicator 工具直接检索这里。
"""
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from ..deps import get_current_user, get_game
from ..services import indicator_scan
from ..services.ide_bridge import anonymous_uid, db_service

router = APIRouter(prefix="/api/indicators", tags=["indicators"])


def _check_level_perm(user: dict, item: dict, point: str) -> bool:
    """层级共享指标（来源 SQL 为 通用/项目）的写权限：同 SQL管理，持 analysis_edit/delete 即可共建。"""
    from backend.ide_app.services.permissions import has_perm
    return db_service.indicator_share_scope(item.get("source_sql")) is not None and has_perm(user, point)


@router.get("")
def list_indicators(
    search: str = "",
    domain: str = "",
    status: str = "",
    page: int = 1,
    size: int = 50,
    user: dict = Depends(get_current_user),
    game: dict = Depends(get_game),
):
    uid = anonymous_uid(user)
    items, total = db_service.list_indicators(
        uid, search=search, domain=domain, status=status, page=page, size=size,
        game=game.get("key"),
    )
    return {"items": items, "total": total, "page": page, "size": size}


@router.get("/domains")
def indicator_domains(user: dict = Depends(get_current_user), game: dict = Depends(get_game)):
    uid = anonymous_uid(user)
    return {"domains": db_service.get_indicator_domains(uid, game=game.get("key"))}


@router.get("/{indicator_id}")
def get_indicator(indicator_id: str, user: dict = Depends(get_current_user)):
    item = db_service.get_indicator_by_metric_id(indicator_id)
    if not item and indicator_id.isdigit():
        item = db_service.get_indicator_by_id(int(indicator_id))
    if not item:
        raise HTTPException(status_code=404, detail="指标不存在")
    return item


@router.post("")
def create_indicator(body: dict, user: dict = Depends(get_current_user)):
    """创建指标（body 为指标字段，metric_name/canonical_sql 必填）。"""
    uid = anonymous_uid(user)
    if not body.get("metric_name") or not body.get("canonical_sql"):
        raise HTTPException(status_code=400, detail="metric_name 与 canonical_sql 必填")
    item = db_service.create_indicator(uid, body)
    return item


@router.put("/{indicator_id}")
def update_indicator(indicator_id: int, body: dict, user: dict = Depends(get_current_user)):
    uid = anonymous_uid(user)
    item = db_service.get_indicator_by_id(indicator_id)
    if not item:
        raise HTTPException(status_code=404, detail="指标不存在")
    if item.get("user_id") != uid:
        # 共享写入：显式分享 write 权限，或层级共享指标（来源 SQL 通用/项目）持 analysis_edit 共建
        perm = db_service.get_shared_permission("indicator", indicator_id, uid)
        if perm != "write" and not _check_level_perm(user, item, "analysis_edit"):
            raise HTTPException(status_code=403, detail="无权修改该指标")
    return db_service.update_indicator(indicator_id, body)


@router.delete("/{indicator_id}")
def delete_indicator(indicator_id: int, user: dict = Depends(get_current_user)):
    uid = anonymous_uid(user)
    item = db_service.get_indicator_by_id(indicator_id)
    if not item:
        raise HTTPException(status_code=404, detail="指标不存在")
    if item.get("user_id") != uid:
        # 层级共享指标同 SQL管理：删除需 analysis_delete
        if not _check_level_perm(user, item, "analysis_delete"):
            raise HTTPException(status_code=403, detail="无权删除该指标")
    db_service.delete_indicator(indicator_id)
    return {"message": "指标已删除"}


# ── 版本 ──

@router.get("/{indicator_id}/versions")
def indicator_versions(indicator_id: int, user: dict = Depends(get_current_user)):
    return {"versions": db_service.list_indicator_versions(indicator_id)}


class VersionBody(BaseModel):
    snapshot: str
    change_comment: str = ""


@router.post("/{indicator_id}/versions")
def create_version(indicator_id: int, body: VersionBody, user: dict = Depends(get_current_user)):
    uid = anonymous_uid(user)
    item = db_service.get_indicator_by_id(indicator_id)
    if not item or item.get("user_id") != uid:
        raise HTTPException(status_code=403, detail="无权操作该指标")
    nxt = (item.get("version") or 1) + 1
    db_service.create_indicator_version(indicator_id, nxt, body.snapshot, body.change_comment, uid)
    return {"message": "版本已记录", "version": nxt}


# ── 共享（shared_items 通用表，item_type='indicator'）──

class ShareBody(BaseModel):
    target_user_ids: List[str]
    permission: str = "read"


@router.post("/{indicator_id}/share")
def share_indicator(indicator_id: int, body: ShareBody, user: dict = Depends(get_current_user)):
    uid = anonymous_uid(user)
    item = db_service.get_indicator_by_id(indicator_id)
    if not item or item.get("user_id") != uid:
        raise HTTPException(status_code=403, detail="仅拥有者可分享")
    for target in body.target_user_ids:
        db_service.add_shared_item("indicator", indicator_id, uid, target, body.permission)
    return {"shared": len(body.target_user_ids)}


@router.delete("/{indicator_id}/share/{target_uid}")
def unshare_indicator(indicator_id: int, target_uid: str, user: dict = Depends(get_current_user)):
    uid = anonymous_uid(user)
    db_service.remove_shared_item("indicator", indicator_id, target_uid)
    return {"message": "已取消分享"}


# ── 指标自动生成（Task E 前端融合）──

@router.post("/scan-sql")
async def scan_sql_indicators(user: dict = Depends(get_current_user), game: dict = Depends(get_game)):
    """扫描「当前用户可见」的 SQL 库 *.sql → 逐个「一拆多」成 draft 子指标（按 metric_id=sql_<主干>_<列> 去重）。"""
    uid = anonymous_uid(user)
    return await indicator_scan.scan_sqls_to_draft(uid, game=game.get("key"))


class GenerateFromSqlBody(BaseModel):
    sql_name: str


@router.post("/generate-from-sql")
async def generate_from_sql(body: GenerateFromSqlBody, user: dict = Depends(get_current_user), game: dict = Depends(get_game)):
    """SQL数据页「一键生成/更新指标」：对单个 SQL 文件「一拆多」成 N 个单指标 draft（无则建、有则同步重解析）。"""
    uid = anonymous_uid(user)
    return await indicator_scan.generate_from_sql(uid, body.sql_name, game=game.get("key"))


@router.post("/{indicator_id}/confirm")
def confirm_indicator(indicator_id: int, user: dict = Depends(get_current_user)):
    """把 draft 指标转正（status → active），供扫描/联动生成的草稿人工确认。"""
    uid = anonymous_uid(user)
    item = db_service.get_indicator_by_id(indicator_id)
    if not item:
        raise HTTPException(status_code=404, detail="指标不存在")
    if item.get("user_id") != uid:
        # 层级共享指标持 analysis_edit 可共建转正
        if not _check_level_perm(user, item, "analysis_edit"):
            raise HTTPException(status_code=403, detail="无权操作该指标")
    return db_service.update_indicator(indicator_id, {"status": "active"})


@router.post("/import-metrics-json")
def import_metrics_json(user: dict = Depends(get_current_user)):
    """一次性迁移：读 analysis/knowledge/metrics.json → 建 draft 指标（canonical_sql 空，待补 SQL）。"""
    uid = anonymous_uid(user)
    from analysis import metrics as _metrics
    items = _metrics.load_metrics()
    created = skipped = failed = 0
    errors = []
    for m in items:
        name = (m.get("name") or m.get("key") or "").strip()
        if not name:
            skipped += 1
            continue
        metric_id = f"metrics_{m.get('key') or name}"
        if db_service.get_indicator_by_metric_id(metric_id):
            skipped += 1
            continue
        aliases = " / ".join(a for a in (m.get("aliases") or []) if a)
        definition = (m.get("description") or "").strip()
        if m.get("formula"):
            definition = (definition + "\n公式：" + m["formula"]).strip()
        data = {
            "metric_id": metric_id,
            "metric_name": name,
            "metric_alias": aliases,
            "canonical_sql": "",
            "definition": definition,
            "granularity": m.get("grain") or "",
            "tags": m.get("dimensions") or [],
            "status": "draft",
        }
        try:
            db_service.create_indicator(uid, data)
            created += 1
        except Exception as e:  # noqa: BLE001 —— 单条失败不阻断整批
            failed += 1
            errors.append({"name": name, "error": str(e)[:160]})
    return {"created": created, "skipped": skipped, "failed": failed, "errors": errors, "total": len(items)}

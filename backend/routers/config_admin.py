"""术语表 / 指标层 / 模型管理配置接口：glossary.md 与 metrics.json 的读写 + 术语候选确认，
以及全站 LLM 模型槽位（services/model_config）的读写。

后台 admin 页用：「AI配置 → 术语与口径」读写术语表与指标定义；「系统管理 → 模型管理」
读写任务→模型映射。术语/指标写走版本化写（覆盖前自动备份到 _versions/，可回滚）。
"""
import json

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from ..deps import get_current_user
from ..services import model_config
from analysis import glossary, metrics, versioning

router = APIRouter(prefix="/api/admin/config", tags=["config"])


def _require_system(user: dict = Depends(get_current_user)) -> dict:
    """全局配置写入口闸门：需 system 权限点，与 RBAC 口径一致。"""
    from backend.ide_app.services.permissions import has_perm
    if not has_perm(user, "system"):
        raise HTTPException(status_code=403, detail="仅系统管理员可修改全局配置")
    return user


class TextSave(BaseModel):
    content: str = ""


class ConfirmEntry(BaseModel):
    term: str
    column: str


class ConfirmReq(BaseModel):
    entries: list[ConfirmEntry]


@router.get("/glossary")
def get_glossary(user=Depends(get_current_user)):
    return {"content": glossary.glossary_text(), "candidates": glossary.list_candidates()}


@router.post("/glossary")
def save_glossary(body: TextSave, user=Depends(_require_system)):
    glossary.save_glossary(body.content)
    return {"ok": True}


@router.post("/glossary/confirm")
def confirm_glossary(body: ConfirmReq, user=Depends(_require_system)):
    res = glossary.confirm_candidates([e.dict() for e in body.entries])
    return {"ok": True, **res}


@router.get("/metrics")
def get_metrics(user=Depends(get_current_user)):
    try:
        content = metrics.METRICS_PATH.read_text(encoding="utf-8")
    except OSError:
        content = "[]"
    error = None
    try:
        json.loads(content or "[]")
    except ValueError as exc:
        error = str(exc)
    return {"content": content, "error": error}


@router.post("/metrics")
def save_metrics(body: TextSave, user=Depends(_require_system)):
    try:
        json.loads(body.content or "[]")
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=f"不是合法 JSON：{exc}")
    versioning.write_text(
        metrics.METRICS_PATH,
        body.content.replace("\r\n", "\n").rstrip() + "\n",
        encoding="utf-8",
        newline="\n",
    )
    return {"ok": True}


# ---- 模型管理（系统管理页：全站 LLM 模型槽位）----

class ModelConfigPut(BaseModel):
    # 槽位 → 模型名；空串 = 清除覆盖（回落环境变量/任务默认/系统默认）。未知槽位/非法模型名由写侧忽略。
    overrides: dict[str, str] = {}


@router.get("/models")
def get_model_config(user=Depends(get_current_user)):
    """模型管理页数据：全部槽位的生效模型+来源+覆盖值，以及可选模型列表。"""
    from .. import config
    return {
        "slots": model_config.effective_models(),
        "models": config.available_models(),
        "default": config.default_model(),
    }


@router.put("/models")
def put_model_config(body: ModelConfigPut, user=Depends(_require_system)):
    """保存模型槽位覆盖（仅 system 权限）。全局兜底模型同步到 ai_client（运行时生效）。"""
    from .. import config
    from analysis import ai_client
    try:
        stored = model_config.write_model_config(body.overrides)
    except OSError as e:
        # 只读/权限/磁盘故障：清晰报错而非裸 500 traceback（对抗审查）
        raise HTTPException(status_code=500, detail=f"模型配置写盘失败：{e}")
    ai_client.set_fallback_model(config.global_fallback_model())
    return {"slots": model_config.effective_models(), "stored": stored}

"""统一工具目录 + 界面编辑端点（data_ai 侧一等公民接口，挂 /api/mcp/catalog）。

与 sql-ide 的 mcp_gateway（/api/mcp/tools 等）并列不冲突。
目录聚合 data_ai 深度分析工具 + sql-ide MCP 工具；编辑写 tool_meta 表（admin-only）。
"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from ..deps import get_current_user
from ..services import tool_catalog
from ..services.ide_bridge import db_service
from backend.ide_app.services.permissions import has_perm

router = APIRouter(prefix="/api/mcp", tags=["mcp-catalog"])


@router.get("/catalog")
def get_catalog():
    """返回全后台统一工具目录（无需鉴权，对齐 /api/mcp/tools）。"""
    return tool_catalog.build_catalog()


class ToolMetaBody(BaseModel):
    key: str
    description: str | None = None
    enabled: bool | None = None


@router.put("/catalog")
def update_catalog(body: ToolMetaBody, user: dict = Depends(get_current_user)):
    """编辑某工具的描述/启停（admin-only = 拥有 system 权限点）。"""
    if not has_perm(user, "system"):
        raise HTTPException(status_code=403, detail="仅管理员可编辑工具")

    key = body.key.strip()
    if not key or "::" not in key:
        raise HTTPException(status_code=400, detail="key 格式应为 {source}::{name}")

    source = key.split("::", 1)[0]
    description = body.description
    if description is not None and not description.strip():
        description = None  # 空串 = 回退代码默认描述
    enabled = bool(body.enabled) if body.enabled is not None else True

    db_service.save_tool_meta(key, source, description, enabled)
    return {"message": "已保存", "key": key}

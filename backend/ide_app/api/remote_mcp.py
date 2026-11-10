"""远程 MCP 服务器配置 API（通用层，Sensor Tower 只是第一行数据）。

权限模型：
- 配置类端点（新增/删除/启停/凭据/OAuth/分享）—— 仅 admin，且只能操作自己配置的服务器。
- 成员只能：列自己可用的（自己配置的 + 被分享的）、看状态与工具清单、测试连通、在对话里使用。
"""
import logging
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

from backend.ide_app.api.auth_api import get_current_user, require_admin
from backend.ide_app.services import db_service
from backend.ide_app.services.remote_mcp import callback_server, manager, oauth, store

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/remote-mcp", tags=["remote-mcp"])


class ServerBody(BaseModel):
    id: Optional[int] = None
    name: str
    url: Optional[str] = ""
    transport: Optional[str] = "http"
    command: Optional[str] = ""
    args: Optional[List[str]] = None
    env: Optional[dict] = None
    auth_type: Optional[str] = "none"
    auth_register_url: Optional[str] = ""
    auth_authorize_url: Optional[str] = ""
    auth_token_url: Optional[str] = ""
    auth_scope: Optional[str] = ""
    auth_resource: Optional[str] = ""
    enabled: Optional[bool] = True


class EnableBody(BaseModel):
    enabled: bool


class CredentialsBody(BaseModel):
    access_token: Optional[str] = None


class OAuthStartBody(BaseModel):
    frontend_origin: Optional[str] = None


class OAuthCompleteBody(BaseModel):
    state: Optional[str] = None
    code: Optional[str] = None
    callback_url: Optional[str] = None


class ShareBody(BaseModel):
    ids: List[int]
    target_user_ids: List[str]
    permission: str = "read"


def _owned(server_id: int, user: dict) -> dict:
    row = db_service.get_remote_mcp_server(server_id)
    if not row:
        raise HTTPException(404, "服务器不存在")
    if row["owner_user_id"] != user["id"]:
        raise HTTPException(403, "只能操作自己配置的服务器")
    return row


@router.get("")
async def list_servers(user: dict = Depends(get_current_user)):
    """列出当前用户可用的服务器（自己配置的 + 被分享的）。凭据不出网。"""
    rows = db_service.list_remote_mcp_for_user(user["id"])
    viewers: dict[str, str] = {}
    for r in rows:
        owner = r.get("shared_by_user_id")
        if owner and owner not in viewers:
            viewers[owner] = db_service.get_username(owner)
    out = []
    for r in rows:
        view = store.public_view(r)
        owner_id = r.get("shared_by_user_id") or ""
        view["shared_by_username"] = viewers.get(owner_id, "")
        out.append(view)
    return out


@router.post("")
async def save_server(body: ServerBody, admin: dict = Depends(require_admin)):
    server_id = body.id
    data = body.model_dump()
    try:
        data["name"] = store.validate_name(body.name)
        transport = (body.transport or "http").lower()
        if transport not in ("http", "sse", "stdio"):
            raise ValueError("transport 只能是 http / sse / stdio")
        data["transport"] = transport
        if transport == "stdio":
            # stdio = 后端主机任意代码执行，命令必须过 allowlist
            data["command"] = store.validate_stdio(body.command or "")
        else:
            if not (body.url or "").strip():
                raise ValueError("http/sse 传输必须填写服务器地址")
        if body.auth_type not in ("none", "bearer", "oauth2"):
            raise ValueError("auth_type 只能是 none / bearer / oauth2")
    except ValueError as e:
        raise HTTPException(400, str(e))

    if server_id:
        _owned(server_id, admin)
    try:
        sid = db_service.upsert_remote_mcp_server(admin["id"], data)
    except ValueError as e:
        raise HTTPException(400, str(e))
    if body.env is not None:
        store.save_env(sid, {k: str(v) for k, v in (body.env or {}).items()})
    return {"id": sid, **store.public_view(db_service.get_remote_mcp_server(sid))}


@router.delete("/{server_id}")
async def delete_server(server_id: int, admin: dict = Depends(require_admin)):
    _owned(server_id, admin)
    db_service.delete_remote_mcp_server(server_id)
    return {"ok": True}


@router.post("/{server_id}/enable")
async def enable_server(server_id: int, body: EnableBody,
                        admin: dict = Depends(require_admin)):
    _owned(server_id, admin)
    db_service.set_remote_mcp_enabled(server_id, body.enabled)
    return {"ok": True}


@router.post("/{server_id}/credentials")
async def save_credentials(server_id: int, body: CredentialsBody,
                           admin: dict = Depends(require_admin)):
    row = _owned(server_id, admin)
    if row.get("auth_type") != "bearer":
        raise HTTPException(400, "该服务器不是 bearer 认证，请走 OAuth 授权")
    token = (body.access_token or "").strip()
    if not token:
        raise HTTPException(400, "access_token 不能为空")
    creds = store.get_credentials(row)
    creds["access_token"] = token
    store.save_credentials(server_id, creds)
    probe = await manager.probe_server(db_service.get_remote_mcp_server(server_id))
    return {"ok": True, **probe}


@router.delete("/{server_id}/credentials")
async def clear_credentials(server_id: int, admin: dict = Depends(require_admin)):
    """清凭据（含 client_id，下次授权会重新 DCR）。"""
    _owned(server_id, admin)
    store.save_credentials(server_id, {})
    db_service.update_remote_mcp_probe(server_id, tools=None, status="", error="")
    return {"ok": True}


@router.post("/{server_id}/test")
async def test_server(server_id: int, user: dict = Depends(get_current_user)):
    """连通性探测。owner 或被分享的成员都可以跑来自检。"""
    row = db_service.get_remote_mcp_server(server_id)
    if not row:
        raise HTTPException(404, "服务器不存在")
    if not _can_access(row, user):
        raise HTTPException(403, "无权访问该服务器")
    return await manager.probe_server(row)


@router.post("/{server_id}/oauth/start")
async def oauth_start(server_id: int, body: OAuthStartBody, request: Request,
                      admin: dict = Depends(require_admin)):
    row = _owned(server_id, admin)
    if row.get("auth_type") != "oauth2":
        raise HTTPException(400, "该服务器不是 OAuth 认证")

    port = await callback_server.ensure_listening()
    if not port:
        raise HTTPException(500, f"回调监听启动失败：{callback_server.get_last_error()}")
    redirect_uri = oauth.build_redirect_uri(port)
    try:
        started = await manager.start_oauth(row, admin["id"], redirect_uri)
    except oauth.OAuthError as e:
        raise HTTPException(400, str(e))
    return {
        **started,
        "callback_port": port,
        "redirect_uri": redirect_uri,
        "listener_warning": callback_server.get_last_error(),
        # 前端据此决定是否把「粘贴回调地址」框做成主路径：
        # 从本机访问（localhost）时环回 listener 收得到，能自动完成；
        # 从别的机器访问（部署后）收不到，必须靠粘贴。
        "loopback_reachable": callback_server.is_local_host(
            request.headers.get("host", "")),
    }


@router.post("/oauth/complete")
async def oauth_complete(body: OAuthCompleteBody, admin: dict = Depends(require_admin)):
    """粘贴回调地址完成授权（服务器部署下的正常路径）。

    接受整条地址栏 URL、仅 query 串、或单独的 code。
    """
    state = (body.state or "").strip()
    code = (body.code or "").strip()
    if body.callback_url:
        parsed = oauth.parse_callback_url(body.callback_url)
        state = state or parsed["state"]
        code = code or parsed["code"]
        if parsed["error"]:
            detail = f"{parsed['error']}: {parsed['error_description']}".strip(": ")
            raise HTTPException(400, f"授权失败：{detail}")
    if not state:
        raise HTTPException(400, "缺少 state —— 请粘贴完整的回调地址")
    if not manager.get_pending(state, admin["id"]):
        raise HTTPException(400, "授权会话不存在或已过期，请重新发起授权")
    if not code:
        raise HTTPException(400, "回调地址中没有授权码 code")

    try:
        return await manager.complete_oauth(state, code)
    except oauth.OAuthError as e:
        raise HTTPException(400, str(e))


@router.get("/oauth/status")
async def oauth_status(state: str, admin: dict = Depends(require_admin)):
    """前端轮询：环回 listener 收到回调后会回填结果。"""
    result = manager.pending_status(state, admin["id"])
    if result.get("status") == "forbidden":
        raise HTTPException(403, "无权访问该授权会话")
    return result


@router.post("/share")
async def share_servers(body: ShareBody, admin: dict = Depends(require_admin)):
    """分享给成员。只支持 collaborative（copy 会复制凭据 → 双份 refresh_token 互相作废）。"""
    permission = body.permission if body.permission in ("read", "write") else "read"
    count = 0
    for sid in body.ids:
        row = db_service.get_remote_mcp_server(sid)
        if not row or row["owner_user_id"] != admin["id"]:
            continue
        for target_uid in body.target_user_ids:
            if target_uid == admin["id"]:
                continue
            db_service.add_shared_item("remote_mcp", sid, admin["id"], target_uid, permission)
            count += 1
    return {"shared": count}


@router.delete("/{server_id}/share/{user_id}")
async def unshare_server(server_id: int, user_id: str,
                         admin: dict = Depends(require_admin)):
    _owned(server_id, admin)
    db_service.remove_remote_mcp_share(server_id, user_id)
    return {"ok": True}


@router.get("/{server_id}/shares")
async def list_shares(server_id: int, admin: dict = Depends(require_admin)):
    _owned(server_id, admin)
    return {"user_ids": db_service.list_remote_mcp_shares(server_id)}


def _can_access(row: dict, user: dict) -> bool:
    if row["owner_user_id"] == user["id"]:
        return True
    return db_service.get_shared_permission("remote_mcp", row["id"], user["id"]) is not None

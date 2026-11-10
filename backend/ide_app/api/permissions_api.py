"""权限管理（RBAC）端点：身份 CRUD + 飞书邮箱映射 + 用户授权，挂在 /api/permissions。

除 /points（权限点清单，登录即可访问）外，均 require system 权限点。
"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, field_validator

from .auth_api import get_current_user, require_perm
from ..services import permissions as perms
from ..services import db_service

router = APIRouter(prefix="/api/permissions", tags=["permissions"])

_system = require_perm("system")


@router.get("/points")
async def list_permission_points(user: dict = Depends(get_current_user)):
    """权限点清单（审计 P2-3）：供前端三处清单统一消费；登录即可访问，不要求 system 权限。

    数据来源 = permissions.ALL_PERMISSION_POINTS（已剔除 personal/workspace 孤儿点的真实清单），
    顺序保持常量定义顺序，稳定不漂移。
    """
    return {"points": list(perms.ALL_PERMISSION_POINTS)}


class IdentityBody(BaseModel):
    key: str
    name: str
    permission_points: list[str] = []
    games: list[str] = ["*"]
    access_levels: dict = {}


class EmailMappingBody(BaseModel):
    identity_key: str
    match_type: str = "exact"  # 'exact' | 'suffix'
    pattern: str


class UserRbacBody(BaseModel):
    identity: list[str] = []
    extra_permissions: list[str] = []
    extra_games: list[str] = []
    extra_access_levels: dict = {}

    @field_validator("identity", mode="before")
    @classmethod
    def _identity_list(cls, v):
        # 兼容旧前端传来的单 key 字符串（滚动部署期间）→ 包成单元素列表
        if isinstance(v, str):
            return [v] if v.strip() else []
        return v


def _clean_points(points: list[str]) -> list[str]:
    """审计 P2-4 复核：只保留真实清单内的权限点，保序去重。

    旧的 personal/workspace 孤儿点已从 ALL_PERMISSION_POINTS 删除；若不在这里过滤，
    前端把 DB 里的旧键原样回写时会永久存活（清单里没有对应复选框、用户也看不到）。
    """
    known = set(perms.ALL_PERMISSION_POINTS)
    seen: set[str] = set()
    out: list[str] = []
    for p in points or []:
        if p in known and p not in seen:
            seen.add(p)
            out.append(p)
    return out


@router.get("/identities")
async def list_identities(user: dict = Depends(_system)):
    return db_service.list_identities()


@router.post("/identities")
async def create_identity(body: IdentityBody, user: dict = Depends(_system)):
    key = body.key.strip()
    if not key:
        raise HTTPException(400, "身份标识(key)不能为空")
    if db_service.get_identity(key):
        raise HTTPException(409, "身份标识已存在")
    db_service.upsert_identity(key, body.name.strip() or key, _clean_points(body.permission_points), body.games,
                               is_builtin=0, access_levels=perms.clean_access_levels(body.access_levels))
    return db_service.get_identity(key)


@router.put("/identities/{key}")
async def update_identity(key: str, body: IdentityBody, user: dict = Depends(_system)):
    existing = db_service.get_identity(key)
    if not existing:
        raise HTTPException(404, "身份不存在")
    db_service.upsert_identity(key, body.name.strip() or key, _clean_points(body.permission_points), body.games,
                               is_builtin=existing["is_builtin"], access_levels=perms.clean_access_levels(body.access_levels))
    return db_service.get_identity(key)


@router.delete("/identities/{key}")
async def delete_identity(key: str, user: dict = Depends(_system)):
    existing = db_service.get_identity(key)
    if not existing:
        raise HTTPException(404, "身份不存在")
    if existing["is_builtin"]:
        raise HTTPException(400, "内置身份不可删除，可编辑其权限点/游戏")
    c = db_service._conn()
    rows = c.execute(
        "SELECT identity FROM users WHERE identity IS NOT NULL AND identity != ''"
    ).fetchall()
    used = sum(1 for r in rows if key in perms._parse_identity_keys(r["identity"]))
    if used > 0:
        raise HTTPException(400, f"仍有 {used} 个用户使用该身份，请先改派")
    # 清理引用该身份的邮箱映射
    c.execute("DELETE FROM identity_email_mappings WHERE identity_key=?", (key,))
    db_service.delete_identity(key)
    return {"message": "身份已删除"}


@router.get("/email-mappings")
async def list_email_mappings(user: dict = Depends(_system)):
    return db_service.list_email_mappings()


@router.post("/email-mappings")
async def create_email_mapping(body: EmailMappingBody, user: dict = Depends(_system)):
    pattern = body.pattern.strip()
    if not pattern:
        raise HTTPException(400, "匹配规则不能为空")
    if body.match_type not in ("exact", "suffix"):
        raise HTTPException(400, "匹配方式只能是 exact 或 suffix")
    if not db_service.get_identity(body.identity_key):
        raise HTTPException(400, "身份不存在")
    return db_service.add_email_mapping(body.identity_key, body.match_type, pattern)


@router.delete("/email-mappings/{mid}")
async def delete_email_mapping(mid: int, user: dict = Depends(_system)):
    db_service.delete_email_mapping(mid)
    return {"message": "映射已删除"}


@router.get("/users")
async def list_permission_users(user: dict = Depends(_system)):
    c = db_service._conn()
    rows = c.execute(
        "SELECT id, username, role, is_active, joydata_email, identity, extra_permissions, extra_games, extra_access_levels "
        "FROM users ORDER BY created_at DESC"
    ).fetchall()
    out = []
    for r in rows:
        d = dict(r)
        view = perms.user_perm_view(d)
        out.append({
            "id": d["id"],
            "username": d["username"],
            "role": d["role"],
            "is_active": d["is_active"],
            "joydata_email": d["joydata_email"],
            "identity": view["identity"],
            "identity_name": view["identity_name"],
            "extra_permissions": perms._parse_list(d["extra_permissions"]),
            "extra_games": perms._parse_list(d["extra_games"]),
            "extra_access_levels": perms._parse_obj(d["extra_access_levels"]),
            "permissions": view["permissions"],
            "games": view["games"],
            "is_custom": view["is_custom"],
        })
    return out


@router.put("/users/{uid}")
async def update_permission_user(uid: str, body: UserRbacBody, user: dict = Depends(_system)):
    target = db_service.get_user_by_id(uid)
    if not target:
        raise HTTPException(404, "用户不存在")
    if uid == "anonymous":
        raise HTTPException(400, "anonymous 是系统回落占位，不可改授权")
    db_service.update_user_rbac(uid, body.identity, _clean_points(body.extra_permissions), body.extra_games,
                                extra_access_levels=perms.clean_access_levels(body.extra_access_levels))
    updated = db_service.get_user_by_id(uid)
    view = perms.user_perm_view(updated)
    return {
        "id": uid,
        "identity": view["identity"],
        "identity_name": view["identity_name"],
        "permissions": view["permissions"],
        "games": view["games"],
        "is_custom": view["is_custom"],
    }

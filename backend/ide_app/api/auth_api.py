from fastapi import APIRouter, HTTPException, Depends
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel
import json
from ..core.auth import hash_password, verify_password, create_token, decode_token
from ..core.settings import settings
from ..models.schemas import AuthResponse, TokenRefreshResponse, MeResponse, UserDetail
from ..services.db_service import create_user, get_user_by_username, get_user_by_id, update_user_token, increment_login_attempts, init_db, _conn, set_user_joydata_email, get_agent_config, delete_user as db_delete_user
from ..services import permissions as perms
from typing import Optional
from datetime import datetime

router = APIRouter(prefix="/api/auth", tags=["auth"])
_security = HTTPBearer(auto_error=False)


def get_current_user(cred: HTTPAuthorizationCredentials = Depends(_security)) -> dict:
    if not cred:
        raise HTTPException(401, "未登录")
    payload = decode_token(cred.credentials)
    if not payload or payload.get("type") != "access":
        raise HTTPException(401, "令牌无效或已过期")
    user = get_user_by_id(payload["sub"])
    if not user:
        raise HTTPException(401, "用户不存在")
    if not user.get("is_active", 1):
        raise HTTPException(403, "账号已被禁用")
    return user


def require_perm(point: str):
    """校验当前用户是否拥有某权限点（导航组）；匿名回落时恒真。"""
    def _check(user: dict = Depends(get_current_user)) -> dict:
        if not perms.has_perm(user, point):
            raise HTTPException(403, "无权限")
        return user
    return _check


def require_admin(user: dict = Depends(get_current_user)) -> dict:
    """兼容旧调用方：管理操作 = 拥有 system 权限点（原 admin 语义）。"""
    if not perms.has_perm(user, "system"):
        raise HTTPException(403, "需要管理员权限")
    return user


class AdminCreateUserBody(BaseModel):
    username: str
    password: str


class LoginBody(BaseModel):
    username: str
    password: str


class RefreshBody(BaseModel):
    refresh_token: str


class ChangePasswordBody(BaseModel):
    old_password: str
    new_password: str


class AdminResetPasswordBody(BaseModel):
    new_password: str


class JoydataEmailBody(BaseModel):
    joydata_email: str


@router.post("/login", response_model=AuthResponse)
async def login(body: LoginBody):
    uname = body.username.strip()
    user = get_user_by_username(uname)
    if not user or user.get("id") == "anonymous":
        # anonymous 是 ide_mount 的 FK 占位行，永不参与登录（对抗审查 HIGH：
        # 该行曾带硬编码口令且拥有全量权限点，一旦登录即绕过 require_admin）。
        # 与用户不存在同响应，防用户名枚举。
        raise HTTPException(401, "用户名或密码错误")
    if user.get("login_attempts", 0) >= settings.LOGIN_MAX_ATTEMPTS:
        raise HTTPException(429, "登录失败次数过多，请稍后再试")
    if not verify_password(body.password, user["password_hash"]):
        increment_login_attempts(uname)
        raise HTTPException(401, "用户名或密码错误")
    from ..services.db_service import clear_login_attempts
    clear_login_attempts(user["id"])
    access, refresh, exp = create_token(user["id"])
    update_user_token(user["id"], refresh, exp.isoformat())
    return {"user": {"id": user["id"], "username": user["username"]}, "access_token": access, "refresh_token": refresh, "expires_at": exp.isoformat()}


@router.post("/refresh", response_model=TokenRefreshResponse)
async def refresh(body: RefreshBody):
    payload = decode_token(body.refresh_token)
    if not payload or payload.get("type") != "refresh":
        raise HTTPException(401, "刷新令牌无效")
    user = get_user_by_id(payload["sub"])
    if not user:
        raise HTTPException(401, "用户不存在")
    access, refresh, exp = create_token(user["id"])
    return {"access_token": access, "refresh_token": refresh, "expires_at": exp.isoformat()}


@router.get("/me")
async def me(user: dict = Depends(get_current_user)):
    view = perms.user_perm_view(user)
    is_admin = perms.has_perm(user, "system")
    try:
        cfg = get_agent_config(user["id"])
    except Exception:
        cfg = {}
    has_key = bool((cfg.get("api_key") or "").strip())
    # llm_access：admin 回落系统默认；configured 已手填个人 Key；required 未配置（AI 全被拦）
    llm_access = "admin" if is_admin else ("configured" if has_key else "required")
    return {
        "id": user["id"],
        "username": user["username"],
        "role": user.get("role", "user"),
        "last_login_at": user.get("last_login_at", ""),
        "identity": view["identity"],
        "identity_name": view["identity_name"],
        "permissions": view["permissions"],
        "games": view["games"],
        "is_custom": view["is_custom"],
        "llm_access": llm_access,
    }


@router.post("/logout")
async def logout(user: dict = Depends(get_current_user)):
    from ..services.cache import clear_user_cache as clear_agent_cache
    clear_agent_cache(user["id"])
    c = _conn()
    c.execute("UPDATE users SET refresh_token=NULL, refresh_token_expires_at=NULL WHERE id=?", (user["id"],))
    c.commit()
    return {"message": "已退出"}


# ── Change own password ──

@router.put("/change-password")
async def change_password(body: ChangePasswordBody, user: dict = Depends(get_current_user)):
    if len(body.new_password) < 6:
        raise HTTPException(400, "新密码至少 6 个字符")
    if not verify_password(body.old_password, user["password_hash"]):
        raise HTTPException(400, "原密码错误")
    new_hash = hash_password(body.new_password)
    c = _conn()
    c.execute("UPDATE users SET password_hash=?, updated_at=datetime('now') WHERE id=?", (new_hash, user["id"]))
    c.commit()
    return {"message": "密码已修改"}


# ── Admin: create user（内部建号，无公开注册；审计 P1-17）──

@router.post("/users", status_code=201)
async def admin_create_user(body: AdminCreateUserBody, admin: dict = Depends(require_admin)):
    uname = body.username.strip()
    if len(uname) < 3:
        raise HTTPException(400, "用户名至少 3 个字符")
    if len(body.password) < 6:
        raise HTTPException(400, "密码至少 6 个字符")
    if get_user_by_username(uname):
        raise HTTPException(409, "用户名已存在")
    init_db()
    user = create_user(uname, hash_password(body.password))
    return {"id": user["id"], "username": user["username"]}


# ── Admin: list users ──

@router.get("/users")
async def list_users(admin: dict = Depends(require_admin)):
    c = _conn()
    rows = c.execute(
        "SELECT id, username, role, is_active, login_attempts, last_login_at, created_at, joydata_email, identity, extra_permissions, extra_games, extra_access_levels "
        "FROM users ORDER BY created_at DESC"
    ).fetchall()
    out = []
    for r in rows:
        d = dict(r)
        view = perms.user_perm_view(d)
        d["identity"] = view["identity"]
        d["identity_name"] = view["identity_name"]
        d["is_custom"] = view["is_custom"]
        out.append(d)
    return out


@router.get("/users/basic")
async def list_users_basic(user: dict = Depends(get_current_user)):
    """所有活跃用户 (id + username) — 用于分享目标选择、Bot 映射等。
    当前用户始终排在第一位。
    """
    c = _conn()
    rows = c.execute(
        "SELECT id, username FROM users WHERE is_active=1 ORDER BY username"
    ).fetchall()
    users = [{"id": r["id"], "username": r["username"]} for r in rows]
    # 当前用户排最前面
    me = next((u for u in users if u["id"] == user["id"]), None)
    if me:
        users.remove(me)
        users.insert(0, me)
    return users


# ── Admin: reset user password ──

@router.put("/users/{target_id}/reset-password")
async def admin_reset_password(target_id: str, body: AdminResetPasswordBody, admin: dict = Depends(require_admin)):
    if len(body.new_password) < 6:
        raise HTTPException(400, "密码至少 6 个字符")
    user = get_user_by_id(target_id)
    if not user:
        raise HTTPException(404, "用户不存在")
    new_hash = hash_password(body.new_password)
    c = _conn()
    c.execute("UPDATE users SET password_hash=?, updated_at=datetime('now'), login_attempts=0 WHERE id=?", (new_hash, target_id))
    c.commit()
    return {"message": f"用户 {user['username']} 密码已重置"}


# ── Admin: 绑定 joydata 邮箱（看板「每人各看各的」身份来源）──

@router.put("/users/{target_id}/joydata-email")
async def admin_set_joydata_email(target_id: str, body: JoydataEmailBody, admin: dict = Depends(require_admin)):
    user = get_user_by_id(target_id)
    if not user:
        raise HTTPException(404, "用户不存在")
    email = body.joydata_email.strip()
    set_user_joydata_email(target_id, email)
    # 审计 P1-17 收尾：命中映射的身份由 admin 设置邮箱这一刻（前端已弹显式确认）快照进
    # users.identity——仅当用户无显式身份时写入，之后 resolve_identity 不再实时重算邮箱映射，
    # 改映射表不会追溯重归既有用户；邮箱验证环节不设（内部后台、账号开启走内部调整），
    # 以「管理员确认 + 可改显式身份」替代
    fresh = get_user_by_id(target_id)
    auto_ident = perms._email_identity(fresh or {})
    applied = False
    if auto_ident and not perms._parse_identity_keys(fresh.get("identity")):
        c = _conn()
        c.execute("UPDATE users SET identity=?, updated_at=datetime('now') WHERE id=?", (json.dumps([auto_ident["key"]]), target_id))
        c.commit()
        applied = True
    return {
        "message": f"用户 {user['username']} 的 joydata 邮箱已更新",
        "joydata_email": email,
        "auto_identity": (auto_ident or {}).get("key", ""),
        "auto_identity_name": (auto_ident or {}).get("name", ""),
        "identity_applied": applied,
    }


# ── Admin: 删除用户 ──

@router.delete("/users/{target_id}")
async def delete_user(target_id: str, admin: dict = Depends(require_admin)):
    target = get_user_by_id(target_id)
    if not target:
        raise HTTPException(404, "用户不存在")
    if target["id"] == "anonymous":
        raise HTTPException(400, "anonymous 是系统回落占位，不可删除")
    if target["id"] == admin["id"]:
        raise HTTPException(400, "不能删除当前登录账号")
    # 保护最后一个拥有 system 权限点的账号，避免系统管理无人可进
    if perms.has_perm(target, "system"):
        c = _conn()
        all_users = c.execute("SELECT * FROM users").fetchall()
        # 对抗审查 HIGH：anonymous 占位行经 effective_permissions 持有全量权限点（含 system），
        # 计入会让「最后一个系统账号」永远删不掉之外，还会让本保护形同虚设——必须剔除。
        admins = [u for u in all_users if u["id"] != "anonymous" and perms.has_perm(dict(u), "system")]
        if len(admins) <= 1:
            raise HTTPException(400, "不能删除最后一个拥有系统管理权限的账号")
    db_delete_user(target_id)
    return {"message": f"用户 {target['username']} 已删除"}

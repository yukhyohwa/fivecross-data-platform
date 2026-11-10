"""依赖注入：数据库 engine 单例 + 鉴权桩（预留账号体系）+ 当前游戏项目。"""
from fastapi import Depends, HTTPException, Request

from . import config
from .services import games

_engine = None


def get_engine():
    """返回复用的 SQLAlchemy engine（懒加载单例，避免每次请求重建连接池）。"""
    global _engine
    if _engine is None:
        _engine = config.build_engine()
    return _engine


# 聊天「不选游戏」哨兵（X-Game: __any__）只在以下端点返回 game=None（chat/agent 流程负责
# 提问绑定游戏）；打到其它 ~40 个 Depends(get_game) 消费者时按缺省 key 回落允许集第一项，
# 防伪造哨兵让它们 500。
_CHAT_SENTINEL_ROUTES = frozenset({
    "/api/chat",
    "/api/chat/suggest",
    "/api/chat/suggest-merge",
    "/api/chat/gaps",
    "/api/chat/gap-whitelist",
    "/api/chat/gap-fix",
    "/api/chat/gap-fix/apply",
    "/api/chat/gap-answer",
    "/api/chat/gap-answer/apply",
    "/api/chat/export-csv",
    "/api/agent/chat/stream",
})


def _is_chat_sentinel_route(request: Request) -> bool:
    route = request.scope.get("route")
    return bool(route) and getattr(route, "path", "") in _CHAT_SENTINEL_ROUTES


def get_game(request: Request):
    """解析当前游戏项目：优先 `X-Game` 请求头，其次 `game` query 参数，回退默认游戏。

    返回游戏 dict：{key, name, region, short_name, description, db}；聊天页「不选游戏」哨兵
    （X-Game: __any__）打到聊天/深度分析端点时返回 None（由调用方提问绑定游戏）。
    带游戏授权硬拦：非全游戏用户请求无权限游戏 → 403；未指定则回退到允许集内第一个游戏；
    零权限用户一律 403（明确告知，不回落）。
    """
    key = request.headers.get("X-Game") or request.query_params.get("game") or ""
    # 游戏授权（RBAC）：懒 import 避免与 backend 包加载循环
    from backend.ide_app.services.permissions import effective_games
    allowed = effective_games(get_current_user(request))
    key = key.strip()
    if not allowed:
        raise HTTPException(403, "您没有任何游戏的数据权限，无法查询数据，请联系管理员开通")
    if key == "__any__":
        if _is_chat_sentinel_route(request):
            return None
        key = ""  # 非聊天端点：按缺省 key 回落允许集第一项
    if "*" not in allowed:
        if key and key not in allowed:
            raise HTTPException(403, "无此游戏权限")
        if not key:
            key = allowed[0]
    # games.json is a local registry; resolving a project must not initialize
    # the legacy reference-company MySQL/StarRocks engine. Data queries are
    # routed later through fivecross-data-client.
    return games.resolve(key)


def get_current_user(request: Request) -> dict:
    """解析可选登录身份：请求带有效 `Authorization: Bearer <JWT>` 时返回真实用户，
    否则（AUTH_ENABLED=false）回退匿名用户，业务路由无需改动。

    复用 sql-ide（backend/ide_app）的 JWT 实现与 users 表；懒 import 避免循环依赖。
    """
    try:
        from backend.ide_app.core.auth import decode_token
        from backend.ide_app.services.db_service import get_user_by_id
    except Exception:
        # ide_app 未就绪（理论上不会发生）：退化为旧的匿名/未实现行为
        if not config.auth_enabled():
            return {"username": "anonymous", "authenticated": False}
        raise HTTPException(status_code=401, detail="鉴权服务未就绪")

    auth_header = request.headers.get("Authorization", "")
    token = auth_header[7:].strip() if auth_header.startswith("Bearer ") else ""

    if token:
        payload = decode_token(token)
        if payload and payload.get("type") == "access":
            user = get_user_by_id(payload.get("sub"))
            if user and user.get("is_active", 1):
                user = dict(user)
                user["authenticated"] = True
                return user

    if not config.auth_enabled():
        return {"username": "anonymous", "authenticated": False}
    raise HTTPException(status_code=401, detail="未登录或令牌无效")


def require_analysis_edit(user: dict = Depends(get_current_user)) -> dict:
    """「新增/修改 专项·知识库·SQL·算法」权限点闸门（analysis_edit）。

    无该点但有 analysis 时仅可查看；匿名回落恒真。写入口统一收敛到此处，
    避免各路由各自散落 has_perm 判断。
    """
    from backend.ide_app.services.permissions import has_perm
    if not has_perm(user, "analysis_edit"):
        raise HTTPException(status_code=403, detail="仅可查看：无「新增/修改」专项·知识库·SQL·算法 的权限")
    return user


def require_analysis_delete(user: dict = Depends(get_current_user)) -> dict:
    """「删除 专项·知识库·SQL·算法」权限点闸门（analysis_delete）。"""
    from backend.ide_app.services.permissions import has_perm
    if not has_perm(user, "analysis_delete"):
        raise HTTPException(status_code=403, detail="仅可查看：无「删除」专项·知识库·SQL·算法 的权限")
    return user

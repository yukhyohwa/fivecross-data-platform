"""FiveCross Data Platform FastAPI entrypoint."""
import hmac
import json
import sys
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles


class TokenAuthMiddleware:
    """共享令牌鉴权（纯 ASGI，不包裹响应，故不影响 SSE 流式返回）。

    配置了 AUTH_TOKEN 时，所有 /api/* 请求必须携带匹配的 X-Auth-Token 头，否则 401。
    OPTIONS（CORS 预检）与 /api/auth/login 放行；未配置令牌则完全透明（保持现状）。
    """

    def __init__(self, app, token: str):
        self.app = app
        self.token = token

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        path = scope.get("path", "")
        method = scope.get("method", "")
        if (
            self.token
            and path.startswith("/api/")
            and method != "OPTIONS"
            and path not in ("/api/auth/login", "/api/auth/refresh")

        ):
            headers = {k.decode("latin-1").lower(): v.decode("latin-1") for k, v in scope.get("headers", [])}
            # 常数时间比较，避免共享令牌被时序侧信道探测
            if not hmac.compare_digest(headers.get("x-auth-token", ""), self.token):
                body = json.dumps({"detail": "缺少或错误的访问令牌（X-Auth-Token）"}).encode("utf-8")
                await send({
                    "type": "http.response.start",
                    "status": 401,
                    "headers": [
                        (b"content-type", b"application/json"),
                        (b"content-length", str(len(body)).encode("ascii")),
                    ],
                })
                await send({"type": "http.response.body", "body": body})
                return
        await self.app(scope, receive, send)


class UserContextMiddleware:
    """把当前登录用户注入 analysis.ai_client 的 per-user LLM 上下文（纯 ASGI、不包裹响应）。

    只在 /api/* 下解析 Bearer 令牌；analysis 包内所有 LLM 调用（sql_gen / kb_gen 等，不经
    backend.services.llm 的 complete*）据此路由到该用户个人 API Key——非管理员未配 key 时由
    resolver 抛 LLMNotConfigured 统一 403，不再静默回落全局 .env。复用 sql-ide 的 JWT 解码。
    """

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        path = scope.get("path", "")
        token = ""
        if path.startswith("/api/"):
            headers = {k.decode("latin-1").lower(): v.decode("latin-1") for k, v in scope.get("headers", [])}
            auth = headers.get("authorization", "")
            if auth[:7].lower() == "bearer ":
                token = auth[7:].strip()
        user = None
        if token:
            try:
                from backend.ide_app.core.auth import decode_token
                from backend.ide_app.services.db_service import get_user_by_id

                payload = decode_token(token)
                if payload and payload.get("type") == "access":
                    u = get_user_by_id(payload.get("sub"))
                    if u and u.get("is_active", 1):
                        user = dict(u)
                        user["authenticated"] = True
            except Exception:
                user = None
        if user is None and not config.auth_enabled():
            # 与 get_current_user 对齐：匿名（未开鉴权）请求也注入 anonymous 上下文，
            # 使「个人」层级资产按 owner 归属（owner_key="anonymous"）可正常往返，而非保存后不可见。
            user = {"username": "anonymous", "authenticated": False}
        from analysis import ai_client

        tok = ai_client.set_current_user(user)
        try:
            await self.app(scope, receive, send)
        finally:
            ai_client.reset_current_user(tok)


from . import config  # noqa: F401  （导入即设置 sys.path、加载 .env）
from .routers import agent, chat, chat_history, config_admin, kb_admin, meta, models, reports, skills, sql_admin, sql_history, versions
from .routers import memory as memory_router, indicators as indicators_router  # noqa: E501  （P4 融合）
from . import ide_mount  # noqa: F401  （原 sql-ide 能力，已迁入 backend/ide_app，挂 /api/*）
from backend.ide_app.api.auth_api import router as unified_auth_router  # noqa: E402  （统一认证：共用账户/JWT）
from backend.ide_app.api.permissions_api import router as permissions_router  # noqa: E402  （权限管理 RBAC）
from .routers import mcp_catalog  # noqa: E402  （统一工具目录：晚于 ide_mount，复用已加载的 mcp_gateway）
from backend.services.llm import LLMNotConfigured  # noqa: E402  （非管理员未配 LLM → 统一 403）

@asynccontextmanager
async def lifespan(app: FastAPI):
    # IDE 子应用启动（建库/迁移/恢复连接/调度器/连接池/飞书 WS）
    await ide_mount.ide_startup()
    # 全局兜底模型同步（模型管理 store > LITELLM_FALLBACK_MODEL > deepseek-v4-pro），
    # 运行时修改经 PUT /api/admin/config/models 即时同步。
    from analysis import ai_client as _ai
    _ai.set_fallback_model(config.global_fallback_model())
    # 审计 P2-13：dist/src 漂移校验（仅告警，绝不阻塞启动）
    try:
        from scripts.check_dist_drift import check_only
        check_only(log=lambda msg: print(msg, flush=True))
    except Exception as e:  # 校验脚本异常不影响服务
        print(f"[dist-drift] 校验执行失败（忽略）：{e}", flush=True)
    # 审计建议 10：ide_data.db 每日备份 daemon（独立前缀 ide_data_daily_*，与启动快照互不干扰；
    # 每小时醒来一次，同一天已备过则跳过；daemon 线程随进程退出，任何失败不阻断服务）
    import threading
    stop_daily_backup = threading.Event()

    def _daily_backup_loop():
        from backend.ide_app.services import db_service as _db_svc
        while not stop_daily_backup.is_set():
            _db_svc.backup_db_daily()
            stop_daily_backup.wait(3600)

    threading.Thread(target=_daily_backup_loop, daemon=True, name="db-daily-backup").start()
    yield
    stop_daily_backup.set()
    await ide_mount.ide_shutdown()


app = FastAPI(title="FiveCross Data Platform", version="1.0.0", lifespan=lifespan)


@app.exception_handler(LLMNotConfigured)
async def _llm_not_configured_handler(request, exc: LLMNotConfigured):
    """非管理员未配个人 LLM Key：所有 AI 端点统一返回 403 + 清晰提示，而非 500。"""
    from fastapi.responses import JSONResponse
    return JSONResponse(status_code=403, content={"detail": str(exc)})


# 共享令牌鉴权（先注册=内层；CORS 后注册=外层，保证 401 也带 CORS 头、预检放行）
app.add_middleware(TokenAuthMiddleware, token=config.auth_token())

app.add_middleware(
    CORSMiddleware,
    # 本地使用：allow_origins=["*"] 全开即可。注意不能与 allow_credentials=True 同时用——
    # 浏览器规范下，凭据请求不允许与通配源 "*" 搭配，二者矛盾，故这里显式关闭凭据。
    # 审计 P2-11 评审结论（2026-10-15）：现状安全。理由：鉴权为 Bearer token（Authorization 头），
    # token 存于前端 localStorage（同源隔离），无 Cookie/环境凭据可被跨域附带或窃取。
    # 残余风险（不阻塞）：① 任意网页可跨域请求本 API 并读取响应，若默认口令未改存在已知口令登录路径；
    # ② 若未来引入 Cookie 会话登录，必须把 allow_origins 收敛为具体 origin 白名单。
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# per-user LLM 上下文（最后注册=最外层，最先解析用户，覆盖所有 /api/* 端点）
app.add_middleware(UserContextMiddleware)

app.include_router(meta.router)
app.include_router(chat.router)
app.include_router(agent.router)  # /api/agent/* —— 深度分析（agentic 循环）
app.include_router(sql_admin.router)
app.include_router(sql_history.router)  # /api/sql-history —— SQL 编辑器「历史记录」侧栏
app.include_router(kb_admin.router)
app.include_router(skills.router)
app.include_router(models.router)
app.include_router(reports.router)
app.include_router(chat_history.router)
app.include_router(versions.router)

app.include_router(config_admin.router)
app.include_router(unified_auth_router)  # /api/auth/* —— 统一认证
app.include_router(permissions_router)  # /api/permissions/* —— 权限管理 RBAC

# ── P4 融合：data_ai 侧一等公民接口 ──────────────────────────────────────────────
# 记忆/指标/标签 = data_ai 核心资产，匿名可用（映射 anonymous 用户），复用 ide_data.db。
app.include_router(memory_router.router)        # /api/memory/*
app.include_router(indicators_router.router)    # /api/indicators/*
# 敏感凭证域（BI 看板/MCP/远程 MCP/BI 配置）强绑定用户身份，
# 直接复用 sql-ide 的 router 对象挂到 /api（需登录）。
app.include_router(ide_mount.mcp_router)           # /api/mcp/*
app.include_router(mcp_catalog.router)             # /api/mcp/catalog —— 统一工具目录 + 编辑
app.include_router(ide_mount.remote_mcp_router)    # /api/remote-mcp/*

class NoCacheStaticFiles(StaticFiles):
    """静态资源一律 no-store：改前端后浏览器绝不缓存（含 index.html），避免旧包被复用导致「看不到更新」。"""

    async def __call__(self, scope, receive, send):
        async def _send(message):
            if message["type"] == "http.response.start":
                headers = [(k, v) for k, v in message.get("headers", []) if k != b"cache-control"]
                headers.append((b"cache-control", b"no-store, no-cache, must-revalidate"))
                message["headers"] = headers
            await send(message)

        await super().__call__(scope, receive, _send)


# 前端统一（Task E 终章）：React 壳挂根 /；data_ai vanilla 页面挂 /app（iframe 嵌入用）。
# 注意 /app 必须先于 / 挂载（根静态目录会吞掉一切未命中路径）。API 路由已全部挂到 /api/*。
IDE_FRONTEND_DIR = Path(__file__).resolve().parent.parent / "ide_frontend" / "dist"
FRONTEND_DIR = Path(__file__).resolve().parent.parent / "frontend"
app.mount("/app", NoCacheStaticFiles(directory=str(FRONTEND_DIR), html=True), name="frontend")
app.mount("/", NoCacheStaticFiles(directory=str(IDE_FRONTEND_DIR), html=True), name="ide-frontend")

# reload probe

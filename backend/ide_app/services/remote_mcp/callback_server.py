"""MCP OAuth 环回回调 listener —— 对齐 Claude Code 的实现。

只处理 /callback；绑 127.0.0.1；端口取 settings.REMOTE_MCP_CALLBACK_PORT。
传感器（Sensor Tower）只接受 https 或 http+localhost 的 redirect_uri，
环回口天然满足，因此无需 TLS / 反向代理 / 前端回调页。

两种部署形态：
- 后端与浏览器同机（本地 dev / Electron）→ 本 listener 直接收到回调，零交互。
- 后端在服务器、浏览器在用户机器 → 回调打不到这里，用户把地址栏 URL 粘回
  UI，走 /api/remote-mcp/{id}/oauth/complete（CC 在远端会话下也是这个兜底）。
"""
import asyncio
import html
import logging
import urllib.parse

from backend.ide_app.core.settings import settings

from . import manager

logger = logging.getLogger(__name__)

CALLBACK_PATH = "/callback"

_server: asyncio.AbstractServer | None = None
_port: int = 0
_start_lock: asyncio.Lock | None = None
_last_error: str = ""


def _lock() -> asyncio.Lock:
    global _start_lock
    if _start_lock is None:
        _start_lock = asyncio.Lock()
    return _start_lock


def get_port() -> int:
    return _port


def get_last_error() -> str:
    return _last_error


def is_listening() -> bool:
    return _server is not None


def is_local_host(host: str) -> bool:
    """发起方是否从本机访问（决定 UI 要不要默认展开「粘贴回调」框）。"""
    h = (host or "").split(":")[0].strip().lower()
    return h in ("localhost", "127.0.0.1", "::1", "[::1]")


def _page(title: str, message: str, ok: bool = False) -> bytes:
    color = "#2ea043" if ok else "#d1242f"
    return (
        "<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"UTF-8\">"
        f"<title>{html.escape(title)}</title></head>"
        "<body style=\"font-family:system-ui,-apple-system,sans-serif;background:#0d1117;"
        "color:#e6edf3;display:flex;align-items:center;justify-content:center;"
        "height:100vh;margin:0\">"
        "<div style=\"max-width:560px;text-align:center;line-height:1.8\">"
        f"<h2 style=\"color:{color}\">{html.escape(title)}</h2>"
        f"<p>{html.escape(message)}</p></div></body></html>"
    ).encode("utf-8")


def _respond(writer: asyncio.StreamWriter, status: int, body: bytes,
             reason: str = "OK") -> None:
    headers = (
        f"HTTP/1.1 {status} {reason}\r\n"
        "Content-Type: text/html; charset=utf-8\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n"
        "Cache-Control: no-store\r\n"
        "\r\n"
    ).encode("utf-8")
    writer.write(headers + body)


async def _handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        try:
            raw = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=10)
        except (asyncio.IncompleteReadError, asyncio.TimeoutError):
            return
        request_line = raw.split(b"\r\n", 1)[0].decode("latin-1", "replace")
        parts = request_line.split(" ")
        target = parts[1] if len(parts) > 1 else ""
        parsed = urllib.parse.urlparse(target)
        path = parsed.path

        if path != CALLBACK_PATH:
            body = _page(
                "404 Not Found",
                f"这是FiveCross 数据平台的 MCP OAuth 回调监听器，只处理 {CALLBACK_PATH}。"
                f"如果你的 OAuth 提供方跳转到了这里，说明注册的 redirect_uri 应当是 "
                f"http://localhost:{_port}{CALLBACK_PATH}。",
            )
            _respond(writer, 404, body, "Not Found")
            return

        query = urllib.parse.parse_qs(parsed.query)
        state = (query.get("state") or [""])[0]
        code = (query.get("code") or [""])[0]
        error = (query.get("error") or [""])[0]
        error_desc = (query.get("error_description") or [""])[0]

        if error:
            message = f"{error}: {error_desc}" if error_desc else error
            manager.set_pending_result(state, {"ok": False, "error": message})
            _respond(writer, 400, _page("授权失败", message), "Bad Request")
            return

        if not manager.peek_pending(state):
            _respond(writer, 400, _page(
                "invalid state parameter",
                "授权会话不存在或已过期（授权码约 10 分钟内有效）。请回到FiveCross 数据平台重新发起授权。",
            ), "Bad Request")
            return

        if not code:
            _respond(writer, 400, _page("缺少 code", "回调地址中没有授权码。"), "Bad Request")
            return

        try:
            result = await manager.complete_oauth(state, code)
        except Exception as e:
            manager.set_pending_result(state, {"ok": False, "error": str(e)[:300]})
            _respond(writer, 400, _page("换取 token 失败", str(e)[:300]), "Bad Request")
            return

        manager.set_pending_result(state, result)
        count = result.get("tools_count", 0)
        _respond(writer, 200, _page(
            "✓ 授权成功",
            f"已发现 {count} 个工具。可以关闭本页返回FiveCross 数据平台。",
            ok=True,
        ))
    except Exception as e:  # 兜底：绝不让 listener 因单个请求崩掉
        logger.warning("remote_mcp callback listener error: %s", e)
    finally:
        try:
            await writer.drain()
        except Exception:
            pass
        writer.close()


async def ensure_listening() -> int:
    """懒启动 listener，返回实际端口。

    固定端口被占用时回退到系统临时端口 —— redirect_uri 随之改变，调用方
    （manager.start_oauth）会因为 redirect_uri 不匹配而重新走一次 DCR。
    """
    global _server, _port, _last_error
    async with _lock():
        if _server is not None:
            return _port

        desired = int(getattr(settings, "REMOTE_MCP_CALLBACK_PORT", 43975) or 43975)
        for port in (desired, 0):
            try:
                _server = await asyncio.start_server(_handle, "127.0.0.1", port)
                _port = _server.sockets[0].getsockname()[1]
                manager.set_callback_port(_port)
                if port == 0:
                    _last_error = (
                        f"回调端口 {desired} 已被占用，已回退到临时端口 {_port}。"
                        f"若是本机 Claude Code 占用，可用 "
                        f"`netstat -ano | findstr :{desired}`（Windows）或 "
                        f"`lsof -ti:{desired} -sTCP:LISTEN`（macOS/Linux）确认。"
                    )
                    logger.warning("remote_mcp: %s", _last_error)
                else:
                    _last_error = ""
                logger.info("remote_mcp: OAuth callback listener on 127.0.0.1:%s", _port)
                return _port
            except OSError as e:
                _last_error = f"回调监听启动失败（端口 {port or '临时'}）：{e}"
                logger.warning("remote_mcp: %s", _last_error)
                _server = None
        return 0


async def shutdown() -> None:
    global _server
    if _server is not None:
        _server.close()
        try:
            await _server.wait_closed()
        except Exception:
            pass
        _server = None

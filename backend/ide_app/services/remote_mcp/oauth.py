"""远程 MCP 服务器 OAuth 2.1 原语：DCR + PKCE(S256) + token 交换/刷新。

无状态 —— 不碰数据库、不碰 FastAPI 状态。失败抛 OAuthError（带 HTTP 状态与响应体）。
"""
import base64
import hashlib
import secrets
import time
import urllib.parse

import httpx

_DEFAULT_TIMEOUT = 20


class OAuthError(Exception):
    """OAuth 交互失败。status/body 供上层透传给 UI 排查。"""

    def __init__(self, message: str, status: int = 0, body: str = ""):
        super().__init__(message)
        self.status = status
        self.body = body


def pkce_pair() -> tuple[str, str]:
    """生成 (code_verifier, code_challenge)，S256。"""
    verifier = secrets.token_urlsafe(64)[:64]
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()
    ).rstrip(b"=").decode()
    return verifier, challenge


async def register_client(register_url: str, redirect_uri: str, client_name: str,
                          timeout: float = _DEFAULT_TIMEOUT) -> dict:
    """DCR（RFC7591）注册 public client。返回含 client_id 的响应。

    注意：Sensor Tower 会强制把 token_endpoint_auth_method 降级为 none、
    grant_types 收敛为 authorization_code，且不返回 client_secret —— 属预期行为。
    """
    if not register_url:
        raise OAuthError("该服务器未配置 DCR 注册地址（auth_register_url）")
    payload = {
        "client_name": client_name,
        "redirect_uris": [redirect_uri],
        "token_endpoint_auth_method": "none",
        "grant_types": ["authorization_code"],
        "response_types": ["code"],
    }
    async with httpx.AsyncClient(timeout=timeout) as c:
        r = await c.post(register_url, json=payload)
    if r.status_code >= 400:
        raise OAuthError(f"DCR 注册失败 HTTP {r.status_code}", r.status_code, r.text[:500])
    data = r.json()
    if not data.get("client_id"):
        raise OAuthError("DCR 注册响应缺少 client_id", r.status_code, r.text[:500])
    return data


def build_authorize_url(authorize_url: str, *, client_id: str, redirect_uri: str,
                        scope: str, state: str, code_challenge: str,
                        resource: str = "") -> str:
    params = {
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "scope": scope,
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
        "state": state,
    }
    if resource:
        params["resource"] = resource
    return f"{authorize_url}?{urllib.parse.urlencode(params)}"


async def exchange_code(token_url: str, *, code: str, client_id: str,
                        redirect_uri: str, code_verifier: str,
                        timeout: float = _DEFAULT_TIMEOUT) -> dict:
    """授权码换 token。授权码单次使用、约 10 分钟过期。"""
    data = {
        "grant_type": "authorization_code",
        "code": code,
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "code_verifier": code_verifier,
    }
    return await _post_token(token_url, data, timeout)


async def refresh_access_token(token_url: str, *, refresh_token: str, client_id: str,
                               timeout: float = _DEFAULT_TIMEOUT) -> dict:
    data = {
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": client_id,
    }
    return await _post_token(token_url, data, timeout)


async def _post_token(token_url: str, data: dict, timeout: float) -> dict:
    if not token_url:
        raise OAuthError("该服务器未配置 token 端点（auth_token_url）")
    async with httpx.AsyncClient(timeout=timeout) as c:
        r = await c.post(
            token_url, data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
    if r.status_code >= 400:
        raise OAuthError(
            f"token 端点返回 HTTP {r.status_code}", r.status_code, r.text[:500]
        )
    return r.json()


def merge_token_response(old: dict, new: dict) -> dict:
    """合并刷新响应：新响应未带 refresh_token 时保留旧的（轮换语义）。"""
    merged = dict(old)
    merged.update(new)
    if not new.get("refresh_token") and old.get("refresh_token"):
        merged["refresh_token"] = old["refresh_token"]
    merged["obtained_at"] = int(time.time())
    merged["expires_at"] = merged["obtained_at"] + int(merged.get("expires_in", 7200))
    return merged


def parse_callback_url(value: str) -> dict:
    """解析用户粘贴的回调地址。

    接受三种形态（复刻 Claude Code 远端会话的「复制地址栏 URL」兜底）：
      - 整条 URL：  http://localhost:43975/callback?code=...&state=...
      - 仅 query：  ?code=...&state=...   或   code=...&state=...
      - 仅授权码：  <code>（此时拿不到 state，由调用方决定是否允许）

    返回 {'code','state','error','error_description'}，缺失的键为空串。
    """
    out = {"code": "", "state": "", "error": "", "error_description": ""}
    raw = (value or "").strip()
    if not raw:
        return out
    # 去掉可能被整条复制的引号/空白
    raw = raw.strip().strip('"').strip("'").strip()

    query = ""
    if "?" in raw:
        query = raw.split("?", 1)[1]
    elif raw.startswith("code=") or raw.startswith("state=") or raw.startswith("error="):
        query = raw
    elif "&" in raw and "=" in raw:
        query = raw

    if query:
        try:
            pairs = urllib.parse.parse_qs(query, keep_blank_values=True)
        except Exception:
            pairs = {}
        for k in out:
            if pairs.get(k):
                out[k] = pairs[k][0]
        if out["code"] or out["error"]:
            return out

    # 没解析出任何东西：当作裸授权码（不含 ? & = 的 token）
    if raw and not any(ch in raw for ch in "?&="):
        out["code"] = raw
    return out


def build_redirect_uri(port: int, path: str = "/callback") -> str:
    """环回收回调地址。ST 只接受 https 或 http+localhost/127.0.0.1。"""
    return f"http://localhost:{port}{path}"

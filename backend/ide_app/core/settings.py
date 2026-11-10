"""Centralized configuration via environment variables.

All tuneable constants live here. Use `from backend.ide_app.core.settings import settings`
and read `settings.FIELD` instead of scattered os.getenv() calls.

Env vars are loaded only from this platform's root .env (if present) and then
from the process environment. No sibling project configuration is consulted.
"""
from pathlib import Path
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=str(Path(__file__).resolve().parents[3] / ".env"),
        env_file_encoding="utf-8",
        case_sensitive=True,
        extra="ignore",
    )

    # ── Server ──────────────────────────────────────────────────────────────
    CORS_ORIGINS: str = (
        "http://localhost:5173,http://localhost:5174,"
        "http://localhost:5175,http://localhost:5176,"
        "http://localhost:8080,http://192.168.23.124:5174,"
        "http://192.168.23.124:28000,http://10.68.31.76:25173,"
        "http://10.68.31.76:28000,http://192.168.23.124:5176,"
    )

    # ── Auth ─────────────────────────────────────────────────────────────────
    JWT_SECRET_KEY: str = ""
    ACCESS_TOKEN_EXPIRE_HOURS: int = 8
    REFRESH_TOKEN_EXPIRE_DAYS: int = 30
    LOGIN_MAX_ATTEMPTS: int = 5

    # ── Internal database ────────────────────────────────────────────────────
    DB_ENCRYPT_KEY: str = ""

    # ── Query limits ─────────────────────────────────────────────────────────
    DEFAULT_MAX_ROWS: int = 1000
    AGENT_CONTEXT_MAX_ROWS: int = 200

    # ── Schema cache ─────────────────────────────────────────────────────────
    SCHEMA_CACHE_TTL_SECONDS: int = 3600
    SCHEMA_REFRESH_INTERVAL_SECONDS: int = 300


    # ── AI / LLM ──────────────────────────────────────────────────────────────
    # These are forwarded to the claude-agent-sdk subprocess via the OS environment.
    # Setting them here centralizes documentation; pydantic-settings also validates types.
    ANTHROPIC_BASE_URL: str = ""
    ANTHROPIC_AUTH_TOKEN: str = ""

    # Model used by the Claude backend (passed to ClaudeAgentOptions).
    # Set to the exact model ID recognized by your Anthropic endpoint or LiteLLM proxy.
    AGENT_MODEL: str = "claude-sonnet-4-5"

    # Agent streaming timeout (seconds): how long to wait between SDK events.
    AGENT_STREAM_TIMEOUT_S: int = 180

    # Max tool-call rounds per agent turn (both legacy and Claude backends).
    AGENT_MAX_ROUNDS: int = 8

    # Claude mode 工具白名单（逗号分隔，支持 glob 模式）。
    # 默认仅允许 mcp__sqlide__*；如需开放内置工具：mcp__sqlide__*,Read,Write,Bash
    # 注意：已启用的远程 MCP 服务器会自动并入 mcp__<name>__*（并集语义），无需在此重复配置。
    AGENT_ALLOWED_TOOLS: str = ""

    # ── 远程 MCP 服务器（通用配置层；consumer: app/services/remote_mcp/）──────
    # OAuth 环回回调端口（复刻 Claude Code 的机制）。Sensor Tower 只接受
    # https 或 http+localhost 的 redirect_uri，环回口天然满足。
    # 注意：本机若同时跑 Claude Code，它也用这个端口（实测 43973），故默认错开。
    REMOTE_MCP_CALLBACK_PORT: int = 43975
    # 刷新 access token 的提前量（秒）。远端 access token 约 2h。
    REMOTE_MCP_REFRESH_SKEW_S: int = 900
    # 授权待处理会话 TTL（秒），应 ≥ 授权码有效期（约 10 分钟）
    REMOTE_MCP_PENDING_TTL_S: int = 600

    # ── Joydata MCP（joydata_core，源自 joydata-dashboard-analyst）───────────
    # MCP 基地址（不含 /joydata-mcp-core 后缀；OAuth 授权服务器元数据从
    # {JOYDATA_MCP_BASE}/oauth/.well-known/oauth-authorization-server 运行时发现）。
    # 默认预发环境（与 joydata-dashboard-analyst/mcp.json 一致）；生产域名
    # joydata-api.123u.com 在内网才可达，可用环境变量切换。
    JOYDATA_MCP_BASE: str = "https://joydata-api-pre.123u.com/api/openapi"
    # Joydata Web 前端地址（「原站模式」iframe / 新窗口打开目标）。
    # 默认与 MCP 同为预发环境，保证 OAuth 登录 cookie 与看板数据同域。
    JOYDATA_WEB_URL: str = "https://joydata-pre.123u.com"
    # OAuth 回调公网基地址（redirect_uri = {base}/api/joydata/oauth/callback）。
    # 留空 = 用请求侧推断（request.base_url，且 Host 必须在白名单内）；反代部署时按需显式配置。
    JOYDATA_PUBLIC_BASE: str = ""
    # 未配 JOYDATA_PUBLIC_BASE 时额外放行的回调 Host（逗号分隔；本机地址始终放行）。
    # 防 Host 头伪造把 DCR redirect_uri 注册到攻击者域名。
    # 默认放行本系统生产部署域名 joydata_ai.123u.com（Host 白名单只拦「攻击者域名」，
    # 放行自己的部署域名不构成风险；对抗审查 2026-10-23 补充：白名单本身防不了「同域
    # 回调完成绑定」——攻击者在自己浏览器发起授权再诱骗受害者点回调链接。该攻击由
    # /oauth/start 下发的 state 会话 cookie + 回调校验防护。正式推荐仍是显式配
    # JOYDATA_PUBLIC_BASE）。
    JOYDATA_ALLOWED_HOSTS: str = "joydata_ai.123u.com"
    # refresh token 提前量（秒）与授权会话 TTL（秒）
    JOYDATA_REFRESH_SKEW_S: int = 900
    JOYDATA_PENDING_TTL_S: int = 600
    # MCP 调用超时（秒）
    JOYDATA_MCP_TIMEOUT_S: int = 60

    # Agent context management
    AGENT_MAX_OUTPUT_TOKENS: int = 16384        # LLM 单次输出上限
    AGENT_CONTEXT_WARN_TOKENS: int = 30000      # 上下文 token 预警阈值（超过后裁剪工具结果）
    AGENT_TOOL_RESULT_MAX_CHARS: int = 4000     # 单条工具结果最大字符数

    # ── Prompts ──────────────────────────────────────────────────────────────
    # Override the prompts directory (absolute path). Default: app/prompts/.
    PROMPTS_DIR: str = ""
    # Extra text appended to the agent system prompt (no file change needed).
    SYSTEM_PROMPT_EXTRA: str = ""

    @property
    def cors_origins_list(self) -> list[str]:
        return [o.strip() for o in self.CORS_ORIGINS.split(",") if o.strip()]

    @property
    def prompts_dir_path(self) -> Path:
        if self.PROMPTS_DIR:
            return Path(self.PROMPTS_DIR)
        return Path(__file__).parent.parent / "prompts"


settings = Settings()

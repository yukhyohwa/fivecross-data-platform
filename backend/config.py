"""FiveCross platform configuration.

The reference application's StarRocks/MySQL adapter is retained only as an
explicitly disabled legacy compatibility path. Analytical data access for
FiveCross projects must go through fivecross-data-client (AliCloud/ThinkingData).
"""
import configparser
import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from sqlalchemy import create_engine
from urllib.parse import quote_plus

# data_ai/backend/config.py -> parents: [0]=backend [1]=data_ai [2]=PY
PROJECT_ROOT = Path(__file__).resolve().parents[2]

# data_ai 应用根目录（analysis 包、数据目录 sql/knowledge/code/reports/_versions、.env 都在这）
DATA_AI_ROOT = Path(__file__).resolve().parents[1]
CHAT_HISTORY_DIR = DATA_AI_ROOT / "chat_history"
SUBSCRIPTION_DIR = DATA_AI_ROOT / "subscriptions"
REPORT_CONFIG_PATH = DATA_AI_ROOT / "report_config.json"
# 全站 LLM 模型槽位 store（「系统管理 → 模型管理」页读写，见 services/model_config.py）
MODEL_CONFIG_PATH = DATA_AI_ROOT / "model_config.json"
GAMES_PATH = DATA_AI_ROOT / "games.json"
PRICING_PATH = DATA_AI_ROOT / "pricing.json"

# 让 `import analysis.*` 可用（必须先于任何 analysis 导入）
if str(DATA_AI_ROOT) not in sys.path:
    sys.path.insert(0, str(DATA_AI_ROOT))

# 加载 data_ai 根 .env（OPENAI_API_KEY / LITELLM_BASE_URL 等，供 ai_client 使用）
load_dotenv(DATA_AI_ROOT / ".env")

from analysis.ai_client import MODELS as _DEFAULT_MODELS  # noqa: E402


def _db_config_paths() -> list[Path]:
    """db_config.ini 的查找顺序：环境变量 DB_CONFIG_PATH > PY 根目录 > data_ai 根目录。"""
    candidates = []
    env_path = os.environ.get("DB_CONFIG_PATH", "").strip()
    if env_path:
        candidates.append(Path(env_path))
    candidates.append(PROJECT_ROOT / "db_config.ini")
    candidates.append(DATA_AI_ROOT / "db_config.ini")
    return candidates


def db_settings() -> dict:
    """数据库连接配置（ini 优先，环境变量覆盖）。"""
    parser = configparser.ConfigParser()
    raw: dict = {}
    for p in _db_config_paths():
        if p.exists():
            parser.read(p, encoding="utf-8")
            if parser.has_section("database"):
                raw = dict(parser["database"])
                break

    # DB_PORT 可能被环境变量覆盖为非数字：int() 会抛异常导致启动失败，这里兜底回退默认端口。
    port_raw = os.environ.get("DB_PORT", raw.get("port", "9030"))
    try:
        port = int(port_raw)
    except (TypeError, ValueError):
        port = 9030

    return {
        "host": os.environ.get("DB_HOST", raw.get("host", "localhost")),
        "port": port,
        "user": os.environ.get("DB_USER", raw.get("user", "")),
        "password": os.environ.get("DB_PASSWORD", raw.get("password", "")),
        "database": os.environ.get("DB_NAME", raw.get("database", "")),
    }


def build_engine():
    """Build the optional legacy StarRocks/MySQL engine.

    This path is disabled by default because the copied reference project's
    MySQL endpoint belongs to 欢乐互娱, not FiveCross. FiveCross data routes
    must use ``fivecross-data-client``.
    """
    if os.environ.get("ENABLE_LEGACY_MYSQL", "false").strip().lower() not in {"1", "true", "yes"}:
        raise RuntimeError(
            "Legacy MySQL/StarRocks route is disabled for FiveCross; "
            "use fivecross-data-client (AliCloud/ThinkingData)."
        )
    s = db_settings()
    url = (
        f"mysql+pymysql://{quote_plus(s['user'])}:{quote_plus(s['password'])}"
        f"@{s['host']}:{s['port']}/{s['database']}"
    )
    return create_engine(
        url,
        pool_pre_ping=True,
        # SQL 执行读超时（审计·聊天优化块 C）：pymysql socket 级超时，与 LLM READ_TIMEOUT 同档
        # 封顶，避免某条取数在库上长时间挂起把整轮聊天拖死（此前无 SQL 超时）。可经环境变量覆盖。
        connect_args={
            "read_timeout": int(os.environ.get("DB_READ_TIMEOUT", "300")),
            "write_timeout": int(os.environ.get("DB_WRITE_TIMEOUT", "60")),
        },
    )


def available_models() -> list[str]:
    """可用模型列表：默认复用 ai_client.MODELS，可用 CHAT_MODELS（逗号分隔）覆盖/追加。"""
    override = os.environ.get("CHAT_MODELS", "").strip()
    if override:
        return [m.strip() for m in override.split(",") if m.strip()]
    return list(_DEFAULT_MODELS)


def default_model() -> str:
    """统一默认执行模型（审计 P0-10）。

    默认使用项目已配置且网关可确认的 claude-opus-5-5；可用 DEFAULT_MODEL 环境变量覆盖；
    若环境变量与默认值都不在可用列表内则回退 [0]。任务槽位的显式覆盖仍由
    services.model_config 解析，用户个人显式模型选择不受此系统默认影响。
    """
    ms = available_models()
    candidates = [
        m.strip() for m in os.environ.get("DEFAULT_MODEL", "").split(",") if m.strip()
    ] + ["claude-opus-5-5"]
    for c in candidates:
        if c in ms:
            return c
    return ms[0] if ms else ""



def auth_enabled() -> bool:
    """是否启用鉴权。v1 为 false；上线时置 true 并接入 JWT/OAuth。"""
    return os.environ.get("AUTH_ENABLED", "false").strip().lower() in ("1", "true", "yes")


def auth_token() -> str:
    """共享访问令牌（X-Auth-Token）。为空则不启用令牌校验（保持现状）。"""
    return os.environ.get("AUTH_TOKEN", "").strip()


# 自动生成 SQL 时探查的目标库（现有 SQL 里实际引用的库）
DEFAULT_TARGET_DB = os.environ.get("CHAT_TARGET_DB", "pf_rooc_am")

# 深度分析 Agent（P3）：模型与最大工具调用轮数。模型走 litellm 网关的 OpenAI 兼容名（见 ai_client.MODELS），
# 默认用 deepseek-v4-pro——claude-opus-4-6 经 Vertex 网关被 Anthropic 按项目级拒绝（见 ai_client 注释），
# 直接默认会稳定 400/502；deepseek-v4-pro 是该网关已验证可靠的兜底档。均可经环境变量覆盖。
AGENT_MODEL = os.environ.get("AGENT_MODEL", "deepseek-v4-pro")
# 兜底档与主档错开（审计 P1-3）：主档 deepseek-v4-pro 网关偶发挂起时，换 flash 大概率可用；
# 若同档互备，网关项目级故障会把两档一起打挂。
AGENT_FALLBACK_MODEL = os.environ.get("AGENT_FALLBACK_MODEL", "deepseek-v4-flash")
AGENT_MAX_ROUNDS = int(os.environ.get("AGENT_MAX_ROUNDS", "12"))

# 聊天整轮看门狗（审计·聊天优化块 C）：普通聊天与深度分析的「整轮」总时长上限（含全部 LLM 调用、
# 取数与重试）。此前没有整轮限制：READ_TIMEOUT 被每次重试重新给满后，单轮可跑 1000+ 秒。
# 到点由路由层主动结束并提示缩小范围（前端另有 ~930s 自动停止兜底）。均可经环境变量覆盖。
CHAT_TOTAL_TIMEOUT_S = int(os.environ.get("CHAT_TOTAL_TIMEOUT_S", "900"))
AGENT_TOTAL_TIMEOUT_S = int(os.environ.get("AGENT_TOTAL_TIMEOUT_S", "900"))
# 深度思考（报告开推理）整轮上限：开推理后三模型单轮可到数百秒，900s 整轮会截断深度思考报告；
# 放宽到 1800s 让「深度思考」模式能完整跑完三模型（可经环境变量覆盖）。
CHAT_DEEP_TOTAL_TIMEOUT_S = int(os.environ.get("CHAT_DEEP_TOTAL_TIMEOUT_S", "1800"))

# 深度分析喂给模型的历史轮数（审计·聊天优化块 B）：取最近 N 轮对话（用户+助手各算一条消息，
# 一轮≈2 条）随命中资产一起注入，让 AI Native 处理时带上上下文记忆。
AGENT_HISTORY_ROUNDS = int(os.environ.get("AGENT_HISTORY_ROUNDS", "10"))

# 指标拆分（一拆多）：单次结构化 JSON 输出，无需推理，用快速档 deepseek-v4-flash
# （推理模型 deepseek-v4-pro 慢且易把预算花在推导上导致正文为空/读超时）。
SPLIT_MODEL = os.environ.get("SPLIT_MODEL", "deepseek-v4-flash")

# 任务→模型映射（审计 P1-4）：生成入口按任务选型，不再各处 available_models()[0]/body.model 直取。
# 全部默认走 default_model()（deepseek-v4-pro），单任务可用 TASK_MODEL_<TASK> 环境变量覆盖；
# agent/split 沿用既有 AGENT_MODEL/SPLIT_MODEL 变量保持单点。
# 2026-10-26 起接入「模型管理」store：解析优先级 = 模型管理（model_config.json）
# > 环境变量 > 任务默认 > 系统默认；环境变量名表与解析逻辑统一在 services/model_config.py。


def task_model(task: str) -> str:
    """任务→模型映射入口：模型管理 store > 环境变量 > 任务默认 > default_model()。

    agent/split/fallback 等槽位默认走既有 AGENT_MODEL/SPLIT_MODEL 常量（保持与 config 属性一致）；
    report_ver 任务默认 deepseek-v4-flash（2026-10-26，验证轮保速度，见 model_config）。
    """
    from .services import model_config  # 惰性导入避免循环依赖
    return model_config._resolve(task)[0]


def agent_fallback_model() -> str:
    """深度分析 Agent 兜底模型：模型管理 store > AGENT_FALLBACK_MODEL 环境变量 > deepseek-v4-flash。"""
    from .services import model_config
    return model_config._resolve("agent_fallback")[0]


def global_fallback_model() -> str:
    """全局兜底模型（complete_with_fallback 自动切换档）：模型管理 store >
    LITELLM_FALLBACK_MODEL 环境变量 > deepseek-v4-pro。经 ai_client.set_fallback_model 生效。"""
    from .services import model_config
    return model_config._resolve("fallback")[0]


# temperature 按任务类型固定（审计 P1-4）：结构化 JSON 抽取 0（确定性、防幻觉格式），
# 生成类 0.3（适度发散）。接线点：services/llm.resolve_model_for_task 注入 analysis 请求上下文
# （ai_client 在调用方未显式传 temperature 时应用）。
_TEMPERATURES = {
    "structured": float(os.environ.get("TASK_TEMPERATURE_STRUCTURED", "0")),
    "generation": float(os.environ.get("TASK_TEMPERATURE_GENERATION", "0.3")),
}

# 任务名 → temperature 类型（P1-4 接线）：对话/正文生成类 generation；结构化 JSON 抽取 structured。
_TASK_TEMP_KIND = {
    "chat": "generation",        # 主对话
    "agent": "generation",       # 深度分析 Agent（工具调用轮）
    "report_gen": "generation",  # 报告生成
    "report_sum": "generation",  # 报告汇总
    "sql": "structured",         # SQL 生成
    "kb": "structured",          # 知识库摘要/问答生成
    "skill": "structured",       # 专项快照改写/关联
    "model": "structured",       # 算法模型生成/关联
    "report_ver": "structured",  # 报告验证
    "gap": "structured",         # 缺口修复
    "split": "structured",       # 指标拆分
}


def task_temperature(task: str) -> float:
    """按任务名取固定 temperature：结构化任务 0 / 生成类 0.3（均可经环境变量覆盖）；
    未知任务回落 generation。"""
    kind = _TASK_TEMP_KIND.get(task, "generation")
    return _TEMPERATURES.get(kind, _TEMPERATURES["generation"])


def core_table_patterns(game_key: str | None = None) -> list[str]:
    """SQL 生成时纳入 schema 的核心表过滤子串。

    目标库有 900+ 张表，全量喂给模型会超长且低效；默认只覆盖游戏流水主表 +
    当前游戏专属汇总/应用层表，可用环境变量 CHAT_CORE_TABLES（逗号分隔子串）覆盖。
    """
    override = os.environ.get("CHAT_CORE_TABLES", "").strip()
    if override:
        return [p.strip() for p in override.split(",") if p.strip()]
    k = (game_key or "").strip()
    patterns = [
        "dwd_all_games_",  # 全游戏核心明细（充值/活跃/注册/登录/安装等）
        "dim_kpi_target",  # KPI 目标表
    ]
    if k:
        patterns.append(f"dws_{k}_")  # 当前游戏汇总
        patterns.append(f"ads_{k}_")  # 当前游戏应用层
    return patterns

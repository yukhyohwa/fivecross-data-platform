import json
from .settings import settings

from .paths import APP_DIR  # 审计 P2-4：数据目录统一到项目 data_ai/data/.sql-ide（import 时自动搬迁旧 ~/.sql-ide）

CONNECTIONS_FILE = APP_DIR / "connections.json"
HISTORY_FILE = APP_DIR / "history.json"

# Re-exported for backward compatibility — prefer importing from settings directly.
DEFAULT_MAX_ROWS = settings.DEFAULT_MAX_ROWS
AGENT_CONTEXT_MAX_ROWS = settings.AGENT_CONTEXT_MAX_ROWS


def ensure_app_dir():
    APP_DIR.mkdir(parents=True, exist_ok=True)


def load_connections() -> dict:
    ensure_app_dir()
    if CONNECTIONS_FILE.exists():
        return json.loads(CONNECTIONS_FILE.read_text())
    return {}


def save_connections(connections: dict):
    ensure_app_dir()
    CONNECTIONS_FILE.write_text(
        json.dumps(connections, indent=2, ensure_ascii=False)
    )


def load_history() -> list:
    ensure_app_dir()
    if HISTORY_FILE.exists():
        return json.loads(HISTORY_FILE.read_text())
    return []


def save_history(history: list):
    ensure_app_dir()
    HISTORY_FILE.write_text(
        json.dumps(history, indent=2, ensure_ascii=False)
    )

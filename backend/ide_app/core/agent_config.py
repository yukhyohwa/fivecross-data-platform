import json

from .paths import APP_DIR  # 审计 P2-4：agent 配置文件随数据目录迁到项目 data_ai/data/.sql-ide

AGENT_CONFIG_FILE = APP_DIR / "agent_config.json"


def load_agent_config() -> dict:
    AGENT_CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    if AGENT_CONFIG_FILE.exists():
        return json.loads(AGENT_CONFIG_FILE.read_text())
    return {"api_key": "", "model": "deepseek-chat", "api_base": "https://api.deepseek.com/v1"}


def save_agent_config(data: dict):
    AGENT_CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    AGENT_CONFIG_FILE.write_text(json.dumps(data, indent=2, ensure_ascii=False))

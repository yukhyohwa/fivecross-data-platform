"""Prompt 配置加载器

所有 LLM prompt 从 app/prompts/*.md 加载，便于运维更新优化而无需改代码。

约定：
- 每个 .md 文件是一个 prompt 单元
- 文件可用 `---system---` 和 `---user---` 分隔符划分为 system/user 两段
  （无分隔符则整文件作为单一 prompt）
- {占位符} 用 str.format 渲染，调用方传 kwargs
- 读取后内存缓存，开发期可改文件即时生效（不缓存 system/user 拆分结果以外）

可通过环境变量 PROMPTS_DIR 指定自定义 prompt 目录（覆盖默认 app/prompts/）。
可通过 SYSTEM_PROMPT_EXTRA 向 agent_system prompt 追加额外内容（无需改文件）。
"""

from pathlib import Path
from typing import Optional

_DEFAULT_PROMPTS_DIR = Path(__file__).parent
_CACHE: dict[str, str] = {}


def _prompts_dir() -> Path:
    """Return the active prompts directory (env override or package default)."""
    from backend.ide_app.core.settings import settings
    if settings.PROMPTS_DIR:
        return Path(settings.PROMPTS_DIR)
    return _DEFAULT_PROMPTS_DIR


def _read(name: str) -> str:
    """读取 prompt 文件原文（带缓存）。支持子目录路径，如 'agent/system'。"""
    if name not in _CACHE:
        path = _prompts_dir() / f"{name}.md"
        if not path.exists():
            raise FileNotFoundError(f"Prompt 文件不存在: {path}")
        _CACHE[name] = path.read_text(encoding="utf-8")
    return _CACHE[name]


def load_system_user(name: str, **kwargs) -> tuple[str, str]:
    """加载含 system/user 两段的 prompt

    文件格式：
        ---system---
        system prompt 内容
        ---user---
        user prompt 内容

    Returns:
        (system, user) 渲染后的元组；无对应段则为空串
    """
    text = _read(name)
    system = ""
    user = ""
    if "---system---" in text:
        parts = text.split("---system---", 1)
        rest = parts[1] if len(parts) > 1 else ""
        if "---user---" in rest:
            system, user = rest.split("---user---", 1)
        else:
            system = rest
    elif "---user---" in text:
        user = text.split("---user---", 1)[1]
    else:
        # 无分隔符，整文件作为 system
        system = text
    system = system.strip()
    user = user.strip()
    if kwargs:
        try:
            system = system.format(**kwargs)
            user = user.format(**kwargs)
        except (KeyError, IndexError):
            pass
    return system, user


def reload():
    """清空缓存，下次读取重新从磁盘加载（开发调试用）"""
    _CACHE.clear()

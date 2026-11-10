"""通用远程 MCP 服务器配置层。

对外主要入口：
    manager.probe_server(row) / manager.start_oauth(...) / manager.complete_oauth(...)
    store.public_view(row) / store.validate_name(name)

设计背景见 plan：认证复刻 Claude Code 的环回 + 粘贴兜底模型；
服务器由 admin 配置、经 shared_items(item_type='remote_mcp') 分享给成员。
"""

from . import callback_server, manager, oauth, store  # noqa: F401

__all__ = ["manager", "store", "oauth", "callback_server"]

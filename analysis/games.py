"""游戏「家族」归一：把同一游戏的多地区服归到同一个家族键（去掉常见地区后缀）。

skills / docs / sql 的「项目」层级绑定的是家族（项目）而非具体地区服，
过滤时统一按 family_key 比对，避免绑到 rooc_am 后在主键 rooc 下搜不到。
"""

# 常见地区服后缀：用于把「同一游戏的多地区服」归到一个家族（如 kof / kof_sea -> kof）。
_REGION_SUFFIXES = (
    "_kr", "_jp", "_na", "_hmt", "_sea", "_cn", "_lna", "_am",
    "_th", "_tw", "_vn", "_id", "_sg", "_my", "_ph", "_global",
)


def family_key(game_key: str | None) -> str:
    """把游戏 key 归一到「家族」键：去掉常见地区后缀。kof_sea -> kof；ro_kr -> ro；无后缀则原样。"""
    k = (game_key or "").strip().lower()
    for suf in _REGION_SUFFIXES:
        if k.endswith(suf) and len(k) > len(suf):
            return k[: -len(suf)]
    return k


def visible_to(level: str | None, meta_game: str | None, current_key: str | None,
               meta_owner: str | None = None, current_owner: str | None = None) -> bool:
    """跨游戏/跨用户隔离判定。

    - 通用层级：全局可见。
    - 项目层级：按家族键同族可见（kof/kof_sea 互见，kof 与 ro_cn 隔离）。
    - 个人层级：仅归属键匹配（meta_owner == current_owner）可见；current_owner 为空（无用户上下文）
      或 meta_owner 为空（历史个人项未标注归属）时均不可见——宁可隐藏也不泄露他人个人资产。
    """
    level = (level or "").strip()
    if level == "" or level == "通用":
        return True
    if level == "个人":
        return bool(current_owner) and meta_owner == current_owner
    return family_key(meta_game) == family_key(current_key)


def owner_key(user) -> str | None:
    """从用户 dict 取「个人」资产归属键：id 优先，其次 username，匿名兜底 anonymous；空用户返回 None。"""
    if not user:
        return None
    return user.get("id") or user.get("username") or "anonymous"


def current_owner_key() -> str | None:
    """当前请求用户上下文的归属键（个人层级资产 owner）；无用户上下文返回 None。

    懒 import ai_client 避免模块加载期循环依赖；data_ai 每请求经中间件 set_current_user 注入，
    streamlit 等无注入场景自然回落 None（个人项不外泄）。
    """
    try:
        from analysis.ai_client import current_user
    except Exception:
        return None
    return owner_key(current_user())

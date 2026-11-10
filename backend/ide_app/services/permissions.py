"""RBAC 权限解析：二分法（游戏 × 身份）的生效权限计算，纯逻辑、无 FastAPI 依赖。

兼容两套 get_current_user：
- data_ai `backend.deps.get_current_user`：匿名回落 dict 无 `id`、带 `authenticated=False`。
- ide_app `auth_api.get_current_user`：始终返回真实用户（含 id/identity/extra_* 等列）。

统一以 `user.get("id")` 判空识别 anonymous（deps 版无 id；ide_app 版不会出现 anonymous）。
"""
import json
from typing import Optional

from . import db_service

# 权限点全集：4 个导航组 + 2 个「分析配置」细粒度动作点 + 4 个运行时「使用」点。
# 审计 P2-3：personal/workspace 为孤儿权限点（全后端无任何 has_perm/清单消费），已删除。
# analysis_edit = 新增/修改 专项·知识库·SQL·算法；analysis_delete = 删除上述四类。
# 二者皆缺但持有 analysis 时 → 分析配置仅可查看。
# sql_use/kb_use/skill_use/model_use = 运行时「使用」闸门（2026-10-29）：勾选了才能在
# 聊天/深度分析/专项执行里实际查询/引用对应资产，与只管增删改的 analysis_edit/delete 是两回事。
ALL_PERMISSION_POINTS = [
    "apps", "analysis", "ai", "system", "analysis_edit", "analysis_delete",
    "sql_use", "kb_use", "skill_use", "model_use",
]

# 资产机密等级：L1 绝密 > L2 机密 > L3 秘密。SQL / 知识库 / 专项 三类资产各带一档；
# 算法不分档。授予是「多选集合」（身份/用户各持一个 level 子集），资产档位命中集合即放行。
CONFIDENTIALITY_LEVELS = ["L1", "L2", "L3"]
CONFIDENTIALITY_LABELS = {"L1": "绝密", "L2": "机密", "L3": "秘密"}
LEVEL_TYPES = ("sql", "kb", "skill")  # model 无档位

ANONYMOUS = "anonymous"
DEFAULT_IDENTITY_KEY = "default"

# 身份种子：14 个业务身份 + 1 个兜底 default。games 默认 ["*"] = 全游戏。
BUILTIN_IDENTITIES: list[dict] = [
    {"key": "dev_admin", "name": "开发管理", "permission_points": ALL_PERMISSION_POINTS[:]},
    {"key": "data_analysis", "name": "数据分析", "permission_points": ["apps", "analysis", "analysis_edit", "analysis_delete", "ai"]},
    {"key": "corp_at", "name": "公司AT", "permission_points": ["apps"]},
    {"key": "ops_normal", "name": "运营普通", "permission_points": ["apps"]},
    {"key": "ops_senior", "name": "运营高级", "permission_points": ["apps"]},
    {"key": "finance", "name": "财务金流", "permission_points": ["apps"]},
    {"key": "rd_planning", "name": "研发策划", "permission_points": ["apps"]},
    {"key": "rd_program", "name": "研发程序", "permission_points": ["apps"]},
    {"key": "pm", "name": "项目PM", "permission_points": ["apps"]},
    {"key": "project_owner", "name": "项目负责人", "permission_points": ["apps"]},
    {"key": "ua", "name": "买量投放", "permission_points": ["apps"]},
    {"key": "social_media", "name": "社媒营销", "permission_points": ["apps"]},
    {"key": "cs", "name": "项目客服", "permission_points": ["apps"]},
    {"key": "security", "name": "产品安全", "permission_points": ["apps", "analysis"]},
    {"key": "default", "name": "普通用户", "permission_points": ["apps"]},
]


def _parse_list(raw) -> list:
    if not raw:
        return []
    try:
        v = json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return []
    return v if isinstance(v, list) else []


def _parse_obj(raw) -> dict:
    """把 access_levels / extra_access_levels 的 JSON 串（或已解 dict）规整为 dict。"""
    if isinstance(raw, dict):
        return raw
    if not raw:
        return {}
    try:
        v = json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return {}
    return v if isinstance(v, dict) else {}


def is_anonymous(user: Optional[dict]) -> bool:
    return not user or (user.get("id") in (None, ANONYMOUS))


def _full_access_identity() -> dict:
    return {
        "key": "",
        "name": "",
        "permission_points": ALL_PERMISSION_POINTS[:],
        "games": ["*"],
        "access_levels": {t: list(CONFIDENTIALITY_LEVELS) for t in LEVEL_TYPES},
    }


def _email_identity(user: dict) -> Optional[dict]:
    """用 joydata_email 走映射：先精确、再后缀（取最长 pattern）。命中返回身份，否则 None。"""
    email = (user.get("joydata_email") or "").strip().lower()
    if not email:
        return None
    rows = db_service.list_email_mappings()
    best: Optional[dict] = None
    best_len = 0
    for m in rows:
        pattern = (m.get("pattern") or "").strip().lower()
        if not pattern:
            continue
        if m.get("match_type") == "exact":
            if email == pattern:
                # 精确命中即最优
                ident = db_service.get_identity(m["identity_key"])
                if ident:
                    return ident
        else:  # suffix
            if email.endswith(pattern) and len(pattern) > best_len:
                ident = db_service.get_identity(m["identity_key"])
                if ident:
                    best = ident
                    best_len = len(pattern)
    return best


def _normalize_identity(ident: Optional[dict]) -> dict:
    """把 DB 行（permission_points/games/access_levels 是 JSON 字符串）规整为 list/dict 字段，
    避免下游把字符串当列表逐字符迭代。"""
    if not ident:
        return {"key": "", "name": "", "permission_points": [], "games": [], "access_levels": {}, "is_builtin": 0}
    return {
        "key": ident.get("key", ""),
        "name": ident.get("name", ""),
        "permission_points": _parse_list(ident.get("permission_points")),
        "games": _parse_list(ident.get("games")),
        "access_levels": _parse_obj(ident.get("access_levels")),
        "is_builtin": ident.get("is_builtin", 0),
    }


def _parse_identity_keys(raw) -> list[str]:
    """把 users.identity 落库值规整为身份 key 列表（多身份并存）。

    兼容两种形态：
    - 新：JSON 数组 `["dev_admin","data_analysis"]`；
    - 旧：单 key 字符串 `"dev_admin"`（历史数据）。
    空 / 非法 → []。
    """
    if not raw:
        return []
    s = raw.strip() if isinstance(raw, str) else ""
    if not s:
        return []
    try:
        v = json.loads(s)
    except (TypeError, json.JSONDecodeError):
        v = None
    if isinstance(v, list):
        return [x.strip() for x in v if isinstance(x, str) and x.strip()]
    return [s]


def resolve_identities(user: Optional[dict]) -> list[dict]:
    """返回该用户生效身份列表（多身份并存，权限/游戏/机密档位取并集）。

    顺序：匿名回落（全量）→ 显式 identities（多选，逐个解析、去重）→ default。
    审计 P1-17 收尾：邮箱映射不再每次请求实时重算——命中身份在 admin 设置 joydata 邮箱
    并经前端显式确认后，由 admin_set_joydata_email 快照进 users.identity（存量用户在
    seed_identities 启动时一次性快照）。改映射表不会追溯重归既有用户；_email_identity
    保留仅供该端点返回披露。
    """
    if is_anonymous(user):
        return [_full_access_identity()]

    idents: list[dict] = []
    seen: set[str] = set()
    for key in _parse_identity_keys(user.get("identity")):
        if key in seen:
            continue
        seen.add(key)
        ident = db_service.get_identity(key)
        if ident:
            idents.append(_normalize_identity(ident))
    if not idents:
        ident = db_service.get_identity(DEFAULT_IDENTITY_KEY)
        if ident:
            idents.append(_normalize_identity(ident))
    if not idents:
        return [{"key": "", "name": "", "permission_points": [], "games": [], "access_levels": {}}]
    return idents


def resolve_identity(user: Optional[dict]) -> dict:
    """返回该用户主身份（首个）dict——兼容旧调用方；多身份取并集请用 resolve_identities。"""
    idents = resolve_identities(user)
    return idents[0] if idents else {"key": "", "name": "", "permission_points": [], "games": [], "access_levels": {}}


def effective_permissions(user: Optional[dict]) -> set[str]:
    if is_anonymous(user):
        return set(ALL_PERMISSION_POINTS)
    points: set[str] = set()
    for ident in resolve_identities(user):
        points.update(ident.get("permission_points", []))
    points.update(_parse_list(user.get("extra_permissions")))
    return points


def effective_games(user: Optional[dict]) -> list[str]:
    if is_anonymous(user):
        return ["*"]
    games: set[str] = set()
    for ident in resolve_identities(user):
        g = ident.get("games", [])
        if "*" in g:
            return ["*"]
        games.update(g)
    out = set(games)
    out.update(_parse_list(user.get("extra_games")))
    return sorted(out)


def has_perm(user: Optional[dict], point: str) -> bool:
    return point in effective_permissions(user)


def is_game_allowed(user: Optional[dict], game_key: str) -> bool:
    allowed = effective_games(user)
    if "*" in allowed:
        return True
    return (game_key or "") in allowed


def effective_access_levels(user: Optional[dict], typ: str) -> set[str]:
    """返回该用户在某类资产（sql/kb/skill）上被授予的机密档位集合。

    - 匿名回落 / system 管理员：全档（L1/L2/L3）。
    - 身份 access_levels[typ] ∪ 用户 extra_access_levels[typ]（多选集合）。
    - 两者都空 → 默认最低档 {"L3"}（勾选了使用点但没设档 → 默认只能看最低档）。
    """
    if typ not in LEVEL_TYPES:
        return set()
    if is_anonymous(user) or has_perm(user, "system"):
        return set(CONFIDENTIALITY_LEVELS)
    merged: set[str] = set()
    for ident in resolve_identities(user):
        levels = ident.get("access_levels", {}).get(typ)
        if isinstance(levels, list):
            merged.update(l for l in levels if l in CONFIDENTIALITY_LEVELS)
    extra = _parse_obj(user.get("extra_access_levels")) if user else {}
    elv = extra.get(typ)
    if isinstance(elv, list):
        merged.update(l for l in elv if l in CONFIDENTIALITY_LEVELS)
    return merged or {CONFIDENTIALITY_LEVELS[-1]}  # 默认 L3


def can_use_asset(user: Optional[dict], typ: str, confidentiality: Optional[str] = None) -> bool:
    """运行时资产使用判定：先验「使用」权限点，再验资产机密档位。

    - typ ∈ sql/kb/skill/model；model 无档位，只查 model_use。
    - 未分级（confidentiality 空/非法）资产不设限：有对应使用点即放行。
    - 分级资产：要求资产档位 ∈ 用户被授予的档位集合。
    """
    if typ == "model":
        return has_perm(user, "model_use")
    if typ not in LEVEL_TYPES:
        return False
    if not has_perm(user, f"{typ}_use"):
        return False
    if not confidentiality or confidentiality not in CONFIDENTIALITY_LEVELS:
        return True
    return confidentiality in effective_access_levels(user, typ)


def normalize_confidentiality(value: Optional[str]) -> Optional[str]:
    """把资产机密档位规整到 L1/L2/L3；空/非法 → None（未分级）。"""
    v = (value or "").strip()
    return v if v in CONFIDENTIALITY_LEVELS else None


def clean_access_levels(raw: Optional[dict]) -> dict:
    """把身份/用户的 access_levels 规整为 {sql/kb/skill: [L1..L3]} 合法多选集合。

    只保留 LEVEL_TYPES 里的键与 CONFIDENTIALITY_LEVELS 里的值，保序去重；非法键值丢弃。
    """
    out: dict[str, list[str]] = {}
    if not isinstance(raw, dict):
        return out
    for typ in LEVEL_TYPES:
        levels = raw.get(typ)
        if not isinstance(levels, list):
            continue
        seen: list[str] = []
        for l in levels:
            if l in CONFIDENTIALITY_LEVELS and l not in seen:
                seen.append(l)
        if seen:
            out[typ] = seen
    return out


def user_perm_view(user: Optional[dict]) -> dict:
    """供 /me 与权限管理「用户授权」列表使用的统一视图。identity/identity_name 为多身份并列列表。"""
    idents = resolve_identities(user)
    extra_p = _parse_list(user.get("extra_permissions")) if user else []
    extra_g = _parse_list(user.get("extra_games")) if user else []
    return {
        "identity": [i.get("key", "") for i in idents if i.get("key")],
        "identity_name": [i.get("name", "") for i in idents if i.get("name")],
        "permissions": sorted(effective_permissions(user)),
        "games": effective_games(user),
        "is_custom": bool(extra_p or extra_g),
    }


def seed_identities() -> None:
    """幂等种入 14+1 个身份，并把存量 admin（role='admin' 且未分身份）归到 dev_admin。

    每次启动调用（不依赖 run_migration 的「无用户才建库」分支）。

    ⚠️ 只「缺则插入」，绝不覆盖已存在身份的 permission_points/games：权限管理允许编辑内置
    身份的「游戏授权」（全游戏 ↔ 自定义），若每次启动用默认 ["*"] 覆盖，用户改完一重启/
    一部署就被打回全游戏（upsert_identity 的 ON CONFLICT UPDATE 会把 games 重置为 ["*"]）。
    故这里先 get_identity 判存在性，只补缺、不动存量。
    """
    for ident in BUILTIN_IDENTITIES:
        if db_service.get_identity(ident["key"]):
            continue  # 已存在：保留用户对其权限点/游戏授权的自定义，不覆盖
        db_service.upsert_identity(
            key=ident["key"],
            name=ident["name"],
            permission_points=ident["permission_points"],
            games=["*"],
            is_builtin=1,
        )
    # 存量 admin → dev_admin（仅当 role='admin' 且 identity 为空，避免覆盖手动改派）
    c = db_service._conn()
    c.execute(
        "UPDATE users SET identity=? WHERE role='admin' AND (identity IS NULL OR identity='')",
        (json.dumps(["dev_admin"]),),
    )
    # 审计 P1-17 收尾：把存量「空 identity + 已设邮箱」的用户一次性按映射快照身份，
    # 之后 resolve_identities 不再实时重算邮箱映射（幂等：已快照的行不再为空，下次启动跳过）
    for r in c.execute(
        "SELECT id, joydata_email FROM users WHERE (identity IS NULL OR identity='') AND joydata_email!=''"
    ).fetchall():
        ident = _email_identity(dict(r))
        if ident:
            c.execute("UPDATE users SET identity=? WHERE id=?", (json.dumps([ident["key"]]), r["id"]))
    c.commit()

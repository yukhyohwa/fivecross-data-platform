"""全站 LLM 模型槽位管理：data_ai 里每个「用模型的地方」一个槽位，统一存
data_ai/model_config.json，供「系统管理 → 模型管理」页读写；解析优先级：

    模型管理（model_config.json）> 环境变量（TASK_MODEL_*/AGENT_* 等）> 任务默认 > 系统默认

config.task_model 是唯一入口（审计 P1-4 的任务→模型单一入口），内部调 _resolve，
因此 SQL 生成/专项/知识库/算法/报告三模型/缺口修复/指标拆分等所有生成路径自动生效。
老 report_config.json（报告三模型）在 store 首次读取时一次性迁移进来，之后以 store 为准。

写盘防护：线程锁 + tmp+os.replace 原子改名 + 覆盖前 .bak 备份（与 versioning 模块同口径）——
并发 PUT 不丢更新、进程中断不留半截 JSON、误存可人工恢复；热路径带 mtime 读缓存。

槽位清单即「全站 LLM 使用位置盘点」（2026-10-26）：
  chat           主对话（聊天窗口 AI 对话/追问 + SQL 复核/结果解读；用户可在聊天页自选模型覆盖）
  agent          深度分析 Agent 主模型（工具调用循环）
  agent_fallback 深度分析兜底（主模型失败时换用）
  sql            SQL 生成
  kb             知识库摘要/问答
  skill          专项快照改写/关联
  model          算法模型生成/关联
  report_gen     报告生成轮（三模型流水线初稿）
  report_ver     报告验证轮（数据复核；两轮模式同时定稿）
  report_sum     报告汇总轮（最终定稿）
  gap            缺口修复
  split          指标拆分（SQL 文件一拆多）
  fallback       全局兜底模型（任何 LLM 调用主模型失败时自动切换；经 ai_client.set_fallback_model 生效）

per-user 个人 LLM 配置
（右上角用户菜单，仅覆盖 chat/agent 主模型）也不在此，那是个人维度不是系统维度。
"""
import json
import os
import threading

from .. import config

# 槽位注册表（顺序即「模型管理」页展示顺序）
MODEL_SLOTS = [
    {"key": "chat", "label": "主对话", "desc": "聊天窗口 AI 对话/追问 + SQL 复核/结果解读（用户可在聊天页自选模型临时覆盖）"},
    {"key": "agent", "label": "深度分析 Agent", "desc": "聊天窗口「深度分析」工具调用循环主模型"},
    {"key": "agent_fallback", "label": "深度分析兜底", "desc": "深度分析主模型失败/挂起时自动切换（与主模型错档更抗故障）"},
    {"key": "sql", "label": "SQL 生成", "desc": "AI 自动生成/改写 SQL"},
    {"key": "kb", "label": "知识库生成", "desc": "知识库文档摘要/问答"},
    {"key": "skill", "label": "专项生成", "desc": "专项快照改写/关联"},
    {"key": "model", "label": "算法模型生成", "desc": "算法模型代码生成/关联"},
    {"key": "report_gen", "label": "报告生成轮", "desc": "三模型流水线：初稿生成（长文，建议旗舰档）"},
    {"key": "report_ver", "label": "报告验证轮", "desc": "三模型流水线：数据复核（两轮模式同时定稿；默认快速档保速度）"},
    {"key": "report_sum", "label": "报告汇总轮", "desc": "三模型流水线：最终汇总定稿（长文，建议旗舰档）"},
    {"key": "gap", "label": "缺口修复", "desc": "追问缺口/深挖补充分析"},
    {"key": "split", "label": "指标拆分", "desc": "SQL 文件拆分为单指标（结构化 JSON，快速档）"},
    {"key": "fallback", "label": "全局兜底", "desc": "任何 LLM 调用主模型失败时自动切换（高级，谨慎修改）"},
]

_SLOT_KEYS = [s["key"] for s in MODEL_SLOTS]

# 槽位 → 环境变量（部署级固定档）
_SLOT_ENV = {
    "chat": "TASK_MODEL_CHAT",
    "sql": "TASK_MODEL_SQL",
    "kb": "TASK_MODEL_KB",
    "skill": "TASK_MODEL_SKILL",
    "model": "TASK_MODEL_MODEL",
    "report_gen": "TASK_MODEL_REPORT_GEN",
    "report_ver": "TASK_MODEL_REPORT_VER",
    "report_sum": "TASK_MODEL_REPORT_SUM",
    "gap": "TASK_MODEL_GAP",
    "agent": "AGENT_MODEL",
    "agent_fallback": "AGENT_FALLBACK_MODEL",
    "split": "SPLIT_MODEL",
    "fallback": "LITELLM_FALLBACK_MODEL",
}

# 任务默认档（区别于「系统默认」default_model()）：这些槽位有独立的经验默认值。
# report_ver 2026-10-26 起默认快速档 deepseek-v4-flash（用户要求验证轮保速度：
# 验证是数据复核而非长文创作，flash 足够；deepseek-v4-pro 验证轮多次 300s 读超时）。
def _special_default(key: str) -> str | None:
    if key == "agent":
        return config.AGENT_MODEL
    if key == "agent_fallback":
        return config.AGENT_FALLBACK_MODEL
    if key == "split":
        return config.SPLIT_MODEL
    if key == "report_ver":
        return "deepseek-v4-flash"
    if key == "fallback":
        return "deepseek-v4-pro"
    return None


# 进程级读缓存（key=str(path) → (mtime_ns, size, dict)）：task_model 在 LLM 热路径上，
# 文件未变化时不再重复磁盘 IO；写盘后同步更新缓存。
_store_cache: dict[str, tuple[tuple[int, int] | None, dict]] = {}
# 老 report_config.json → store 的一次性迁移按（路径）记账：写失败不阻断读取，
# 也不在热路径反复重试。
_migrated_paths: set[str] = set()
# 读-改-写串行化：并发 PUT（/api/admin/config/models 与 /api/reports/config 共享同一 store）
# 不丢更新。
_write_lock = threading.Lock()


def _parse_file(path) -> dict:
    """读 JSON 配置：缺失/坏 JSON/顶层非对象一律当空（与老 report_config 同口径）。"""
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    return data if isinstance(data, dict) else {}


def read_model_config() -> dict:
    """读 model_config.json（仅合法模型名生效）；store 缺失时一次性迁移老 report_config.json 的三模型。

    迁移落盘一次后，老文件保留作历史、不再参与解析（避免两份配置分叉）。
    """
    p = config.MODEL_CONFIG_PATH
    try:
        st = p.stat()
        key: tuple[int, int] | None = (int(st.st_mtime_ns), st.st_size)
    except OSError:
        key = None
    ckey = str(p)
    if ckey in _store_cache and _store_cache[ckey][0] == key:
        return _store_cache[ckey][1]
    valid = set(config.available_models())
    if key is not None:
        data = _parse_file(p)
        out = {k: v for k, v in data.items() if k in _SLOT_KEYS and isinstance(v, str) and v in valid}
        _store_cache[ckey] = (key, out)
        return out

    # 一次性迁移：老 report_config.json → 新 store 的 report_* 槽位
    out: dict = {}
    if ckey not in _migrated_paths:
        _migrated_paths.add(ckey)
        legacy = _parse_file(config.REPORT_CONFIG_PATH)
        migrated = {}
        for old, new in (("model_gen", "report_gen"), ("model_ver", "report_ver"), ("model_sum", "report_sum")):
            v = legacy.get(old)
            if isinstance(v, str) and v and v in valid:
                migrated[new] = v
        if migrated:
            try:
                write_model_config(migrated)
                out = migrated
            except OSError:
                pass  # 迁移落盘失败不阻断读取（本次仍按迁移值生效，下次再试）
    _store_cache[ckey] = (key, out)
    return out


def write_model_config(overrides: dict) -> dict:
    """把 {槽位: 模型名} 写进 store：空串=清除覆盖（回落环境变量/默认）；未知槽位/非法
    模型名忽略（第二道防线：防止占位名/已下线模型经 API 落盘，重演老 report_config
    被写 x/y/z 挂起 ~290s 的坑）。返回最终落盘的覆盖映射。"""
    valid = set(config.available_models())
    with _write_lock:
        # 直接读盘（不经 read_model_config：store 缺失时 read 会触发迁移→write→read 递归）
        raw = _parse_file(config.MODEL_CONFIG_PATH)
        current = {k: v for k, v in raw.items() if k in _SLOT_KEYS and isinstance(v, str) and v in valid}
        for k, v in (overrides or {}).items():
            if k not in _SLOT_KEYS:
                continue
            v = (v or "").strip()
            if not v:
                current.pop(k, None)
            elif v in valid:
                current[k] = v
            # 非法模型名：静默忽略（与老 report_config 写侧口径一致）
        out = {k: current[k] for k in _SLOT_KEYS if k in current}
        p = config.MODEL_CONFIG_PATH
        if not out and not p.exists():
            # 无事可写且 store 从未存在：不落盘——保证老 report_config 的一次性迁移
            # 不被「空 PUT」抢先创建空文件阻断
            _store_cache.pop(str(p), None)
            return {}
        tmp = p.with_name(p.name + ".tmp")
        try:
            p.parent.mkdir(parents=True, exist_ok=True)
            if p.exists() and p.stat().st_size:
                try:
                    p.replace(p.with_name(p.name + ".bak"))  # 覆盖前留一份备份（误存可人工恢复）
                except OSError:
                    pass  # 备份失败不阻断写盘
            tmp.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8", newline="\n")
            os.replace(tmp, p)  # 原子改名：并发/中断不产生半截 JSON
        finally:
            if tmp.exists():
                try:
                    tmp.unlink()
                except OSError:
                    pass
        try:
            st = p.stat()
            _store_cache[str(p)] = ((int(st.st_mtime_ns), st.st_size), out)
        except OSError:
            _store_cache.pop(str(p), None)
        return out


def _resolve(key: str, ignore_store: bool = False) -> tuple[str, str]:
    """按优先级解析槽位 → (模型名, 来源)。来源：模型管理/环境变量/任务默认/系统默认。
    ignore_store=True 跳过 store（effective_models 计算「清除覆盖后自动回落档」用）。"""
    if not ignore_store:
        m = read_model_config().get(key)
        if m:
            return m, "模型管理"
    env = _SLOT_ENV.get(key)
    if env:
        v = os.environ.get(env, "").strip()
        if v:
            return v, "环境变量"
    d = _special_default(key)
    if d:
        return d, "任务默认"
    return config.default_model(), "系统默认"


def effective_models() -> list[dict]:
    """「模型管理」页数据：每个槽位的生效模型 + 来源 + 覆盖值（无覆盖为 None）+ 清除覆盖后的自动档。"""
    store = read_model_config()
    out = []
    for slot in MODEL_SLOTS:
        key = slot["key"]
        model, source = _resolve(key)
        out.append({
            "key": key,
            "label": slot["label"],
            "desc": slot["desc"],
            "model": model,
            "source": source,
            "override": store.get(key),  # None = 未在模型管理覆盖
            "auto_model": _resolve(key, ignore_store=True)[0],  # 覆盖被清除后自动回落到此模型
        })
    return out

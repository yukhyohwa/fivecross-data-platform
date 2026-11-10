# 权限点「使用」与资产机密等级（L1/L2/L3）——设计文档

> 状态：**已定稿 + 已实施**（2026-10-29）
> 日期：2026-10-29

## 1. 需求原文理解

1. 新增 4 个「使用」权限点：**SQL查询使用 / 知识库查询 / 专项使用 / 算法使用**，只有勾选了才能用。
2. **SQL / 知识库 / 专项** 三类资产增加 **L1-绝密 / L2-机密 / L3-秘密** 三档；这个档位「融合」到上面的使用权限点里。**算法不分档**。
3. 如果 **L2-机密 的专项** 绑定了 **L1-绝密 的 SQL / 知识库**，不要设限、不要阻止执行——**一切以专项的机密等级为准**。

## 2. 现状梳理（决定实现方式）

- 权限点 = 纯字符串集合，存 `identities.permission_points`（身份，JSON 数组）+ `users.extra_permissions`（用户级补充，JSON 数组）。`effective_permissions(user) = 身份点 ∪ 用户补充点`。
- 游戏授权 = `identities.games`（`["*"]`=全游戏）与 `users.extra_games`，独立于权限点。
- **聊天窗口（自由对话）目前没有权限点闸门**：`POST /chat` 只挂 `get_current_user + get_game`（登录 + 游戏授权）。所以现在任何登录用户都能在聊天里使用 SQL/知识库/专项/算法。这 4 个新点是**新增的运行时使用限制层**，与只管「新增/修改/删除」的 `analysis_edit`/`analysis_delete` 是两回事。
- 资产元数据（`meta.json`）：
  - SQL：`analysis/sql_store.py` 的 `read_sql_meta/write_sql_meta`，已有 `level/game/owner/fields`。
  - 知识库：`analysis/knowledge_store.py` 的 `read_doc_meta/write_doc_meta`，已有 `level/game/owner`。
  - 专项：`analysis/knowledge_store.py` 的 `read_skill_meta/write_skill_meta`，已有 `level/game/owner/online`（`online` 为上次上/下线功能新增）。
  - 算法：`backend/services/forecast.py`（code/ 外部能力 + 内置能力），无 `level/game/owner` 体系（个人模型有 owner 隔离，见 `visible_capabilities`）。

## 3. 设计方案（推荐）

### 3.1 新增权限点

`backend/ide_app/services/permissions.py` 的 `ALL_PERMISSION_POINTS` 增加 4 个：

| key | 中文名 | 说明 |
| --- | --- | --- |
| `sql_use` | SQL查询使用 | 能否在运行时使用 SQL（自由对话点名/命中、专项执行里的 SQL 步骤） |
| `kb_use` | 知识库查询 | 能否在运行时使用知识库文档（作为分析上下文） |
| `skill_use` | 专项使用 | 能否在运行时使用/执行专项 |
| `model_use` | 算法使用 | 能否在运行时使用算法（预测/建模） |

### 3.2 机密等级

- 新增常量 `CONFIDENTIALITY_LEVELS = ["L1", "L2", "L3"]`，敏感度 `L1(绝密) > L2(机密) > L3(秘密)`，rank 记 `L1=3, L2=2, L3=1`。
- 资产元数据加字段 `confidentiality`：取值 `"L1" | "L2" | "L3" | 缺省/空`。**缺省 = 未分级 = 不设限**。
- 算法不设此字段。

### 3.3 档位如何「融合」进权限点

每个身份除了勾选 `sql_use/kb_use/skill_use/model_use`，还为 SQL/知识库/专项 三个「分级」点各存一个**可多选的档位集合（授予集）**：

- `identities` 表新增 JSON 列 `access_levels`，形如 `{"sql":["L1","L2"],"kb":["L3"],"skill":["L2","L3"]}`。缺省（空 / 未设置）= **只授 `L3`**。
- `users` 表新增 JSON 列 `extra_access_levels`，用户级补充（与 `extra_permissions` 同套路），与身份集合**取并集**。

语义：**勾选了使用点 = 能用；档位 = 能用哪些档的资产（集合命中即放行）。** 勾选但没设档 → 默认 `["L3"]`（只能取用最低档，需手动往上勾）。`effective_access_levels(user, typ)` 返回 `set`；资产档位 `confidentiality` 命中该集合即放行。

### 3.4 生效判定（伪代码）

```python
CONFIDENTIALITY_LEVELS = ["L1", "L2", "L3"]  # L1 绝密 > L2 机密 > L3 秘密

def effective_access_levels(user, typ):  # typ ∈ sql/kb/skill → set
    if user is None or user["id"] == "anonymous":   # 匿名回落 → 全档
        return set(CONFIDENTIALITY_LEVELS)
    if has_perm(user, "system"):                    # 管理员 → 全档
        return set(CONFIDENTIALITY_LEVELS)
    levels = set(身份 access_levels.get(typ, []) | 用户 extra_access_levels.get(typ, []))
    return {lv for lv in levels if lv in CONFIDENTIALITY_LEVELS} or {"L3"}

def can_use_asset(user, typ, asset_confidentiality):
    if typ == "model":                               # 算法不分档：只查使用点
        return has_perm(user, "model_use")
    if typ not in ("sql", "kb", "skill"):
        return False
    if not has_perm(user, f"{typ}_use"):             # 1) 使用点
        return False
    if not asset_confidentiality:                    # 2) 未分级资产不查档
        return True
    return asset_confidentiality in effective_access_levels(user, typ)  # 3) 集合命中
```

`model_use` 无档位：只查 `has_perm(user, "model_use")`。

### 3.5 「一切以专项等级为准」规则

专项执行（选中专项 → 跑它的 SQL/知识库/算法）时：

1. 只校验 `skill_use` + **专项自身** `confidentiality`。
2. 该专项绑定的 SQL/知识库/算法在**作为专项的一部分执行时，跳过它们自己的档位校验**（不拦、不报错）。
3. 边界：用户**直接点名**那条 SQL / 文档（不是通过专项）时，仍按 SQL/文档 自己的档校验。即「跳过」只发生在「作为专项组成部分被执行」这条链路上。

### 3.6 执行点（后端强制，不依赖前端）

| 位置 | 校验 |
| --- | --- |
| `meta.py /api/knowledge` | docs 按 `kb_use`+档过滤；skills 按 `skill_use`+档过滤（叠加现有 online 过滤） |
| `chat.py` 专项匹配/校验/执行 | `skill_use`+档；专项执行时绑定 SQL/文档跳过档位校验 |
| `chat.py` SQL/文档直接命中执行 | `sql_use`+档 / `kb_use`+档 |
| `chat.py` 预测/算法执行 | `model_use` |
| `agent_tools.list_special_skills` / `search_knowledge(kind=sql/docs/model)` | 对应 `_use`+档过滤 |
| `agent_deep` 深度分析资产命中 | 同上 |
| `forecast` 模型执行 | `model_use` |

> 匿名回落用户（未登录）沿用现有「全量权限」语义，不受新点限制（与现状一致）。

### 3.7 前端改动

1. **权限管理 `PermissionPage.tsx` / `UserManagementPage.tsx`（身份/用户编辑弹窗）**：现有权限点复选框下方/旁边，新增 4 个使用点；对 SQL/知识库/专项 三个点，各配一组**多选复选框 L1/L2/L3（默认只勾 L3）**。算法使用点无档位。
2. **资产管理**（拍板点 5 已定：本次一并做）：
   - 专项管理 / SQL管理 / 知识库管理：新建/编辑时增加「机密等级」选择（未分级 / L1 / L2 / L3）。算法管理不加。
   - 列表侧栏显示档位徽标（红=绝密 / 橙=机密 / 蓝=秘密），与上次上/下线徽标同套路。

## 4. 向后兼容 / 迁移

- **资产**：历史 SQL/知识库/专项 无 `confidentiality` → 按「未分级=不设限」处理，无需迁移，不会突然锁死。
- **身份**：`seed_identities` 逻辑已改为「只缺则插入、不覆盖」。上线后 4 个新使用点**既有身份默认全不勾**（见第 5 节结论 2），由用户在权限管理页逐个开通；`access_levels` 空 = 只授 L3。

## 5. 拍板结论（2026-10-29，已定稿）

1. **档位默认**：默认 **L3**；L1/L2/L3 为**多选去勾**（授予集合），勾选即纳入可用档，未勾则不可用。默认只授 L3，需手动往上勾。
2. **既有 15 个身份迁移**：**先全不勾** 4 个新使用点（上线即默认用不了），由用户在权限管理页逐个开通，不动既有身份已配的点。
3. **执行范围**：**聊天 / 深度分析 / 专项执行** 的运行时使用纳入新点；订阅报告与看板暂不纳入。
4. **未分级资产**：历史资产未标档 → **不设限**（有任何对应使用点即可用）。
5. **档位标注 UI**：**本次一并做**——SQL/知识库/专项 管理页加「机密等级」选择框 + 列表档位徽标。

## 6. 实现规模预估

- 后端：`permissions.py`（点 + 档位解析 + 判定 helper）、`db_service.py`（`access_levels`/`extra_access_levels` 列 + 读写）、`permissions_api.py`（保存档位）、`meta.py` / `chat.py` / `agent_tools.py` / `agent_deep.py` / `forecast.py`（执行点校验）、`sql_store.py` / `knowledge_store.py`（`confidentiality` 字段读写）、`seed_identities` 迁移补发。
- 前端：`PermissionPage.tsx`（4 点 + 档位下拉）、`api.ts`（类型/端点）、三处资产管理页档位选择与徽标（若拍板点 5 选是）。
- 测试：新增权限点/档位判定、专项执行跳过绑定档位、`/api/knowledge` 过滤、迁移补发等回归用例。

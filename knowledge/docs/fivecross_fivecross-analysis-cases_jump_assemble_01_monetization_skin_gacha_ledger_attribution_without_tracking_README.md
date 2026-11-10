# JUMP Assemble：无专用埋点时的皮肤 Gacha 流水归因

## 这个 case 要解决什么

皮肤 Gacha 没有可直接使用的 `skin_gacha` / `active_gacha` 参与埋点。只有资源流水时，仍可用 `resource_change` 重建一条可复核的行为链路：

```text
皮肤 Gacha 币产出（id=64, nums>0）
    ← 同用户、同秒的付费跃之星扣减（id=3, nums<0）
    ← 兑换皮肤 Gacha 币

皮肤 Gacha 币消耗（id=64, nums<0）
    ← 参与皮肤 Gacha
```

本 case 的重点不是把资源变化简单相加，而是在**缺少活动行为埋点**的条件下，按“用户 + 时间戳”把资源流水还原为可解释的活动参与、兑换和消耗。

## 适用前提

- 已知皮肤 Gacha 币的资源 ID：本 case 为 `64`。
- 已知付费跃之星的资源 ID：本 case 为 `3`。
- `resource_change` 含有用户 ID、事件时间、资源 ID 与变动量 `nums`。
- 可用另一个已验证的同期活动确定观察窗口；本次使用波风凑限时刊物（`gacha_id=104`）窗口 `2026-08-12` 至 `2026-09-09`。

“同期活动”只用于限定时间范围，**不代表皮肤 Gacha 与该卡池存在因果关系**。

## 核心口径

| 指标 | 定义 | 去重粒度 |
|---|---|---|
| 皮肤 Gacha 币消耗总数 | `id=64 AND nums<0` 的 `-nums` 之和 | 流水量 |
| 皮肤 Gacha 参与人数 | 至少一次 `id=64 AND nums<0` 的用户 | 全周期 `DISTINCT lcx_id` |
| 皮肤 Gacha 币产出总数 | `id=64 AND nums>0` 的 `nums` 之和 | 流水量 |
| 关联付费跃之星消耗 | 与 `id=64` 流水同用户、同秒的 `id=3 AND nums<0` 之和 | 操作键 |
| 付费跃之星兑换皮肤币人数 | 同一操作键内同时出现 `id=64, nums>0` 与 `id=3, nums<0` 的用户 | 全周期 `DISTINCT lcx_id` |

操作键：`(lcx_id, DATE_TRUNC('second', #event_time))`。

先在操作键上聚合 `id=64` 和 `id=3`，再关联。不能直接逐行 join，否则同一秒存在多条资源流水时会产生笛卡尔放大。

## 实施步骤

### 1. 统一账号 ID 并排除异常账号

优先使用：

```sql
COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") AS lcx_id
```

排除 `user_result_cluster_23` 中 `internal_users`、`is_water`。如项目另有福利号、测试号或异常 IP 规则，应额外保留标记或排除后复核。

### 2. 将资源流水压到操作粒度

```sql
SELECT
    lcx_id,
    DATE_TRUNC('second', CAST("#event_time" AS timestamp(3))) AS event_time_sec,
    SUM(CASE WHEN id = 64 AND nums < 0 THEN -nums ELSE 0 END) AS skin_coin_used,
    SUM(CASE WHEN id = 64 AND nums > 0 THEN  nums ELSE 0 END) AS skin_coin_produced,
    SUM(CASE WHEN id = 3  AND nums < 0 THEN -nums ELSE 0 END) AS paid_star_used
FROM ta.v_event_23
WHERE "$part_event" = 'resource_change'
  AND "$part_date" BETWEEN DATE '2026-08-12' AND DATE '2026-09-09'
  AND id IN (3, 64)
GROUP BY 1, 2;
```

### 3. 从流水还原参与与兑换

- `skin_coin_used > 0`：用户在该操作中消耗皮肤币，计为一次皮肤 Gacha 参与操作。
- `skin_coin_produced > 0 AND paid_star_used > 0`：用户在该操作中用付费跃之星兑换皮肤币。
- 一位用户可有多次操作；分日人数按当天去重，累计人数必须按整个活动窗口去重。

### 4. 同时输出分日和累计

分日表用于观察开活动首日峰值、衰减及补货节奏；累计行用于回答活动整体规模。累计行的用户人数**不能**将每日 `DISTINCT` 人数相加，应直接从用户级/操作级底表重新 `COUNT(DISTINCT lcx_id)`。

本次可执行 SQL 位于：

```text
jump_tw_weekly_report/sql/ad_hoc/skin_gacha_coin_64_minato.sql
```

## 必做校验

1. **流水符号确认**：抽样核对 `id=64` 的 `nums` 正负方向；不要凭资源名称假设正负含义。
2. **时间粒度敏感性**：先看完整时间戳是否可稳定关联；如上游将同一业务操作分散到相邻秒，比较“精确时间戳 / 秒级 / ±1 秒”三种口径，并明确采用的规则。
3. **同秒串单风险**：同一用户同一秒若还有其他付费跃之星消费，`id=3` 可能被误归因。抽样查看同秒的 `reason`、`source`、`gu_type` 等字段（若存在）。
4. **产消平衡检查**：活动内 `id=64` 产出、消耗和期末余额变化不必完全相等，但差额应能被期初库存、未消耗库存或未覆盖来源解释。
5. **参与定义校验**：仅有 `id=64` 产出而没有消耗的用户属于兑换/持币用户，不应计入“已参与皮肤 Gacha”。
6. **累计去重检查**：累计参与人数、累计兑换人数应小于等于每日人数之和；若相等，需确认是否真的没有跨日复访。

## 能回答与不能回答的问题

| 可以回答 | 不能仅靠流水回答 |
|---|---|
| 有多少皮肤币被产出、消耗 | 用户抽到了哪个皮肤或抽奖结果 |
| 有多少用户实际消耗皮肤币参与 | 每次抽奖次数、保底进度 |
| 有多少用户用付费跃之星兑换皮肤币 | 付费跃之星是否由本次活动新增购买而来 |
| 每日参与/兑换峰值与衰减 | 皮肤 Gacha 对收入或留存的因果增量 |

因此，该方法应称为“**流水归因下的活动参与估计**”，不是对缺失埋点的完全替代。若活动成为长期运营模块，应补充明确的 Gacha 行为事件（抽奖次数、消耗资源、产出物、皮肤 ID、保底状态）和稳定的操作/交易 ID。

## 复用清单

替换下列配置即可复用于其他无埋点活动：

```text
活动窗口        -> 已验证的开始、结束日期
活动币 ID       -> 目标活动的 resource id
付费货币 ID     -> 用于兑换的付费货币 resource id
操作关联键      -> 用户 ID + 精确时间戳/秒级时间戳/交易 ID
黑名单规则      -> 当前项目的内部、测试、水量与福利账号定义
```

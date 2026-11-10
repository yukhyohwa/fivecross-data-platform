# SQL 说明

## 01：阿里云 4 月新增 cohort

文件：[sql/01_odps_april_new_user_rank.sql](sql/01_odps_april_new_user_rank.sql)

### `cohort_accounts`

从 `dm_platform.daily_lcx_user_info` 识别 4 月 23~26 日注册的全球版非水号账户。`day` 条件不仅限定观察窗口，也是 MaxCompute 必需的分区裁剪条件。

### `server_user_info`

这部分等价于已停更 `g63002013_dev.dm_server_user_info` 的必要计算：

1. 从 `daily_user_snapshot` 读取角色日快照。
2. 用 `last_login` 判断该角色当天确实登录。
3. 连接当日 `daily_vip`；VIP 不参与本指标，但保留历史构表上下文。
4. 连接 `dim_rankname` 得到段位名称。

### `latest_role_snapshot`

对每个 `lcm_id + role_id` 按 `snapshot_day` 倒序取第 1 条。这里没有要求快照日期等于 5 月 26 日。

### 最终聚合

把最新角色快照与新增账户 inner join，按 `rank_name` 统计去重角色数。

## 02：数数 6 月新增 cohort

文件：[sql/02_ta_june_new_user_rank.sql](sql/02_ta_june_new_user_rank.sql)

### `cohort_accounts`

从 `NUU` 事件识别 6 月 4~7 日新增账户。

### `latest_role_snapshot`

在 6 月 4 日至 7 月 7 日的全部 `snapshot$` 事件中，先排除无 `match_rank` 的事件，再按账户和角色取最后一条。必须把 `mbga_uid` 放进窗口分组键，避免不同账户可能重复的 `user_id` 互相覆盖。

### `cohort_ranked_roles`

按照 GL 固定阈值将 `match_rank` 映射为中文段位，并与新增账户关联。

### 最终聚合

按段位统计 `account_id + role_id` 去重数。

## 常见错误

### 错误 1：只取观察日当天活跃

这会把问题改成“D30 当天活跃留存用户的段位”，分母明显变小。

### 错误 2：直接读取停更中间表

`g63002013_dev.dm_server_user_info` 已停更，会出现分区为空或结果陈旧。本 case 必须现场还原。

### 错误 3：把空 `match_rank` 归入最高段位

`CASE ... ELSE '灌篮高手'` 会把空值也落入 `ELSE`。数数 SQL 必须在窗口排序前过滤空段位。

### 错误 4：只按 `user_id` 取最新快照

角色 ID 不能假设跨账户全局唯一。正确窗口键是 `mbga_uid + user_id`。

### 错误 5：沿用繁中区服过滤

GL 不使用繁中项目的 `lcm_id` 长度和区服前缀限制。

### 错误 6：把角色数解释为新增账户数

一个账户可以对应多个角色，最终 `role_count` 不能直接当作账户数。

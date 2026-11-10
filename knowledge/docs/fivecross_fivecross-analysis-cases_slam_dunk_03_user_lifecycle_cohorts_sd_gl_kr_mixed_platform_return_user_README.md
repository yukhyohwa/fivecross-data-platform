# 灌篮北美：未充值且一年以上未登录用户

目标：找出灌篮全球版（`app_id = 63002013`）中北美区服（`zone` 首位为 `4`）满足以下条件的角色：

- 历史从未充值；
- 截至 `2026-07-21`，最后登录日不晚于 `2025-07-21`（含当天）；
- 结果粒度为 `account_id + zone_id + role_id`。
- 增加 2026-05-26 最终社团状态：`has_guild` 与 `guild_id`。

## 数据覆盖与合并方式

| 来源 | 覆盖日期 | 用途 |
|---|---|---|
| 阿里云 MaxCompute | 2021-12-08 ～ 2026-05-27 | 北美历史角色、历史最后登录、历史充值 |
| 数数 ThinkingData | 2026-05-01 ～ 2026-07-21 | 补齐 5 月重叠期及 6～7 月登录/充值 |

用户描述中的数数结束日 `2025-07-21` 按上下文视为 `2026-07-21`。两侧数据先分别聚合，再按角色键合并：

- `last_login_day = MAX(账号下所有角色及两侧 last_login_day)`；
- `account_has_recharge = MAX(两侧及账号下所有角色 has_recharge)`；
- 最后才应用一年未登录与未充值筛选。

充值采用账号级口径，因为阿里云 `dm_platform.daily_lcx_user_info.purchase` 是账号粒度。同一账号任一角色/区服有充值，该账号下北美角色均不进入结果。

数数的 `LOGIN_SUCCESS/NUU` 没有携带角色和区服，因此数数补充登录同样按账号级应用：账号在数数侧有新登录时，其北美角色均视为最近登录并排除。

社团状态来自 `g63002013.daily_user_snapshot.guild_id`。优先使用 2026-05-26 快照；角色当天不存在时，使用截至 5 月 26 日最后一次可见状态，并在 `guild_status_day` 保留实际日期。`daily_user_guild_snapshot` 是公会主表，`member` 字段为空，不能用于用户归属。`guild_id` 为空、`0` 或 `-1` 判定为无社团，其余判定为有社团。

## 文件

- `sys_sd_gl_na_odps_user_status.sql`：阿里云查询。
- `sys_sd_gl_na_ta_user_status.sql`：数数查询。
- `sys_run_sd_gl_na_mixed_platform_return_user.py`：运行两份查询并合并，也支持合并手工导出的 CSV。
- `reports/`：最终名单及审计统计。
- `temp_queries/`：自动调用数据客户端时生成的任务 JSON。

## 运行

自动查询两侧并合并：

```powershell
cd C:\Users\5xgames\Desktop\github\fivecross-sql-lib\common\sd_gl_kr_mixed_platform_return_user
python .\sys_run_sd_gl_na_mixed_platform_return_user.py
```

已经手工导出两份 CSV 时：

```powershell
python .\sys_run_sd_gl_na_mixed_platform_return_user.py `
  --skip-fetch `
  --odps-csv <odps.csv> `
  --ta-csv <ta.csv>
```

最终会生成：

- `SD_GL_NA_Unpaid_Inactive_1Y_*.csv`：符合条件的角色名单；
- `SD_GL_NA_Unpaid_Inactive_1Y_Audit_*.csv`：输入行数、跨源重叠、排除原因和最终人数。

## 输出字段

| 字段 | 含义 |
|---|---|
| `account_id` | 跨平台合并账号（阿里云 `mbga_uid` / 数数 `#account_id`） |
| `role_id` | 角色 ID（数数从 `a_usr` 解析） |
| `zone_id` | 区服 ID，最终仅保留首位为 `4` |
| `first_seen_day` | 两侧可见范围内最早出现日 |
| `last_login_day` | 两侧最大登录日 |
| `days_since_last_login` | 截至 2026-07-21 的未登录天数 |
| `has_guild` | 2026-05-26 是否有社团：1=有，0=无 |
| `guild_id` | 2026-05-26 社团 ID；无社团为空 |
| `guild_status_day` | 社团状态实际快照日，不晚于 20260526 |
| `guild_status_is_current_20260526` | 1=来自 2026-05-26 当天；0=来自此前最后可见状态 |
| `source_coverage` | 该角色在哪些数据源出现 |
| `observed_through` | 合并后的数据观察截止日 |

## 东南亚版本

东南亚同属灌篮全球版，区服首位为 `1`，开服日为 2020-11-25。登录、充值、数数补充及社团状态口径与北美一致。

- `sys_sd_gl_sea_odps_user_status.sql`：东南亚阿里云查询。
- `sys_run_sd_gl_sea_mixed_platform_return_user.py`：东南亚运行与合并脚本。

```powershell
python .\sys_run_sd_gl_sea_mixed_platform_return_user.py
```

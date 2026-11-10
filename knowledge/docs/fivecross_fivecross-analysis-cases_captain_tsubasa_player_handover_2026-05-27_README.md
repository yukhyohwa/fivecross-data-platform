# 足球小子海外（Captain Tsubasa）玩家交接数据

## 目标和数据切分

本项目产出供研发公司交接使用的玩家资料及累计充值：

| 时段 | 来源 | 产出 |
| --- | --- | --- |
| `<= 2026-05-27` | 阿里云 / MaxCompute | 文件 A：可联系的历史玩家资料、截至切点的最后登录日和充值 |
| `>= 2026-05-28` | 数数 / Trino，共享项目 `event_19` | 文件 B：`lcm_id` 的切点后最后活跃日和充值 |

数数没有 `did`、`dena_id`、邮箱、手机或角色信息，因此**不能把数数账号直接作为交付用户资料**。最终主文件只以文件 A 为主体，按 `lcm_id` 将文件 B 的最后活跃日和充值补回；B 中无法匹配 A 的账号单独导出给平台部门做邮箱/手机号匹配。

> SQL 中的日期是本次需求给出的 2026 年 5 月切点。如实际下架批次不是 2026 年，请统一替换两个 SQL 顶部 `Params` CTE 的日期；切点前后不可重叠。

## 运行顺序

1. 在 MaxCompute 运行 [`sql/01_aliyun_file_a.sql`](sql/01_aliyun_file_a.sql)，导出 UTF-8 CSV 为 `file_a_aliyun.csv`。
2. 在数数 Trino 运行 [`sql/02_thinkingdata_file_b.sql`](sql/02_thinkingdata_file_b.sql)，导出 UTF-8 CSV 为 `file_b_thinkingdata.csv`。
3. 将两个 CSV 放在同一目录，执行：

```powershell
python .\merge_exports.py .\file_a_aliyun.csv .\file_b_thinkingdata.csv --output-dir .\output
```

脚本会生成：

| 文件 | 用途 |
| --- | --- |
| `player_handover_final.csv` | 交给研发公司的最终玩家信息表；仅包含文件 A 中有邮箱或手机号的玩家 |
| `thinkingdata_unmatched_lcm_ids.csv` | 文件 B 有、文件 A 无法按 `lcm_id` 匹配的数数名单，交平台部门补充用户映射 |
| `merge_summary.json` | 行数、匹配数和金额汇总，供验数 |

## 字段和合并规则

文件 A 一行一个 `lcm_id`，保留以下历史身份/角色字段：

`did`, `dena_id`, `lcm_id`, `encrypt_email`, `encrypt_phone`, `role_id`, `role_name`, `zone_id`, `level`, `vip`, `lastlogin_day`。

两个文件均额外输出：

- `last_active_day`：A 为 2026-05-27 的角色快照 `lastlogin_day`；B 为切点后登录/新建事件的最大日期。
- `recharge_rmb`：阿里云和数数各自归因的实付充值，统一换算成人民币后汇总。

合并时：

- 仅以 `lcm_id` 精确匹配，不会用邮箱、手机号、did 或 dena_id 猜测匹配。
- 匹配成功：`last_active_day = max(A, B)`；`recharge_rmb = A + B`。
- B 中仅有充值、没有登录事件的账号仍会保留并可更新 A 的充值；其 B 的最后活跃日为空。
- B 中无 A 的账号进入 `thinkingdata_unmatched_lcm_ids.csv`，不会混入最终交付表。
- A 中无 B 的账号保留 A 的最后登录日和充值。

## 关键口径与执行前检查

- 数数在共享表 `ta.v_event_19` 内，SQL 必须用 `65002005` 识别足球小子，避免混入新三国 (`65002004`) 与圣斗士等项目。
- 数数活跃目前采用 `LOGIN_SUCCESS`、`NUU`；若业务确认有其它可靠登录事件，可只在 `ActivityEvents` CTE 增加事件名，勿改为整个事件表以免把埋点/支付误当登录。
- 充值覆盖商店购买 `PURCHASE` 和 LCM 钱包直充 `WALLET_DIRECT_CHARGE_PURCHASE`，并剔除 `SANDBOX_RECEIPT` 与商店侧的 `LCX_WALLET`，防止沙盒和钱包渠道重复。
- 汇率缺失时 SQL 暂按原币 `1:1` 处理，并输出前应检查该类记录；如需要严格财务口径，应先补齐汇率再交付。
- 首次正式交付前，建议抽查 10 个同时出现在 A/B 的 `lcm_id`，核对数数 `#account_id` 确为同一 LCM ID，并检查 B 的金额没有与 A 重叠日期。

## 数据安全

最终文件含加密邮箱、加密手机号和账号标识，只应放到受控交接位置，不应提交到 Git 或通过普通群聊传输。

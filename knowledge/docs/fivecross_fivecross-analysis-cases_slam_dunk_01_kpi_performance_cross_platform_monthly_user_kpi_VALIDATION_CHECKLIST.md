# 校验清单

- [ ] 阿里云查询的 `day` 分区覆盖回流判定所需的 90 天回看窗口。
- [ ] 新增、回流、老用户在同一游戏和自然月内互斥。
- [ ] 数数只输出新增与老用户，不把历史缺失误判为回流。
- [ ] 数数购买收入排除 `SANDBOX_RECEIPT`，且汇率表按事件日连接。
- [ ] 每个 Dn 的 `eligible_dN_users` 不小于 `retained_dN_users`。
- [ ] 对每个游戏、月份、用户类型，`arpu_rmb = revenue_rmb / user_count`。
- [ ] 同一数据版本下，阿里云 4 月 D30 分母小于或等于总 cohort；数数 6 月 D27/D30 分母小于或等于总 cohort。
- [ ] 导出后确认 `data_source`、`game`、`app_id`、`month`、`user_type` 均存在且无意外重复行。

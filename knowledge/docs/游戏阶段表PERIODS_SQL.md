> 来源：JoyTools 88 Agent（services/kpi/periods.py）

# 游戏阶段表（PERIODS_SQL）与日期夹取

## 适用游戏
rooc 等 RO 产品线（阶段信息从 public_analyst.dim_gameperiod_info 按游戏代码取）。

## 取数
SELECT game_code, node AS game_period, start_date, end_date, svr_timezone
FROM public_analyst.dim_gameperiod_info ORDER BY game_code, start_date

## 阶段切换口径
- 默认阶段规则：有 obt 时优先 obt（"obt" in options 否则 options[-1]）；chat_bi 已实现 obt 优先，本知识只补阶段切换。
- effective_period_end：end_date 为空或超过今天时夹到今天。
- 阶段切换日归属以 start_date 为准（切换日算新阶段第一天）。

## 日期夹取 caveats
- T+1：今天的分区还在装载，查询默认到昨天（"观察期未走完的格留空，不是 0% 留存"）。
- 落在今天的留存/LTV 会读成近乎全量流失——结束日期包含今天时各项指标都偏低。

## 注意事项
- svr_timezone 空值返回 ""（做时区换算前必须判空）；按库过滤 tz、无 tz 字段的表用 dteventtime + 各服 svr_timezone 转时区。

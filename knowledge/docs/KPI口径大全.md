> 来源：JoyTools 88 Agent（services/kpi/instructions.py、services/kpi/queries.py、services/kpi/dates.py、apps/26_KPI数据速览.py、docs/joytools-mcp.md）

# KPI 固定模板口径大全（LTV/留存/加权/时效）

## 适用游戏
RO 全产品线（rooc / ro_hmt / ro_sea / ro_lna / ro_zxf 等），KPI 固定模板按游戏代码取数。

## LTV 列表与 N 的 off-by-one
- ltv_n_list 从 1 开始、与结果列同号：N=1 是注册当日（当日留存恒 100%，不作为留存指标汇报）；次日留存是 N=2；7 日留存是 N=7。写 SQL 或复述结论时不要出现"次日留存 N=1"这类差一天的表述。
- N 列表的长度决定 SQL 实际计算的行数，取多少 N 直接关系结果大小。
- relative_n 只表示"阶段开始后的前 N 个粒度"，阶段粒度固定（天/周/月），没有日期跨度上限；唯一闸是行数 max_rows_per_section。

## 观察期留空规则
- unbound_ltv_end_date=true 把观察窗口延长到最大 N 对应的那天（不超过昨天）；超出范围的格留空 = 观察期未走完，不是 0% 留存。
- 数据 T+1：今天的分区还在装载，落在今天的留存/LTV 会读成近乎全量流失，所以查询默认到昨天。

## 加权汇总（include_summary）
- 汇总行的比率一律从分子分母重算：付费率 = Σ付费账号数/Σ活跃账号数；ARPPU = Σ收入/Σ付费账号数；ARPU = Σ收入/Σ活跃账号数；留存/LTV 按注册队列加权。
- 活跃账号数按日求和是人日，求均值只能叫日均活跃；"不把加权平均说成简单平均"，summary_note 逐列说明求和/加权/均值/峰值。
- 已付学费：sum(x)/mean(y) = K·sum(x)/sum(y)（K=期数），查 30 天时 ARPPU/ARPU 是真值的 30 倍、新账号-付费率是真值的 1/30。

## 币种与时效
- 固定模板金额为 USD：收入、ARPU/ARPPU/LTV 均为美元/账号；跨币种对比前先确认换算口径。
- 数据时效：T+1，每日 14:00 后可查截至昨日的完整数据。

## 注意事项
- KPI 数据不得用 export_query 复现（多段 SQL 经 pivot/merge/加权，没有对应的单条 SQL，自撰一条口径走样但结果长得一样，交出去就是看不出错的错数据）；要文件用 kpi_export。
- kpi_export 工作簿第一页恒为「参数与口径」：观察期留空这类前提必须跟着文件走，收到文件的人看不到对话。

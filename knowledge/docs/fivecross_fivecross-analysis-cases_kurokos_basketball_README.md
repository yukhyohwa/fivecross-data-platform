# 黑子的篮球分析案例

采用 `游戏 / 一级业务主题 / case` 的目录结构。一个 case 只保留一份，跨主题方法通过相对链接关联。

| 一级主题 | Case | 主要问题 |
| --- | --- | --- |
| `01_kpi_reports` 经营报表 | [weekly_comprehensive_requirements](01_kpi_reports/weekly_comprehensive_requirements/README.md) | 繁中周运营综合需求、LG 活动与分群付费 |
| `02_monetization_liveops` 商业化与活动 | [daily_payment_spike_20260825](02_monetization_liveops/daily_payment_spike_20260825/README.md) | 单日付费异常与商品贡献 |
| `02_monetization_liveops` 商业化与活动 | [tc_august_2026_spend_analysis](02_monetization_liveops/tc_august_2026_spend_analysis/README.md) | 繁中 2026 年 8 月付费及资源消费 |
| `03_player_cultivation_resources` 球员养成与资源 | [tc_lg_midorima_acquisition_cultivation_20260819_20260823](03_player_cultivation_resources/tc_lg_midorima_acquisition_cultivation_20260819_20260823/README.md) | LAST GAME 绿间首五日取得、天赋与觉醒；原 `new_card` |
| `03_player_cultivation_resources` 球员养成与资源 | [awaken_card_fragment_inventory_20260911](03_player_cultivation_resources/awaken_card_fragment_inventory_20260911/README.md) | JP／TC／KR 觉醒卡碎片库存与付费分层 |
| `04_data_audits` 数据核查 | [jp_suspicious_new_devices_20260910](04_data_audits/jp_suspicious_new_devices_20260910/README.md) | 日本服新增设备异常与刷号判断 |
| `04_data_audits` 数据核查 | [bp_purchase_refund_audit_20261001_20261101](04_data_audits/bp_purchase_refund_audit_20261001_20261101/README.md) | BP 购买、失败支付、充值与退款证据 |
| `04_data_audits` 数据核查 | [kuroko_uid_100621823_coin_audit_20261015](04_data_audits/kuroko_uid_100621823_coin_audit_20261015/README.md) | 繁中单玩家黑子币充值、消费与余额 |
| `04_data_audits` 数据核查 | [kr_uuid_blackcoin_flow_20261109](04_data_audits/kr_uuid_blackcoin_flow_20261109/README.md) | 韩服 UID 100687868 的 11 月 9 日黑子币流转 |

## 维护约定

- 按主要业务问题选择一级主题，主题下直接放 case，不继续增加业务分类层级。
- Case 内保存 SQL、执行／核查代码、README 和结果；README 写明数据源、身份粒度、时间边界、复跑方式、测试方案、关联关系与限制。
- 文件夹命名体现区域、对象、业务问题和固定日期；持续维护的报表可以使用稳定名称。
- 共享查询客户端位于仓库同级的 `fivecross-data-client`；共享口径位于 [SQL 库游戏规则](../../fivecross-sql-lib/games/kurokos_basketball/GAME_LOGIC_RULES.md)。不要复制凭据或登录 session。
- 本次分类保留全部历史交付物；历史来源回执中的路径表示当时的位置，当前执行路径以本索引为准。

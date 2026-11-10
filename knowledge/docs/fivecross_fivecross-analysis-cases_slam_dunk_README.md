# Slam Dunk 分析案例库

本目录按一级业务主题组织 Slam Dunk 分析案例，不在分类目录下继续拆分业务子类别。

## 分类索引

| 一级分类 | Case | 主题／主要问题 |
|---|---|---|
| `01_kpi_performance` | `au_user_revenue_decline_analysis` | AU 用户规模、收入及 ARPU 下滑诊断。 |
| `01_kpi_performance` | `revenue_decline_player_vs_spend_20261008` | 台湾服收入下滑：玩家流失、固定老玩家付费变化与殿堂三井对比；本次仅查询 TA。 |
| `01_kpi_performance` | `cross_platform_monthly_user_kpi` | 全球版／韩国版跨平台月度用户、收入及留存 KPI。 |
| `01_kpi_performance` | `kpi_target_completion` | KPI 目标维护、SQL 同步及报表更新。 |
| `02_monetization_liveops` | `hall_of_fame_card_activity_comparison` | 台湾服名人堂卡牌活动、资源消耗及收入对比。 |
| `02_monetization_liveops` | `kr_mystery_shop_item_gains_20260829_20260830` | 韩国服神秘商店指定道具获得与货币消耗。 |
| `03_user_lifecycle_cohorts` | `cross_platform_new_user_d30_rank_distribution` | 全球版新增用户约 D30 段位分布。 |
| `03_user_lifecycle_cohorts` | `sd_gl_kr_mixed_platform_return_user` | 跨平台长期未登录、未付费用户人群提取。 |
| `04_data_extraction_audits` | `item_flow` | 台湾、全球、韩国版本指定道具流水提取。 |
| `04_data_extraction_audits` | `sa_aliyun_user_recharge_history` | 南美用户阿里云时期历史充值明细核查。 |

## 分类边界

- `01_kpi_performance`：整体经营表现、收入趋势、KPI 监控与目标达成。
- `02_monetization_liveops`：卡牌活动、商店及其他商业化运营机制。
- `03_user_lifecycle_cohorts`：新增、回流、沉默用户及生命周期人群。
- `04_data_extraction_audits`：流水明细、单用户历史和专项数据核查。

新增 case 时，应放入最能代表其主要业务问题的一级分类，并在 case 内保留数据源、口径、复跑方法和已知限制。

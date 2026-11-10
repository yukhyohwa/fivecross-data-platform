# 蜡笔小新分析案例

按业务问题分为五个一级主题，结构为 `crayon_shinchan/<主题>/<case>/`。现有 15 个 case 保留各自的分析窗口和交付物。

| 一级主题 | 用途 | Case 数 |
| --- | --- | ---: |
| `01_kpi_reports` | CBT/OBT 综合 KPI、日报和阶段报告 | 2 |
| `02_monetization_liveops` | 付费商品、活动效果、消费与活动时间 | 5 |
| `03_user_lifecycle_progression` | 新用户生命周期、首日流失、主线进度 | 3 |
| `04_surveys_retention` | 问卷画像、行为关联与留存诊断 | 2 |
| `05_data_audits` | 客服、资源流水、补偿与埋点数据核查 | 3 |

## Case 索引

| 主题 | Case | 主要问题 |
| --- | --- | --- |
| KPI 报告 | [tc-cbt-report](01_kpi_reports/tc-cbt-report/README.md) | 繁体 CBT 与新加坡首周表现、留存和 LTV 对比 |
| KPI 报告 | [tc_obt_d1_daily_report_20261015](01_kpi_reports/tc_obt_d1_daily_report_20261015/README.md) | OBT 第3日报及历史底稿 |
| 商业化与活动 | [activity_comparison_review_20261030](02_monetization_liveops/activity_comparison_review_20261030/README.md) | 活动效果、消费去向和固定 cohort 复盘 |
| 商业化与活动 | [activity_event_timetable_20261030](02_monetization_liveops/activity_event_timetable_20261030/README.md) | 活动标识、实际领奖与关联消耗时间 |
| 商业化与活动 | [paid_product_purchase_stage_distribution_20260729_20260824](02_monetization_liveops/paid_product_purchase_stage_distribution_20260729_20260824/README.md) | 商品购买时的主线进度分布 |
| 商业化与活动 | [tc_obt_post_d1_monetization_20261023](02_monetization_liveops/tc_obt_post_d1_monetization_20261023/README.md) | 创角首日后商品购买和活动消费 |
| 商业化与活动 | [weekly_operations_review_20261102](02_monetization_liveops/weekly_operations_review_20261102/README.md) | 周运营复盘：收入与复购、流失分层、服务器运营及首付后第7日登录 |
| 生命周期与进度 | [first_day_tutorial_stage_dropout_20260729_20260824](03_user_lifecycle_progression/first_day_tutorial_stage_dropout_20260729_20260824/README.md) | 首日停留在入门路线的玩家及后续登录 |
| 生命周期与进度 | [new_user_lifecycle_diagnosis](03_user_lifecycle_progression/new_user_lifecycle_diagnosis/README.md) | 首周 KPI、首日留存与主线卡点 |
| 生命周期与进度 | [specific_event_stage_distribution_20260729_20260824](03_user_lifecycle_progression/specific_event_stage_distribution_20260729_20260824/README.md) | 首次获得坐骑等事件发生时的主线阶段 |
| 问卷与留存 | [tc-cbt-survey-analysis](04_surveys_retention/tc-cbt-survey-analysis/README.md) | CBT 问卷画像与留存、付费行为关联 |
| 问卷与留存 | [tc_obt_d3_churn_survey_diagnostic_20261020](04_surveys_retention/tc_obt_d3_churn_survey_diagnostic_20261020/README.md) | OBT D2 返回、D3 缺席的行为与问卷诊断 |
| 数据核查 | [tc_obt_customer_support_mainline_audit_20261017](05_data_audits/tc_obt_customer_support_mainline_audit_20261017/README.md) | 客服要求的主线/限时挑战玩家名单和付费核对 |
| 数据核查 | [tc_obt_mount_feed_audit](05_data_audits/tc_obt_mount_feed_audit/README.md) | 坐骑喂养资源扣除与升级事件匹配 |
| 数据核查 | [tc_obt_toy_reset_compensation_audit_20261018](05_data_audits/tc_obt_toy_reset_compensation_audit_20261018/README.md) | 玩具重置、实际扣款、退款与补偿核对 |

## 维护约定

- 先按主要业务问题选择一个主题，同一 case 只维护一份；跨主题依赖通过相对路径引用。
- 主题下直接放 case，case 内部继续保留自己的 `scripts/`、`sql/`、`data/`、`outputs/` 和说明文档。
- CBT/OBT、TC/SG、日期窗口和历史版本由 case 名与 README 说明，不再增加一层分类目录。
- 新增 case 要在本页登记，并写明数据源、身份、时区、分析窗口、指标分母与交付物。
- 玩家明细、原始问卷、登录 session 等按各 case 的 `.gitignore` 留在本地；移动目录后也要保持原有忽略范围。

本次分类调整同步修正了当前脚本、跨 case 引用及共享 data-client 的路径。历史查询回执、来源 manifest 和交付物保留原始内容；其中的旧绝对路径是当时的来源记录，当前运行路径以本索引和各 case 根目录为准。

埋点文档及项目规则由独立的 [shinchan-events-tracking](../../shinchan-events-tracking/README.md) 维护，通用验收由 [thinkingdata-events-validation](../../thinkingdata-events-validation/README.md) 执行。两者不在分析 case 内复制实现。

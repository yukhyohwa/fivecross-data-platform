# Jump Assemble 分析案例库

本目录汇集 Jump Assemble 的可复核分析案例，覆盖角色／卡池商业化、排位体验、活动参与、日常 KPI 与充值对账。每个 case 应尽量包含问题定义、可运行 SQL、处理脚本、原始查询结果及交付物；分析结论须区分观察性关联与因果结论。

## 使用约定

- **数据源与身份**：以各 case README 中明确的 ThinkingData / Trino 数据源、区域和账号 ID 口径为准；默认排除内部账号与水号。
- **时间与窗口**：日期窗口、时区、D1–D5 等定义必须随 case 固化，跨活动比较应使用相同的完整自然日窗口。
- **交付物**：`sql/` 为可复跑查询，`scripts/` 为处理或生成脚本，`outputs/`、`output/` 为交付结果或可复核快照。
- **大文件**：`node_modules/`、`90_archive/backups/` 及新生成的大体积 CSV/XLSX 不纳入 Git；需要共享时使用受控的数据存储或重新导出。

## Case 索引

目录只按一级业务主题分类，不在分类目录下继续拆分子类别。

| 一级分类 | Case | 主题／主要问题 |
|---|---|---|
| `01_monetization` | [`tc_veteran_cultivation_revenue_decline_20261109`](01_monetization/tc_veteran_cultivation_revenue_decline_20261109/README.md) | TC日常收入下降与角色养成：八题证据链、历史资源供给、充值与消费去向；保存最终66页报告及可复算代码和数据。 |
| `01_monetization` | `academy_mitsuri_first5d_20260824` | 学园活动与限时特供 A 角色的首五日商业化对比。 |
| `01_monetization` | `a_class_delivery_mechanisms_first5d_20260831` | 对比纯 Gacha、BP+Gacha 与学园活动的覆盖、消耗、付费背景与养成。 |
| `01_monetization` | `a_class_return_monetization_20260805` | 评估 item 62 自选复刻池的触达、消耗深度与资源获取经济性。 |
| `01_monetization` | `card_pool_monetization` | 新角色、复刻与限定池商业化分析的方法模板与校验清单。 |
| `01_monetization` | [`tc_firstweek_revenue_attribution_20260624`](01_monetization/tc_firstweek_revenue_attribution_20260624/README.md) | TC 开服首周（6/24–6/30）礼包收入与付费跃之星的英雄／漫画归类；保存流水归因、比例分摊、均分各版及可复跑原始数据和脚本。 |
| `01_monetization` | `s_class_byakuya_minato_monetization_20260828` | 白哉新发与波风湊／西索复刻的等窗口 D1–D5 对比。 |
| `01_monetization` | `s_class_gojo_return_30_pity_20260902` | 五条悟首次复刻 30 抽保底效果复盘。 |
| `01_monetization` | `s_class_sanji_monetization_d1_d5_20260914` | 香吉士 S 级角色首五日售卖诊断。 |
| `01_monetization` | `skin_gacha_ledger_attribution_without_tracking` | 缺少专用埋点时，使用资源流水重建皮肤 Gacha 兑换与消耗链路。 |
| `02_liveops_payments` | `battlepass_s1_s4_decline_20260921` | S1–S4 Battle Pass 销售下滑诊断。 |
| `02_liveops_payments` | `jump_tc_friend_invitation_effectiveness_20260624` | 好友邀请活动的奖励领取覆盖、任务里程碑及领取者付费表现复盘。 |
| `02_liveops_payments` | `jump_star_first_topup_double_20260909` | 各档首次储值双倍的参与、破冰、唤回、提档及后续价值。 |
| `02_liveops_payments` | `nezuko_daily_recharge_reimbursement_20260819` | 玩家充值与活动奖励／补偿的逐日核对。 |
| `02_liveops_payments` | `payment_rate_uplift_20260819` | 活动期付费率变化、SKU 与虚拟货币消耗路径。 |
| `02_liveops_payments` | [`luffy_117_gacha_delivery_audit_20261007`](02_liveops_payments/luffy_117_gacha_delivery_audit_20261007/README.md) | 大路飞117卡池110抽卡奖励核查：按角色与时间匹配 hero_add，关联两日最新持有／觉醒快照；保留内部用户，未匹配不等于确认未发货。 |
| `03_competitive_gameplay` | `cn_ranked_mvp_svp_by_rank` | 按段位统计真人／Bot 对局中的 MVP、SVP 评分分布。 |
| `03_competitive_gameplay` | `ranked_match_balance` | 单排撞车、段位失衡、Bot 暴露、等待时间及英雄杯差异。 |
| `03_competitive_gameplay` | `ranked_season_engagement_20260831` | 重度排位玩家的参与深度、Bot 暴露与 D+1/D+3 再排关系。 |
| `04_engagement_kpi` | `active_duration_lifecycle_mix` | M2 在线时长变化是否由用户生命周期构成与组内时长驱动。 |
| `04_engagement_kpi` | `daily_cn_kpi_20260820` | 日活、付费及会话 KPI 的日级监控与报告。 |
| `04_engagement_kpi` | `tc_au_forecast_to_202612_20260923` | 使用最新成熟 R30／R60／R90 留存重估 TC AU，并预测至 2026 年 12 月。 |
| `05_cohort_extraction` | `obt_first_login_no_nuu_20260826` | OBT 首登且不属于既有 NUU 的用户人群提取。 |
| `90_archive` | `backups` | 历史用户数据、画像、清洗结果与本地备份。 |

## 方法复用边界

- `card_pool_monetization` 是卡池分析的**通用模板**；A 级复刻和 S 级卡池案例应复用其口径，而不是复制维护一套独立方法。
- `a_class_return_monetization_20260805` 与 `a_class_delivery_mechanisms_first5d_20260831` 共享 Nezuko 学园活动的基准和资源归因，但分别回答复刻池与投放机制问题。
- `ranked_match_balance` 与 `ranked_season_engagement_20260831` 共享排位／Bot 口径，但区域、目标和结论不同，均应保留。

## 新增 case 的最低要求

1. 在对应一级分类目录下建立以业务问题和日期命名的 case，并添加 `README.md`。
2. 写清数据源、区域、时间窗、分析对象、分母、排除规则及已知限制。
3. 保存可复跑 SQL 与生成交付物的脚本；输出文件名应包含日期或版本。
4. 对涉及收入、活动参与或 Bot 的结论，明确是否仅为相关性，不将同期指标变化直接归因为单一活动或机制。

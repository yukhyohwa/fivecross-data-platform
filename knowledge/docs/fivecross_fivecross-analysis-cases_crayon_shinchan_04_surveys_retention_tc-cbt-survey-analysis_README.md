# Shin-chan TW CBT 问卷分析

## 最终归档范围（2026-10-18整理）

最终成果为`outputs/questionnaire_charts/questionnaire_behavior_charts_20260802_corrected.xlsx`及reports中的两份分析文字。对应窗口固定2026-07-29～08-02。保留四个正式生成查询与SQL模板；旧日期、延长到8/7的查询、inspect诊断SQL、预览和旧版工作簿已移到项目外备份。为防止再次混入后续数据，默认截止日改为8/2；需要新窗口时须显式传入`--end-date`。

`data/`、原始答卷CSV和带角色答案的生成SQL仅本地保留，不提交Git；正式构建代码、模板、最终Excel和分析文字提交。下方早期“默认昨天”说明已由本节的固定归档窗口替代。

## 目录

- `inputs/`：问卷 CSV 原始导出。脚本会按问卷 ID 匹配最新修改的 `survey_*_responses*.csv`。
- `main.py`：一键重建本地分析产物和日期边界 SQL。
- `scripts/build_inputs.py`：读取 `inputs/`，生成角色标签 `data/processed/questionnaire_role_tags.csv`。
- `scripts/build_daily_retention_ltv_query.py`：生成 D1–D7、LTV1–LTV7 的注册日期 cohort SQL。
- `scripts/build_ltv1_query.py`、`scripts/build_sku_preference_query.py`：生成 LTV1 和 SKU/商品类别偏好 SQL。
- `sql/generated/`：按日期生成的可执行 SQL。
- `data/raw/`：从数据平台下载后放入的 CSV 结果。
- `reports/`：问卷分析与行为报告 Markdown。
- `outputs/questionnaire_charts/`：Excel 工作簿和图表预览。

## 一键生成

在项目根目录执行：

```powershell
cd C:\Users\5xgames\Desktop\github\shihchantc_questionaire
python .\main.py
```

默认使用 `2026-07-29` 作为开始日期，并把“运行当天的前一天”作为最新完整数据分区。例如 8 月 2 日运行时，截止日为 8 月 1 日。也可以显式指定：

```powershell
python .\main.py --start-date 2026-07-29 --end-date 2026-08-01
```

`main.py` 会读取 `inputs/`，重建标签和 SQL，并刷新本地 Markdown/Excel。远程 SQL 仍需通过 ThinkingData/fivecross-data-client 执行；执行后将 CSV 放入 `data/raw/`，再重新运行 `python .\main.py` 即可刷新报告与工作簿。

## 分日口径

- `注册时间` 和 `分析粒度=注册日期` 会保留各注册 cohort；`分析粒度=总体` 用于趋势图。
- 截止日期按“昨天的完整分区”处理，不把今天的进行中分区纳入成熟样本。
- Dn 是注册日后第 n 天登录；LTVn 是注册日到第 n-1 天的累计有效充值，并只对已成熟 cohort 计算。
- `Opts.role_id` 关联游戏 `#account_id`；用户维度多数行为通过 `#user_id` 归并，并排除黑名单账号。

## 重要限制

SQL 只使用已验证的事件字段。若数据平台查询因 stage 数量、字段或权限失败，必须保留失败信息，不能用猜测字段或假数据补齐结果。

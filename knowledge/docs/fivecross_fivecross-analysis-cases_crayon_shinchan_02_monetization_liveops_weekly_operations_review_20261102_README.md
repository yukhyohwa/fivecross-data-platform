# 小新繁体 App18｜2026-11-02 周运营分析

## 当前交付与已知问题

当前交付为 [截至 11 月 9 日的配置表分类修正版](outputs/小新繁体_运营分析_晶钻普通钻石分列_活动规范修正版_截至20261109_配置表分类修正版.xlsx)。本目录仅保留这一份报告、必要的查询与数据证据、收入 CSV 聚合代码及校验入口。

**这份报告存在不同截止混用，尚未修正：**「运营摘要」现金为 4,747,142.35 TWD、商城晶钻支付等值为 2,231,792，覆盖 11/2–11/8；「收入来源」页仍含截至 11/6 的数据，其合计行现金为 3,087,386.05 TWD、晶钻支付等值为 1,545,452。因此不能把该页当作已与全周摘要勾稽一致的最终收入分解。最新配置分类与未归因明细也继承了这一旧窗口。清理只保留原始数字，没有擅自修改交付物。

11/9 全周查询证据和 11/6 旧窗口的原始购买导出均保留，便于后续核对这项差异；清理时记录的最终 Excel SHA256 见 `outputs/final_manifest.json`。

## 数据与业务口径

- 区服：繁体 TC，ThinkingData App18，`ta.v_event_18`；身份以 FC 账号为主，角色／服务器字段另行保留。
- 全周窗口：`2026-11-02 00:00:00 <= event_time < 2026-11-09 00:00:00`，业务时区 Asia/Shanghai。完整收入历史查询从 OBT 2026-10-14 开始，用于活动周期及复购分析。
- 现金按每日汇率折 TWD；商城晶钻支付等值为资源数量 / 100，不能加总为新增现金收入。现金排 water/windows/sandbox/freebuy/COIN，保留 internal；晶钻额外排 internal。
- `>=2`／`>=3` 指有效购买事件次数，不是已认证唯一业务订单数；疑似重复流水保留，敏感性结果不替代正式口径。
- 7 日流失使用连续 7 个完整自然日未登录；战力读取 `battle_start.battlepower`，不使用 `card_power`。
- 首付 +7 仅纳入已成熟 cohort，第 +7 自然日没有 login 才计入未登录；未成熟不输出为 0。
- 社团快照按次日对应前一业务日，缺失不补 0；合服名单仅供观察。
- 活动参与／登录分母缺失时，参与人数和 ARPU 留空，不能用购买账号数替代。

活动规则从共享的 [SQLite 配置及说明](../activity_event_timetable_20261030/README.md) 读取，实际库为 `../activity_event_timetable_20261030/reference/activity_rules.sqlite`。福引机按四主题逐服日龄窗口 D9–11、D16–18、D22–23、D28–30 区分；露营起点为自然日 2026-11-04，结束日期与部分正式 SKU 外键仍未确认。晶钻充值与普通钻石商品分列，不继承 TC 其他项目的货币估值。

## 保留文件与关联关系

| 路径 | 用途 |
| --- | --- |
| `outputs/*配置表分类修正版.xlsx` | 唯一保留的最终报告，含其他未归因商品明细 |
| `outputs/final_manifest.json` | 最终报告 SHA256、8 组源 SQL／CSV／回执的路径及哈希 |
| `sql/revenue_audit/` | 11/9 已执行的收入历史、独立控制、直接晶钻及汇率 SQL；冻结实际执行字节 |
| `sql/retention_servers/` | 11/9 已执行的流失、分服、首付 +7 和社团登录控制 SQL |
| `outputs/revenue_audit/live_refresh/20261109_000000/` | 4 组全周收入源 CSV 及原始回执，供离线重建与独立勾稽 |
| `outputs/retention_servers_refresh/20261109_000000/` | 4 组流失／分服源 CSV 及原始回执 |
| `data/raw/20261106_111916/` | 旧窗口购买数据、SQL 及回执；用于追溯最终收入页中的旧数值 |
| `outputs/revenue_by_activity.csv`、`repurchase_by_activity.csv`、`product_activity_detail.csv` | 全周收入、活动复购及商品级支持汇总，不声明与混用截止的 Excel 逐页一致 |
| `outputs/revenue_audit/` 中其他 CSV／JSON | 源计数勾稽、开服日、配置窗口、疑似重复敏感性与分类修正依据 |
| `scripts/build_revenue_verified_current.py` | 全周收入支持表的离线重建；不是整本最终 Excel 的重建器 |
| `scripts/verify_final.py` | 只读核对最终报告、源数据及 SQL 哈希，并显示已知收入页不一致 |
| `config/refresh.json` | 当前窗口、文件位置与重建范围说明 |

收入源、独立控制与汇率共同进入收入支持表聚合；服务器源提供开服日；SQLite 提供福引机窗口。最终 Excel 后续的商品维表分类修正仅保存了结果与说明，未保留完整独立重建程序，因此不能声称当前脚本可以精确重建整本最终 Excel。

## 使用与验证

在本 case 根目录执行，只读核查，不连接 TA、不改写 Excel：

```powershell
$py = 'C:\Users\5xgames\Desktop\github\fivecross-data-client\.venv\Scripts\python.exe'
& $py scripts/verify_final.py
```

需要重新生成全周支持 CSV 时运行以下命令；它会覆盖支持表和相应汇总回执，但不会修改最终 Excel：

```powershell
& $py scripts/build_revenue_verified_current.py
```

该聚合器校验 CSV 哈希／行数、每日渠道源计数、汇率与金额勾稽、商城和直接晶钻查询重叠边界，并读取实际导出重新核对。原始源数据与共享 SQLite 均需在本地存在；凭据和浏览器会话不属于本案例依赖。

需要重新取数时，通过既有 [fivecross-data-client](../../../../fivecross-data-client/README.md) 执行保留 SQL；当前 SQL 为本次固定截止的实际执行版本，不是自动滚动刷新模板。原始回执中的 runtime 路径是历史执行路径，清理后的对应文件由 `final_manifest.json` 映射。

## 清理记录（2026-11-09）

- 移出 7 份旧版／重复 Excel、过时分支脚本、字段探查及调试 SQL、日志、临时任务、重复导出、浏览器 session 和缓存，共 459 个文件，约 196.73 MiB。
- 在移除 runtime 前，将最终依赖的 8 份已执行 SQL 固化到 `sql/`；保留源 CSV、执行回执与校验关系。
- 删除旧截止 README 叙述、过时刷新配置和支持表脚本中不再适用的报告正文／调试输出。
- 最终 Excel、原始导出及现有支持表内容保持不变。目录清理备份位于仓库外的 `%TEMP%/shinchan_weekly_cleanup_20261109`，未纳入案例或 Git。
- 校验通过仅说明文件和证据保留完好，不代表混用截止问题已修复。

## Git 保存范围

代码、SQL、配置、README、最终工作簿及汇总证据延续现有版本管理规则。`data/`、全周原始收入 CSV、疑似重复事件明细及运行缓存按 `.gitignore` 留在本地；不保存凭据或浏览器 session。

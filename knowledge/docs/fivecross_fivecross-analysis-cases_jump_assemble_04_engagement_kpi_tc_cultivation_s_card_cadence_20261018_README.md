# Jump TC 用户养成分析（截至 2026-10-18）

本目录保留六周业务版，以及老用户全角色养成与资源积累补充版。2026-10-22 已清理被替代的四周/22页历史版本、试验分支数据、旧脚本及预览缓存；现有四份交付文件内容未修改。

## 最终交付

- [六周业务版 PPT，16页](outputs/Jump_TC_用户养成情况分析_截至20261018_业务版_六周版.pptx)
- [六周业务版支持数据，25表](outputs/Jump_TC_用户养成情况分析_支持数据_截至20261018_业务版_六周版.xlsx)
- [老用户全角色养成与资源积累 PPT](outputs/Jump_TC_老用户全角色养成与资源积累分析_截至20261018.pptx)
- [老用户补充版支持数据](outputs/Jump_TC_老用户全角色养成与资源积累分析_截至20261018_支持数据.xlsx)

## 数据与口径

来源为 TA Global `ta.v_event_23`。六周为 2026-09-07 至 2026-10-18，六周均登录的固定同群为5,707人。六周批次最新周14,697活跃、11,008任一养成；停养补充批次最新周14,698活跃、11,009任一养成，两个批次不可混接。

账号、黑名单、汇率及事件口径见所保留 SQL、支持工作簿方法页与查询执行收据。养成操作次数不等于成功次数、净提升或材料消耗。获卡五日取窗口内最后实际快照，不冒称精确第五天末状态；未知不当零。渠道、付费分层及重配权重比较是描述性结果，不代表因果效果。资源持有或余额上涨也不能单独证明资源过剩、足够或已养满。

## 保留的构建与来源

- `scripts/build_report.py`：当前六周版入口，仅依次执行 `prepare_six.py`、`build_six.py`。
- `scripts/depth_six.py`：六周版渠道及养成深度计算。
- `scripts/query_six.py`、`sql/six_week/`：六周版取数入口和版本化 SQL。
- `scripts/query_stagnation.py`、`sql/all_character_stagnation/`：停养补充版取数入口和版本化 SQL。
- `scripts/analyze_stagnation.py`、`extend_stagnation.py`、`build_stagnation.py`：补充版计算及构建。
- `scripts/render_six.ps1`、`contact_six.py`、`verify_six.py`：当前六周版的渲染及校验工具。
- `validation/six_*`、`validation/stagnation_*`：现有交付的统计、来源、哈希和审阅记录；预览图片可重新生成。
- `data/six_week/`、`data/all_character_stagnation/`：本地原始导出、派生底表和执行收据，包含账号级数据，不提交 Git。
- `data/reused/panel.*`、`panel_execution.json`：仅保留当前六周计算仍读取的旧批次面板及来源记录，其余旧批次副本已移除。

## 本地复现

Python 使用 `C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe`。须先具备对应本地导出或重新取数；Git 不包含账号级 CSV。

六周业务版：

```powershell
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/build_report.py
```

停养补充版：依次运行 `scripts/extend_stagnation.py`（包含基础分析）、`scripts/build_stagnation.py`。

如需刷新查询，取数脚本从已提交的 `sql/six_week/` 或 `sql/all_character_stagnation/` 读取定义，不依赖已删除的历史查询目录。每个批次整体刷新，不只替换部分窗口。

预览缓存已清理。需重新视觉校验时先执行 `scripts/render_six.ps1`，该脚本会从当前六周定稿复制临时输入并导出，再运行 `scripts/contact_six.py` 和 `scripts/verify_six.py`。现有审阅收据仍绑定原交付哈希，重新生成的报告必须重新校验。

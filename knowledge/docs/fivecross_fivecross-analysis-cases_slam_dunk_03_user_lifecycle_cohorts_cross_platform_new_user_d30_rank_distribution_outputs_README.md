# 输出目录

- `baseline_20260721.csv`：本 case 固化时使用的汇总基线，不含用户 ID。
- `fixtures/`：由基线按平台拆分的回归输入，可用于离线验证合并脚本。
- `raw/`：每次执行后保存两端原始 CSV。
- `reports/`：每次执行后生成合并段位分布 CSV 和汇总 CSV。

`raw/` 和 `reports/` 由 `scripts/run_case.py` 自动创建。历史输出是否提交到版本库，应按仓库的数据管理规则决定；包含账户或角色明细的文件不得放入本 case。

离线回归示例：

```powershell
python scripts/run_case.py --skip-fetch `
  --odps-csv outputs/fixtures/odps_april_rank.csv `
  --ta-csv outputs/fixtures/ta_june_rank.csv
```

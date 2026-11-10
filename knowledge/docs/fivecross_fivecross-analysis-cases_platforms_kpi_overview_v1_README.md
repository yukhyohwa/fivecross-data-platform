# KPI Overview 自动化汇总工具

本目录包含了一套用于自动化抓取并汇总 **数数 (ThinkingData)** 和 **阿里云 (ODPS)** KPI 数据的工具脚本。

## 1. 目录结构

```text
kpi_overview/
├── sys_aggregate_kpi.py      # Python 汇总主脚本（核心执行文件）
├── sys_kpi_ta_cn.sql         # 国内 TA 查询模板
├── sys_kpi_ta_global.sql     # 海外 TA 查询模板
├── sys_kpi_odps_cn.sql       # 国内 ODPS 查询模板
├── sys_kpi_odps_global.sql   # 海外 ODPS 查询模板
├── README.md                 # 本说明文档
└── aggregated_reports/       # 导出的 Excel 汇总报表存放目录
```

## 2. 依赖项与配置

### 2.1 外部项目依赖
本工具依赖于 `fivecross-data-client` 引擎。
请确保文件夹层级关系如下（脚本默认向上寻找 3 级目录）：
```text
github/
├── fivecross-data-client/    # 必须在此位置
└── fivecross-sql-lib/
    └── common/
        └── kpi_overview/     # 本工具所在目录
```

### 2.2 数据引擎配置
确保 `fivecross-data-client` 根目录下的 `.env` 文件已正确配置：
- `ALIYUN_AK_CN` / `ALIYUN_SK_CN` / `ALIYUN_PROJECT_CN` (国内 ODPS)
- `ALIYUN_AK_OVERSEAS` / `ALIYUN_SK_OVERSEAS` / `ALIYUN_PROJECT_GLOBAL` (海外 ODPS)
- `TA_URL_CN` / `TA_USER_CN` / `TA_PASS_CN` (国内 TA)
- `TA_URL_GLOBAL` / `TA_USER_GLOBAL` / `TA_PASS_GLOBAL` (海外 TA)

## 3. 执行方式

请使用终端进入本目录，然后运行：

### 按月汇总 (推荐)
```powershell
python sys_aggregate_kpi.py 2026-02
```
*这将自动查询 2026 年 2 月全月（1号到最后一天）的数据。*

### 按指定日期范围汇总
```powershell
python sys_aggregate_kpi.py 2026-02-01 2026-02-15
```

### 按单日汇总
```powershell
python sys_aggregate_kpi.py 2026-02-01
```

## 4. 功能特性说明

1.  **自动标题映射**：脚本通过内置的 `rename_map` 逻辑，自动将 SQL 返回的英文别名（如 `revenue_val`）或小写名称（如 `arpu`）翻译为规范的中文表头（“月份”、“游戏名称”、“总流水”等）。
2.  **圣斗士星矢3 [15002011] 特殊处理**：由于该项目不在某些核心维表中，脚本已在 SQL 中显式配置其名称映射。
3.  **编码兼容性**：针对 Windows 环境，脚本移除了所有控制台表情符号并强制使用 UTF-8。
4.  **去重关联**：ODPS SQL 针对分过区的维度表 `dim_app_info` 增加了 `company = 'DeNA'` 的过滤，确保关联时不会因全表扫描或多分区重复导致数据异常。

## 5. 输出结果
汇总后的 Excel 文件将保存在 `aggregated_reports/` 目录下，文件名格式为：
`Unified_KPI_Report_开始日期_结束日期_时间戳.xlsx`

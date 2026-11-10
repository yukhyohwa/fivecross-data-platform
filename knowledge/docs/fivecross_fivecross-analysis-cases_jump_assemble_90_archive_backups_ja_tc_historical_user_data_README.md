# JA TC 历史用户数据处理 (Historical User Data)

本目录包含对日韩繁中旧日历史用户数据的提取合并、清洗与转存工作。为保持项目结构规范整洁，现已划分 `input/` 与 `output/` 目录来进行文件隔离。

## 目录结构
* **`input/`**：存放研发或原始导出的底表数据（如 `ja_tc_output2_20251212.csv`）。
* **`output/`**：存放运营提取的 SQL 结果日志（如 `ja_tc_data_result_20251212.csv`），以及所有 Python 脚本合并、清洗和转换后生成的下游衍生 CSV 及 `.db` 数据库文件。

---

## 1. 数据来源与合并准备

执行 `merge_historical_data_20251212.py` 会分别读取 `input/` 和 `output/` 中的两份原始数据并进行关联对齐：
1. **研发 (R&D) 提供的原始导出数据**。
2. **运营取数执行结果**：后台运行 `ja_tc_historical_data_extract.sql` 所得的附表。

这两者做 Left Join 融合后，将产生用于基础清洗的基准宽表文件。
> **输出产物**：`output/ja_tc_merged_20251212.csv`


## 2. 核心清洗与转换规则

基于生成的基准宽表，我们拆分了两个用于不同财务对账需求的数据清洗脚本：

### A. 转换台币处理脚本 (`clean_data_twd.py`)
执行以下四个步骤的标准清洗：
1. **剔除无创角账号**：删除了没有 `playerId` 的异常数据。
2. **多开去重**：针对同一个账号 (`account`) 进行去重，保留 `create_day`（创角时间）最靠后的记录。
3. **字段精简**：仅保留了 `account`, `pay_money`, `login_day`, `playerId`, `playerName`。
4. **统一汇率/取整（换算台币）**：通过内置逻辑把 `pay_money` 的数值全量 `× 4.5`，并且做四舍五入的取整（转换为纯 Int 类型）。
> **输出产物**：`output/ja_tc_merged_20251212_cleaned.csv`

### B. 原始汇率直出脚本 (`clean_data_rmb.py`)
专门针对不需要做台币汇率折算的场景（包含了一键生成数据库的逻辑）：
- 它的合并去重和字段保留逻辑与流程 A 完全一致。
- 唯一的区别在于，它**不做任何截断或四舍五入，直接保留了 `pay_money` 原始的浮点数（Float）精度**。
- 它并在同个脚本内直接集成了写入 SQLite 数据库的步骤。
> **输出产物**：`output/ja_tc_merged_20251212_cleaned_rmb.csv` 以及同名的 `.db` 数据库。


## 3. SQLite 数据库独立建库

除了通过流程 B 直接生成库文件外，如果是针对流程 A 生成的标准台币表，可以运行 `csv_to_sqlite.py` 脚本：
它利用分块读取，将庞大的数据包高效写入 SQLite 文件结构内。
- **配置与查询优化**：建库时默认在表名 `user_data` 的 `account` 以及 `playerId` 这两个核心业务字段上创建了本地索引 (`Index`)，将连表查询和单点检索的速度提升到了毫秒级。
> **输出产物**：`output/ja_tc_merged_20251212_cleaned.db`

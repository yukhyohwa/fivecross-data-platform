> 来源：JoyTools 88 Agent（services/gitlab/repo.py、assets/28_ROO维表查漏补缺/tools/tlog_meta_query.py、apps/28_ROO维表查漏补缺.py、services/gitlab/instructions.py）

# TLog 分支与游戏映射

## 分支与游戏对应
- Trunk_ep17 → ro_hmt / ro_sea / ro_lna
- Trunk_asia_ep02 → rooc / rooc_am

## 分支关键词（BRANCH_KEYWORDS）
asia.release.ep、am.release.ep、hmt.release.ep、sea.release.ep、lna.release.ep、Trunk_ep、Trunk_asia_ep。

## 目录与配置表
- DIR_PATH_OPTIONS：Table/CSV、overseas_config/HMT|SEA|LNA|Japan/Table/CSV 等候选路径。
- 配置表结构：第 1 行字段名、第 2 行字段备注、第 3 行起数据；__row__ 备注行不算数据行。

## 注意事项
- 分支名大小写坑：trunk_asia_ep02 实为 Trunk_asia_ep02（候选忽略大小写恰好一个匹配时才改读），回传 file_ref=project@提交号:path 时原样保留。
- GitLab 严格只读；filters 之间是 AND 无 OR。
- 同一个日志在不同分支里的字段集可能不同，映射分支后才谈得上字段口径。

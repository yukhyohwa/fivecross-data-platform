> 来源：JoyTools 88 Agent（services/db/macros.py、services/scheduler/instructions.py、docs/joytools-mcp.md）

# DolphinScheduler 调度宏

## 宏语法
- $[yyyy-MM-dd] = 调度日当天；$[yyyy-MM-dd-N] = 调度日往前 N 天。
- 解析正则：$\[yyyy-MM-dd(?:-(\d+))?\]；base_date 缺省今天。

## 执行顺序
- 宏先展开、再校验：被只读校验的文本就是实际执行的文本（宏展开 → validate_readonly_sql → 查询），executed_sql 回显展开后的语句。
- 展开与查询共用同一条只读链路，只读判定/语句超时/密码脱敏完全一致。

## 注意事项
- DS 调度严格只读：只查项目/工作流/节点/定时/实例/日志，严禁修改 SQL、依赖、Cron、上下线、启停重跑。
- 任务实例 ID 必须来自该项目该实例的节点结果，不能把 taskCode 当 taskInstanceId。
- Cron 原样保留，不能把近似推算说成 DS 权威运行时间；无结果不表示任务未运行。

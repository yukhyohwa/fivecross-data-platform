# 本地备份工具集成（交给 agent_tools/chat 所有者）

不要执行云端SQL，不重启，不commit。

## agent_tools.py 精确补丁

在模块导入区增加：
```python
from .local_backup_tools import TOOL_SCHEMAS as LOCAL_BACKUP_SCHEMAS, HANDLERS as LOCAL_BACKUP_HANDLERS
```
在现有 `TOOL_SCHEMAS = [...]` 完成之后（list_tool_metas定义之前）增加：
```python
TOOL_SCHEMAS.extend(LOCAL_BACKUP_SCHEMAS)
```
在现有 `_HANDLERS = {...}` 完成之后增加：
```python
_HANDLERS.update(LOCAL_BACKUP_HANDLERS)
```
这样继承active_tool_schemas启停、dispatch_tool错误包络和工具目录发现，不需要新增旁路路由。工具会从ctx绑定单一local_backup项目并检查sql_use权限；模型不能传project/root/path。

## chat.py 精确补丁

保留所有local_backup请求在SQL生成前fail-closed的分支。原read_launch_revenue入口已兼容显式日期窗口。
`_run_local_backup_revenue_fast_path`中的data事件名称由固定「圣斗士台湾开服前三日收入（CNY）」改为「本地备份经营收入（CNY）」；否则新窗口会显示错误标签。

## 依赖

项目.venv已安装openpyxl==3.1.5（与et-xmlfile）；请将openpyxl>=3.1,<4加入正式依赖文件。CSV路径只依赖stdlib，兼容聊天输出依赖已有pandas。

## 当前并行集成阻塞

执行旧 `test_local_backup_regression.py` 时，chat.py正由其它代理清理；失败为 `_handle` 引用已删除的 `_china_revenue_fast_path`（NameError），发生在本地分支之前。请删除残余调用或恢复正确路由顺序后重跑；本代理未修改chat.py。不得把服务层9项测试和两窗口证据宣称HTTP端到端已通过。

## 验证

平台技能目录 `knowledge/skills/本地备份文件分析/{skill.md,meta.json}`，通用、online=true；通过knowledge_store.list_online_skills加载。不是Hermes文字skill。
执行 `python -m unittest discover -s tests -p test_local_backup_tools.py -v`。真实外部验收脚本见tests/verify_local_backup_external.py，输出可保存为审计证据（仅聚合，不复制大数据）。集成后额外验证dispatch_tool('query_local_backup',...)与active_tool_schemas包含该工具。

"""Agent tool schemas/handlers; bind to existing agent_tools dispatcher."""
from . import local_backup_files as files


def query_local_backup(ctx, action, dataset_id=None, sheet=None, date_column=None,
                       start_date=None, end_date=None, grain='day'):
    # Project comes ONLY from selected authorized context, never model arguments.
    from backend.ide_app.services.permissions import has_perm
    if not has_perm(ctx.get('user'), 'sql_use'):
        raise ValueError('你没有数据查询使用权限。')
    games = ctx.get('games') or [ctx.get('game')]
    if len(games) != 1 or not games[0] or games[0].get('source_type') != 'local_backup':
        raise ValueError('请选择单个已登记的本地备份项目。')
    project = games[0]['key']
    if action == 'list_files':
        return files.list_files(project)
    if action == 'documentation':
        return files.documentation(project)
    if action == 'inspect':
        return files.inspect_file(project, dataset_id, sheet, date_column)
    if action == 'revenue':
        if dataset_id is not None or sheet is not None or date_column is not None:
            raise ValueError('经营收入只能使用审核后的固定数据集/字段，不接受替换。')
        return files.revenue(project, start_date, end_date, grain)
    raise ValueError('未知本地备份操作。')


TOOL_SCHEMAS = [{'type': 'function', 'function': {
    'name': 'query_local_backup',
    'description': '只读本地备份文件分析。选择本地备份项目后，先list_files/documentation，再inspect真实CSV/Excel schema和显式日期列覆盖。revenue需明确start_date/end_date，目前仅星矢TW已审核经营收入；不执行SQL或Python，不接受文件路径。',
    'parameters': {'type': 'object', 'additionalProperties': False,
        'properties': {
            'action': {'type': 'string', 'enum': ['list_files', 'documentation', 'inspect', 'revenue']},
            'dataset_id': {'type': 'string', 'description': '只能使用list_files返回的ID'},
            'sheet': {'type': 'string'}, 'date_column': {'type': 'string'},
            'start_date': {'type': 'string', 'description': '包含首日，YYYY-MM-DD'},
            'end_date': {'type': 'string', 'description': '包含末日，YYYY-MM-DD'},
            'grain': {'type': 'string', 'enum': ['day', 'summary']}},
        'required': ['action']}}}]
HANDLERS = {'query_local_backup': query_local_backup}

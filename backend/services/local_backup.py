"""Read registered external backup exports; never infer cloud schemas."""
import re
from decimal import Decimal

import pandas as pd


FILE_NAME = "圣斗士_繁体_阿里云_每日经营KPI_20161201至20260527.csv"
LAUNCH_DAYS = ["2016-12-01", "2016-12-02", "2016-12-03"]


def parse_revenue_question(question: str, project: str):
    from .local_backup_files import iso_date
    if project != 'saint_seiya_tw_backup':
        raise ValueError('该项目收入问句尚未接入；请用本地备份工具检查文件。')
    q = re.sub(r'\s+', '', question.lower()).strip('？?。！!')
    q = re.sub(r'^(?:请查询|请查|查询|请|查一下)', '', q)
    q = re.sub(r'^(?:星矢|圣斗士星矢|圣斗士|saintseiya)(?:2)?(?:tw|台湾|繁体)?(?:历史备份)?', '', q)
    metric = r'(?:的)?(?:经营收入|收入|流水|充值金额)(?:按日|汇总|合计)?'
    if re.fullmatch(r'开服(?:后)?前(?:3|三)(?:日|天)' + metric, q):
        return LAUNCH_DAYS[0], LAUNCH_DAYS[-1]
    match = re.fullmatch(r'(\d{4}-\d{2}-\d{2})(?:至|到|~)(\d{4}-\d{2}-\d{2})' + metric, q)
    if match:
        return iso_date(match[1]), iso_date(match[2])
    raise ValueError('此问句尚未接入。支持开服前3日收入或YYYY-MM-DD至YYYY-MM-DD收入（按日/汇总）；不替换窗口、不调用云端SQL。')


def read_launch_revenue(question: str, game: dict):
    """Compatibility chat entry backed by the bounded file service."""
    from .local_backup_files import revenue
    start, end = parse_revenue_question(question, game.get('key'))
    result = revenue(game['key'], start, end)
    out = pd.DataFrame(result['rows'])
    out['revenue_cny'] = pd.to_numeric(out['revenue_cny'], errors='raise')
    total = Decimal(result['total_revenue_cny'])
    lines = ['| 日期 | 收入（CNY） | 当日付费人数 |', '|---|---:|---:|']
    lines += [f"| {r['date']} | {r['revenue_cny']} | {r['payers']} |" for r in result['rows']]
    markdown = (f'## 本地备份经营收入\n{start} 至 {end} 收入合计 **{total:,.2f} CNY**'
                f'（未舍入值 {total} CNY）。\n\n' + '\n'.join(lines) +
                f'\n\n来源：外部本地备份 `{FILE_NAME}`；未调用云端数据库。\n'
                'TC / App ID 23000113 / day / overall / ALL。revenue_cny已排水、不重复换汇；'
                '开服锚点2016-12-01来自备份说明，不由最早数据猜测。'
                'KPI文件不提供订单数，未推算订单数；日人数不能相加为周期去重人数。'
                '只核实金额，不据此解释原因或预测。')
    return out, markdown

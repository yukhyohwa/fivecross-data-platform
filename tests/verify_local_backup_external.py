"""Explicit external acceptance; run from repo with PYTHONPATH=. No source writes."""
import csv
import hashlib
import json
from decimal import Decimal
from unittest.mock import patch
from backend.services import local_backup_files as f
from backend.services.local_backup import read_launch_revenue
from analysis import knowledge_store as ks

project = 'saint_seiya_tw_backup'
name = '本地备份文件分析'
assert name in ks.list_online_skills(project)
assert 'query_local_backup' in ks.read_skill(name)
listing = f.list_files(project)
item = next(row for row in listing['files'] if row['name'] == f.FILE_NAME)
inspection = f.inspect_file(project, item['dataset_id'], date_column='period_start')
results = []
for start, end in [('2016-12-01', '2016-12-03'), ('2017-01-01', '2017-01-03')]:
    result = f.revenue(project, start, end)
    # Independent pandas control on the external file (no copied raw data).
    import pandas as pd
    total = Decimal(0)
    matched = 0
    for chunk in pd.read_csv(f.project_dir(project) / f.FILE_NAME, dtype=str, chunksize=50000):
        selected = chunk.loc[(chunk.app_id == '23000113') & (chunk.version == 'TC') &
            (chunk.period_type == 'day') & (chunk.dimension_type == 'overall') &
            (chunk.dimension_value == 'ALL') & chunk.period_start.between(start, end)]
        matched += len(selected)
        total += sum((Decimal(v) for v in selected.revenue_cny), Decimal(0))
    assert matched == result['verified_days'] == 3
    assert str(total) == result['total_revenue_cny']
    out, text = read_launch_revenue(f'星矢 tw {start}至{end}收入按日', {'key': project})
    assert out.date.tolist() == [r['date'] for r in result['rows']]
    result['independent_decimal_control'] = str(total)
    results.append(result)
assert results[0]['total_revenue_cny'] != results[1]['total_revenue_cny']
path = f.project_dir(project) / f.FILE_NAME
h = hashlib.sha256()
with path.open('rb') as stream:
    for block in iter(lambda: stream.read(1024 * 1024), b''):
        h.update(block)
print(json.dumps({'skill_discovered': name, 'dataset': item, 'inspection': inspection,
                  'source_sha256': h.hexdigest(), 'windows': results}, ensure_ascii=False, indent=2))

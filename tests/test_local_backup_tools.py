import csv
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from backend.services import local_backup as lb


class BackupTests(unittest.TestCase):
    def test_explicit_window_not_launch(self):
        self.assertEqual(lb.parse_revenue_question('星矢 tw 2017-01-01至2017-01-03收入按日', 'saint_seiya_tw_backup'), ('2017-01-01', '2017-01-03'))

    def test_unsupported_fails_closed(self):
        for q in ['昨天收入', '开服前7日收入', '2017-01-01至2017-01-03收入按国家', '2017-01-01至2017-01-03订单数']:
            with self.subTest(q=q), self.assertRaises(ValueError):
                lb.parse_revenue_question(q, 'saint_seiya_tw_backup')


class FileServiceTests(unittest.TestCase):
    def setUp(self):
        from backend.services import local_backup_files as f
        self.f = f
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR'))
        self.addCleanup(self.temp.cleanup)
        self.env = patch.dict(os.environ, {'FIVECROSS_ALIYUN_BACKUP_ROOT': self.temp.name})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.folder = Path(self.temp.name) / 'games' / f.PROJECTS['saint_seiya_tw_backup']
        self.folder.mkdir(parents=True)
        (self.folder / f.DOC_NAME).write_text('23000113/TC 2016-12-01 purchase为CNY is_water=不是水', encoding='utf8')
        self.rows = [dict(app_id='23000113', version='TC', period_type='day', dimension_type='overall', dimension_value='ALL', period_start=d, period_end=d, revenue_cny=a, payers='2', au='4', source_observed_days='1', source_coverage_flag='observed_all_dates_not_partition_certification') for d,a in [('2017-01-01','1.001'), ('2017-01-02','2.002')]]
        self.save()

    def save(self):
        with (self.folder / self.f.FILE_NAME).open('w', newline='', encoding='utf-8-sig') as stream:
            writer = csv.DictWriter(stream, fieldnames=list(self.rows[0]))
            writer.writeheader()
            writer.writerows(self.rows)

    def query(self, **kwargs):
        return self.f.revenue('saint_seiya_tw_backup', '2017-01-01', '2017-01-02', **kwargs)

    def test_exact_decimal_summary(self):
        result = self.query(grain='summary')
        self.assertEqual(result['total_revenue_cny'], '3.003')
        self.assertEqual(result['rows'], [])
        self.assertIsNone(result['order_count'])

    def test_missing_duplicate_unknown(self):
        baseline = [r.copy() for r in self.rows]
        cases = [baseline[:1], baseline + [baseline[0]],
                 [dict(baseline[0], revenue_cny='NaN'), baseline[1]],
                 [dict(baseline[0], revenue_cny=''), baseline[1]],
                 [dict(baseline[0], source_coverage_flag='unknown'), baseline[1]]]
        for rows in cases:
            with self.subTest(rows=rows):
                self.rows = rows
                self.save()
                with self.assertRaises(ValueError):
                    self.query()

    def test_paths_project_and_schema(self):
        for key in ['../secret', 'C:/Users/secret', 'not_registered']:
            with self.assertRaises(ValueError):
                self.f.list_files(key)
        for ident in ['../secret', str(self.folder / self.f.FILE_NAME)]:
            with self.assertRaises(ValueError):
                self.f.inspect_file('saint_seiya_tw_backup', ident)
        listing = self.f.list_files('saint_seiya_tw_backup')
        result = self.f.inspect_file('saint_seiya_tw_backup', listing['files'][0]['dataset_id'], date_column='period_start')
        self.assertEqual(result['coverage']['distinct_dates'], 2)
        self.assertEqual(result['coverage']['rows'], 2)
        self.assertIn('revenue_cny', result['columns'])

    def test_excel_actual_schema_and_coverage(self):
        from openpyxl import Workbook
        book = Workbook()
        book.active.append(['date', 'amount'])
        book.active.append(['2020-01-01', 12])
        book.active.append([None, None])
        book.save(self.folder / 'fixture.xlsx')
        item = next(r for r in self.f.list_files('saint_seiya_tw_backup')['files'] if r['name'] == 'fixture.xlsx')
        result = self.f.inspect_file('saint_seiya_tw_backup', item['dataset_id'], date_column='date')
        self.assertEqual(result['columns'], ['date', 'amount'])
        self.assertEqual(result['coverage']['min'], '2020-01-01')

    def test_invalid_range_scan_limit_schema(self):
        with self.assertRaises(ValueError):
            self.f.revenue('saint_seiya_tw_backup', '2017-01-03', '2017-01-01')
        with patch.object(self.f, 'MAX_SCAN_ROWS', 1), self.assertRaises(ValueError):
            self.query()
        for r in self.rows:
            del r['revenue_cny']
        self.save()
        with self.assertRaisesRegex(ValueError, '缺少'):
            self.query()

    def test_symlink_outside_project(self):
        outside = Path(self.temp.name) / 'outside.csv'
        outside.write_text('secret\n1\n')
        link = self.folder / 'escape.csv'
        try:
            link.symlink_to(outside)
        except OSError:
            # Windows without symlink privilege: exercise the same resolved boundary.
            with self.assertRaises(ValueError):
                self.f.safe_file(self.folder, outside)
        else:
            with self.assertRaises(ValueError):
                self.f.list_files('saint_seiya_tw_backup')

    def test_tool_selected_context(self):
        from backend.services.local_backup_tools import query_local_backup
        with patch('backend.ide_app.services.permissions.has_perm', return_value=True):
            with self.assertRaises(ValueError):
                query_local_backup({'game': {'key': 'saint_seiya_tw_backup'}}, 'list_files')
            result = query_local_backup({'game': {'key': 'saint_seiya_tw_backup', 'source_type': 'local_backup'}}, 'revenue', start_date='2017-01-01', end_date='2017-01-02')
            self.assertEqual(result['total_revenue_cny'], '3.003')
        with patch('backend.ide_app.services.permissions.has_perm', return_value=False), self.assertRaises(ValueError):
            query_local_backup({}, 'list_files')


if __name__ == '__main__':
    unittest.main()

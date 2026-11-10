"""Regression: selected file backup must not become Shin-chan/cloud SQL."""
import json
import unittest
from unittest.mock import patch

from backend.routers.chat import ChatRequest, _handle
from backend.services.games import get_games


class LocalBackupRegression(unittest.TestCase):
    def events(self, question):
        game = next(g for g in get_games() if g['key'] == 'saint_seiya_tw_backup')
        with patch('backend.routers.chat.run_raw_sql', side_effect=AssertionError('Cloud SQL must not run')):
            return [json.loads(s.removeprefix('data: ').strip()) for s in _handle(ChatRequest(message=question), game)]

    def test_exact_report_reads_registered_file(self):
        events = self.events('星矢 tw 开服前3日的收入')
        self.assertFalse(any(e['type'] == 'sql' for e in events))
        rows = next(e['table']['rows'] for e in events if e['type'] == 'data')
        self.assertEqual([r[0] for r in rows], ['2016-12-01', '2016-12-02', '2016-12-03'])
        self.assertEqual([r[1] for r in rows], [58815.68, 65522.996, 100915.892])
        text = json.dumps(events, ensure_ascii=False)
        for forbidden in ('price_usd_from_api', 'vopenid', 'ta.v_event_18'):
            self.assertNotIn(forbidden, text)
        self.assertIn('225,254.57 CNY', text)

    def test_unsupported_requests_do_not_return_first_three_days(self):
        for q in ('星矢 tw 昨天收入', '星矢 tw 开服前7日收入', '星矢 tw 开服前3日收入按国家', '留存率'):
            with self.subTest(q=q):
                events = self.events(q)
                self.assertFalse(any(e['type'] in ('sql', 'data') for e in events))
                self.assertIn('尚未接入', events[-1]['markdown'])


if __name__ == '__main__':
    unittest.main()

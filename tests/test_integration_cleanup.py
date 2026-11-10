"""Integration at the HTTP boundary, real external file, no user storage writes."""
import json
from decimal import Decimal
import pytest


def events(response):
    assert response.status_code == 200, response.text
    return [json.loads(line[6:]) for line in response.text.splitlines() if line.startswith('data: ')]


def local_client(monkeypatch):
    from fastapi.testclient import TestClient
    from backend.main import app
    from backend.deps import get_current_user
    monkeypatch.setenv('AUTH_ENABLED', 'false')
    monkeypatch.setenv('AUTH_TOKEN', '')
    return TestClient(app)


@pytest.mark.parametrize('question,total', [
    ('星矢台湾 开服前3日的收入', '225254.568'),
    ('星矢台湾 2017-01-01至2017-01-03收入', '670541.77'),
])
def test_real_http_windows_and_continue(monkeypatch, question, total):
    import backend.routers.chat as chat
    monkeypatch.setattr(chat, 'resolve_model_for_task', lambda *a, **k: (_ for _ in ()).throw(AssertionError('Local files must not resolve LLM')))
    monkeypatch.setattr(chat, 'run_raw_sql', lambda *a, **k: (_ for _ in ()).throw(AssertionError('No cloud SQL')))
    client = local_client(monkeypatch)
    headers = {'X-Game': 'saint_seiya_tw_backup'}
    first = events(client.post('/api/chat', json={'message': question}, headers=headers))
    second = events(client.post('/api/chat', json={'message': '继续', 'history': [{'role': 'user', 'text': question}]}, headers=headers))
    for result in (first, second):
        assert not any(e['type'] in ('error', 'sql') for e in result), result
        data = next(e for e in result if e['type'] == 'data')
        assert data['name'] == '本地备份经营收入（CNY）'
        assert sum(Decimal(str(row[1])) for row in data['table']['rows']) == Decimal(total)


def test_preset_truncated_question_failclosed(monkeypatch):
    import backend.routers.chat as chat
    monkeypatch.setattr(chat, 'resolve_model_for_task', lambda *a, **k: (_ for _ in ()).throw(AssertionError('No LLM')))
    client = local_client(monkeypatch)
    for header in ('saint_seiya_tw_backup', '__any__'):
        result = events(client.post('/api/chat', headers={'X-Game': header}, json={
            'mode': 'preset', 'preset_skill': '本地备份文件分析',
            'message': '【预设专项 本地备份文件分析】星矢台湾 开服前3日的收'}))
        assert not any(e['type'] in ('sql', 'error', 'data') for e in result), result
        assert any('收入' in e.get('markdown', '') and '确认' in e.get('markdown', '') for e in result)


def test_backup_tool_registered():
    from backend.services import agent_tools as tools
    assert 'query_local_backup' in {s['function']['name'] for s in tools.TOOL_SCHEMAS}
    assert 'query_local_backup' in tools._HANDLERS
    assert 'search_web' not in tools._HANDLERS


def test_jev_not_in_runtime():
    from pathlib import Path
    root = Path(__file__).resolve().parents[1]
    assert not (root / 'analysis/jev_client.py').exists()
    for f in ('backend/routers/chat.py', 'backend/services/report_analyze.py', 'backend/services/llm.py'):
        assert 'jev' not in (root / f).read_text(encoding='utf-8').lower()

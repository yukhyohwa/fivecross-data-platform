"""P1-1：已确认指标（ide_data.db indicators）→ SQL 生成上下文注入（indicator_hint 通道）。"""
from backend.ide_app.services.db_service import _conn
from backend.services import indicator_hint


def _user_row(uid) -> dict:
    if isinstance(uid, dict):
        uid = uid["id"]
    return dict(_conn().execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone())


def _insert_indicator(uid, metric_id, name, status="active", alias="", definition="",
                      sql="SELECT 1", granularity="day"):
    c = _conn()
    c.execute(
        "INSERT INTO indicators (user_id, metric_id, metric_name, metric_alias, status,"
        " definition, canonical_sql, granularity) VALUES (?,?,?,?,?,?,?,?)",
        (uid, metric_id, name, alias, status, definition, sql, granularity),
    )
    c.commit()


def test_anonymous_returns_empty(seeded):
    assert indicator_hint.confirmed_indicators(None) == []
    assert indicator_hint.indicator_hint("充值金额", None) == ""


def test_active_visible_deprecated_filtered(seeded):
    admin = _user_row(seeded["admin"])
    _insert_indicator(admin["id"], "kpi_recharge", "充值金额", status="active")
    _insert_indicator(admin["id"], "kpi_old", "旧口径", status="deprecated")
    names = {i.get("metric_name") for i in indicator_hint.confirmed_indicators(admin)}
    assert "充值金额" in names
    assert "旧口径" not in names


def test_match_by_alias_and_no_hit(seeded):
    admin = _user_row(seeded["admin"])
    _insert_indicator(admin["id"], "kpi_pay", "充值金额", alias="流水", definition="充值金额=付费流水")
    hits = indicator_hint.match_indicators("查一下流水", admin)
    assert [h.get("metric_id") for h in hits] == ["kpi_pay"]
    assert indicator_hint.match_indicators("活跃用户数", admin) == []


def test_hint_renders_definition_sql_granularity(seeded):
    admin = _user_row(seeded["admin"])
    _insert_indicator(
        admin["id"], "kpi_arppu", "付费ARPPU",
        definition="ARPPU=收入/付费人数",
        sql="SELECT sum(pay)/count(distinct uid) FROM t WHERE 1=1",
        granularity="month",
    )
    text = indicator_hint.indicator_hint("查付费ARPPU", admin)
    assert "已确认业务指标口径" in text
    assert "ARPPU=收入/付费人数" in text
    assert "SELECT sum(pay)/count(distinct uid)" in text
    assert "粒度：month" in text


def test_hint_sql_truncated_at_limit(seeded):
    admin = _user_row(seeded["admin"])
    _insert_indicator(admin["id"], "kpi_long", "长SQL指标", sql="SELECT " + "x" * 2000)
    text = indicator_hint.indicator_hint("长SQL指标", admin)
    assert "x" * 2000 not in text  # canonical_sql 注入截断（_SQL_MAX_CHARS=600），防撑爆上下文

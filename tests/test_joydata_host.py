"""Joydata OAuth 回调 Host 白名单（2026-10-23：生产域名 joydata_ai.123u.com 默认放行）。

背景：未配 JOYDATA_PUBLIC_BASE 时回调地址由请求 Host 推断，Host 不在白名单即报
「未识别的主机」——反代部署（nginx 后 Host=域名）必中。修复：settings 默认值放行
本系统生产部署域名；换域名部署仍推荐显式配 JOYDATA_PUBLIC_BASE。
"""
from backend.ide_app.core.settings import Settings
from backend.routers.joydata import _allowed_joydata_hosts


def test_settings_class_default_allows_production_domain():
    default = Settings.model_fields["JOYDATA_ALLOWED_HOSTS"].default or ""
    assert "joydata_ai.123u.com" in default


def test_allowed_hosts_reads_settings_list(monkeypatch):
    from backend.ide_app.core import settings as settings_mod

    monkeypatch.setattr(settings_mod.settings, "JOYDATA_ALLOWED_HOSTS",
                        "a.example.com,b.example.com")
    hosts = _allowed_joydata_hosts()
    assert "a.example.com" in hosts
    assert "b.example.com" in hosts
    assert "localhost" in hosts and "127.0.0.1" in hosts  # 本机地址始终放行

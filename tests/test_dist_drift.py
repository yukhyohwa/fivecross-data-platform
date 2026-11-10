"""审计 P2-13：dist/src 漂移校验脚本的单测（纯文件系统行为，不依赖真实构建产物）。"""
import json
import time

import pytest

import scripts.check_dist_drift as dd


@pytest.fixture()
def drift_env(tmp_path, monkeypatch):
    """把漂移脚本的路径常量指到临时目录，与真实 ide_frontend 隔离。"""
    src = tmp_path / "src"
    dist = tmp_path / "dist"
    src.mkdir(); dist.mkdir()
    (src / "a.ts").write_text("const a = 1", encoding="utf-8")
    (src / "b.css").write_text("body{}", encoding="utf-8")
    monkeypatch.setattr(dd, "SRC_DIR", src)
    monkeypatch.setattr(dd, "DIST_DIR", dist)
    monkeypatch.setattr(dd, "FINGERPRINT_FILE", dist / ".src-fingerprint.json")
    return {"src": src, "dist": dist}


def test_fingerprint_is_content_based(drift_env):
    """指纹与内容相关、与 mtime 无关；改回原内容视为一致。"""
    h1 = dd.overall_hash(dd.compute_fingerprint())
    time.sleep(0.05)
    (drift_env["src"] / "a.ts").write_text("const a = 999", encoding="utf-8")
    h2 = dd.overall_hash(dd.compute_fingerprint())
    (drift_env["src"] / "a.ts").write_text("const a = 1", encoding="utf-8")
    h3 = dd.overall_hash(dd.compute_fingerprint())
    assert h1 != h2 and h1 == h3


def test_check_without_fingerprint_returns_2(drift_env, capsys):
    """无指纹文件 → 退出码 2（旧构建产物提示）。"""
    assert dd.check_only() == 2
    assert ".src-fingerprint.json" in capsys.readouterr().out


def test_stamp_then_check_returns_0(drift_env):
    """构建打标后校验一致 → 0。"""
    assert dd.stamp() == 0
    assert dd.check_only() == 0


def test_src_change_detected_with_file_list(drift_env, capsys):
    """改了 src 未重新构建 → 1，且报告具体文件（改动/新增/删除）。"""
    dd.stamp()
    (drift_env["src"] / "a.ts").write_text("const a = 2", encoding="utf-8")
    (drift_env["src"] / "new.tsx").write_text("x", encoding="utf-8")
    (drift_env["src"] / "b.css").unlink()
    assert dd.check_only() == 1
    out = capsys.readouterr().out
    assert "a.ts" in out and "new.tsx" in out and "b.css" in out


def test_legacy_fingerprint_format_still_detects_drift(drift_env):
    """旧格式（仅总指纹、无 files 明细）也能检出漂移。"""
    dd.stamp()
    payload = json.loads(dd.FINGERPRINT_FILE.read_text(encoding="utf-8"))
    del payload["files"]
    payload["fingerprint"] = "deadbeef"
    dd.FINGERPRINT_FILE.write_text(json.dumps(payload), encoding="utf-8")
    assert dd.check_only() == 1


def test_real_src_dir_hash_stable():
    """真实 src 指纹两次计算稳定（只读不写）。"""
    h1 = dd.overall_hash(dd.compute_fingerprint())
    h2 = dd.overall_hash(dd.compute_fingerprint())
    assert h1 == h2
    assert dd.SRC_DIR.is_dir()

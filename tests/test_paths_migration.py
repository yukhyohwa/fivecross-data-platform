"""审计 P2-4 复核：paths.py 数据目录迁移的加固行为单测。

覆盖整体搬迁、补齐、encryption.key 冲突备份、失败降级（含「旧 key 仍被需要」时
仍抛错的唯一例外）。所有目录均指到 tmp_path，与真实 ~/.sql-ide / data_ai/data 隔离。
"""
import glob

import pytest

import backend.ide_app.core.paths as paths


@pytest.fixture()
def dirs(tmp_path, monkeypatch):
    """把迁移脚本的路径常量指到临时目录。"""
    old = tmp_path / "old"
    new = tmp_path / "new"
    monkeypatch.setattr(paths, "OLD_APP_DIR", old)
    monkeypatch.setattr(paths, "NEW_APP_DIR", new)
    return {"old": old, "new": new}


def test_full_move_migrates_key_without_reading(dirs, capsys):
    old, new = dirs["old"], dirs["new"]
    old.mkdir()
    (old / "encryption.key").write_bytes(b"REALKEY")
    (old / "agent_config.json").write_text("{}", encoding="utf-8")
    paths._migrate_legacy_dir()
    assert (new / "encryption.key").read_bytes() == b"REALKEY"
    assert (new / "agent_config.json").read_text(encoding="utf-8") == "{}"
    assert not old.exists()
    assert "REALKEY" not in capsys.readouterr().out  # 绝不打印密钥内容


def test_new_exists_fills_missing_files_only(dirs):
    old, new = dirs["old"], dirs["new"]
    old.mkdir(); new.mkdir()
    (old / "keep.txt").write_text("old-version", encoding="utf-8")
    (old / "extra.txt").write_text("extra", encoding="utf-8")
    (new / "keep.txt").write_text("new-version", encoding="utf-8")
    paths._migrate_legacy_dir()
    # 目标已存在的普通文件不覆盖；缺失的补齐（key 的冲突处理见专属用例）
    assert (new / "keep.txt").read_text(encoding="utf-8") == "new-version"
    assert (new / "extra.txt").read_text(encoding="utf-8") == "extra"


def test_key_conflict_backs_up_new_and_adopts_old(dirs, capsys):
    old, new = dirs["old"], dirs["new"]
    old.mkdir(); new.mkdir()
    (old / "encryption.key").write_bytes(b"OLDKEY")
    (new / "encryption.key").write_bytes(b"NEWKEY")
    paths._migrate_legacy_dir()
    assert (new / "encryption.key").read_bytes() == b"OLDKEY"
    backups = glob.glob(str(new / "encryption.key.bak-*"))
    assert len(backups) == 1
    assert open(backups[0], "rb").read() == b"NEWKEY"
    out = capsys.readouterr().out
    assert "OLDKEY" not in out and "NEWKEY" not in out  # 备份提示不泄密钥内容


def test_key_conflict_identical_is_noop(dirs):
    old, new = dirs["old"], dirs["new"]
    old.mkdir(); new.mkdir()
    (old / "encryption.key").write_bytes(b"SAME")
    (new / "encryption.key").write_bytes(b"SAME")
    paths._migrate_legacy_dir()
    assert glob.glob(str(new / "encryption.key.bak-*")) == []


def test_move_failure_without_old_key_is_swallowed(dirs, monkeypatch, capsys):
    old, new = dirs["old"], dirs["new"]
    old.mkdir()
    (old / "other.txt").write_text("x", encoding="utf-8")
    def boom(src, dst):
        raise PermissionError("locked")
    monkeypatch.setattr(paths.shutil, "move", boom)
    paths._migrate_legacy_dir()  # 不抛错：失败记日志，下次启动重试
    assert "WARN" in capsys.readouterr().out


def test_move_failure_with_old_key_still_raises(dirs, monkeypatch):
    """旧目录仍持有真 key 且新目录没有 → 宁可启动失败，也不静默换路径生成随机 key。"""
    old, new = dirs["old"], dirs["new"]
    old.mkdir()
    (old / "encryption.key").write_bytes(b"REALKEY")
    def boom(src, dst):
        raise PermissionError("locked")
    monkeypatch.setattr(paths.shutil, "move", boom)
    with pytest.raises(PermissionError):
        paths._migrate_legacy_dir()


def test_no_old_dir_creates_new(dirs):
    new = dirs["new"]
    paths._migrate_legacy_dir()
    assert new.is_dir()
    paths._migrate_legacy_dir()  # 幂等
    assert new.is_dir()

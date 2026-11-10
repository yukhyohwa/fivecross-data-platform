"""数据目录统一落点（审计 P2-4）：从 ~/.sql-ide 迁移到项目目录 data_ai/data/.sql-ide。

任何模块 import 本文件即自动完成一次性迁移（幂等，后端重启后生效）：
- 新旧目录都不存在 → 在新路径新建；
- 新目录不存在、旧目录存在 → shutil.move 整体搬迁旧目录（不读取任何文件内容，
  尤其是 encryption.key——Fernet 密钥，丢了就解不开已存密文，只原样搬移、绝不打印内容）；
- 新目录已存在 → 原样使用；旧目录若仍有残存文件则按文件名逐个补齐（目标已存在则跳过）。

审计 P2-4 复核（对抗式核验）后的两点加固：
1. encryption.key 单独对待：新目录已有同名 key 时比对字节——不一致则先把新 key
   改名备份（encryption.key.bak-<时间戳>）再搬入旧 key，绝不静默保留错误 key；
2. 迁移失败不再一律抛崩启动：只有「旧目录仍持有真 key、新目录没有内容一致的 key」
   这一种情况仍原样抛出（否则 crypto 会在新路径静默生成随机 key，旧 key 加密的
   全部密文永久失读——比启动失败更糟）；其余失败记日志继续启动，下次启动自动重试。
"""
import shutil
from datetime import datetime
from pathlib import Path

# 旧落点（历史 sql-ide 用户目录）
OLD_APP_DIR = Path.home() / ".sql-ide"
# 新落点：data_ai/data/.sql-ide（按本文件位置推导，与启动时的工作目录无关）
NEW_APP_DIR = Path(__file__).resolve().parents[3] / "data" / ".sql-ide"

_KEY_FILE = "encryption.key"


def _key_bytes(p: Path) -> bytes | None:
    """读 key 文件字节；读不到/读失败返回 None（只比对内容，绝不打印内容）。"""
    try:
        return p.read_bytes() if p.is_file() else None
    except OSError:
        return None


def _old_key_still_needed() -> bool:
    """旧目录仍持有 encryption.key、且新目录里没有内容一致的 key。

    此时若静默继续启动，crypto 会在新路径生成随机 key，旧 key 加密的全部密文永久
    失读——这是唯一一种「宁可启动失败也要人工介入」的情形。
    """
    old_key = _key_bytes(OLD_APP_DIR / _KEY_FILE)
    if old_key is None:
        return False
    return _key_bytes(NEW_APP_DIR / _KEY_FILE) != old_key


def _reconcile_key(old: Path, target: Path) -> None:
    """新目录已有同名 encryption.key：内容一致则跳过；不一致则备份新 key 后采用旧 key。"""
    old_key = _key_bytes(old)
    if old_key is None or _key_bytes(target) == old_key:
        return
    backup = target.with_name(f"{_KEY_FILE}.bak-{datetime.now():%Y%m%d%H%M%S}")
    shutil.move(str(target), str(backup))
    shutil.move(str(old), str(target))
    print(f"[paths] [WARN] 新旧 encryption.key 不一致：新 key 已备份为 {backup.name}，"
          f"采用旧 key（历史密文以旧 key 为准，无需人工处理）")


def _migrate_legacy_dir() -> None:
    try:
        if not OLD_APP_DIR.is_dir():
            # 无旧目录：直接在新路径建目录（失败交给 crypto 的 mkdir 兜底，不阻塞启动）
            NEW_APP_DIR.mkdir(parents=True, exist_ok=True)
            return
        if not NEW_APP_DIR.exists():
            # 新目录尚不存在：整体搬迁旧目录（只搬文件，不读内容、不打印内容）
            NEW_APP_DIR.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(OLD_APP_DIR), str(NEW_APP_DIR))
            print(f"[paths] 数据目录已从 {OLD_APP_DIR} 整体迁移到 {NEW_APP_DIR}")
            return
        # 已迁移过：只补齐旧目录里尚未搬走的文件
        for old in sorted(OLD_APP_DIR.iterdir()):
            if not old.is_file():
                continue
            target = NEW_APP_DIR / old.name
            if target.exists():
                if old.name == _KEY_FILE:
                    _reconcile_key(old, target)
                continue
            try:
                shutil.move(str(old), str(target))
            except OSError as exc:
                if old.name == _KEY_FILE:
                    raise  # 交给外层判断：旧 key 仍被需要时必须抛错，否则 crypto 会在本进程内生成随机 key
                print(f"[paths] [WARN] 迁移文件失败（下次启动自动重试）：{old.name}：{exc}")
    except OSError as exc:
        if _old_key_still_needed():
            raise
        print(f"[paths] [WARN] 数据目录迁移失败（下次启动自动重试）：{exc}")


_migrate_legacy_dir()

# 统一数据目录（Path 对象，供 config / crypto / agent_config / migrations 引用）
APP_DIR = NEW_APP_DIR

"""Fernet symmetric encryption for stored DB passwords."""
import os
from cryptography.fernet import Fernet

from .paths import APP_DIR  # 审计 P2-4：密钥文件随数据目录迁到项目 data_ai/data/.sql-ide（旧 ~/.sql-ide 自动搬迁，密钥只搬不读）

_KEY_ENV = "DB_ENCRYPT_KEY"
_KEY_FILE = APP_DIR / "encryption.key"


def _get_key() -> bytes:
    # 1) Env var takes priority
    env_key = os.environ.get(_KEY_ENV, "")
    if env_key:
        return env_key.encode()

    # 2) Read from persistent file
    if _KEY_FILE.exists():
        return _KEY_FILE.read_bytes()

    # 3) Generate, persist, return
    _KEY_FILE.parent.mkdir(parents=True, exist_ok=True)
    k = Fernet.generate_key()
    _KEY_FILE.write_bytes(k)
    print(f"[crypto] Key generated and saved to {_KEY_FILE}")
    return k


_fernet = Fernet(_get_key())


def encrypt(plain: str) -> str:
    if not plain:
        return ""
    return _fernet.encrypt(plain.encode()).decode()


def decrypt(cipher: str) -> str:
    if not cipher:
        return ""
    try:
        return _fernet.decrypt(cipher.encode()).decode()
    except Exception:
        return ""

import os
import uuid
import hashlib
from datetime import datetime, timedelta
from typing import Optional
from jose import jwt, JWTError
import bcrypt

_SECRET_ENV = "JWT_SECRET_KEY"
_ALG = "HS256"

# Cache the generated secret so encode/decode use the same key
_SECRET_CACHE: Optional[str] = None


def _secret() -> str:
    global _SECRET_CACHE
    if _SECRET_CACHE:
        return _SECRET_CACHE
    try:
        from backend.ide_app.core.settings import settings
        s = settings.JWT_SECRET_KEY
    except Exception:
        s = os.environ.get(_SECRET_ENV, "")
    if s:
        _SECRET_CACHE = s
        return s
    k = hashlib.sha256(os.urandom(64)).hexdigest()
    _SECRET_CACHE = k
    print(f"[auth] WARNING: {_SECRET_ENV} not set, using random key (sessions invalidated on restart)")
    return k


def _access_expire_minutes() -> int:
    try:
        from backend.ide_app.core.settings import settings
        return settings.ACCESS_TOKEN_EXPIRE_HOURS * 60
    except Exception:
        return 480


def _refresh_expire_days() -> int:
    try:
        from backend.ide_app.core.settings import settings
        return settings.REFRESH_TOKEN_EXPIRE_DAYS
    except Exception:
        return 30


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()


def verify_password(password: str, hashed: str) -> bool:
    return bcrypt.checkpw(password.encode(), hashed.encode())


def create_token(user_id: str) -> tuple[str, str, datetime]:
    """Returns (access_token, refresh_token, access_expires_at)."""
    now = datetime.utcnow()
    access_exp = now + timedelta(minutes=_access_expire_minutes())
    refresh_exp = now + timedelta(days=_refresh_expire_days())

    access = jwt.encode(
        {"sub": user_id, "type": "access", "exp": access_exp, "iat": now},
        _secret(), algorithm=_ALG,
    )
    refresh = jwt.encode(
        {"sub": user_id, "type": "refresh", "exp": refresh_exp, "iat": now, "jti": str(uuid.uuid4())},
        _secret(), algorithm=_ALG,
    )
    return access, refresh, access_exp


def decode_token(token: str) -> Optional[dict]:
    try:
        return jwt.decode(token, _secret(), algorithms=[_ALG])
    except JWTError:
        return None

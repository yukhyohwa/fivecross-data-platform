"""重启后端后的端点冒烟（P1-16/P1-17 验收）：
- /api/auth/register 已下线（405：根静态挂载兜底）
- POST /api/auth/users 仅 admin（无 token 401 / 普通用户 403 / admin 201 + 123456 可登录）
- /api/admin/versions + /diff 可用（优先对真实历史版本做一次 diff，无版本时回落 404 探测）
- /api/auth/me 与前端首页正常
全程不打印任何凭证；临时建号用户 smoke_tmp 最后经 DELETE /api/auth/users/{id} 清理。
用法：python scripts/smoke_restart.py
"""
import sys
from pathlib import Path

import httpx

_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT))  # data_ai 根：backend 与 analysis 包都在这里

from backend.ide_app.core.auth import create_token  # noqa: E402
from backend.ide_app.services.db_service import _conn  # noqa: E402
from analysis import versioning  # noqa: E402

BASE = "http://localhost:8000"
FAILED = []


def check(name: str, ok: bool, detail: str = "") -> None:
    if not ok:
        FAILED.append(name)
    print(f"{'OK ' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))


def _version_probe() -> tuple[str, str] | None:
    """在 _versions/ 里找一个真实工件版本，映射回 (kind, name)；没有则返回 None。"""
    vdir = versioning.VERSIONS_DIR
    if not vdir.is_dir():
        return None
    for entry in sorted(vdir.rglob("*")):
        if not entry.is_file():
            continue
        rel = entry.relative_to(vdir)  # e.g. sql/x.sql/<ver>.sql
        parts = rel.parts
        if len(parts) < 2:
            continue
        stem = Path(parts[-2]).stem if len(parts) >= 2 else parts[-1]
        head, name = parts[0], parts[1]
        if head == "sql":
            return "sql", name
        if head == "code" and name.endswith(".py"):
            return "model", name[:-3]
        if head == "knowledge" and len(parts) >= 3 and parts[1] == "docs":
            return "doc", Path(parts[2]).stem
        if head == "knowledge" and len(parts) >= 3 and parts[1] == "skills":
            return "skill", parts[2]
    return None


def main() -> int:
    row = _conn().execute("SELECT id FROM users WHERE username=?", ("admin",)).fetchone()
    if not row:
        print("FAIL  未找到 admin 账户")
        return 1
    # 幂等预清理：上次中断可能遗留 smoke_tmp（固定用户名重复建号会 409）
    c0 = _conn()
    c0.execute("DELETE FROM users WHERE username=?", ("smoke_tmp",))
    c0.commit()
    token, _, _ = create_token(row["id"])
    H = {"Authorization": f"Bearer {token}"}
    uid = None
    with httpx.Client(timeout=15) as c:
        r = c.get(f"{BASE}/api/auth/me", headers=H)
        check("GET /api/auth/me（admin token）", r.status_code == 200 and r.json().get("username") == "admin", str(r.status_code))

        r = c.post(f"{BASE}/api/auth/register", json={"username": "evil", "password": "123456"})
        check("POST /api/auth/register 已下线", r.status_code == 405, str(r.status_code))

        r = c.post(f"{BASE}/api/auth/login", json={"username": "anonymous", "password": "whatever"})
        check("anonymous 占位行登录被拒", r.status_code == 401, str(r.status_code))

        r = c.post(f"{BASE}/api/auth/users", json={"username": "smoke_tmp", "password": "123456"})
        check("POST /api/auth/users（无 token）", r.status_code == 401, str(r.status_code))

        r = c.post(f"{BASE}/api/auth/users", json={"username": "smoke_tmp", "password": "123456"}, headers=H)
        check("POST /api/auth/users（admin 建号）", r.status_code == 201, str(r.status_code))
        uid = r.json().get("id") if r.status_code == 201 else None

        r = c.post(f"{BASE}/api/auth/login", json={"username": "smoke_tmp", "password": "123456"})
        ok_login = r.status_code == 200
        check("新账号以初始密码 123456 登录", ok_login, str(r.status_code))

        if ok_login:
            t2 = r.json()["access_token"]
            r = c.post(f"{BASE}/api/auth/users", json={"username": "smoke_tmp2", "password": "123456"},
                       headers={"Authorization": f"Bearer {t2}"})
            check("POST /api/auth/users（普通用户被拒）", r.status_code == 403, str(r.status_code))

        probe = _version_probe()
        if probe:
            kind, name = probe
            r = c.get(f"{BASE}/api/admin/versions", params={"kind": kind, "name": name}, headers=H)
            ok_list = r.status_code == 200
            check(f"GET /api/admin/versions（{kind}/{name}）", ok_list, str(r.status_code))
            if ok_list:
                versions = r.json().get("versions") or []
                if versions:
                    vf = versions[0]["file"]
                    r = c.get(f"{BASE}/api/admin/versions/diff", params={"kind": kind, "name": name, "version_file": vf}, headers=H)
                    ok_diff = r.status_code == 200 and "diff" in r.json()
                    n = len(r.json().get("diff", "")) if ok_diff else 0
                    check(f"GET /api/admin/versions/diff（{kind}/{name} 真实版本）", ok_diff, f"{str(r.status_code)} {n} 字符")
        else:
            r = c.get(f"{BASE}/api/admin/versions/diff",
                      params={"kind": "sql", "name": "smoke", "version_file": "no.sql"}, headers=H)
            check("GET /api/admin/versions/diff（无版本时 404 探测）", r.status_code == 404, str(r.status_code))

        r = c.get(BASE)
        check("前端首页", r.status_code == 200 and "html" in r.headers.get("content-type", ""), str(r.status_code))

        if uid:
            r = c.delete(f"{BASE}/api/auth/users/{uid}", headers=H)
            check("清理 smoke_tmp（DELETE /api/auth/users/{id}）", r.status_code in (200, 204), str(r.status_code))

    print(f"\n{'全部通过' if not FAILED else '失败项：' + ', '.join(FAILED)}（共 {len(FAILED)} 失败）")
    return 1 if FAILED else 0


if __name__ == "__main__":
    raise SystemExit(main())

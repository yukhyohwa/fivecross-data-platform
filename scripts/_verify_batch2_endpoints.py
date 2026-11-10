# -*- coding: utf-8 -*-
"""批次2-4 端点/模块探针 v2：下载端点、rename 闭环、分页、模型注册、export_artifacts 冒烟。

运行：cwd=data_ai，用真实解释器（不加 -I：httpx 等在用户 site-packages）。
不打印任何凭证值。
"""
import json
import os
import sys
import time
from decimal import Decimal

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import httpx

# 导入即设置 sys.path（含 analysis 包），与 main.py 同机制
import backend.config  # noqa: F401

from backend.ide_app.core.auth import create_token
from backend.services.export_artifacts import deliver_artifact, EXPORT_ROOT

BASE = "http://127.0.0.1:8000"
ADMIN_ID = "77577f56-356"

access, _refresh, _exp = create_token(ADMIN_ID)
H = {"Authorization": f"Bearer {access}"}
ok_all = True


def check(name, cond, detail=""):
    global ok_all
    mark = "PASS" if cond else "FAIL"
    if not cond:
        ok_all = False
    print(f"[{mark}] {name} {detail}")


def main():
    with httpx.Client(base_url=BASE, headers=H, timeout=30) as c:
        # 1) chat-history 分页
        r = c.get("/api/chat-history", params={"limit": 30, "offset": 0})
        check("chat-history 分页 status=200", r.status_code == 200, f"status={r.status_code}")
        d = r.json()
        sess = d.get("sessions")
        check("返回含 sessions/total/truncated", isinstance(sess, list) and "total" in d and "truncated" in d,
              f"keys={sorted(d.keys())} total={d.get('total')} truncated={d.get('truncated')}")
        check("limit 生效（<=30）", len(sess) <= 30, f"len={len(sess)}")

        # 2) rename 闭环：创建 → 改名 → 校验 → 还原 → 删除
        created = c.post("/api/chat-history", json={
            "title": "探针-rename-测试会话",
            "messages": [{"role": "user", "text": "hello"}, {"role": "assistant", "text": "hi"}],
        })
        check("创建会话 status=200", created.status_code == 200, f"status={created.status_code} body={created.text[:120]}")
        sid = created.json().get("sid") or created.json().get("id")
        if sid:
            r2 = c.put(f"/api/chat-history/{sid}/rename", json={"title": "探针-改后标题"})
            check("rename status=200 且 ok", r2.status_code == 200 and r2.json().get("ok") is True,
                  f"status={r2.status_code} body={r2.text[:120]}")
            r2v = c.get(f"/api/chat-history/{sid}")
            check("改名已生效", r2v.status_code == 200 and r2v.json().get("title") == "探针-改后标题",
                  f"title={r2v.json().get('title') if r2v.status_code == 200 else r2v.status_code}")
            r2b = c.put(f"/api/chat-history/{sid}/rename", json={"title": "x" * 60})
            print(f"  (info) 超长 60 字符 rename: status={r2b.status_code} body={r2b.text[:120]}")
            r2c = c.delete(f"/api/chat-history/{sid}")
            check("清理删除会话", r2c.status_code == 200, f"status={r2c.status_code}")
        else:
            check("创建会话返回 sid", False, f"body={created.text[:200]}")

        # 3) 无 token：AUTH_ENABLED=false 时匿名回落是既定行为，仅报告
        r3 = httpx.get(BASE + "/api/chat-history", timeout=30)
        print(f"  (info) 无 token 访问 chat-history: status={r3.status_code}（AUTH_ENABLED=false 本地模式匿名回落）")

        # 4) 下载端点
        r4 = c.get("/api/agent/artifacts/abcd1234efab/download")
        check("下载端点 合法id不存在→404", r4.status_code == 404, f"status={r4.status_code} body={r4.text[:60]}")
        r4b = c.get("/api/agent/artifacts/" + "a" * 100 + "/download")
        check("下载端点 超长 id→400", r4b.status_code == 400, f"status={r4b.status_code} body={r4b.text[:60]}")
        r4c = c.get("/api/agent/artifacts/..%2F..%2Fetc/download")
        check("下载端点 穿越格式 id 非 200", r4c.status_code != 200, f"status={r4c.status_code}")

        # 5) 模型列表含新注册模型
        r5 = c.get("/api/admin/models")
        check("模型列表 status=200", r5.status_code == 200, f"status={r5.status_code}")
        body = r5.json()
        models = body.get("models") if isinstance(body, dict) else body
        names = [m.get("name") for m in models]
        check("模型列表含 joytools_留存预测", "joytools_留存预测" in names, f"names={names}")
        for m in models:
            if m.get("name") == "joytools_留存预测":
                meta = m.get("meta") or {}
                check("新模型 level=通用", meta.get("level") == "通用", f"meta={meta}")
                check("新模型 input=upload（无绑定 SQL，无快照）", meta.get("input") == "upload", f"input={meta.get('input')}")

        # 6) SSRF：保存闸门 400 + 不落库（不打印 api_key 等凭证字段，只比 api_base）
        r6 = c.put("/api/agent/config", json={"api_key": "probe-x", "model": "deepseek-chat",
                                              "api_base": "http://169.254.169.254/latest/meta-data"})
        check("保存云元数据 api_base→400", r6.status_code == 400, f"status={r6.status_code} body={r6.text[:80]}")
        r6b = c.put("/api/agent/config", json={"api_key": "probe-x", "model": "deepseek-chat",
                                               "api_base": "http://127.0.0.1:8000/v1"})
        check("保存回环 api_base→400", r6b.status_code == 400, f"status={r6b.status_code}")
        g = c.get("/api/agent/config")
        gb = g.json() if g.status_code == 200 else {}
        check("被拒 base 未落库", gb.get("api_base") not in ("http://169.254.169.254/latest/meta-data", "http://127.0.0.1:8000/v1"),
              f"stored api_base={gb.get('api_base')!r}")


def smoke_export():
    print("\n--- export_artifacts 冒烟（进程内）---")
    import openpyxl

    sheets = [{
        "name": "冒烟表",
        "columns": ["big", "money", "mixed", "formula", "normal"],
        "rows": [
            [10 ** 16, Decimal("1234.56"), 1, "=cmd()", "a"],
            [123, Decimal("0.105"), "text", "-hello", "b"],
            [456, Decimal("7"), 2, "@x", "c"],
            [789, None, 3, "+y", "d"],
        ],
    }]
    res = deliver_artifact(sheets, fmt="xlsx", subject="冒烟-导出")
    check("deliver 返回非空信封", bool(res.get("file_name")) and bool(res.get("download_url")),
          f"file_name={res.get('file_name')} url={res.get('download_url')}")
    aid = res["download_url"].rstrip("/download").split("/")[-1]
    xlsx_path = EXPORT_ROOT / "anonymous" / f"{aid}.xlsx"
    check("xlsx 已落盘 anonymous 目录", xlsx_path.exists(), f"path={xlsx_path}")
    if xlsx_path.exists():
        wb = openpyxl.load_workbook(xlsx_path)
        ws = wb.active
        got = [[ws.cell(row=rr, column=cc) for cc in range(1, 6)] for rr in range(2, 6)]
        check("大整数转文本", isinstance(got[0][0].value, str) and got[0][0].value == str(10 ** 16), f"got={got[0][0].value!r}")
        check("Decimal 数值保留两位", float(got[0][1].value) == 1234.56, f"got={got[0][1].value!r}")
        check("公式前缀= 存为文本格非公式", got[0][3].data_type == "s" and got[0][3].value == "=cmd()",
              f"data_type={got[0][3].data_type!r} value={got[0][3].value!r}")
        check("混型列全文本", isinstance(got[0][2].value, str) and isinstance(got[1][2].value, str),
              f"got={got[0][2].value!r}/{got[1][2].value!r}")
        for p in [xlsx_path, xlsx_path.with_suffix(".meta.json")]:
            try:
                p.unlink()
            except OSError:
                pass
    # csv 冒烟 + BOM
    res2 = deliver_artifact(sheets, fmt="csv", subject="冒烟-csv")
    check("csv 信封 ok", bool(res2.get("file_name")), f"file_name={res2.get('file_name')}")
    aid2 = res2["download_url"].rstrip("/download").split("/")[-1]
    csv_path = EXPORT_ROOT / "anonymous" / f"{aid2}.csv"
    if csv_path.exists():
        with open(csv_path, "rb") as fh:
            head = fh.read(3)
        check("csv 带 utf-8-sig BOM", head == b"\xef\xbb\xbf", f"head={head!r}")
        for p in [csv_path, csv_path.with_suffix(".meta.json")]:
            try:
                p.unlink()
            except OSError:
                pass
    # 空结果 → empty 信封不落盘
    res3 = deliver_artifact([{"name": "空", "columns": ["a"], "rows": []}], fmt="xlsx", subject="空导出")
    check("空结果 empty=True 且无 download_url", res3.get("empty") is True and not res3.get("download_url"),
          f"res={res3}")
    # 清理上轮遗留（anonymous 目录内所有本次未删除文件）
    adir = EXPORT_ROOT / "anonymous"
    if adir.is_dir():
        for p in adir.iterdir():
            try:
                p.unlink()
            except OSError:
                pass


def smoke_model():
    print("\n--- 预测模型注册冒烟（进程内）---")
    from backend.services import forecast
    from analysis import code_store
    caps = forecast.load_external_capabilities()
    names = list(caps.keys())
    check("load_external_capabilities 发现 joytools_留存预测", "joytools_留存预测" in names, f"names={names}")
    # run() 冒烟：30 天留存衰减序列（upload 型能力无 func，直接经 load_func_from_code 加载代码）
    import pandas as pd
    days = list(range(1, 31))
    ret = [0.42 * (d ** -0.55) * (0.985 ** d) for d in days]
    df = pd.DataFrame({"留存天数": days, "留存率": ret})
    fn = forecast.load_func_from_code("joytools_留存预测", code_store.read_code("joytools_留存预测"))
    if callable(fn):
        try:
            out = fn(df, "2026-10-16")
            tables = out.get("tables") or []
            check("run() 返回 tables 非空", len(tables) > 0, f"tables={len(tables)}")
            print(f"  (info) run 返回 meta={json.dumps(out.get('meta'), ensure_ascii=False)[:300]}")
        except Exception as e:
            check("run() 不抛异常", False, f"err={type(e).__name__}: {e}")
    else:
        check("load_func_from_code 能加载 run", False, f"fn={fn!r}")


def smoke_cancel():
    print("\n--- cancel 归属校验冒烟（进程内）---")
    from backend.services import agent_deep as d
    d.register_run("probe_run_a", "ownerA")
    check("越权取消返回 None", d.request_cancel("probe_run_a", "ownerB") is None)
    check("不存在 run 返回 None", d.request_cancel("probe_run_zz", "ownerA") is None)
    check("归属匹配取消 True", d.request_cancel("probe_run_a", "ownerA") is True)
    d.unregister_run("probe_run_a")
    check("unregister 后返回 None", d.request_cancel("probe_run_a", "ownerA") is None)


if __name__ == "__main__":
    main()
    smoke_export()
    smoke_model()
    smoke_cancel()
    print("\nRESULT:", "ALL PASS" if ok_all else "HAS FAIL")
    sys.exit(0 if ok_all else 1)

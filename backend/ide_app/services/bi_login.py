"""BI 平台飞书扫码登录 — Playwright 浏览器自动化抓取 JWT token。

流程：
  1. 后台线程启动 headless Chromium，打开 BI/飞书登录页（展示二维码）。
  2. 循环：整页截图存 PNG（供前端展示二维码）+ 跨所有 frame 轮询 token。
  3. 扫码后可能跳授权（consent）页 → 自动点击「授权/同意/允许」按钮（遍历所有 frame）。
  4. JWT 落 localStorage/sessionStorage → 命中即回调 on_token 存库。

若 Playwright 未安装，PLAYWRIGHT_AVAILABLE=False，start() 会立即置 error 状态。
"""

import re
import threading
import time

try:
    from playwright.sync_api import sync_playwright

    PLAYWRIGHT_AVAILABLE = True
except Exception:  # pragma: no cover - 未安装 playwright
    PLAYWRIGHT_AVAILABLE = False

_JWT_RE = re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")

# 在 frame 的 localStorage + sessionStorage 里找形如 JWT 的值
_JS_FIND_JWT = r"""() => {
    const re = /eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/;
    for (const store of [localStorage, sessionStorage]) {
        for (let i = 0; i < store.length; i++) {
            const k = store.key(i);
            const v = store.getItem(k);
            if (v && re.test(v)) {
                const m = v.match(re);
                if (m) return m[0];
            }
        }
    }
    return null;
}"""

# 授权/同意 按钮文本（用于扫码后的 consent 页自动点击）
_BTN_RE = re.compile(r"^(Authorize|授权)$", re.I)
_BTN_SELECTOR = "button, a, [role='button'], .feishu-button, .larkui-button"


def _find_token(page):
    """跨所有 frame 找 JWT token。"""
    for f in page.frames:
        try:
            t = f.evaluate(_JS_FIND_JWT)
            if t:
                return t
        except Exception:
            continue
    return None


def _click_authorize(page) -> str:
    """跨所有 frame 尝试点击授权按钮，返回命中的按钮文本（没点则空串）。"""
    for f in page.frames:
        try:
            els = f.locator(_BTN_SELECTOR, has_text=_BTN_RE)
            n = els.count()
            for i in range(n):
                try:
                    txt = (els.nth(i).inner_text() or "").strip()
                    els.nth(i).click(timeout=1000)
                    return txt[:40]
                except Exception:
                    continue
        except Exception:
            continue
    return ""


class QrLoginSession:
    """一次扫码登录会话。on_token(token) 在抓到 token 时回调（用于存库）。"""

    def __init__(self, base_url: str, on_token):
        self.base_url = base_url
        self.on_token = on_token
        self.state = "starting"  # starting | waiting_scan | done | timeout | error
        self.message = ""
        self.png_bytes = None
        self.token = None
        # 诊断信息：页面地址 / frames / 最近命中的按钮文本
        self.page_url = ""
        self.frame_urls = []
        self.btn_hint = ""
        self._thread = None

    def start(self):
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        if not PLAYWRIGHT_AVAILABLE:
            self.state = "error"
            self.message = "Playwright 未安装，请用 pip install playwright && playwright install chromium"
            return
        try:
            with sync_playwright() as p:
                browser = p.chromium.launch(headless=True)
                page = browser.new_page(viewport={"width": 1280, "height": 900})
                # 保留 base_url 为兜底（已配置则优先），否则用飞书登录页
                # url = self.base_url or (
                #     "https://accounts.feishu.cn/accounts/page/login?app_id=12&no_trap=1"
                #     "&redirect_uri=https%3A%2F%2Fopen.feishu.cn%2Fopen-apis%2Fauthen%2Fv1"
                #     "%2Findex%3Fapp_id%3Dcli_a6c72eaa3d6b5013%26redirect_uri%3Dhttps%253A"
                #     "%252F%252Fjoy.123u.com%252Flogin%253Fredirect%253D%252Fguide"
                # )
                url = ("https://accounts.feishu.cn/accounts/page/login?app_id=12&no_trap=1"
                    "&redirect_uri=https%3A%2F%2Fopen.feishu.cn%2Fopen-apis%2Fauthen%2Fv1"
                    "%2Findex%3Fapp_id%3Dcli_a6c72eaa3d6b5013%26redirect_uri%3Dhttps%253A"
                    "%252F%252Fjoy.123u.com%252Flogin%253Fredirect%253D%252Fguide")
                page.goto(url, timeout=30000, wait_until="domcontentloaded")
                self.state = "waiting_scan"
                deadline = time.time() + 180
                while time.time() < deadline:
                    # 记录诊断信息，便于排查
                    try:
                        self.page_url = page.url
                        self.frame_urls = [f.url for f in page.frames]
                    except Exception:
                        pass
                    # 扫码后可能先跳授权（consent）页 → 自动点击授权按钮
                    self.btn_hint = _click_authorize(page) or self.btn_hint
                    try:
                        self.png_bytes = page.screenshot()
                    except Exception:
                        self.png_bytes = None
                    token = _find_token(page)
                    if token:
                        self.token = token
                        try:
                            self.on_token(token)
                        except Exception as e:
                            self.state = "error"
                            self.message = f"token 存库失败: {e}"
                            browser.close()
                            return
                        self.state = "done"
                        browser.close()
                        return
                    time.sleep(2)
                self.state = "timeout"
                self.message = "等待扫码超时（180s），请重试"
                browser.close()
        except Exception as e:
            self.state = "error"
            self.message = str(e)

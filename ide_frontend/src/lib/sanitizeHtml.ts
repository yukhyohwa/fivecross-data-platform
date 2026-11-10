/**
 * 零依赖 HTML 清理：渲染 AI/用户 Markdown（marked.parse 输出）或通知正文前调用，
 * 防止 dangerouslySetInnerHTML 注入 <script>/事件属性/javascript: 链接。
 *
 * 用浏览器原生 DOMParser 走真实解析树，比正则可靠；白名单思路：
 * 移除危险元素 + 移除所有 on* 事件属性 + 移除 javascript:/data:/vbscript: 协议属性。
 */
export function sanitizeHtml(html: string): string {
  if (!html) return '';
  const doc = new DOMParser().parseFromString(html, 'text/html');
  const FORBIDDEN = new Set([
    'script', 'style', 'iframe', 'object', 'embed', 'form',
    'link', 'meta', 'base', 'svg', 'math', 'template', 'noscript', 'video', 'audio',
  ]);
  doc.querySelectorAll('*').forEach((el) => {
    const tag = el.tagName.toLowerCase();
    if (FORBIDDEN.has(tag)) {
      el.remove();
      return;
    }
    Array.from(el.attributes).forEach((a) => {
      const name = a.name.toLowerCase();
      if (name.startsWith('on')) {
        el.removeAttribute(a.name);
      } else if (
        (name === 'href' || name === 'src' || name === 'xlink:href' || name === 'action' || name === 'formaction') &&
        /^\s*(javascript|data|vbscript):/i.test(a.value)
      ) {
        el.removeAttribute(a.name);
      }
    });
  });
  return doc.body.innerHTML;
}

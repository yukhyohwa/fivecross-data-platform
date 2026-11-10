// XSS 防护：marked 4.x 不消毒，直接把 AI 回答 / 报告 / 历史 markdown 塞进 innerHTML
// 会执行其中的恶意 HTML（数据库值被模型回显时尤其危险）。这里统一走 DOMPurify 过滤。
// 依赖加载顺序：vendor/marked.min.js -> vendor/dompurify.min.js -> 本文件。

// 禁用删除线：AI 生成的正文里 ~ 常是「约/区间」的近似记号，并非 markdown 的 ~~删除线~~，
// 被 marked 解析成 <del> 会把中间内容划掉。两处兜底：
//   1) 重写 del 渲染器：~~text~~ / ~text~ 直接透传内容，不生成 <del>；
//   2) DOMPurify 额外禁 <del>/<s>/<strike>，防止 AI 直接输出原生 HTML 删除线标签。
// marked 加载失败时不注册渲染器，sanitizeHtml 会 fail-closed 返回空串。
if (typeof marked !== 'undefined' && marked.use) {
  marked.use({
    renderer: {
      del: function (text) { return text; }
    }
  });
}

function sanitizeHtml(markdown) {
  // fail-closed：marked 或 DOMPurify 任一加载失败，宁可渲染失败也绝不把未消毒 HTML 塞进 innerHTML（防 XSS）
  if (typeof marked === 'undefined' || !window.DOMPurify) {
    console.error('[sanitize] marked/DOMPurify 未加载，已阻断本次 markdown 渲染以防范 XSS');
    return '';
  }
  const html = marked.parse(markdown == null ? '' : String(markdown));
  return DOMPurify.sanitize(html, { FORBID_TAGS: ['del', 's', 'strike'] });
}

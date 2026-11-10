/* 主题同步：跟随 React 壳的 localStorage['sql-ide-theme']（'dark'/'light'）。
   把 .dark 类挂到 <html>，并监听 storage 事件在壳切换主题时实时同步（iframe 同源共享 localStorage）。
   在各页面 <head> 中同步执行，避免 iframe 首帧闪白。 */
(function () {
  var KEY = 'sql-ide-theme';
  function apply() {
    var t = null;
    try { t = localStorage.getItem(KEY); } catch (e) {}
    var dark = t !== 'light'; // 默认 dark，与 React 壳 ThemeProvider 的默认值一致
    var root = document.documentElement;
    if (dark) { root.classList.add('dark'); } else { root.classList.remove('dark'); }
  }
  apply();
  window.addEventListener('storage', function (e) {
    if (e.key === KEY || e.key === null) { apply(); }
  });
})();

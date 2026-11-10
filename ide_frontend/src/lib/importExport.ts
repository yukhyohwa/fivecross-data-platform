/**
 * JSON 文件导入/导出工具函数
 */

/**
 * 触发浏览器下载 JSON 文件
 */
export function downloadJson(data: any, filename: string) {
  const json = JSON.stringify(data, null, 2);
  const blob = new Blob([json], { type: 'application/json;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

/**
 * 打开文件选择器，解析并返回 JSON 内容
 * @returns 解析后的 JSON 对象，取消或失败时返回 null
 */
export function pickJsonFile(): Promise<any | null> {
  return new Promise((resolve) => {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = '.json';
    input.onchange = async (e: Event) => {
      const file = (e.target as HTMLInputElement).files?.[0];
      if (!file) { resolve(null); return; }
      try {
        const text = await file.text();
        const parsed = JSON.parse(text);
        resolve(parsed);
      } catch (err) {
        alert('JSON 文件格式错误: ' + (err as Error).message);
        resolve(null);
      }
    };
    // 用户取消选择
    input.oncancel = () => resolve(null);
    input.click();
  });
}

/**
 * 生成标准导出文件名
 */
export function exportFilename(type: string): string {
  const date = new Date().toISOString().slice(0, 10);
  return `${type}_export_${date}.json`;
}

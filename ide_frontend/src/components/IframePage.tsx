import React from 'react';

/** 轻量 iframe 容器：占满内容区，嵌入 data_ai vanilla 页面（/app/*）。
 *  `reloadKey` 变化 → 重新挂载 iframe（游戏切换后刷新页面、重取数据）。 */
export const IframePage: React.FC<{
  src: string;
  reloadKey?: number;
}> = ({ src, reloadKey = 0 }) => {
  return (
    <iframe
      key={`${src}-${reloadKey}`}
      src={src}
      title="data_ai"
      allow="clipboard-read; clipboard-write"
      style={{ width: '100%', height: '100%', border: 'none', display: 'block' }}
    />
  );
};

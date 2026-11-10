import React from 'react';

const SkeletonLines: React.FC<{ count?: number }> = ({ count = 5 }) => (
  <div style={{ padding: 12 }}>
    {Array.from({ length: count }).map((_, i) => (
      <div key={i} style={{
        height: 14, marginBottom: 10, borderRadius: 4, backgroundColor: 'var(--surface-heavy)',
        width: `${60 + i * 8}%`, animation: 'skeleton-pulse 1.5s ease-in-out infinite',
      }} />
    ))}
  </div>
);

export default SkeletonLines;

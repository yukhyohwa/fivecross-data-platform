# ---- 构建阶段 ----
FROM node:20-alpine AS build

WORKDIR /app

# 安装依赖
COPY package.json ./
RUN npm config set registry https://registry.npmmirror.com \
    && npm install

# 复制源码并构建
COPY . .
ARG VITE_API_BASE=
ENV VITE_API_BASE=$VITE_API_BASE

# VITE_API_BASE 为空时走相对路径，由 nginx 反代 /api/ 到后端（同源无跨域）
RUN npm run build

# ---- 运行阶段 ----
FROM nginx:alpine

COPY --from=build /app/dist /usr/share/nginx/html

# Nginx 配置
# - SPA fallback: 非文件路由回退到 index.html
# - /api/ 代理到后端 backend:28000（Docker bridge DNS）
# - proxy_buffering off: SSE 流式响应不缓冲
# - proxy_read_timeout 600s: Agent 长对话超时保护
RUN printf 'server { \n\
  listen 25173; \n\
  root /usr/share/nginx/html; \n\
  index index.html; \n\
  \n\
  # 允许大请求体（图片 base64 上传，默认 1m 会 413） \n\
  client_max_body_size 20m; \n\
  \n\
  # SPA fallback \n\
  location / { \n\
    try_files $uri $uri/ /index.html; \n\
  } \n\
  \n\
  # API 反代到后端 \n\
  location /api/ { \n\
    proxy_pass http://backend:28000/api/; \n\
    proxy_set_header Host $host; \n\
    proxy_set_header X-Real-IP $remote_addr; \n\
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; \n\
    proxy_set_header X-Forwarded-Proto $scheme; \n\
    proxy_set_header X-Forwarded-Host $host; \n\
    proxy_http_version 1.1; \n\
    proxy_connect_timeout 30s; \n\
    proxy_read_timeout 600s; \n\
    proxy_send_timeout 600s; \n\
    proxy_buffering off; \n\
  } \n\
  \n\
  # Gzip 压缩 \n\
  gzip on; \n\
  gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript image/svg+xml; \n\
  gzip_min_length 1000; \n\
}' > /etc/nginx/conf.d/default.conf

EXPOSE 25173

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -q --spider http://localhost:25173/ || exit 1

CMD ["nginx", "-g", "daemon off;"]

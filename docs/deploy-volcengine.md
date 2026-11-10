# 部署到火山云服务器（JumpServer 上传方式）

目标服务器：`huanle@da-vc-sh-joytools-10-68-31-76`（火山云 ECS，经 JumpServer 访问）。
本仓库：`https://git-intra.123u.com/hanqiding/data_ai`（主分支 `main`）。

> 本文全部事实均对照代码核实（2026-10-21）：全新库自动建管理员（backend/ide_app/migrations.py）、
> JWT 密钥必须显式配置（backend/ide_app/core/auth.py）、活库在仓库根（backend/ide_app/services/db_service.py）。

---

## 0. 两大前置连通性（决定成败，先确认再动手）

| 依赖 | 检查方式 | 不通的后果 |
|---|---|---|
| **数据仓库**（StarRocks/MySQL，`db_config.ini` 或 `DB_HOST/DB_PORT/DB_USER/DB_PASSWORD/DB_NAME`） | 服务器上 `mysql -h <host> -P <port> -u <user> -p` 或 `nc -vz <host> <port>` | 取数全失败 |
| **LLM 网关**（`.env` 里的 `LITELLM_BASE_URL` / `OPENAI_API_KEY`，内部 LiteLLM，OpenAI 兼容） | 服务器上 `curl -v <LITELLM_BASE_URL>` | AI 生成全失败（SQL/报告/深度分析） |
| **指标标签 MySQL**（可选：`.env` 里 `MYSQL_MAIN_HOST/USER/PASSWORD/DATABASE/PORT`） | 不配则启动日志 `[quota_tags] ensure failed (non-fatal): Can't connect to MySQL on 'localhost'` | 看板指标标签/指标说明功能不可用（不影响取数与聊天） |

服务器主机名带 `joytools`（内网机），大概率与数据/网关同内网、直接可通；若是公网 ECS 则需要数据侧开通白名单或走内网打通。**先确认这两点再继续。**

## 1. 服务器初始化

```bash
# ⚠️ 硬约束：Python 3.10+（代码用了 str | None / list | None 语法，3.9 启动直接 TypeError:
#   unsupported operand type(s) for |: 'type' and 'NoneType'）
python3 --version
# Rocky/CentOS 系系统自带的是 3.9 —— 装 AppStream 里的 3.11（yum/dnf 源里都有）：
sudo dnf install -y python3.11 python3.11-pip python3.11-devel
python3.11 --version     # 之后建 venv 都用这个解释器，别再用默认 python3

# 基础件：git（方式 A 用）、venv 与 pip 支撑包（Ubuntu/Debian 缺 python3-venv 会直接失败）
sudo apt install -y git python3-venv python3-pip        # 或 CentOS/Rocky：sudo dnf install -y git python3-pip

# 时区：取数按 dteventtime+服务器时区换算口径、每日备份 daemon 也按本地时间触发
sudo timedatectl set-timezone Asia/Shanghai

# 磁盘余量（/opt 代码+SQLite+聊天记录、/backup 备份都在增长，建议预留 ≥10G）
df -h /opt

# 建运行用户（不建议 root 直接跑）
sudo useradd -m -s /bin/bash dataai

# 部署目录
sudo mkdir -p /opt/data_ai && sudo chown dataai:dataai /opt/data_ai
```

## 2. 代码上传（二选一）

**方式 A：git clone（推荐，之后更新省事）**——前提是服务器能访问 `git-intra.123u.com`（内网一般可以）。

**A1：SSH deploy key clone**（先测 `sudo -u dataai ssh -o StrictHostKeyChecking=accept-new git@git-intra.123u.com true`；
报 Connection reset = 这台 GitLab 没开 SSH，直接用 A2）。通的话，按 9.2① 给 dataai 生成 deploy key 并贴到 GitLab（只读权限），然后：

```bash
cd /opt && sudo -u dataai git clone git@git-intra.123u.com:hanqiding/data_ai
```

**A2：HTTPS deploy token clone**——GitLab 没开 SSH（`ssh git@... true` 报 Connection reset）时用。
GitLab 项目页 Settings → Repository → **Deploy tokens** → 新建（Scopes 只勾 `read_repository`，
创建后 token 只显示一次，立刻复制）：

```bash
# credential store：凭据只进 /home/dataai/.git-credentials（600，dataai 私有），
# 不留在 .git/config 里；之后自动更新的 fetch 自动从这里取凭据
sudo -u dataai git config --global credential.helper store
# ⚠️ URL 里的「用户名」不是 token 的 Name，而是 Deploy tokens 列表里的 Username 列
# （默认格式 gitlab+deploy-token-{n}）。填 Name 会报 HTTP Basic: Access denied。
cd /opt && sudo -u dataai git clone https://<Username列的值>:<token>@git-intra.123u.com/hanqiding/data_ai
# 抹掉 URL 里的凭据，换成干净地址（凭据已在 store 里，不影响后续 fetch）
sudo -u dataai git -C /opt/data_ai remote set-url origin https://git-intra.123u.com/hanqiding/data_ai.git
sudo -u dataai git -C /opt/data_ai fetch   # 验证免密拉取
```

> **为什么不留 token 在 URL 里**：token URL 会明文写进 `.git/config`，任何能读该文件的人
> 都可冒用这个 GitLab 凭据。deploy token 只读、可随时吊销，配 store 后 fetch 照常免密。

**方式 B：JumpServer 上传**——本地打包 zip（**排除 `.venv/`、`__pycache__/`、`node_modules/`**，Windows 的 venv 打到 Linux 无用），
JumpServer 文件管理上传到服务器后：

```bash
# 解压到临时目录 → 复制内容进 /opt/data_ai → 统一属主（sudo unzip 解出的文件属 root，不 chown 后面全报 PermissionError）
sudo unzip data_ai.zip -d /tmp/upload/
sudo cp -a /tmp/upload/data_ai/* /opt/data_ai/
sudo chown -R dataai:dataai /opt/data_ai
```

> `.env`、`db_config.ini` 排除在 git 之外，上传文件夹不会带它们——见下一步单独放。
> `ide_frontend/dist` 已入库，服务器**不需要 Node** 构建前端。

## 3. 密钥与连接配置

```bash
cd /opt/data_ai
sudo -u dataai vi .env
```

`.env` 内容（至少这几项）：

```ini
# 1) LLM 网关（从本地复制值）
OPENAI_API_KEY=...
LITELLM_BASE_URL=...
DEFAULT_MODEL=...

# 2) JWT 密钥：必须显式设置！不设则每次重启随机生成（auth.py 会打印警告），
#    所有已登录用户登录态全部失效。生成：openssl rand -hex 32
JWT_SECRET_KEY=<openssl rand -hex 32 的输出>

# 3) 鉴权开关：先不写（默认 false=匿名可用）。改完 admin 初始密码后再置 true 重启。
# AUTH_ENABLED=true

# 4) Joydata 连接回调（可选但推荐）：显式声明本系统公网地址，Joydata OAuth 回调就不走
#    Host 白名单推断。代码默认已放行 joydata_ai.123u.com（JOYDATA_ALLOWED_HOSTS 默认值），
#    换域名部署时必配此项，否则「连接 Joydata」会报「未识别的主机」。
# JOYDATA_PUBLIC_BASE=https://joydata_ai.123u.com
```

```bash
# 数据库连接（二选一）
sudo -u dataai vi db_config.ini          # [database] host/port/user/password/database
# 或写进 systemd 的 Environment=（DB_HOST/DB_PORT/DB_USER/DB_PASSWORD/DB_NAME）

# 两个文件都是明文凭据，收归 600（同机其他账号不可读）
sudo chmod 600 /opt/data_ai/.env /opt/data_ai/db_config.ini
```

其余**不需要手工准备**（首次启动自动生成/建库）：

| 文件 | 说明 |
|---|---|
| `ide_data.db`（**仓库根目录**，不是 backend/ 下） | 账户/RBAC/记忆/指标 SQLite 库。**全新部署自动建库**；迁移老数据才复制（须连同 encryption.key 一起）。注意：backend/ide_data.db 是历史遗留孤儿文件，勿被它误导 |
| `data/.sql-ide/encryption.key` | Fernet 密钥（个人 LLM Key 加密用）。**全新部署自动生成**；只有「迁移已有库」才需要从老机器整套复制 |
| `backups/`（仓库根） | 应用内建每日备份 daemon 的产物目录，自动轮转 |

## 4. 安装依赖并试跑

```bash
cd /opt/data_ai
sudo -u dataai python3.11 -m venv .venv     # 必须 ≥3.10 的解释器（见第 1 节），系统默认 python3 是 3.9 会 TypeError
# 内网机无外网 PyPI 时配内网源：
#   sudo -u dataai .venv/bin/pip config set global.index-url <内网 pip 源>
sudo -u dataai .venv/bin/pip install -r requirements.txt

# 前台试跑（确认能启动、无 import 错误）
sudo -u dataai .venv/bin/python -m uvicorn backend.main:app --host 0.0.0.0 --port 8000
# 另开窗口健康检查：
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8000/api/admin/sqls   # 期望 200
```

启动成功且能连上数据/网关后，Ctrl+C 停掉，进入下一步。

## 5. 首个管理员（自动创建，登录后立即改密）

**全新库第一次启动时自动创建管理员 `admin`**（users 表为空时 `run_migration` 建号并置 role='admin'，
启动时 seed_identities 自动归入 dev_admin 身份 = 全量权限点含 system，无需任何手工引导）。
初始口令是迁移逻辑硬编码的默认值，见 `backend/ide_app/migrations.py` 的 `run_migration()`（本文不重复打印）。
**登录后第一件事就是改密**：

```bash
# 登录（/api/auth/login 不依赖 AUTH_ENABLED，匿名模式同样可用）
TOKEN=$(curl -s -X POST http://127.0.0.1:8000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"<初始口令，见 migrations.py>"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# 改密（≥6 位）
curl -s -X PUT http://127.0.0.1:8000/api/auth/change-password \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"old_password":"<初始口令>","new_password":"<新口令>"}'
```

之后二选一：

- **保持匿名模式**（`AUTH_ENABLED` 不设）：所有人打开即用，适合纯内网、团队自用的「通用工具」定位。注意匿名请求持有全量权限点，**仅限可信内网**。
- **开启登录**：`.env` 里设 `AUTH_ENABLED=true` 并重启；此后必须登录（账号由 admin 在系统管理 → 用户管理创建，无公开注册）。

## 6. systemd 服务

`/etc/systemd/system/data-ai.service`：

```ini
[Unit]
Description=Data AI (data_ai) FastAPI service
After=network.target

[Service]
User=dataai
WorkingDirectory=/opt/data_ai
ExecStart=/opt/data_ai/.venv/bin/python -m uvicorn backend.main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=3
# 单 worker 是硬约束：应用有进程内存态（运行注册表/锁），--workers N 会串号
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now data-ai
sudo journalctl -u data-ai -f
```

## 7. 网络放行（安全组 + 主机防火墙，缺了这一步外面访问不到）

```bash
# 1) 火山云控制台：该 ECS 的安全组 → 入方向规则 → 放行 TCP 80
#    建议只放内网/堡垒网段（如 10.0.0.0/8），勿对公网全开——
#    匿名模式下 80 对不可信网段开放等于把全量权限点裸奔
# 2) 主机侧防火墙（有则放行）：
sudo firewall-cmd --add-port=80/tcp --permanent && sudo firewall-cmd --reload   # CentOS/Rocky
sudo ufw allow 80/tcp                                                            # Ubuntu
```

## 8. Nginx 反向代理（SSE 必须关 buffering）

把下面配置写到 **`/etc/nginx/conf.d/data-ai.conf`**（nginx.conf 默认 `include conf.d/*.conf`，
放这里即生效；后面第 11 节改域名也是改这个文件）：

```bash
sudo tee /etc/nginx/conf.d/data-ai.conf > /dev/null <<'EOF'
server {
    listen 80;
    server_name _;   # 换成你的域名/IP（见第 11 节）

    client_max_body_size 64m;          # 大 SQL/文件上传

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_buffering off;              # SSE 流式（聊天/深度分析）必须关闭
        proxy_read_timeout 900s;          # 与后端整轮看门狗 900s 对齐
        proxy_send_timeout 900s;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;   # 回传真实协议（后端 Joydata 回调
            # 校验非本机地址必须 https；uvicorn 默认不解析该头，靠 nginx→127.0.0.1 放行兜底，
            # 若将来启用 --proxy-headers 此头即生效）
    }
}
EOF
sudo nginx -t && sudo systemctl reload nginx
```

> 服务器主机名带 `joytools`，可能是共享机器：8000 被占时改 `.service` 与 nginx 里的端口。
> ⚠️ 共享机上 nginx 往往**早已在运行**：`enable --now` 只保证开机自启、**不会重载配置**，
> 写完新 conf 后必须 `sudo systemctl reload nginx`（或 `nginx -s reload`），否则新站点不生效、
> 域名/接口全部 404。无域名访问时（Host 头不匹配 server_name）请求落进系统默认站同样 404，
> 属正常——用域名（或 `curl -H "Host: 域名"`）访问即命中。
> CORS 现状 `allow_origins=["*"]` + Bearer 鉴权，无需 nginx 层处理跨域。
> `server_name` 换成域名的方法见第 11 节。

## 9. 自动更新：本地 push → 服务器自动最新

**目标**：本地 `git push` 后，服务器在数分钟内自动变成最新版本并重启生效。
**验证锚点**：`GET /api/version`（本仓库自带端点，无需鉴权）返回当前 git commit/branch，
服务器上 `curl -s http://127.0.0.1:8000/api/version` 与本地 `git rev-parse --short HEAD` 对比即可确认版本。
返回 `{"available": false}` 表示部署目录不是 git 仓库（zip 上传且没按 9.2 转成 git），自动更新装不上。

### 9.1 先定方案：跑两条测试

| 测试 | 命令（在服务器上） | 结果 → 方案 |
|---|---|---|
| 服务器能否访问内网 GitLab | `curl -sI https://git-intra.123u.com --connect-timeout 5` | 通 → **方案 A**（轮询拉取，推荐） |
| 本地能否 SSH 直连服务器 | 本地 `ssh -o ConnectTimeout=5 huanle@<服务器IP或域名> true` | 通且方案 A 不通 → **方案 B**（push-to-deploy） |

都不通 = 服务器完全到不了代码源 → 退回第 2 节方式 B 手动上传（无自动更新）。

### 9.2 方案 A：服务器轮询拉取（推荐，2 分钟级自动更新）

**① 免密拉取（一次性，二选一）**：

**变体 1：SSH deploy key**。先探测：`sudo -u dataai ssh -o StrictHostKeyChecking=accept-new git@git-intra.123u.com true`
报 Connection reset = 这台 GitLab 没开 SSH（22 端口），直接用变体 2。通的话，GitLab 项目页
Settings → Repository → Deploy keys → 「Add deploy key」，粘贴下面生成的**公钥**（只读，勾掉 write 权限）：

```bash
# 在服务器上生成（dataai 用户；useradd 建的 home 里没有 .ssh，先建目录）
sudo -u dataai mkdir -p /home/dataai/.ssh
sudo -u dataai ssh-keygen -t ed25519 -f /home/dataai/.ssh/id_ed25519 -N ""
sudo cat /home/dataai/.ssh/id_ed25519.pub      # 复制这行到 GitLab deploy key
# 首次连接写入 known_hosts（否则 git 交互问 yes/no 会卡死非交互会话）
sudo -u dataai ssh -o StrictHostKeyChecking=accept-new git@git-intra.123u.com true
```

**变体 2：HTTPS deploy token**。项目页 Settings → Repository → **Deploy tokens** → 新建，
Scopes 只勾 `read_repository`，创建后 token 只显示一次立刻复制：

```bash
sudo -u dataai git config --global credential.helper store   # 凭据只进 ~/.git-credentials（600，dataai 私有）
# ⚠️ 「用户名」= Deploy tokens 列表里的 Username 列（默认 gitlab+deploy-token-{n}），不是 Name
cd /opt && sudo -u dataai git clone https://<Username列的值>:<token>@git-intra.123u.com/hanqiding/data_ai
sudo -u dataai git -C /opt/data_ai remote set-url origin https://git-intra.123u.com/hanqiding/data_ai.git
sudo -u dataai git -C /opt/data_ai fetch   # 验证免密
```

> 首次部署用方式 A clone 过的话，把 `origin` 换成与所选变体一致的地址即可：
> SSH：`git@git-intra.123u.com:hanqiding/data_ai.git`；HTTPS：`https://git-intra.123u.com/hanqiding/data_ai.git`

**② 安装更新脚本与定时器**（本仓库 deploy/ 目录已备好）：

```bash
sudo cp /opt/data_ai/deploy/dataai-update.service /opt/data_ai/deploy/dataai-update.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now dataai-update.timer
```

> service 的 `ExecStart` 直接指向 `/opt/data_ai/deploy/update.sh`（本仓库脚本），**不再 `cp` 到
> `/usr/local/bin`**——改仓库里的 update.sh 并 push 后，服务器下轮自动生效，无需手动重拷。

**③ 验证闭环**（在本地开发机）：

```bash
git commit --allow-empty -m "test: 验证自动更新" && git push origin main
# 服务器上 2~3 分钟后：
curl -s http://127.0.0.1:8000/api/version    # commit 应等于刚推的短哈希
sudo journalctl -u dataai-update -n 20       # 应看到 "deploying ... done"
```

工作方式：`dataai-update.timer` 每 2 分钟跑一次 `update.sh`——fetch → 对比「已成功部署的 commit」
（记录在 `/var/lib/dataai-update/last-deployed` 标记文件，**不是**拿 HEAD 对比）→ 有新提交则
`git reset --hard origin/main`（丢弃服务器对「被跟踪文件」的本地改动，未跟踪文件保留）→
`pip install -r requirements.txt`（幂等，无变更秒过）→ 重启 `data-ai`
（streamlit 若部署为 systemd 单元同启）→ **全部成功才更新标记**。任何一步失败（网络闪断、
依赖装坏、新版本起不来）脚本立即退出、标记不动，下个周期重试整个部署。日志在
`journalctl -u dataai-update`。服务器上的仓库永远只 reset 到远端、不做本地提交，不会因分叉坏掉；
用 reset 而非 `--ff-only` 是因为服务器 App 运行期会写 `chat_history/`、`knowledge/skills/`、`sql/`
这些被跟踪目录，工作树长期不干净，`--ff-only` 会因「本地改动会被覆盖」而卡住部署。

**服务器上运行产物不受影响**：`ide_data.db`、`.env`、`db_config.ini`、`data/`、`backups/` 全部被
`.gitignore` 排除，pull 只动 tracked 文件。

**zip 上传部署（第 2 节方式 B）的用户，先补一步把目录变成 git 仓库**，才能启用本方案：

```bash
cd /opt/data_ai
sudo -u dataai git init
sudo -u dataai git remote add origin https://git-intra.123u.com/hanqiding/data_ai.git   # 地址与 9.2① 所选路线一致
sudo -u dataai git fetch --quiet origin main
sudo -u dataai git reset --hard origin/main          # 用远端内容覆盖解压内容（运行时产物已被 .gitignore 排除，不受影响）
sudo -u dataai git checkout -b main origin/main --force
```

### 9.3 方案 B：git push-to-deploy（本地 push 直达服务器）

服务器到不了 GitLab、但本地能 SSH 直连服务器（22 端口可达）时用。

**权限模型（先看懂再动手）**：推送身份 = **dataai**（不是 huanle/root）。钩子以 dataai 执行，
checkout 进自己的工作树、pip 装进自己的 venv 都不用 sudo；只有两条重启命令需要 sudo，靠
NOPASSWD sudoers 放行。`hooks/` 目录收归 root——dataai 是 Web 服务的运行用户，web 层被攻破时
攻击者改不了钩子、拿不到 root。

**服务器一次性初始化（root 执行）**：

```bash
# ① 裸仓：归 dataai（推送者要写 objects/refs），钩子目录再单独收归 root
sudo mkdir -p /opt/data_ai.git
cd /opt/data_ai.git && sudo git init --bare
sudo chown -R dataai:dataai /opt/data_ai.git
sudo cp /opt/data_ai/deploy/post-receive hooks/post-receive
sudo chmod +x hooks/post-receive
sudo chown -R root:root hooks

# ② dataai 的免密 sudo：只放行两条重启命令（/etc/sudoers.d/dataai-deploy）
sudo tee /etc/sudoers.d/dataai-deploy > /dev/null <<'EOF'
dataai ALL=(root) NOPASSWD: /usr/bin/systemctl restart data-ai, /usr/bin/systemctl restart dataai-streamlit
EOF
sudo chmod 440 /etc/sudoers.d/dataai-deploy

# ③ 开发机公钥放进 dataai 的 authorized_keys（把 <开发机 id_*.pub 内容> 上传到服务器后）：
sudo mkdir -p /home/dataai/.ssh
sudo cp /tmp/id_ed25519.pub /home/dataai/.ssh/authorized_keys   # 路径按上传位置改
sudo chown -R dataai:dataai /home/dataai/.ssh
sudo chmod 700 /home/dataai/.ssh && sudo chmod 600 /home/dataai/.ssh/authorized_keys
```

**本地开发机配置**（可只加 push URL，`git push origin main` 一次推两处：内网留档 + 服务器上线）：

```bash
git remote set-url --add --push origin ssh://dataai@<服务器IP或域名>:/opt/data_ai.git
git push origin main
```

push 即部署：post-receive 钩子检出 main 到 `/opt/data_ai` → 装依赖 → 重启服务。推送日志就是部署日志。
若 push 报错但服务器代码已更新（钩子失败但 refs 已推进的边角情况），按 9.4 手动兜底补完依赖与重启。

### 9.4 手动兜底（自动更新坏了/首次部署时用）

```bash
cd /opt/data_ai && sudo -u dataai git fetch origin main && sudo -u dataai git reset --hard origin/main && sudo -u dataai .venv/bin/pip install -r requirements.txt
sudo systemctl restart data-ai
sudo systemctl restart dataai-streamlit 2>/dev/null || true   # streamlit 部署了才需要
# 修复后让自动更新接续（把「已部署」标记推进到当前 commit，否则下个周期会再部署一遍——无害但多余）
sudo -u dataai git rev-parse HEAD | sudo tee /var/lib/dataai-update/last-deployed
```

覆盖式上传（JumpServer zip）与「哪些文件绝不能删」的清单不变，见第 2 节与下节备份清单。
前端更新同样零操作：本地改 `ide_frontend/src` 构建 `dist` 提交即可，自动更新会把新 dist 带到服务器。

## 10. 备份

**内建备份（无需手工）**：应用每日自动备份 + 启动快照，产物在 `/opt/data_ai/backups/`，自动轮转。

**离线备份（建议 cron 每日）**——三件套缺一不可：

```bash
mkdir -p /backup
umask 077        # 压缩包内含明文凭据（.env/db_config.ini/encryption.key），只允许 root 读
tar czf /backup/data_ai-$(date +%F).tar.gz \
  /opt/data_ai/ide_data.db \
  /opt/data_ai/data/.sql-ide/encryption.key \
  /opt/data_ai/.env /opt/data_ai/db_config.ini \
  /opt/data_ai/sql /opt/data_ai/knowledge /opt/data_ai/code \
  /opt/data_ai/chat_history /opt/data_ai/subscriptions /opt/data_ai/reports
```

- SQLite 热备需无写入窗口（凌晨低峰）；更稳的做法是停服后 tar，或用 `sqlite3 .backup`。
- 丢 `encryption.key` = 已加密的个人 LLM Key 永久解不开（只有 key 文件这一处，务必备份）。
- 丢 `.env`/`db_config.ini` = 恢复后连不上 LLM 网关/数据仓库。
- 迁移老库：`ide_data.db` + `encryption.key` 必须**成对**复制，缺一不可。

## 11. 域名与 HTTPS

### 11.1 先判断：内网域名还是公网域名

| 场景 | 条件 | 做法 |
|---|---|---|
| **内网域名（推荐）** | 访问者都在公司内网/VPN 内（本机 hostname 就是内网机） | 找 IT 在内网 DNS 加一条 A 记录：`data-ai.huanle.com → 10.68.31.76`（用服务器内网 IP），无备案要求 |
| **公网域名** | 要从外网访问 | 火山云（或任意注册商）注册域名 → **必须先 ICP 备案**（未备案的域名解析到国内服务器，80/443 会被运营商拦截）→ 解析到 ECS 公网 IP |

主机名 `da-vc-sh-joytools-10-68-31-76` 里 `10-68-31-76` 就是内网 IP，团队日常走 JumpServer/内网访问 → **大概率走内网域名**，公网 + 备案是另一摊事，能不走就不走。

### 11.2 改 Nginx `server_name`（把 IP 访问换成域名）

编辑第 8 节的 nginx 配置，把 `server_name _;` 换成真实域名，重载即生效：

```bash
sudo vi /etc/nginx/conf.d/data-ai.conf     # 第 8 节那份配置
# server_name data-ai.huanle.com;
sudo nginx -t && sudo systemctl reload nginx
```

> 内网 DNS 没生效时，也可以先在本机 hosts 里加 `10.68.31.76 data-ai.huanle.com` 应急验证 nginx 是否正常。

浏览器访问 `http://data-ai.huanle.com/`，能打开登录页/看板即成功。

### 11.3 HTTPS（可选，按需）

- **内网**：申请公司内部 CA 签发的证书（或自签），配置 443 + 80 跳转 443。自签证书浏览器会告警，需在客户端导入根证书。
- **公网**：域名备案完成 + 公网可达后，`certbot --nginx -d data-ai.huanle.com` 一键签发 Let's Encrypt 并自动改配置（安全组需放行 80/443）。

nginx 443 配置骨架（其余 location 块与第 8 节完全一致）：

```nginx
server {
    listen 443 ssl;
    server_name data-ai.huanle.com;
    ssl_certificate     /etc/nginx/ssl/data-ai.crt;
    ssl_certificate_key /etc/nginx/ssl/data-ai.key;
    # location / { ... 同第 8 节 ... }
}
server {
    listen 80;
    server_name data-ai.huanle.com;
    return 301 https://$host$request_uri;
}
```

> HTTPS 与自动更新无耦合：证书到期换证书不影响 9 节的部署闭环，反之亦然。

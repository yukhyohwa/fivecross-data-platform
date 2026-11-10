#!/usr/bin/env bash
# =============================================================
# Data AI 自动更新脚本（方案 A：服务器轮询拉取）
#
# 安装（服务器上，root 执行）：
#   sudo cp /opt/data_ai/deploy/dataai-update.{service,timer} /etc/systemd/system/
#   sudo systemctl daemon-reload && sudo systemctl enable --now dataai-update.timer
# 定时器触发 service，ExecStart 直接跑本仓库脚本（改脚本即改行为，无需再 cp 副本）。
#
# 行为：
#   1. git fetch origin main（免密依赖 dataai 用户的 SSH deploy key，见部署文档 9.2）
#   2. 「已成功部署的 commit」记录在 /var/lib/dataai-update/last-deployed（标记文件），
#      origin/main == 标记 → 无事发生，退出 0
#   3. 有新提交 → git reset --hard origin/main（丢弃服务器对被跟踪文件的本地改动）→ 装依赖 → 重启服务 → 全部成功才更新标记
#   4. 任何一步失败（网络闪断/pip 失败/服务起不来）→ set -e 立即退出，标记不动，
#      下个周期重试整个部署（不用 HEAD 判断，pull 之后的失败不会被静默跳过）；
#      失败信息进 journalctl -u dataai-update
# =============================================================
set -euo pipefail

APP=/opt/data_ai
STATE_DIR=/var/lib/dataai-update
STATE_FILE="$STATE_DIR/last-deployed"

cd "$APP"

# 全部 git 命令都以 dataai 身份跑：仓库归 dataai，root 直接跑会撞
# git 的 safe.directory（dubious ownership）检查；root 能免密 sudo -u。
sudo -u dataai git fetch --quiet origin main

REMOTE=$(sudo -u dataai git rev-parse origin/main)
DEPLOYED=$(cat "$STATE_FILE" 2>/dev/null || echo none)

if [ "$REMOTE" = "$DEPLOYED" ]; then
  exit 0
fi

echo "[dataai-update] $(date -Is) deploying ${DEPLOYED:0:7} -> ${REMOTE:0:7}"

# 硬对齐远端（reset --hard），不依赖工作树干净。服务器 App 运行期会写 chat_history/、
# knowledge/skills/、sql/ 这些被 git 跟踪的目录，让工作树长期带未提交改动，--ff-only
# 会因「本地改动会被覆盖」而卡住部署。这里直接丢弃服务器上对「被跟踪文件」的本地改动，
# 把工作树复位到 origin/main（这些文件的正本在 git 里，服务器只读运行，本地改动非正本）。
# reset --hard 不碰未跟踪文件（新产生的聊天记录/专项运行态会保留）；也绝不合并分叉——
# 服务器上的仓库永远不该有本地提交，reset 只会把它移到 origin/main。
sudo -u dataai git reset --hard origin/main

# 依赖幂等安装：无变更时秒过，有变更时补齐（内网 pip 源见部署文档第 4 节）
sudo -u dataai "$APP/.venv/bin/pip" install -q -r "$APP/requirements.txt"

# 后端必重启（无 --reload 是硬约束）。streamlit 若部署为 systemd 单元则一并重启：
# 先探测单元是否存在——不存在是常态（streamlit 可独立跑），不能与「重启失败」混为一谈。
systemctl restart data-ai
if systemctl cat dataai-streamlit.service >/dev/null 2>&1; then
  systemctl restart dataai-streamlit
fi

# 全部成功才落标记：此标记是「该 commit 已部署成功」的唯一证据
mkdir -p "$STATE_DIR"
echo "$REMOTE" > "$STATE_FILE"

echo "[dataai-update] $(date -Is) done: $(sudo -u dataai git rev-parse --short HEAD)"

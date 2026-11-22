#!/usr/bin/env bash
# ReplayCloud 云主机一键部署（Ubuntu 22.04/24.04，x86_64，root 运行）
# 用法:
#   bash deploy.sh --token 你的访问令牌 [--lite] [--skip-weights] [--port 8080]
set -euo pipefail

TOKEN=""
LITE=0
SKIP_WEIGHTS=0
PORT=8080
HOME_DIR=/opt/replay

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --lite) LITE=1; shift ;;
    --skip-weights) SKIP_WEIGHTS=1; shift ;;
    --port) PORT="$2"; shift 2 ;;
    *) echo "未知参数 $1"; exit 1 ;;
  esac
done

if [[ -z "$TOKEN" ]]; then
  TOKEN=$(head -c 24 /dev/urandom | base64 | tr -d '=+/')
  echo "未指定令牌，已自动生成: $TOKEN"
fi
if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "错误：官方推理服务端只有 linux-x64 版本，本机是 $(uname -m)，无法部署。"
  exit 1
fi

echo "==> 安装系统依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-venv python3-pip ffmpeg curl unzip

echo "==> 准备目录 $HOME_DIR"
mkdir -p "$HOME_DIR"/{models,weights,outputs,uploads,gateway}
cp gateway.py requirements.txt "$HOME_DIR/gateway/"
cp download_server.py fetch_weights.py weights_required.json weights_stem.json "$HOME_DIR/"

echo "==> 创建 Python 环境"
python3 -m venv "$HOME_DIR/venv"
"$HOME_DIR/venv/bin/pip" install --upgrade pip
"$HOME_DIR/venv/bin/pip" install -r "$HOME_DIR/gateway/requirements.txt"

echo "==> 下载官方推理服务端（数 GB，视网络情况）"
python3 "$HOME_DIR/download_server.py" --dest "$HOME_DIR/server"

if [[ "$SKIP_WEIGHTS" == "0" ]]; then
  echo "==> 下载模型权重"
  if [[ "$LITE" == "1" ]]; then
    python3 "$HOME_DIR/fetch_weights.py" --dest "$HOME_DIR/weights" --lite
  else
    python3 "$HOME_DIR/fetch_weights.py" --dest "$HOME_DIR/weights"
  fi
fi

echo "==> 写入 systemd 服务"
cat > /etc/systemd/system/replay-inference.service <<EOF
[Unit]
Description=Replay Inference Server (official linux-x64)
After=network.target

[Service]
Type=simple
WorkingDirectory=$HOME_DIR/server
ExecStart=$HOME_DIR/server/replay-server-linux
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/replay-gateway.service <<EOF
[Unit]
Description=ReplayCloud Gateway
After=replay-inference.service

[Service]
Type=simple
WorkingDirectory=$HOME_DIR/gateway
ExecStart=$HOME_DIR/venv/bin/uvicorn gateway:app --host 0.0.0.0 --port $PORT
Restart=always
RestartSec=5
Environment=REPLAY_HOME=$HOME_DIR
Environment=REPLAY_TOKEN=$TOKEN
Environment=REPLAY_UPSTREAM=http://127.0.0.1:62362

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now replay-inference replay-gateway

IP=$(curl -s --max-time 10 https://api.ipify.org || hostname -I | awk '{print $1}')
cat <<MSG

============================================================
部署完成！
  iPad 客户端服务器地址:  http://$IP:$PORT
  访问令牌:               $TOKEN

请在云厂商安全组/防火墙放行 TCP $PORT。
推理服务端首次启动需要加载模型，/health 可能要等 1-2 分钟才正常。

常用命令:
  查看推理日志: journalctl -u replay-inference -f
  查看网关日志: journalctl -u replay-gateway -f
  重启:        systemctl restart replay-inference replay-gateway

重要：weights/ 与 server/ 是官方关停前留下的资源，建议尽快打包
备份到你自己的对象存储（tar -czf replay-backup.tar.gz -C /opt replay）。
============================================================
MSG

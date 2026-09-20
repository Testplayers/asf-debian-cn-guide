#!/usr/bin/env bash
# =============================================================================
# 国内 Debian 一键安装 ArchiSteamFarm (ASF)
#   - 自动安装依赖（含 ASF 必需的 libicu，缺它会 SIGABRT 崩溃）
#   - GitHub 直连超时自动切换镜像，支持断点续传 + zip 完整性校验
#   - 绕过「老版本 unzip 不支持 zip64」的解压坑（改用 python3 zipfile）
#   - 生成 systemd 服务（含内存上限保护）
#
# 用法:
#   bash install-asf.sh
#   ASF_DIR=/opt/asf IPC_URL='http://127.0.0.1:1242' bash install-asf.sh
# =============================================================================
set -uo pipefail

ASF_DIR="${ASF_DIR:-/opt/asf}"
IPC_URL="${IPC_URL:-http://127.0.0.1:1242}"
MIRRORS=(
  "https://ghfast.top/"
  "https://gh-proxy.com/"
  "https://ghproxy.net/"
  "https://mirror.ghproxy.com/"
  ""
)
GH_URL="https://github.com/JustArchiNET/ArchiSteamFarm/releases/latest/download/ASF-linux-x64.zip"

log()  { echo -e "\033[32m[+]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
die()  { echo -e "\033[31m[x]\033[0m $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 运行（sudo -i）"

# ---------------------------------------------------------------- 1. 依赖
log "安装基础依赖..."
if [ -f /etc/debian_version ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl unzip python3 ca-certificates >/dev/null

  # ASF 依赖 libicu；Debian 各版本包名不同（libicu72 / libicu76 ...）
  if ! ldconfig -p 2>/dev/null | grep -q 'libicu'; then
    PKG="$(apt-cache search --names-only '^libicu[0-9]+$' 2>/dev/null | awk '{print $1}' | sort -V | tail -1)"
    if [ -n "${PKG:-}" ]; then
      log "安装 $PKG（ASF 必需，缺少会直接 SIGABRT 崩溃）"
      apt-get install -y -qq "$PKG" >/dev/null
    else
      warn "未找到 libicu 包，若 ASF 启动崩溃请手动安装：apt install libicu*"
    fi
  fi
else
  warn "非 Debian 系统，跳过 apt 依赖安装"
fi

# ---------------------------------------------------------------- 2. 下载
mkdir -p "$ASF_DIR" && cd "$ASF_DIR"
ZIP="$ASF_DIR/ASF-linux-x64.zip"

if [ -s "$ZIP" ] && python3 -m zipfile -t "$ZIP" >/dev/null 2>&1; then
  log "已存在完整安装包，跳过下载"
else
  OK=0
  for m in "${MIRRORS[@]}"; do
    name="${m:-官方直连}"
    log "尝试下载源：$name"
    # -C - 断点续传；失败自动换下一个镜像
    if curl -fL --connect-timeout 10 --max-time 900 -C - -o "$ZIP" "${m}${GH_URL}"; then
      if python3 -m zipfile -t "$ZIP" >/dev/null 2>&1; then
        log "下载完成且 zip 校验通过"
        OK=1; break
      else
        warn "文件不完整（可能被截断），换下一个源"
        rm -f "$ZIP"
      fi
    else
      warn "该源下载失败，换下一个"
    fi
  done
  [ "$OK" = "1" ] || die "所有下载源均失败，请手动下载 ASF-linux-x64.zip 放到 $ASF_DIR"
fi

# ---------------------------------------------------------------- 3. 解压
log "解压（python3 zipfile，兼容 zip64）..."
python3 - "$ZIP" "$ASF_DIR" <<'PY'
import sys, zipfile, pathlib
zip_path, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zip_path) as z:
    z.extractall(out)
print("  extracted ->", out)
PY

[ -f "$ASF_DIR/ArchiSteamFarm" ] || die "解压后未找到 ArchiSteamFarm 可执行文件"
chmod +x "$ASF_DIR/ArchiSteamFarm"
mkdir -p "$ASF_DIR/config" "$ASF_DIR/plugins" "$ASF_DIR/logs"

# ---------------------------------------------------------------- 4. 配置
if [ ! -f "$ASF_DIR/config/ASF.json" ]; then
  IPC_PW="$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
  cat > "$ASF_DIR/config/ASF.json" <<EOF
{
  "IPCPassword": "$IPC_PW",
  "Headless": false,
  "LoginLimiterDelay": 15,
  "FarmingDelay": 15,
  "Statistics": false
}
EOF
  log "已生成 ASF.json，IPC 密码：$IPC_PW  （请妥善保存）"
  warn "注意：不要手写 \"UpdateChannel\": \"Stable\"，该字段必须是数字枚举，写字符串会导致配置解析失败（见 FAQ Q2.3）"
else
  log "ASF.json 已存在，保持不变"
fi

if [ ! -f "$ASF_DIR/config/IPC.config" ]; then
  cat > "$ASF_DIR/config/IPC.config" <<EOF
{
  "Kestrel": {
    "Endpoints": {
      "HTTP": {
        "Url": "$IPC_URL"
      }
    }
  }
}
EOF
  log "已生成 IPC.config，监听 $IPC_URL（IPC 监听地址只在 IPC.config 里，不生效于 ASF.json）"
fi

# ---------------------------------------------------------------- 5. systemd
log "写入 systemd 服务..."
cat > /etc/systemd/system/asf.service <<EOF
[Unit]
Description=ArchiSteamFarm
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$ASF_DIR
ExecStart=$ASF_DIR/ArchiSteamFarm --path $ASF_DIR --system-required
Restart=always
RestartSec=10
Nice=15
IOSchedulingClass=idle
# 内存上限：避免 ASF 异常膨胀拖垮小内存机器
MemoryMax=600M
OOMPolicy=stop

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now asf >/dev/null 2>&1
sleep 8

# ---------------------------------------------------------------- 6. 结果
if systemctl is-active --quiet asf; then
  log "ASF 已启动 ✅"
else
  warn "ASF 未能启动，查看日志： journalctl -u asf -n 50 --no-pager"
  journalctl -u asf -n 15 --no-pager -o cat | sed 's/^/    /'
fi

echo
echo "================= 安装完成 =================="
echo " 目录     : $ASF_DIR"
echo " IPC 监听 : $IPC_URL"
echo " 状态     : $(systemctl is-active asf)"
echo
echo " 下一步 —— 添加 Steam 账号（挂卡机器人）："
echo "   1) 网页控制台（推荐）："
echo "        ssh -L 1242:127.0.0.1:1242 root@<你的服务器IP>"
echo "        浏览器打开 http://localhost:1242 ，输入上面的 IPC 密码"
echo "   2) 或直接写配置文件 $ASF_DIR/config/<机器人名>.json"
echo "      { \"SteamLogin\": \"账号\", \"SteamPassword\": \"密码\", \"Enabled\": true }"
echo
echo " 若账号能登录但迟迟不掉卡，请立刻阅读 docs/03-社区反代-steam-proxy.md"
echo "============================================="

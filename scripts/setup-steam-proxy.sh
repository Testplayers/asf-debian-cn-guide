#!/usr/bin/env bash
# =============================================================================
# steam-proxy : 本地反代绕过 steamcommunity.com 的 SNI 阻断
#
#   原理：Caddy 反代时把上游写成 IP（不发 SNI），GFW 的关键词过滤匹配不到
#   组成：自签 CA + 叶子证书 → 装进系统信任链 → Caddy 监听 127.0.0.1:443
#         + /etc/hosts 把 steamcommunity.com 指向 127.0.0.1
#
# 用法:
#   bash setup-steam-proxy.sh                      # 自动挑选可用上游 IP
#   UPSTREAM_IP=104.89.103.51 bash setup-steam-proxy.sh
#   USE_8443=1 bash setup-steam-proxy.sh           # 监听 8443 + iptables 重定向（443 被占用时用）
# =============================================================================
set -uo pipefail

PROXY_DIR="${PROXY_DIR:-/opt/steam-proxy}"
LISTEN_PORT=443
DOMAINS=("steamcommunity.com" "www.steamcommunity.com")
# 已知可用的社区边缘 IP（Akamai/Valve），会依次测试，失效属正常，脚本会自动换
CANDIDATES_DEFAULT="104.89.103.51 23.212.62.70 23.62.198.226 23.32.238.19 23.45.138.131"

log()  { echo -e "\033[32m[+]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
die()  { echo -e "\033[31m[x]\033[0m $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 运行（sudo -i）"
[ "${USE_8443:-0}" = "1" ] && LISTEN_PORT=8443

mkdir -p "$PROXY_DIR" && cd "$PROXY_DIR"

# ---------------------------------------------------------------- 1. Caddy
if ! command -v caddy >/dev/null 2>&1; then
  log "安装 Caddy..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg >/dev/null 2>&1
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null 2>&1 || {
    warn "apt 安装失败，尝试直接下载二进制"
    curl -fL --connect-timeout 10 --max-time 300 -o /tmp/caddy.tar.gz \
      "https://ghfast.top/https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_amd64.tar.gz" \
      && tar -xzf /tmp/caddy.tar.gz -C /usr/bin caddy && chmod +x /usr/bin/caddy
  }
fi
command -v caddy >/dev/null 2>&1 || die "Caddy 安装失败，请手动安装后重试"
caddy version | sed 's/^/    caddy /'

# ---------------------------------------------------------------- 2. 自签证书
if [ ! -f "$PROXY_DIR/cacert.crt" ] || [ ! -f "$PROXY_DIR/steamcommunity.crt" ]; then
  log "生成自签 CA 与叶子证书（含 SAN）..."
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$PROXY_DIR/cakey.key" -out "$PROXY_DIR/cacert.crt" \
    -subj "/CN=Local Steam Proxy CA" 2>/dev/null

  openssl req -newkey rsa:2048 -nodes \
    -keyout "$PROXY_DIR/steamcommunity.key" -out "$PROXY_DIR/steamcommunity.csr" \
    -subj "/CN=steamcommunity.com" 2>/dev/null

  SAN="subjectAltName=DNS:steamcommunity.com,DNS:www.steamcommunity.com,DNS:store.steampowered.com"
  printf "%s\n" "$SAN" > "$PROXY_DIR/san.cnf"
  openssl x509 -req -in "$PROXY_DIR/steamcommunity.csr" \
    -CA "$PROXY_DIR/cacert.crt" -CAkey "$PROXY_DIR/cakey.key" -CAcreateserial \
    -out "$PROXY_DIR/steamcommunity.crt" -days 3650 -extfile "$PROXY_DIR/san.cnf" 2>/dev/null

  chmod 600 "$PROXY_DIR/cakey.key" "$PROXY_DIR/steamcommunity.key"
  log "证书生成完毕"
else
  log "证书已存在，跳过生成"
fi

log "把 CA 装进系统信任链（curl / python / Steam 客户端都会用它校验）..."
cp "$PROXY_DIR/cacert.crt" /usr/local/share/ca-certificates/steam-proxy-ca.crt
update-ca-certificates 2>&1 | tail -2 | sed 's/^/    /'

# ---------------------------------------------------------------- 3. 选上游
UPSTREAM="${UPSTREAM_IP:-}"
if [ -z "$UPSTREAM" ]; then
  log "自动测试候选上游 IP（无 SNI + Host: steamcommunity.com）..."
  for ip in $CANDIDATES_DEFAULT; do
    code="$(curl -sS -k -o /tmp/sp_probe.out -w '%{http_code}' --max-time 12 \
      "https://$ip/" -H 'Host: steamcommunity.com' 2>/dev/null || true)"
    if [ "$code" = "200" ] || [ "$code" = "302" ]; then
      UPSTREAM="$ip"
      log "选中上游：$ip (HTTP $code)"
      break
    fi
    warn "  $ip 不可用 (HTTP ${code:-超时})"
  done
fi
[ -n "$UPSTREAM" ] || die "未找到可用上游 IP。请手动指定：UPSTREAM_IP=1.2.3.4 bash $0
  提示：可用 scripts/diagnose-steam-net.sh 找 IP，或从其他已跑通的机器上抄一个"

# ---------------------------------------------------------------- 4. Caddyfile
if [ "$LISTEN_PORT" = "443" ]; then
  ADDRS="https://steamcommunity.com, https://www.steamcommunity.com"
else
  ADDRS="https://steamcommunity.com:8443, https://www.steamcommunity.com:8443"
fi

cat > "$PROXY_DIR/Caddyfile" <<EOF
{
	admin off
	auto_https off
}

$ADDRS {
	bind 127.0.0.1
	tls $PROXY_DIR/steamcommunity.crt $PROXY_DIR/steamcommunity.key
	# 上游写 IP：Caddy 不会发送 SNI，从而绕过关键词阻断
	reverse_proxy https://$UPSTREAM {
		transport http {
			tls
			tls_insecure_skip_verify
		}
	}
}
EOF
log "Caddyfile 已生成（上游 $UPSTREAM，监听 127.0.0.1:$LISTEN_PORT）"

# ---------------------------------------------------------------- 5. hosts
for d in "${DOMAINS[@]}"; do
  if ! grep -qE "^127\.0\.0\.1[[:space:]]+$d\$" /etc/hosts; then
    echo "127.0.0.1 $d" >> /etc/hosts
    log "hosts 追加：127.0.0.1 $d"
  fi
done

# ---------------------------------------------------------------- 6. 服务
if [ "$LISTEN_PORT" = "8443" ]; then
  # 443 被占用时：监听 8443 + iptables 把本机 443 重定向过来
  EXEC_PRE='ExecStartPre=-/bin/bash -c "iptables -t nat -C OUTPUT -p tcp -d 127.0.0.1 --dport 443 -j REDIRECT --to-ports 8443 2>/dev/null || iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 --dport 443 -j REDIRECT --to-ports 8443"'
  EXEC_POST='ExecStopPost=-/bin/bash -c "iptables -t nat -D OUTPUT -p tcp -d 127.0.0.1 --dport 443 -j REDIRECT --to-ports 8443"'
else
  EXEC_PRE=""; EXEC_POST=""
fi

cat > /etc/systemd/system/steam-proxy.service <<EOF
[Unit]
Description=Steam Community Local Reverse Proxy (SNI bypass)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=XDG_DATA_HOME=$PROXY_DIR/data
Environment=XDG_CONFIG_HOME=$PROXY_DIR/config
$EXEC_PRE
ExecStart=/usr/bin/caddy run --config $PROXY_DIR/Caddyfile --adapter caddyfile
$EXEC_POST
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now steam-proxy >/dev/null 2>&1
sleep 5

# ---------------------------------------------------------------- 7. 验证
echo
echo "==================== 验证 ===================="
echo -n "  服务状态 : "; systemctl is-active steam-proxy
echo -n "  监听端口 : "; ss -tlnp 2>/dev/null | grep -E "127\.0\.0\.1:$LISTEN_PORT" | awk '{print $4}' | head -1
echo -n "  社区首页 : "; curl -sS -o /dev/null -w 'HTTP %{http_code} (%{time_total}s)\n' --max-time 25 https://steamcommunity.com/ 2>&1 | tail -1
echo -n "  徽章页   : "; curl -sS -o /dev/null -w 'HTTP %{http_code}\n' --max-time 25 https://steamcommunity.com/my/badges 2>&1 | tail -1
echo -n "  内容抽查 : "; curl -sS --max-time 25 https://steamcommunity.com/ 2>/dev/null | grep -o 'Steam' | head -1
echo
echo "  首页 200 + 徽章页 302 = 正常（302 表示需要登录，是预期行为）"
echo "  若失败：bash scripts/diagnose-steam-net.sh 诊断，或换上游 IP："
echo "    UPSTREAM_IP=<新IP> bash $0   然后 systemctl restart steam-proxy"
echo "============================================="

# 03 社区反代 steam-proxy（核心章节）

> 本章解决国内部署 ASF 最常见的致命问题：**账号能登录、ASF 显示在线，但一张卡都不掉。**
> 一键脚本：`bash scripts/setup-steam-proxy.sh`

## 3.1 症状判断

```bash
journalctl -u asf -n 100 --no-pager | grep -iE 'badge|Request failed|catalog'
```

出现下面任意一条，就是本章要解决的问题：

```
Checking first badge page...          ← 一直卡在这一句
Request failed after 3 attempts       ← 读取徽章页失败
Unable to fetch the badge page
```

**判定**：Steam 有两条独立的通道

| 通道 | 用途 | 国内状态 |
|------|------|---------|
| CM 长连接（TCP 27017 等）| 登录、挂卡状态上报 | ✅ 一般可用（所以能"在线"）|
| HTTPS 网页（`steamcommunity.com`）| **读取可掉落卡片列表** | ❌ 被阻断（所以掉不出卡）|

## 3.2 分两层诊断（关键！处理方式完全不同）

```bash
bash scripts/diagnose-steam-net.sh
```

或手工三步：

### 第一步：DNS 解析

```bash
getent hosts steamcommunity.com
```

| 输出 | 结论 |
|------|------|
| `127.0.0.1  steamcommunity.com` | ✅ 已配好本地反代 |
| `2a03:2880:...face:b00c...` 或 `69.171.x.x` / `31.13.x.x` | ❌ **DNS 污染**（解析到 Facebook 的 IP）|
| 正常 Valve/Akamai IP（`104.x`、`23.x`）| 未污染，继续下一步 |

### 第二步：带 SNI / 不带 SNI 对比（决定性判据）

```bash
# 1) 带 SNI（正常 HTTPS）
curl -sS -o /dev/null -w 'HTTP %{http_code} %{time_total}s\n' --max-time 15 https://steamcommunity.com/
# 典型结果：超时 / curl: (28) ...

# 2) 不带 SNI（直接连 IP，用 Host 头）
curl -sS -k -o /tmp/p.out -w 'HTTP %{http_code} %{time_total}s\n' --max-time 15 \
  https://104.89.103.51/ -H 'Host: steamcommunity.com'
grep -o 'steamcommunity\|Steam' /tmp/p.out | head -2
# 典型结果：HTTP 302 且响应里含 Steam 域名 → 说明「不带 SNI 可以正常访问」
```

| 现象 | 结论 |
|------|------|
| 带 SNI `Connection reset by peer`（TCP 连上后立刻被 RST）| ❌ **SNI 关键词阻断** |
| 带 SNI 超时、不带 SNI 也超时 | 该 IP 不可用，换 IP 再测 |
| 不带 SNI 返回 200/302 且有 Steam 内容 | ✅ 找到了可用上游，可以按本章部署 |

> 实测原文：
> ```
> Trying 23.45.138.131:443...
> Recv failure: Connection reset by peer        ← ClientHello（含 SNI）发出瞬间被重置
> ```
> 这说明**IP 层没被封，封的是 TLS 握手里的域名关键字**。

## 3.3 原理：上游写 IP，反代就不会发 SNI

```
ASF 请求 https://steamcommunity.com
   │  ① /etc/hosts: steamcommunity.com → 127.0.0.1
   ▼
② 本地 Caddy（127.0.0.1:443，自签证书，CA 已加入系统信任链）
   │  ③ reverse_proxy https://<Akamai IP>   ← 关键：上游是 IP，Go/Caddy 不发送 SNI
   ▼
④ Akamai 边缘节点（能识别 Host 头）──► Steam 社区 ✅
```

- **②** 必须让本机信任自签 CA，否则 ASF 读徽章页时会因证书不通过而失败
- **③** 是整个方案的灵魂：`proxy_pass`/`reverse_proxy` 的地址是 **IP** 时不会发送 SNI，GFW 的关键词过滤匹配不到
- **④** 边缘节点靠 HTTP `Host` 头（或 TLS 之外的报文）识别站点，所以不带 SNI 也能拿到正确内容

> ⚠️ 因此**不能用普通反代**（比如把 `steamcommunity.com` 反代到 `https://steamcommunity.com`）：
> 那样反代进程自己发出的请求同样带 SNI，一样被重置。**必须把上游写成 IP。**

## 3.4 部署步骤（手工版，脚本版见 `scripts/setup-steam-proxy.sh`）

### ① 安装 Caddy

```bash
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  > /etc/apt/sources.list.d/caddy-stable.list
apt-get update && apt-get install -y caddy
caddy version
```

（装不上就下载官方二进制：`caddy_linux_amd64.tar.gz`，或用 GitHub 镜像加速）

### ② 自签 CA + 叶子证书（含 SAN）

```bash
mkdir -p /opt/steam-proxy && cd /opt/steam-proxy

# CA
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout cakey.key -out cacert.crt -subj "/CN=Local Steam Proxy CA"

# 站点证书（CN + SAN 都要有，否则客户端校验证书失败）
openssl req -newkey rsa:2048 -nodes \
  -keyout steamcommunity.key -out steamcommunity.csr -subj "/CN=steamcommunity.com"

cat > san.cnf <<'EOF'
subjectAltName=DNS:steamcommunity.com,DNS:www.steamcommunity.com,DNS:store.steampowered.com
EOF

openssl x509 -req -in steamcommunity.csr -CA cacert.crt -CAkey cakey.key -CAcreateserial \
  -out steamcommunity.crt -days 3650 -extfile san.cnf

chmod 600 cakey.key steamcommunity.key
```

### ③ 把 CA 装进系统信任链（**必须**）

```bash
cp /opt/steam-proxy/cacert.crt /usr/local/share/ca-certificates/steam-proxy-ca.crt
update-ca-certificates
```

> 没做这一步的典型现象：Caddy 起来了、`curl -k` 能通，但 **ASF 依然读不到徽章页**（证书校验失败）。
> `curl` 报错关键字：`SSL certificate problem: unable to get local issuer certificate`。

### ④ 写 Caddyfile

```caddyfile
{
	admin off
	auto_https off
}

https://steamcommunity.com, https://www.steamcommunity.com {
	bind 127.0.0.1
	tls /opt/steam-proxy/steamcommunity.crt /opt/steam-proxy/steamcommunity.key
	# 上游写成 IP：不发 SNI，绕过关键词阻断
	reverse_proxy https://104.89.103.51 {
		transport http {
			tls
			tls_insecure_skip_verify
		}
	}
}
```

说明：
- `auto_https off`：禁止 Caddy 自己申请证书（我们用自签的）
- `bind 127.0.0.1`：只监听本机
- 该上游 IP 直接对 HTTPS 说 TLS，所以 `tls` + `tls_insecure_skip_verify`（证书是 Akamai 的，与我们的域名不匹配，跳过校验）
- 若要同时代理商店页，可把 `https://store.steampowered.com` 也加进地址列表（并在 hosts 里加上它）

### ⑤ hosts 指向本机

```bash
cat >> /etc/hosts <<'EOF'
127.0.0.1 steamcommunity.com
127.0.0.1 www.steamcommunity.com
EOF
```

> 只加**被墙的**域名。像 `store.steampowered.com` 如果本身能直连（用 `curl` 测），**不要**加进 hosts，直连更快。

### ⑥ systemd 服务

**方案 A：直接监听 443（简单，推荐）** —— 前提是本机 443 没被占用

```ini
[Unit]
Description=Steam Community Local Reverse Proxy (SNI bypass)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=XDG_DATA_HOME=/opt/steam-proxy/data
Environment=XDG_CONFIG_HOME=/opt/steam-proxy/config
ExecStart=/usr/bin/caddy run --config /opt/steam-proxy/Caddyfile --adapter caddyfile
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

**方案 B：监听 8443 + iptables 重定向**（443 已被占用时，例如本机还跑着网站）

Caddyfile 里地址改成 `https://steamcommunity.com:8443, https://www.steamcommunity.com:8443`，服务加：

```ini
ExecStartPre=-/bin/bash -c "iptables -t nat -C OUTPUT -p tcp -d 127.0.0.1 --dport 443 -j REDIRECT --to-ports 8443 2>/dev/null || iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 --dport 443 -j REDIRECT --to-ports 8443"
ExecStopPost=-/bin/bash -c "iptables -t nat -D OUTPUT -p tcp -d 127.0.0.1 --dport 443 -j REDIRECT --to-ports 8443"
```

> ⚠️ 方案 B 的坑：**iptables 没装**时 `ExecStartPre` 静默失败（`-` 前缀不中断），
> 结果 443 被重定向到一个没人监听的端口 → 所有请求秒失败（`HTTP 000`）。
> 检查：`iptables -t nat -L OUTPUT -n`，没有规则就 `apt install iptables`。
> **能用方案 A 就别用 B。**

```bash
systemctl daemon-reload
systemctl enable --now steam-proxy
```

## 3.5 验证

```bash
systemctl is-active steam-proxy              # active
ss -tlnp | grep -E '127.0.0.1:(443|8443)'    # 在监听

curl -sS -o /dev/null -w '首页: HTTP %{http_code} (%{time_total}s)\n' https://steamcommunity.com/
curl -sS -o /dev/null -w '徽章: HTTP %{http_code}\n' https://steamcommunity.com/my/badges
```

| 结果 | 结论 |
|------|------|
| 首页 **200**，徽章页 **302** | ✅ 正常（302=需要登录，是预期行为）|
| `HTTP 000` 且极快返回 | 连接被拒 → 端口没监听 / iptables 错指（见 ⑥ 的坑）|
| `SSL certificate problem` | CA 没装进信任链（回到 ③）|
| 超时 | 上游 IP 失效，换 IP |

最后重启 ASF 看真实效果：

```bash
systemctl restart asf
journalctl -u asf -f --no-pager | grep -iE 'badge|farming|Request failed'
# 期待出现: Checking first badge page... → Farming ... → 或 "nothing to farm"
```

## 3.6 上游 IP 会失效 —— 怎么维护

Akamai/Valve 的边缘 IP 会变，几个月后可能失效，表现是首页超时。换 IP 即可：

```bash
# 方法1：换一个候选 IP（脚本里有候选列表）
UPSTREAM_IP=23.212.62.70 bash scripts/setup-steam-proxy.sh
systemctl restart steam-proxy

# 方法2：找新 IP
#   · 从能直连 Steam 的机器上执行 getent hosts steamcommunity.com
#   · 或用公共 DoH（注意国内 DNS 常被污染，DoH 结果不一定可信）
curl -sS 'https://dns.alidns.com/resolve?name=steamcommunity.com&type=A'
#   · 然后逐个用「不带 SNI」测试：curl -k https://<IP>/ -H 'Host: steamcommunity.com'
```

把 Caddyfile 里那一行 IP 改掉，`systemctl restart steam-proxy` 即可（证书、hosts 都不用动）。

## 3.7 其他方案为什么不行（避免走弯路）

| 方案 | 结果 | 原因 |
|------|------|------|
| 改 hosts 指向真实 IP | ❌ | 只解决 DNS 污染；SNI 阻断照样 RST |
| 普通反代（上游写域名）| ❌ | 反代进程自己发 SNI，一样被重置 |
| Cloudflare WARP / wgcf | ❌ | 实测 UDP 被限速到不可用（单请求 30s+），换接入点后直接握手失败 |
| 换 DNS（8.8.8.8 / AliDNS）| ❌ | 阻断不在 DNS 层（但可用来**发现**真实 IP）|
| 把 `api.steampowered.com` 也这样绕过 | ❌ | 该上游**必须带 SNI**，不带 SNI 时直接 `tlsv1 alert internal error`。所以墙内的 `GetOwnedGames` 等 Web API 基本不可用，要用 Steam **客户端本地接口**代替 |
| 上代理/机场 | ✅ 可行 | 但要额外成本和维护；本文方案零成本 |

## 3.8 附录：这套反代还能干什么

部署好之后，**本机所有程序**访问 `steamcommunity.com` 都会自动走反代（因为 hosts 是本机全局的），例如：

- ASF 读取徽章页、检查可掉落卡片
- 自建工具读取社区库页面（**需要登录 cookie**：Steam 客户端的 CEF cookie 库可用 Chromium 的 `peanuts` 密钥解密，见下）
- 读取 `store.steampowered.com` 的游戏名/封面（该域名如果直连不畅，也可加进 hosts + Caddyfile）

> 小技巧（进阶）：Steam 客户端（headless）在 `~/.local/share/Steam/config/htmlcache/Default/Cookies` 存着登录态，
> 用 AES-128-CBC + 密钥 `PBKDF2("peanuts","saltysalt",1,16)` 可解出 `steamLoginSecure`，进而以「已登录身份」请求社区/商店接口。

下一步 → [04 常见问题 FAQ](04-常见问题.md)

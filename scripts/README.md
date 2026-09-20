# 脚本说明

三个脚本都**可重复执行**（幂等），已在 Debian 12/13 实测。

| 脚本 | 作用 | 需要的权限 |
|------|------|-----------|
| [`install-asf.sh`](install-asf.sh) | 安装 ASF：装依赖(libicu) → 镜像下载 → zip64 兼容解压 → 写 ASF.json/IPC.config → systemd 服务 → 启动验证 | root |
| [`setup-steam-proxy.sh`](setup-steam-proxy.sh) | 部署社区反代：装 Caddy → 自签 CA/证书 → 装系统信任链 → 自动挑可用上游 IP → 写 Caddyfile/hosts/systemd → 验证 | root |
| [`diagnose-steam-net.sh`](diagnose-steam-net.sh) | 只读诊断：DNS 污染判定、带/不带 SNI 对比、上游 IP 筛选、Steam CM 连通性、其他域名可达性 | 任意 |

## 典型使用顺序

```bash
# 1. 先诊断（只读，不改系统）
bash scripts/diagnose-steam-net.sh

# 2. 装 ASF
bash scripts/install-asf.sh

# 3. 装社区反代（掉卡必需）
bash scripts/setup-steam-proxy.sh

# 4. 重启 ASF 并观察
systemctl restart asf
journalctl -u asf -f --no-pager | grep -iE 'badge|farming'
```

## 可调环境变量

```bash
# install-asf.sh
ASF_DIR=/opt/asf IPC_URL='http://127.0.0.1:1242' bash scripts/install-asf.sh

# setup-steam-proxy.sh
UPSTREAM_IP=23.212.62.70 bash scripts/setup-steam-proxy.sh   # 跳过自动探测，指定上游
USE_8443=1 bash scripts/setup-steam-proxy.sh                 # 本机 443 被占用时，改用 8443 + iptables

# diagnose-steam-net.sh
CANDIDATES="104.89.103.51 23.212.62.70" bash scripts/diagnose-steam-net.sh
```

## 注意事项

- `setup-steam-proxy.sh` 会**修改 `/etc/hosts`**（把 `steamcommunity.com` 指向 127.0.0.1）并**安装自签 CA 到系统信任链**。若要撤销：
  ```bash
  sed -i '/steamcommunity.com/d' /etc/hosts
  rm -f /usr/local/share/ca-certificates/steam-proxy-ca.crt && update-ca-certificates
  systemctl disable --now steam-proxy
  ```
- 脚本里的**候选上游 IP 会随时间失效**，失效时按 [docs/03](../docs/03-社区反代-steam-proxy.md#36-上游-ip-会失效--怎么维护) 换一个即可。
- 请勿把含真实 IP/密码的改动提交到公开仓库。

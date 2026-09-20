# 国内云服务器 Debian 部署 ASF 挂卡完全指南

> 在**国内云服务器**（腾讯云 / 阿里云等）的 Debian 上部署 [ArchiSteamFarm](https://github.com/JustArchiNET/ArchiSteamFarm)（ASF）自动挂卡的完整实践文档。
>
> 除了常规安装步骤，本文档重点解决国内环境下的**核心拦路虎**：
> `steamcommunity.com` 被 **DNS 污染 + SNI 关键词阻断**，导致 ASF「显示在线、却一张卡都不掉」。
> 解决方案是本地 `steam-proxy`（Caddy 反代 + 自签 CA + 无 SNI 上游），本文档给出完整部署与验证过程。

> ℹ️ **本仓库只包含「ASF 挂卡」这一条主线**。
> 进阶的**「成就解锁 + Web 面板」**整套实现（无头 Steam 客户端、Steamworks 成就工具、
> 任务队列/计费面板、游戏库获取、可掉卡扫描、内存事故复盘）已拆分到独立仓库
> **`steam-achieve-panel`**（私有），本仓库不再重复维护。

---

## 📚 文档目录（建议按顺序阅读）

| # | 文档 | 内容 |
|---|------|------|
| 01 | [环境准备](docs/01-环境准备.md) | 系统要求、国内镜像源、依赖（**libicu**）、swap、用户与目录规划 |
| 02 | [安装 ASF](docs/02-安装ASF.md) | 镜像加速下载、**zip64 解压坑**、`ASF.json`/`IPC.config`、systemd、添加机器人、2FA 令牌、从旧机迁移免令牌 |
| 03 | [社区反代 steam-proxy](docs/03-社区反代-steam-proxy.md) | **核心章节**：DNS 污染 vs SNI 阻断的诊断、自签 CA + Caddy 无 SNI 上游、hosts/iptables、验证、上游 IP 维护 |
| 04 | [常见问题 FAQ](docs/04-常见问题.md) | 安装 / 配置 / 网络 / 挂卡 / 内存 五类问题与解决办法（全部来自实战踩坑）|
| 05 | [运维与安全](docs/05-运维与安全.md) | 日志排查、开机自启、备份恢复、IPC 安全、SSH 隧道、多实例与内存控制 |
| 06 | [命令速查表](docs/06-命令速查.md) | 一页看完所有常用命令 |

## 🧰 附带脚本

| 脚本 | 用途 | 说明 |
|------|------|------|
| [`scripts/install-asf.sh`](scripts/install-asf.sh) | 一键安装 ASF | 自动装依赖、镜像下载、zip64 兼容解压、生成 systemd 服务 |
| [`scripts/setup-steam-proxy.sh`](scripts/setup-steam-proxy.sh) | 一键部署社区反代 | 自签 CA、Caddy、hosts、系统信任链，并自动验证 |
| [`scripts/diagnose-steam-net.sh`](scripts/diagnose-steam-net.sh) | 网络诊断 | 判断是 DNS 污染还是 SNI 阻断，并筛选可用上游 IP |

用法见各脚本头部注释，或直接：

```bash
bash scripts/install-asf.sh
bash scripts/setup-steam-proxy.sh
bash scripts/diagnose-steam-net.sh
```

## ⚙️ 附带配置样例（占位符，请替换成自己的值）

```text
code/deploy/
├── config-samples/
│   ├── ASF.json            安全基线（Headless、IPCPassword、登录限速）
│   └── IPC.config          IPC 监听地址（默认只监听本机）
└── debian/
    ├── Caddyfile.steam-proxy     社区反代（上游写 IP、不发 SNI）
    └── systemd/steam-proxy.service
```

---

## ⚡ 30 秒看懂原理

### 问题：为什么 ASF「在线却不掉卡」

```
ASF ──登录──► Steam CM 服务器        ✅ 国内一般可以连通（登录用的是长连接，非 443 网页）
ASF ──读徽章页──► https://steamcommunity.com  ❌ 被阻断 → 拿不到可掉落卡片列表 → 永远 0 张卡
```

阻断分两层（**必须分清楚，处理方式完全不同**）：

| 层 | 现象 | 说明 |
|---|---|---|
| DNS 污染 | 域名解析到 Facebook 的 IP（如 `69.171.x.x`、IPv6 `…face:b00c…`）| 改 hosts 即可 |
| SNI 阻断 | TCP 能连上、但 TLS 握手时发出 `ClientHello` 瞬间被 `Connection reset by peer` | **改 hosts 无效**，必须绕过 |

### 解决：本地反代 + 上游写 IP（不发 SNI）

```
ASF 请求 https://steamcommunity.com
   │  /etc/hosts 指向 127.0.0.1
   ▼
本地 Caddy（自签证书，CA 已装进系统信任链）
   │  reverse_proxy https://<Akamai 边缘 IP>   ← 关键：上游写 IP，Go/Caddy 不发送 SNI
   ▼
Akamai 边缘节点 ──► Steam 社区  ✅
```

> **核心结论**：GFW 的关键词过滤看的是 TLS 握手里的 **SNI**。反代上游填 **IP 而不是域名** 时不会发送 SNI，过滤就匹配不到。
> 实测：`curl -k https://<IP>/ -H 'Host: steamcommunity.com'` 返回 `200/302` 且响应头含 Steam 的 CSP 域名 → 说明「不带 SNI」可以正常访问。

---

## ✅ 实测环境

| 项目 | 说明 |
|------|------|
| 系统 | Debian 12 (bookworm) / Debian 13 (trixie)，x86_64 |
| 配置 | 2 核 2G 最稳；**1G 内存必须配 2G swap**；ASF 单实例约 100–150MB |
| 网络 | 腾讯云 / 阿里云大陆机房实测可用（跨云直连带宽可能很差，见 FAQ Q4.6）|
| ASF 版本 | 6.x（自包含 .NET，无需另装运行时）|

## ⚠️ 免责声明

- 自动化挂卡 **违反 Steam 用户协议**，账号存在被限制/封禁的风险，请自行评估并承担后果。
- 本文档仅用于技术研究与个人学习，请勿用于商业代挂等高风险场景。
- 文档中出现的 IP、密码、路径均为**占位符**，请勿把真实服务器地址、账号密码提交到公开仓库。
- 例外说明：`docs/03`、`scripts/` 中出现的 `104.89.103.51` 一类地址是
  **Valve CDN（Akamai）的公开边缘 IP**，用于演示「反代上游写 IP 而非域名以避开 SNI 过滤」，
  它们属于公开信息、且会随时间变化，**请以 `scripts/diagnose-steam-net.sh` 的实时探测结果为准**。

## 📄 License

MIT（文档内容）。ASF 本体采用 Apache-2.0。

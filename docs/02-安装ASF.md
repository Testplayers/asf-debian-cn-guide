# 02 安装 ASF

> 一键脚本：`bash scripts/install-asf.sh`
> 本章是脚本的详细说明，便于排错与手工部署。

## 2.1 下载 ASF

ASF 提供**自包含**的 linux-x64 包（自带 .NET 运行时，不用另装）。

```bash
mkdir -p /opt/asf && cd /opt/asf

# GitHub 直连在国内经常超时，用镜像加速（按顺序尝试）
for m in "https://ghfast.top/" "https://gh-proxy.com/" "https://ghproxy.net/" ""; do
  echo "尝试: ${m:-官方直连}"
  curl -fL --connect-timeout 10 --max-time 900 -C - -o ASF-linux-x64.zip \
    "${m}https://github.com/JustArchiNET/ArchiSteamFarm/releases/latest/download/ASF-linux-x64.zip" && break
done
```

要点：
- `-C -` 表示**断点续传**（镜像同步中断时会截断文件，续传能救回来）
- 下载完**一定要校验**（见下）

```bash
ls -lh ASF-linux-x64.zip
python3 -m zipfile -t ASF-linux-x64.zip && echo "zip 完整 ✅"
```

### ⚠️ 常见坑：`unzip` 报错但文件其实是好的

Debian 自带的 `unzip 6.0` **不支持 zip64 格式**，会报类似：

```
error: invalid zip file with overlapped components (possible zip bomb)
```

而 `python3 -m zipfile -t` 能正常通过 —— 说明**文件没问题，是 unzip 太老**。

**解决：用 python3 解压**

```bash
python3 - <<'PY'
import zipfile
with zipfile.ZipFile('/opt/asf/ASF-linux-x64.zip') as z:
    z.extractall('/opt/asf')
print("解压完成")
PY
chmod +x /opt/asf/ArchiSteamFarm
```

> 注意：ASF 的 zip **内部没有顶层目录**，直接解到 `/opt/asf` 即可，
> 解压后应看到 `/opt/asf/ArchiSteamFarm`、`/opt/asf/plugins/` 等。

## 2.2 目录结构

```bash
mkdir -p /opt/asf/config /opt/asf/plugins /opt/asf/logs
ls /opt/asf/
# ArchiSteamFarm  config  logs  plugins  ...
```

## 2.3 主配置 `config/ASF.json`

最小可用配置：

```json
{
  "IPCPassword": "换成你的强密码",
  "Headless": false,
  "LoginLimiterDelay": 15,
  "FarmingDelay": 15,
  "Statistics": false
}
```

| 字段 | 说明 |
|------|------|
| `IPCPassword` | 网页控制台（IPC）密码，**必设**，否则谁都能操作你的账号 |
| `Headless` | `false` 时首次登录遇到令牌验证会在控制台等待输入；`true` 则完全无人值守（适合批量托管）|
| `LoginLimiterDelay` | 多账号登录的最小间隔（秒），**多账号时调大能降低风控概率** |
| `FarmingDelay` | 每轮挂卡检查间隔（分钟）|
| `Statistics` | 是否上报匿名统计，建议 `false` |

### ⚠️ 常见坑：`UpdateChannel` 写成字符串导致配置解析失败

```
ERROR ... Failed to parse config file: expected number, got string
```

**原因**：`UpdateChannel` 是**数字枚举**（不是 `"Stable"` 这种字符串）。

**解决**：直接**删掉这个字段**（默认就是稳定版），不要手写字符串：

```bash
python3 - <<'PY'
import json
p='/opt/asf/config/ASF.json'
d=json.load(open(p))
d.pop('UpdateChannel', None)
json.dump(d, open(p,'w'), indent=2, ensure_ascii=False)
print("已移除 UpdateChannel")
PY
```

## 2.4 IPC 监听地址：只在 `IPC.config` 里生效！

**这是最容易踩的坑之一**：把监听地址写进 `ASF.json`（比如 `"Kestrel": {...}`）**完全没用**，ASF 的 IPC 端口由 `config/IPC.config` 控制。

```json
{
  "Kestrel": {
    "Endpoints": {
      "HTTP": {
        "Url": "http://127.0.0.1:1242"
      }
    }
  }
}
```

| 需求 | Url 写法 |
|------|---------|
| 仅本机（**推荐**，用 SSH 隧道访问）| `http://127.0.0.1:1242` |
| 监听所有网卡（需自己把控安全 + 防火墙放行）| `http://*:1242` |

改完 `systemctl restart asf`，验证：

```bash
ss -tlnp | grep 1242
```

## 2.5 systemd 服务（含内存保护）

```ini
[Unit]
Description=ArchiSteamFarm
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/asf
ExecStart=/opt/asf/ArchiSteamFarm --path /opt/asf --system-required
Restart=always
RestartSec=10
Nice=15
IOSchedulingClass=idle
MemoryMax=600M      # 关键：防止 ASF 异常膨胀把小内存机器拖垮
OOMPolicy=stop

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now asf
sleep 10
systemctl status asf --no-pager
ss -tlnp | grep 1242
```

- `--system-required`：让 ASF 感知到是 systemd 托管，退出行为更规范
- `MemoryMax`：超限会被 OOM 杀掉并由 `Restart=always` 拉起，**比拖死整机好**
- 多实例：复制一份目录 + 改服务名 + 改 IPC 端口即可（见 05 章）

## 2.6 添加挂卡机器人（Steam 账号）

### 方式 A：网页控制台（推荐）

在**你本地电脑**建立 SSH 隧道（IPC 只监听本机，不要暴露公网）：

```bash
ssh -L 1242:127.0.0.1:1242 root@<服务器IP>
```

浏览器打开 `http://localhost:1242` → 输入 `IPCPassword` → Bots → 新建机器人，填 Steam 用户名/密码。

### 方式 B：配置文件

`/opt/asf/config/<机器人名>.json`（文件名即机器人名，会原样出现在日志里）：

```json
{
  "SteamLogin": "你的Steam用户名",
  "SteamPassword": "你的Steam密码",
  "Enabled": true
}
```

ASF 会**自动检测新增配置文件并登录**，无需重启：

```bash
journalctl -u asf -f --no-pager | grep -iE 'logged on|farming|error'
```

看到 `Successfully logged on as 7656119xxxxxxxxxx` 就成功了。

## 2.7 2FA 手机令牌怎么处理

三种情况：

| 情况 | 处理 |
|------|------|
| 账号**没开**手机令牌（或邮件验证）| 一般直接登录 |
| 开了手机令牌，**首次**登录需要验证码 | 看日志/控制台提示 `RequiredInput`，在 IPC 输入：`2fa <机器人名> <5位验证码>`；`Headless: false` 时会打印 `Please enter 2FA code` |
| 想**彻底免手动** | 用 ASF 内置 **MobileAuthenticator** 插件导入 `.maFile`（Steam++ / Watt Toolkit 导出过就有）；导入后 ASF 自动生成验证码 |

导入 maFile 的日志关键字：`MobileAuthenticator`、`imported successfully`。

## 2.8 从旧机器迁移（免令牌登录）⭐

换服务器/重装时，**不要重新登录**（大概率触发令牌甚至风控），直接搬运登录凭据：

```bash
# 在旧机打包（只需少量文件，不必搬整个 ASF）
tar czf /tmp/asf-state.tgz -C /opt/asf config plugins

# 传到新机并展开
scp /tmp/asf-state.tgz root@<新机IP>:/tmp/
ssh root@<新机IP> "cd /opt/asf && tar xzf /tmp/asf-state.tgz && systemctl restart asf"
```

关键就是 `config/` 目录里的：

| 文件 | 作用 |
|------|------|
| `<机器人>.json` | 账号配置（含密码）|
| `<机器人>.db` | **登录会话令牌**（这就是免令牌的关键）|
| `ASF.db`、`ASF.json`、`IPC.config` | 主配置与缓存 |

> ⚠️ **同一账号不要在两台机器同时登录**：会互相挤下线，并可能触发 Steam 令牌重新验证。
> 正确顺序：**先停旧机 → 再启动新机**。

## 2.9 确认挂卡真的在工作（重要）

**「显示在线」不等于「在掉卡」**。请务必看日志确认：

```bash
journalctl -u asf -n 100 --no-pager | grep -iE 'farming|badge|cards|Request failed'
```

| 日志 | 含义 |
|------|------|
| `Checking first badge page...` | ✅ 正在读徽章页（说明社区可访问）|
| `Farming ... (x/y cards remaining)` | ✅ 正常挂卡中 |
| `We don't have anything to farm on this account!` | ✅ 卡已挂完（正常终点）|
| `Request failed` / `Unable to fetch badge page` / 一直卡在 `Checking first badge page` | ❌ **社区访问被阻断 —— 去第三章** |

> 实战结论：在国内机器上，**只要没做第三章的社区反代，就一定是「假在线」**：账号能登录、ASF 面板显示在线，但**一张卡都不会掉**。

下一步 → [03 社区反代 steam-proxy](03-社区反代-steam-proxy.md)

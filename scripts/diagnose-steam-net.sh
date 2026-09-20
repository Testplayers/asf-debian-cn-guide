#!/usr/bin/env bash
# =============================================================================
# Steam 网络诊断：判断 ASF 掉不了卡到底是「DNS 污染」还是「SNI 阻断」
#   - 解析检查（识别污染特征）
#   - 带 SNI / 不带 SNI 对比测试（关键判据）
#   - 候选上游 IP 可用性筛选
#   - Steam CM 服务器连通性（决定能否登录）
#   - store.steampowered.com / api.steampowered.com 可达性
#
# 用法: bash diagnose-steam-net.sh
# =============================================================================
CANDIDATES="${CANDIDATES:-104.89.103.51 23.212.62.70 23.62.198.226 23.32.238.19 23.45.138.131 104.244.43.128}"

grn() { echo -e "\033[32m$*\033[0m"; }
red() { echo -e "\033[31m$*\033[0m"; }
yel() { echo -e "\033[33m$*\033[0m"; }
hr()  { echo "-----------------------------------------------------------"; }

hr; echo "1) DNS 解析检查"
HOSTS_IP="$(getent hosts steamcommunity.com 2>/dev/null | head -1 | awk '{print $1}')"
ALIDNS_IP="$(curl -sS --max-time 8 'https://dns.alidns.com/resolve?name=steamcommunity.com&type=A' 2>/dev/null \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print(' '.join(a['data'] for a in d.get('Answer',[]) if a.get('type')==1))" 2>/dev/null)"
echo "  /etc/hosts 生效结果 : ${HOSTS_IP:-解析失败}"
echo "  AliDNS 公共解析结果 : ${ALIDNS_IP:-解析失败}"
POLLUTED=0
for ip in $HOSTS_IP $ALIDNS_IP; do
  case "$ip" in
    69.171.*|31.13.*|157.240.*|*face:b00c*) POLLUTED=1 ;;
  esac
done
[ "$POLLUTED" = "1" ] && red "  ⚠ 解析到 Facebook 的 IP → 典型 DNS 污染" || grn "  解析结果未见明显污染特征"
[ -n "$HOSTS_IP" ] && [ "$HOSTS_IP" = "127.0.0.1" ] && grn "  ✓ 已配置 hosts → 本地反代（正常状态）"

hr; echo "2) 带 SNI 直连测试（预期：失败/超时 = SNI 被阻断）"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 https://steamcommunity.com/ 2>/dev/null || echo '超时')"
echo "  https://steamcommunity.com/ → HTTP ${CODE}"
if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
  grn "  ✓ 直连可用（若已配 hosts，这里其实走的是本地反代）"
else
  yel "  直连不通（SNI 阻断或未配 hosts），需走本地反代"
fi

hr; echo "3) 不带 SNI 访问候选上游（预期：200/302 且有 Steam 内容）"
BEST=""
for ip in $CANDIDATES; do
  OUT="$(curl -sS -k -o /tmp/diag_sp.out -w '%{http_code}/%{time_total}s' --max-time 12 \
    "https://$ip/" -H 'Host: steamcommunity.com' 2>/dev/null || echo '失败')"
  MARK=""
  if grep -qi 'steam' /tmp/diag_sp.out 2>/dev/null; then MARK="✓含Steam内容"; fi
  printf "  %-16s %-18s %s\n" "$ip" "$OUT" "$MARK"
  case "$OUT" in 200/*|302/*) [ -z "$BEST" ] && BEST="$ip" ;; esac
done
[ -n "$BEST" ] && grn "  → 推荐上游 IP: $BEST   （用 UPSTREAM_IP=$BEST bash setup-steam-proxy.sh）" \
               || red "  → 没有可用上游 IP，请更新候选列表（IP 会随时间失效）"

hr; echo "4) Steam CM 服务器连通性（决定能否登录，与 443 网页无关）"
python3 - <<'PY' 2>/dev/null || yel "  需要 python3 才能做该项检测"
import socket, json, urllib.request
from concurrent.futures import ThreadPoolExecutor

cms = []
try:
    d = json.loads(urllib.request.urlopen(
        "https://api.steampowered.com/ISteamDirectory/GetCMList/v1/?cellid=0&format=json",
        timeout=15).read())
    cms = [c.split(':')[0] for c in (d.get('response') or {}).get('serverlist') or []]
    print(f"  GetCMList 获取到 {len(cms)} 个 CM（api 域名可达）")
except Exception as e:
    # api 域名被墙时用一份兜底列表
    cms = ["103.28.54.162","103.28.54.169","146.66.152.38","155.133.248.38","162.254.192.71"]
    print(f"  api.steampowered.com 不可达（{type(e).__name__}），改用兜底列表 {len(cms)} 个")

def test(h):
    for port in (27017, 27018, 443):
        s = socket.socket(); s.settimeout(6)
        try:
            s.connect((h, port)); return f"{h}:{port}"
        except Exception:
            pass
        finally:
            try: s.close()
            except Exception: pass
    return None

hits = [r for r in ThreadPoolExecutor(max_workers=20).map(test, cms[:40]) if r]
print(f"  可连通 CM: {len(hits)}/{min(len(cms),40)}  →  {'✓ 可以登录' if hits else '✗ 全部不通，客户端无法登录'}")
for h in hits[:5]:
    print(f"    {h}")
PY

hr; echo "5) 其他 Steam 域名可达性"
for d in store.steampowered.com api.steampowered.com login.steampowered.com; do
  printf "  %-28s " "$d"
  curl -sS -o /dev/null -w 'HTTP %{http_code} (%{time_total}s)\n' --max-time 12 "https://$d/" 2>/dev/null || echo "超时/失败"
done
echo
yel "  注：api.steampowered.com 在国内常被 SNI 阻断，且该上游要求必须带 SNI，"
yel "      因此无法用「上游写 IP」的方式绕过 —— 相关 Web API（GetOwnedGames 等）在墙内基本不可用，"
yel "      需要在服务器上用本地 Steam 客户端接口代替（见 docs/03 附录）。"

hr; echo "结论速查"
echo "  · 解析到 Facebook IP → DNS 污染          → 改 hosts 可解决"
echo "  · TCP 通但 TLS 被 reset → SNI 阻断        → 必须用本地反代（上游写 IP）"
echo "  · CM 不通 → 登录都上不去                   → 换机房/换线路（部分 IP 段被整段限制）"
echo "  · 首页 200 但徽章页失败 → 反代没生效        → 检查 hosts / 服务状态 / CA 信任"
hr

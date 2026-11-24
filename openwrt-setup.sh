#!/bin/sh
# ============================================================
# 一键脚本：OpenWrt VM 侧（内网 bridge）
# 架构：VLESS 反向代理的内网端
#   - netifd 原生 wireguard 拨入 VPS（仅作隧道底层）
#   - 本机跑一个 xray bridge：经反向隧道连回 VPS portal，
#     收到的流量用 freedom 直连本机宽带上行出网（出口 = 本机宽带 IP）
#
# 子命令：
#   install      部署 wg0 隧道 + relay bridge（默认）
#   show-keys    查看本机隧道与 relay 配置（只读）
#   set-endpoint 更换 VPS 地址/端口（保留密钥、peer 与 relay 配置不动）
#   uninstall    停止 relay、删除 /etc/xray-relay 与 wg0 配置、清理防火墙归属
#   help         显示本帮助
#
# 用法一（交互式，逐项提示输入）：
#   sh openwrt-setup.sh
#
# 用法二（环境变量预填，非交互）：
#   SERVER_HOST=38.22.94.13 SERVER_PORT=51820 \
#   SERVER_PUBLIC_KEY=xxx VM_PRIVATE_KEY=xxx \
#   TUNNEL_UUID=xxx sh openwrt-setup.sh install
#
# 可选环境变量：
#   VM_IP=10.77.0.2          隧道本机 IP
#   TUNNEL_PORT=5679         对端 interconn 端口（与 VPS 一致）
#   LAN_IF=br-lan            LAN 网卡名（仅备注/兼容旧脚本）
#   KEEPALIVE=25             对端心跳秒数
#   XRAY_ARCH=64             xray 发布包架构后缀（linux-64 / linux-arm64）
#   SKIP_INSTALL=1           跳过 opkg 装包（内核模块/工具已自带时用）
#   DRY_RUN=1                只生成配置，不重载网络/防火墙/不启 relay
#   ASSUME_YES=1             uninstall 跳过确认提示
# ============================================================
set -u

RELAY_DIR=/etc/xray-relay
RELAY_BIN=${RELAY_DIR}/xray
RELAY_CONF=${RELAY_DIR}/config.json
INIT_FILE=/etc/init.d/xray-relay
FW_INCLUDE=/etc/firewall.wg-zt.sh

usage() {
  sed -n '2,31p' "$0"
}

show_keys() {
  echo "== 本机 WireGuard 隧道配置（netifd /etc/config/network） =="
  uci show network.wg0 2>/dev/null
  uci show network.wg0peer 2>/dev/null
  if command -v wg >/dev/null 2>&1; then
    PRIV=$(uci -q get network.wg0.private_key)
    [ -n "$PRIV" ] && echo "本机公钥 = $(echo "$PRIV" | wg pubkey)"
  fi
  echo
  echo "== relay bridge 配置 =="
  cat "$RELAY_CONF" 2>/dev/null || echo "未部署"
}

set_endpoint() {
  # 用法: openwrt-setup.sh set-endpoint <新VPS地址或域名> [端口]
  NEW_HOST=${2:-}
  NEW_PORT=${3:-$(uci -q get network.wg0peer.endpoint_port)}
  NEW_PORT=${NEW_PORT:-51820}
  if [ -z "$NEW_HOST" ]; then
    echo "用法: $0 set-endpoint <新VPS地址或域名> [端口]" >&2
    exit 1
  fi
  PUB=$(uci -q get network.wg0peer.public_key)
  if [ -z "$PUB" ]; then
    echo "错误: 未找到 network.wg0peer，请先完成 install" >&2
    exit 1
  fi

  uci set network.wg0peer.endpoint_host="$NEW_HOST"
  uci set network.wg0peer.endpoint_port="$NEW_PORT"
  uci commit network
  echo "==> 已持久化 endpoint = ${NEW_HOST}:${NEW_PORT}"

  if command -v wg >/dev/null 2>&1; then
    wg set wg0 peer "$PUB" endpoint "${NEW_HOST}:${NEW_PORT}" 2>/dev/null \
      && echo "==> 已生效到运行中的 wg0（下一次心跳即重新握手）" \
      || { echo "==> wg set 未生效，重启 wg0"; ifup wg0 2>/dev/null || true; }
  else
    ifup wg0 2>/dev/null || true
  fi

  echo "-- 当前 wg0 状态 --"
  wg show wg0 2>/dev/null || uci show network.wg0peer
}

do_uninstall() {
  echo "==> 卸载 OpenWrt relay bridge 与 wg0 隧道"
  if [ "${ASSUME_YES:-0}" != "1" ]; then
    printf "确认卸载？停止 relay、删除 %s、移除 wg0 配置 [y/N]: " "$RELAY_DIR"
    read -r ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "已取消"; exit 0; }
  fi

  echo "    停止并移除 relay 服务"
  if [ -x "$INIT_FILE" ]; then
    "$INIT_FILE" stop 2>/dev/null || true
    "$INIT_FILE" disable 2>/dev/null || true
  fi
  killall xray 2>/dev/null || true
  rm -rf "$RELAY_DIR"
  rm -f "$INIT_FILE"

  echo "    移除 netifd wg0 接口"
  ifdown wg0 2>/dev/null || true
  uci -q delete network.wg0peer
  uci -q delete network.wg0
  uci commit network

  echo "    清理防火墙 wg0 归属与 include"
  LAN_ZONE=$(uci show firewall | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='lan'$/\1/p" | head -1)
  if [ -n "$LAN_ZONE" ]; then
    uci -q del_list firewall."$LAN_ZONE".network='wg0'
  fi
  uci -q delete firewall.wgztinc
  rm -f "$FW_INCLUDE"
  uci commit firewall
  /etc/init.d/firewall restart 2>/dev/null || true

  echo "==> 卸载完成（ZeroTier 及其余配置未改动）"
}

case "${1:-install}" in
  install) ;;
  show-keys|keys|show) show_keys; exit 0 ;;
  set-endpoint|endpoint|set-ip) set_endpoint "$@"; exit 0 ;;
  uninstall|remove|rm) do_uninstall; exit 0 ;;
  help|-h|--help) usage; exit 0 ;;
  *) echo "未知子命令: $1" >&2; usage; exit 1 ;;
esac

# ---- 1. 收集参数：环境变量优先，缺什么提示输入 ----
if [ -z "${SERVER_HOST:-}" ]; then
  printf "请输入 VPS IP [38.22.94.13]: "; read -r SERVER_HOST
  SERVER_HOST=${SERVER_HOST:-38.22.94.13}
fi
if [ -z "${SERVER_PORT:-}" ]; then
  printf "请输入 VPS WireGuard 端口 [51820]: "; read -r SERVER_PORT
  SERVER_PORT=${SERVER_PORT:-51820}
fi
if [ -z "${SERVER_PUBLIC_KEY:-}" ]; then
  printf "请输入 VPS WireGuard 公钥（SERVER_PUBLIC_KEY）: "; read -r SERVER_PUBLIC_KEY
fi
if [ -z "${VM_PRIVATE_KEY:-}" ]; then
  printf "请输入本机 WireGuard 私钥（VM_PRIVATE_KEY）: "; read -r VM_PRIVATE_KEY
fi
if [ -z "${TUNNEL_UUID:-}" ]; then
  printf "请输入隧道 UUID（TUNNEL_UUID，VPS show-keys 里取）: "; read -r TUNNEL_UUID
fi
if [ -z "${VM_IP:-}" ]; then
  printf "请输入隧道本机 IP [10.77.0.2]: "; read -r VM_IP
  VM_IP=${VM_IP:-10.77.0.2}
fi
if [ -z "${LAN_IF:-}" ]; then
  printf "请输入 LAN 网卡名 [br-lan]: "; read -r LAN_IF
  LAN_IF=${LAN_IF:-br-lan}
fi
KEEPALIVE=${KEEPALIVE:-25}
TUNNEL_PORT=${TUNNEL_PORT:-5679}
XRAY_ARCH=${XRAY_ARCH:-64}

SERVER_ENDPOINT="${SERVER_HOST}:${SERVER_PORT}"
PEER_IP="${VM_IP%.*}.1"

if [ -z "$SERVER_PUBLIC_KEY" ] || [ -z "$VM_PRIVATE_KEY" ] || [ -z "$TUNNEL_UUID" ]; then
  echo "错误：SERVER_PUBLIC_KEY、VM_PRIVATE_KEY、TUNNEL_UUID 不能为空" >&2
  exit 1
fi

echo "==> 参数确认"
echo "  VPS 端点 : $SERVER_ENDPOINT"
echo "  隧道 IP  : $VM_IP  (对端 $PEER_IP)"
echo "  隧道端口 : $TUNNEL_PORT"
echo "  LAN 网卡 : $LAN_IF"
echo

DRY_RUN=${DRY_RUN:-0}

# ---- 2. 安装 WireGuard 组件（可选） ----
echo "==> 1/5 检查 WireGuard 组件"
if [ "$DRY_RUN" = "1" ]; then
  echo "[DRY_RUN] 跳过 opkg update / install"
elif [ "${SKIP_INSTALL:-0}" = "1" ]; then
  echo "[SKIP_INSTALL] 跳过软件包安装"
else
  opkg update || echo "警告: opkg update 失败（源不可达则用 SKIP_INSTALL=1 跳过）"
  opkg install kmod-wireguard wireguard-tools luci-proto-wireguard || \
    echo "警告: opkg install 失败；若内核模块已在可忽略"
fi

if [ ! -f /lib/netifd/proto/wireguard.sh ]; then
  echo "错误: 未找到 /lib/netifd/proto/wireguard.sh，netifd 无法托管 wireguard 接口" >&2
  echo "      请先安装 luci-proto-wireguard / kmod-wireguard 后重试" >&2
  exit 1
fi

# ---- 3. 写入 netifd 原生 wg0 接口与对端 ----
echo "==> 2/5 写入 netifd wg0 配置"
uci -q delete network.wg0peer || true
uci -q delete network.wg0 || true

uci set network.wg0=interface
uci set network.wg0.proto='wireguard'
uci -q delete network.wg0.addresses || true
uci add_list network.wg0.addresses="${VM_IP}/24"
uci set network.wg0.private_key="${VM_PRIVATE_KEY}"
uci set network.wg0.mtu='1420'

uci set network.wg0peer=wireguard_wg0
uci set network.wg0peer.public_key="${SERVER_PUBLIC_KEY}"
uci set network.wg0peer.endpoint_host="${SERVER_HOST}"
uci set network.wg0peer.endpoint_port="${SERVER_PORT}"
uci -q delete network.wg0peer.allowed_ips || true
uci add_list network.wg0peer.allowed_ips="${PEER_IP}/32"
uci set network.wg0peer.persistent_keepalive="${KEEPALIVE}"

if [ "$DRY_RUN" != "1" ]; then
  uci commit network
  echo "已写入 /etc/config/network（interface wg0 + peer wg0peer）"
else
  echo "[DRY_RUN] 未 commit network"
fi

# ---- 4. 防火墙：wg0/zt 网卡加入 lan 区域 + 持久化 include 放行 ----
echo "==> 3/5 配置防火墙放行"
LAN_ZONE=$(uci show firewall | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='lan'$/\1/p" | head -1)
if [ -n "$LAN_ZONE" ]; then
  # 确保 lan 网桥与 wg0 都在 lan 区域内：缺 lan 时 fw4 不会生成 br-lan 入站
  # 放行规则，LAN 客户端的 DHCP Discover 会被默认 drop 策略丢弃，拿不到 IPv4。
  uci -q del_list firewall."$LAN_ZONE".network='lan' || true
  uci -q del_list firewall."$LAN_ZONE".network='wg0' || true
  uci add_list firewall."$LAN_ZONE".network='lan'
  uci add_list firewall."$LAN_ZONE".network='wg0'
  echo "    lan / wg0 已加入 lan 区域"
else
  echo "    未找到 lan 区域，跳过 zone 归属（靠 include 兜底）"
fi

cat > "$FW_INCLUDE" <<'EOF'
#!/bin/sh
for n in /sys/class/net/zt* /sys/class/net/wg0; do
  [ -e "$n" ] || continue
  n=$(basename "$n")
  nft insert rule inet fw4 input iifname "$n" accept 2>/dev/null || true
  nft insert rule inet fw4 forward iifname "$n" accept 2>/dev/null || true
done
EOF
chmod +x "$FW_INCLUDE"

uci -q delete firewall.wgztinc || true
uci set firewall.wgztinc=include
uci set firewall.wgztinc.type='script'
uci set firewall.wgztinc.path="$FW_INCLUDE"

if [ "$DRY_RUN" != "1" ]; then
  uci commit firewall
  /etc/init.d/network reload || echo "警告: network reload 返回非零"
  /etc/init.d/firewall restart || echo "警告: 防火墙重启返回非零"
  ifup wg0 2>/dev/null || /sbin/ifup wg0 2>/dev/null || true
else
  echo "[DRY_RUN] 未 commit firewall，未重载服务"
fi

# ---- 5. 部署 relay bridge（xray 进程 + procd 自启） ----
echo "==> 4/5 部署 relay bridge"
mkdir -p "$RELAY_DIR"

if [ ! -x "$RELAY_BIN" ] && [ "$DRY_RUN" != "1" ]; then
  echo "    下载 Xray linux-${XRAY_ARCH} 静态二进制..."
  XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.tar.gz"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o /tmp/xray-relay.tar.gz "$XRAY_URL" || DL_FAIL=1
  elif command -v wget >/dev/null 2>&1; then
    wget -O /tmp/xray-relay.tar.gz "$XRAY_URL" || DL_FAIL=1
  else
    DL_FAIL=1
  fi
  if [ "${DL_FAIL:-0}" != "1" ]; then
    tar -xzf /tmp/xray-relay.tar.gz -C "$RELAY_DIR" --strip-components=1 xray
    chmod +x "$RELAY_BIN"
    rm -f /tmp/xray-relay.tar.gz
  else
    echo "    警告: 自动下载失败；请手动把 xray 二进制放到 ${RELAY_BIN} 后重跑本脚本" >&2
  fi
fi

cat > "$RELAY_CONF" <<EOF
{
  "log": { "loglevel": "info" },
  "dns": {
    "queryStrategy": "UseIPv4",
    "servers": [ "223.5.5.5", "119.29.29.29" ]
  },
  "outbounds": [
    {
      "tag": "out",
      "protocol": "freedom",
      "settings": { "finalRules": [ { "action": "allow" } ] },
      "streamSettings": { "sockopt": { "domainStrategy": "UseIPv4" } }
    },
    {
      "tag": "tunnel",
      "protocol": "vless",
      "settings": {
        "address": "${PEER_IP}",
        "port": ${TUNNEL_PORT},
        "id": "${TUNNEL_UUID}",
        "encryption": "none",
        "reverse": { "tag": "r-tunnel" }
      },
      "streamSettings": { "network": "tcp" }
    }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": [ "r-tunnel" ], "outboundTag": "out" }
    ]
  }
}
EOF

# procd 开机自启脚本
cat > "$INIT_FILE" <<'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

PROG=/etc/xray-relay/xray
CFG=/etc/xray-relay/config.json

start_service() {
  procd_open_instance
  procd_set_param command "$PROG" run -config "$CFG"
  procd_set_param respawn 3600 5 5
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}

stop_service() {
  killall xray 2>/dev/null || true
}
EOF
chmod +x "$INIT_FILE"

if [ "$DRY_RUN" != "1" ]; then
  "$INIT_FILE" enable
  if [ -x "$RELAY_BIN" ]; then
    "$RELAY_BIN" -test -config "$RELAY_CONF" 2>&1 | tail -2 || true
    killall xray 2>/dev/null || true
    "$INIT_FILE" restart
  else
    echo "    relay 二进制缺失，暂未启动；补齐 ${RELAY_BIN} 后执行 $INIT_FILE start" >&2
  fi
fi

# ---- 6. 自检 ----
echo "==> 5/5 自检"
if [ "$DRY_RUN" != "1" ]; then
  sleep 2
  echo "-- wg0 状态 --"
  ip addr show wg0 2>/dev/null || echo "    wg0 接口尚未出现"
  command -v wg >/dev/null 2>&1 && wg show wg0 || true
  echo "-- relay 进程 --"
  ps | grep -E 'xray' | grep -v grep || echo "    relay 未运行"
  echo "-- ping 隧道对端 $PEER_IP --"
  if ping -c 3 -W 3 "$PEER_IP"; then
    echo "隧道已通。回 VPS 上 wg show / ss -tnlp | grep ${TUNNEL_PORT} 应能看到反向隧道连接。"
  else
    echo "隧道不通：检查 Endpoint 可达性、密钥是否填反、${SERVER_PORT}/UDP 是否放行。"
  fi
fi

echo
echo "==================== 部署完成 ===================="
echo "复查命令：sh $0 show-keys"
echo "卸载命令：sh $0 uninstall"

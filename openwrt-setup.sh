#!/bin/sh
# ============================================================
# 一键脚本：国外 OpenWrt VM 侧（交互输入 VPS 地址/端口与密钥）
# 作用：装 WireGuard 客户端配置，拨入 VPS 隧道，放行转发与 NAT
#
# 用法一（交互式，逐项提示输入）：
#   sh openwrt-setup.sh
#
# 用法二（环境变量预填，非交互）：
#   SERVER_HOST=38.22.94.13 SERVER_PORT=51820 \
#   SERVER_PUBLIC_KEY=xxx VM_PRIVATE_KEY=xxx sh openwrt-setup.sh
#
# 可选环境变量：
#   VM_IP=10.77.0.2     隧道本机 IP
#   LAN_IF=br-lan       OpenWrt LAN 网卡名
#   SKIP_INSTALL=1      跳过 opkg 装包（内核模块/工具已自带时用）
#   DRY_RUN=1           只生成配置，不装包/不重启服务（用于校验）
# ============================================================
set -eu

# 子命令：查询本机隧道配置（不改动任何配置）
case "${1:-}" in
  show-keys|keys|show)
    CONF=/etc/wireguard/wg0.conf
    if [ ! -f "$CONF" ]; then
      echo "未找到 $CONF，请先运行本脚本完成部署" >&2
      exit 1
    fi
    echo "== 本机 WireGuard 隧道配置 =="
    grep -E '^(Address|PrivateKey|Endpoint|PublicKey) =' "$CONF"
    if command -v wg >/dev/null 2>&1; then
      PRIV=$(sed -n 's/^PrivateKey = //p' "$CONF")
      echo "本机公钥 = $(echo "$PRIV" | wg pubkey)"
    fi
    exit 0
    ;;
esac

# ---- 1. 收集参数：环境变量优先，缺什么提示输入 ----
if [ -z "${SERVER_HOST:-}" ]; then
  printf "请输入 VPS IP [38.22.94.13]: "; read SERVER_HOST
  SERVER_HOST=${SERVER_HOST:-38.22.94.13}
fi
if [ -z "${SERVER_PORT:-}" ]; then
  printf "请输入 VPS WireGuard 端口 [51820]: "; read SERVER_PORT
  SERVER_PORT=${SERVER_PORT:-51820}
fi
if [ -z "${SERVER_PUBLIC_KEY:-}" ]; then
  printf "请输入 VPS WireGuard 公钥（SERVER_PUBLIC_KEY）: "; read SERVER_PUBLIC_KEY
fi
if [ -z "${VM_PRIVATE_KEY:-}" ]; then
  printf "请输入本机 WireGuard 私钥（VM_PRIVATE_KEY）: "; read VM_PRIVATE_KEY
fi
if [ -z "${VM_IP:-}" ]; then
  printf "请输入隧道本机 IP [10.77.0.2]: "; read VM_IP
  VM_IP=${VM_IP:-10.77.0.2}
fi
if [ -z "${LAN_IF:-}" ]; then
  printf "请输入 LAN 网卡名 [br-lan]: "; read LAN_IF
  LAN_IF=${LAN_IF:-br-lan}
fi

SERVER_ENDPOINT="${SERVER_HOST}:${SERVER_PORT}"

if [ -z "$SERVER_PUBLIC_KEY" ] || [ -z "$VM_PRIVATE_KEY" ]; then
  echo "错误：SERVER_PUBLIC_KEY 和 VM_PRIVATE_KEY 不能为空" >&2
  exit 1
fi

echo "==> 参数确认"
echo "  VPS 端点 : $SERVER_ENDPOINT"
echo "  隧道 IP  : $VM_IP"
echo "  LAN 网卡 : $LAN_IF"
echo

DRY_RUN=${DRY_RUN:-0}

echo "==> 1/4 安装 WireGuard 组件"
if [ "$DRY_RUN" = "1" ]; then
  echo "[DRY_RUN] 跳过 opkg update / install"
elif [ "${SKIP_INSTALL:-0}" = "1" ]; then
  if ! command -v wg >/dev/null 2>&1; then
    echo "错误：SKIP_INSTALL=1 但未找到 wg，请先手动安装 kmod-wireguard / wireguard-tools" >&2
    exit 1
  fi
  if command -v wg-quick >/dev/null 2>&1; then
    echo "[SKIP_INSTALL] 跳过软件包安装（已检测到 wg / wg-quick）"
  else
    echo "[SKIP_INSTALL] 未检测到 wg-quick，将使用手动方式拉起隧道"
  fi
else
  opkg update
  opkg install kmod-wireguard wireguard-tools luci-proto-wireguard
fi

echo "==> 2/4 写入 wg0 配置"
mkdir -p /etc/wireguard
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${VM_IP}/24
PrivateKey = ${VM_PRIVATE_KEY}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${LAN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${LAN_IF} -j MASQUERADE

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${SERVER_ENDPOINT}
AllowedIPs = 10.77.0.1/32
PersistentKeepalive = 25
EOF
chmod 600 /etc/wireguard/wg0.conf
echo "已写入 /etc/wireguard/wg0.conf"

# 拉起隧道：优先 wg-quick；缺失时手动创建接口并加载精简配置
# （wg setconf 不识别 Address/PostUp/PostDown/DNS 等 wg-quick 专属行）
PEER_IP="${VM_IP%.*}.1"
wg_start() {
  if command -v wg-quick >/dev/null 2>&1; then
    wg-quick up wg0
    return 0
  fi
  ip link del wg0 2>/dev/null || true
  ip link add wg0 type wireguard
  ip addr add ${VM_IP}/24 dev wg0
  awk '!/^[[:space:]]*(Address|PostUp|PostDown|DNS)[[:space:]]*=/' \
    /etc/wireguard/wg0.conf > /tmp/wg0-nolink.conf
  wg setconf wg0 /tmp/wg0-nolink.conf
  ip link set wg0 up
  ip route replace ${PEER_IP}/32 dev wg0
  iptables -A FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
  iptables -t nat -A POSTROUTING -o ${LAN_IF} -j MASQUERADE 2>/dev/null || true
}

wg_stop() {
  if command -v wg-quick >/dev/null 2>&1; then
    wg-quick down wg0
    return 0
  fi
  iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
  iptables -t nat -D POSTROUTING -o ${LAN_IF} -j MASQUERADE 2>/dev/null || true
  ip link del wg0 2>/dev/null || true
}

echo "==> 3/4 防火墙放行 wg0"
if [ "$DRY_RUN" != "1" ]; then
  uci -q add_list firewall.lan.network='wg0'
  uci commit firewall || echo "警告: uci commit firewall 返回非零，继续后续步骤"
  /etc/init.d/firewall restart || echo "警告: 防火墙重启返回非零，继续后续步骤"
else
  echo "[DRY_RUN] 跳过 uci 写入与防火墙重启"
fi

echo "==> 4/4 配置开机自启并启动隧道"
cat > /etc/init.d/wg0 <<INIT
#!/bin/sh /etc/rc.common
START=99
STOP=10
WG_IP=${VM_IP}
PEER_IP=${PEER_IP}
CONF=/etc/wireguard/wg0.conf
start() {
    if command -v wg-quick >/dev/null 2>&1; then
        wg-quick up wg0
    else
        ip link add wg0 type wireguard 2>/dev/null
        ip addr add \${WG_IP}/24 dev wg0 2>/dev/null
        awk '!/^[[:space:]]*(Address|PostUp|PostDown|DNS)[[:space:]]*=/' "\$CONF" > /tmp/wg0-nolink.conf
        wg setconf wg0 /tmp/wg0-nolink.conf
        ip link set wg0 up
        ip route replace \${PEER_IP}/32 dev wg0
    fi
}
stop() {
    if command -v wg-quick >/dev/null 2>&1; then
        wg-quick down wg0
    else
        ip link del wg0 2>/dev/null
    fi
}
INIT
chmod +x /etc/init.d/wg0

if [ "$DRY_RUN" != "1" ]; then
  /etc/init.d/wg0 enable || echo "警告: 开机自启注册返回非零"
  wg_start || true
else
  echo "[DRY_RUN] 跳过开机自启与隧道启动"
fi

echo
echo "==================== 部署完成 ===================="
echo "自检：ping -c 3 10.77.0.1"
if [ "$DRY_RUN" != "1" ]; then
  if ping -c 3 10.77.0.1; then
    echo "隧道已通。回 VPS 上 wg show 应能看到握手记录。"
  else
    echo "隧道不通：检查 Endpoint 可达性、密钥是否填反、51820/UDP 是否放行。"
  fi
fi

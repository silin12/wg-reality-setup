#!/bin/sh
# ============================================================
# 一键脚本：国外 OpenWrt VM 侧（交互输入 VPS 地址/端口与密钥）
# 作用：用 netifd 原生 wireguard 协议拨入 VPS 隧道，并持久化放行
#       wg0 / ZeroTier 网卡的本机访问与转发。
# 说明：不依赖 wg-quick（部分固件只装了一半 wireguard-tools，无 wg-quick）。
#
# 用法一（交互式，逐项提示输入）：
#   sh openwrt-setup.sh
#
# 用法二（环境变量预填，非交互）：
#   SERVER_HOST=38.22.94.13 SERVER_PORT=51820 \
#   SERVER_PUBLIC_KEY=xxx VM_PRIVATE_KEY=xxx sh openwrt-setup.sh
#
# 可选环境变量：
#   VM_IP=10.77.0.2        隧道本机 IP
#   LAN_IF=br-lan          OpenWrt LAN 网卡名（仅备注/兼容旧脚本）
#   KEEPALIVE=25           对端心跳秒数
#   SKIP_INSTALL=1         跳过 opkg 装包（内核模块/工具已自带时用）
#   DRY_RUN=1              只生成配置，不重载网络/防火墙（用于校验）
# ============================================================
set -u

# 子命令：查询本机隧道配置（不改动任何配置）
case "${1:-}" in
  show-keys|keys|show)
    echo "== 本机 WireGuard 隧道配置（netifd /etc/config/network） =="
    uci show network.wg0 2>/dev/null
    uci show network.wg0peer 2>/dev/null
    if command -v wg >/dev/null 2>&1; then
      PRIV=$(uci -q get network.wg0.private_key)
      [ -n "$PRIV" ] && echo "本机公钥 = $(echo "$PRIV" | wg pubkey)"
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
KEEPALIVE=${KEEPALIVE:-25}

SERVER_ENDPOINT="${SERVER_HOST}:${SERVER_PORT}"
PEER_IP="${VM_IP%.*}.1"

if [ -z "$SERVER_PUBLIC_KEY" ] || [ -z "$VM_PRIVATE_KEY" ]; then
  echo "错误：SERVER_PUBLIC_KEY 和 VM_PRIVATE_KEY 不能为空" >&2
  exit 1
fi

echo "==> 参数确认"
echo "  VPS 端点 : $SERVER_ENDPOINT"
echo "  隧道 IP  : $VM_IP  (对端 $PEER_IP)"
echo "  LAN 网卡 : $LAN_IF"
echo

DRY_RUN=${DRY_RUN:-0}

# ---- 2. 安装 WireGuard 组件（可选） ----
echo "==> 1/4 检查 WireGuard 组件"
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
echo "==> 2/4 写入 netifd wg0 配置"
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
echo "==> 3/4 配置防火墙放行"
LAN_ZONE=$(uci show firewall | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='lan'$/\1/p" | head -1)
if [ -n "$LAN_ZONE" ]; then
  uci -q del_list firewall.${LAN_ZONE}.network='wg0' || true
  uci add_list firewall.${LAN_ZONE}.network='wg0'
  echo "    wg0 已加入 lan 区域"
else
  echo "    未找到 lan 区域，跳过 zone 归属（靠 include 兜底）"
fi

cat > /etc/firewall.wg-zt.sh <<'EOF'
#!/bin/sh
for n in /sys/class/net/zt* /sys/class/net/wg0; do
  [ -e "$n" ] || continue
  n=$(basename "$n")
  nft insert rule inet fw4 input iifname "$n" accept 2>/dev/null || true
  nft insert rule inet fw4 forward iifname "$n" accept 2>/dev/null || true
done
EOF
chmod +x /etc/firewall.wg-zt.sh

uci -q delete firewall.wgztinc || true
uci set firewall.wgztinc=include
uci set firewall.wgztinc.type='script'
uci set firewall.wgztinc.path='/etc/firewall.wg-zt.sh'

if [ "$DRY_RUN" != "1" ]; then
  uci commit firewall
  /etc/init.d/network reload || echo "警告: network reload 返回非零"
  /etc/init.d/firewall restart || echo "警告: 防火墙重启返回非零"
  ifup wg0 2>/dev/null || /sbin/ifup wg0 2>/dev/null || true
else
  echo "[DRY_RUN] 未 commit firewall，未重载服务"
fi

# ---- 5. 自检 ----
echo "==> 4/4 自检"
if [ "$DRY_RUN" != "1" ]; then
  sleep 2
  echo "-- wg0 状态 --"
  ip addr show wg0 2>/dev/null || echo "    wg0 接口尚未出现"
  command -v wg >/dev/null 2>&1 && wg show wg0 || true
  echo "-- ping 隧道对端 $PEER_IP --"
  if ping -c 3 -W 3 "$PEER_IP"; then
    echo "隧道已通。回 VPS 上 wg show 应能看到握手记录。"
  else
    echo "隧道不通：检查 Endpoint 可达性、密钥是否填反、${SERVER_PORT}/UDP 是否放行。"
  fi
fi

echo
echo "==================== 部署完成 ===================="
echo "复查命令：sh $0 show-keys"

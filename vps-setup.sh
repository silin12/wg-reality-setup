#!/usr/bin/env bash
# ============================================================
# 一键脚本：VPS 侧（公网入口，Debian/Ubuntu）
# 架构：VLESS 反向代理（Portal）
#   PC --VLESS+REALITY:5678--> VPS portal --反向隧道(WG 内网)--> OpenWrt VM bridge
#   实际出网由 VM bridge 的 freedom 走它自己的本地宽带上行，VPS 只做中继。
#
# 子命令：
#   install      部署 WireGuard 服务端 + Xray portal（默认进编号菜单）
#   show-keys    查看已保存的密钥 / 隧道参数 / 客户端链接（只读）
#   refresh-link 换 IP 后重建客户端链接（密钥 / 端口 / 配置不变）
#   uninstall    停止并卸载 portal 与 wg0 隧道（保留 xray 二进制，除非 PURGE_XRAY=1）
#   help         显示本帮助
#
# 用法：
#   bash vps-setup.sh                 # 进入主菜单（1安装 2查询 3改IP 4卸载 0退出）
#   bash vps-setup.sh [install|show-keys|refresh-link [新IP]|uninstall|help]
#
# 可选环境变量（install 时生效）：
#   VMLAN=192.168.4.0/24          # OpenWrt VM 的内网网段
#   WAN_IF=ens17                  # VPS 公网网卡
#   REALITY_PORT=5678             # REALITY 入站端口（PC 连接）
#   TUNNEL_PORT=5679              # interconn 反向隧道入站（只绑 WG 内网地址）
#   SERVER_PUBLIC_IP=38.22.94.13  # VPS 公网 IP（写进客户端链接）
#   ASSUME_YES=1                  # uninstall 跳过确认提示
#   PURGE_XRAY=1                  # uninstall 时一并删除 xray 二进制与服务
# ============================================================
set -euo pipefail

WG_PORT=${WG_PORT:-51820}
WG_NET=10.77.0.0/24
WG_VPS_IP=10.77.0.1
WG_VM_IP=10.77.0.2
VMLAN=${VMLAN:-}
WAN_IF=${WAN_IF:-ens17}
REALITY_PORT=${REALITY_PORT:-5678}
TUNNEL_PORT=${TUNNEL_PORT:-5679}
SERVER_PUBLIC_IP=${SERVER_PUBLIC_IP:-38.22.94.13}
REALITY_SNI=${REALITY_SNI:-www.microsoft.com}
REALITY_DEST=${REALITY_DEST:-www.microsoft.com:443}
XRAY_BIN=/usr/local/bin/xray
XRAY_CONF=/usr/local/etc/xray/config.json
KEYS_FILE=/etc/wireguard/keys.env
LINK_FILE=/etc/wireguard/client-link.txt

usage() {
  sed -n '2,27p' "$0"
}

show_keys() {
  if [ ! -f "$KEYS_FILE" ]; then
    echo "未找到 $KEYS_FILE，请先运行本脚本完成部署" >&2
    return 1
  fi
  echo "== WireGuard / 反向隧道参数（OpenWrt 端部署时填） =="
  grep -E '^(SERVER_PUBLIC_KEY|VM_PRIVATE_KEY|VM_IP|VMLAN|TUNNEL_UUID|TUNNEL_PORT|WG_VPS_IP)=' "$KEYS_FILE"
  if [ -f "$LINK_FILE" ]; then
    echo
    echo "== 中国侧客户端 vless 链接 =="
    cat "$LINK_FILE"
  fi
}

refresh_link() {
  # 用法: vps-setup.sh refresh-link [新公网IP]
  [ -f "$KEYS_FILE" ] || { echo "未找到 $KEYS_FILE，请先完成部署" >&2; exit 1; }  # shellcheck disable=SC1090
  . "$KEYS_FILE"

  # 兜底：旧部署未把客户端参数落 keys.env 时，从现有 portal 配置解析
  if [ -z "${UUID:-}" ] && [ -f "$XRAY_CONF" ]; then
    UUID=$(sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' "$XRAY_CONF" | head -1)
  fi
  if [ -z "${REALITY_PUB:-}" ] && [ -f "$XRAY_CONF" ]; then
    PRIV=$(sed -n 's/.*"privateKey": *"\([^"]*\)".*/\1/p' "$XRAY_CONF" | head -1)
    [ -n "${PRIV:-}" ] && REALITY_PUB=$("$XRAY_BIN" x25519 -i "$PRIV" | sed -n 's/^Password (PublicKey): //p')
  fi
  if [ -z "${SHORT_ID:-}" ] && [ -f "$XRAY_CONF" ]; then
    SHORT_ID=$(sed -n '/"shortIds"/{n; s/^[[:space:]]*"\([^"]*\)".*/\1/p; q}' "$XRAY_CONF")
  fi
  if [ -z "${REALITY_SNI:-}" ] && [ -f "$XRAY_CONF" ]; then
    REALITY_SNI=$(sed -n '/"serverNames"/{n; s/^[[:space:]]*"\([^"]*\)".*/\1/p; q}' "$XRAY_CONF")
  fi
  [ -z "${REALITY_PORT:-}" ] && REALITY_PORT=${REALITY_PORT:-5678}

  NEW_IP=${1:-}
  if [ -z "$NEW_IP" ]; then
    NEW_IP=$(curl -s --max-time 5 https://ifconfig.me || true)
    [ -z "$NEW_IP" ] && NEW_IP=$(curl -s --max-time 5 https://api.ip.sb/ip || true)
  fi
  NEW_IP=$(echo "$NEW_IP" | tr -d '[:space:]')
  if [ -z "$NEW_IP" ]; then
    echo "无法自动获取公网 IP，请手动传入: $0 refresh-link <IP>" >&2
    exit 1
  fi

  CLIENT_LINK="vless://${UUID}@${NEW_IP}:${REALITY_PORT}?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&flow=xtls-rprx-vision&type=tcp#foreign-relay"
  printf '%s\n' "$CLIENT_LINK" > "$LINK_FILE"
  chmod 600 "$LINK_FILE"
  echo "==> 客户端链接已更新（endpoint = ${NEW_IP}:${REALITY_PORT}，密钥不变）"
  echo "$CLIENT_LINK"
}

do_uninstall() {
  echo "==> 卸载 VPS portal 与 WireGuard 隧道"
  echo "    注意: 本脚本只清理本方案组件；不触碰 Docker 容器、/tpdata 与"
  echo "    Trojan Panel 相关服务（panel / core / dbguard / tpbackup / redis / mariadb / caddy）。"
  if [ "${ASSUME_YES:-0}" != "1" ]; then
    printf "确认卸载？将停止本方案 xray portal、删除其配置与 wg0 配置 [y/N]: "
    read -r ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "已取消"; exit 0; }
  fi

  MARKER="${XRAY_CONF}.wg-reality"
  if [ ! -f "$MARKER" ]; then
    echo "    警告: 未找到标记 $MARKER，当前 xray 配置可能不属于本方案；"
    echo "    为避免影响混部的 Trojan Panel，跳过 xray 服务与配置的删除。"
  else
    echo "    停止并禁用本方案 xray portal 服务"
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true

    if [ -f "$XRAY_CONF" ]; then
      cp -a "$XRAY_CONF" "${XRAY_CONF}.bak-uninstall"
      rm -f "$XRAY_CONF"
      echo "    已删除 portal 配置（备份: ${XRAY_CONF}.bak-uninstall）"
    fi
    rm -f "$MARKER"
  fi

  echo "    拆除 wg0 隧道"
  wg-quick down wg0 2>/dev/null || true
  systemctl disable wg-quick@wg0 2>/dev/null || true
  rm -f /etc/wireguard/wg0.conf "$KEYS_FILE" "$LINK_FILE"

  rm -f /etc/sysctl.d/99-wg-reality.conf

  if [ "${PURGE_XRAY:-0}" = "1" ]; then
    echo "    警告: PURGE_XRAY=1 会移除系统 xray 二进制与服务单元；"
    echo "    混部 Trojan Panel 的机器上请勿使用（面板自带核心在 /tpdata/bin 下，不受影响）。"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove || true
  fi

  echo "==> 卸载完成"
}

pause_to_menu() {
  echo
  printf "按回车返回主菜单，输入 q 退出: "
  read -r back || { echo; exit 0; }
  case "$back" in q|quit|exit) echo "Bye."; exit 0 ;; esac
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    echo "=============================================================="
    echo " WG-Reality Portal · VPS 侧（Debian/Ubuntu）"
    echo "=============================================================="
    echo " 1. 安装 / 部署 portal（WireGuard + Xray）"
    echo " 2. 查看密钥与客户端链接"
    echo " 3. 更换 VPS IP（重建客户端链接，密钥不变）"
    echo " 4. 卸载 portal 与 wg0 隧道"
    echo " 0. 退出"
    echo "=============================================================="
    printf "请选择 (0 退出): "
    read -r opt || { echo; exit 0; }
    case "$opt" in
      1) return 0 ;;
      2) show_keys; pause_to_menu ;;
      3) refresh_link ""; pause_to_menu ;;
      4) do_uninstall; pause_to_menu ;;
      0|q|quit|exit) echo "Bye."; exit 0 ;;
      *) echo "无此选项，请重新输入"; sleep 1 ;;
    esac
  done
}

case "${1:-}" in
  install) ;;
  show-keys|keys|show) show_keys; exit 0 ;;
  refresh-link|relink|refresh) refresh_link "$2"; exit 0 ;;
  uninstall|remove|rm) do_uninstall; exit 0 ;;
  menu) main_menu ;;
  help|-h|--help) usage; exit 0 ;;
  "") main_menu ;;
  *) echo "未知子命令: $1" >&2; usage; exit 1 ;;
esac

# 收集 OpenWrt 内网网段（环境变量优先，缺则提示输入）
if [ -z "$VMLAN" ]; then
  printf "请输入 OpenWrt VM 内网网段 [192.168.4.0/24]: "; read -r VMLAN
  VMLAN=${VMLAN:-192.168.4.0/24}
fi

echo "==> 1/6 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y wireguard-tools curl openssl iptables

echo "==> 2/6 开启 IPv4 转发"
mkdir -p /etc/sysctl.d
if [ -f /etc/sysctl.conf ]; then
  sed -i '/^net.ipv4.ip_forward/d' /etc/sysctl.conf
fi
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-wg-reality.conf
sysctl -w net.ipv4.ip_forward=1

echo "==> 3/6 初始化 WireGuard 服务端（仅作隧道底层，不跑默认路由）"
mkdir -p /etc/wireguard && chmod 600 /etc/wireguard
if [ ! -f /etc/wireguard/wg0.conf ]; then
  SERVER_PRIV="$(wg genkey)"
  VM_PRIV="$(wg genkey)"
  SERVER_PUB="$(echo "$SERVER_PRIV" | wg pubkey)"
  VM_PUB="$(echo "$VM_PRIV" | wg pubkey)"

  umask 077
  cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${WG_VPS_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
PostUp = iptables -C FORWARD -i wg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -C POSTROUTING -s ${WG_NET} -o ${WAN_IF} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${WG_NET} -o ${WAN_IF} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NET} -o ${WAN_IF} -j MASQUERADE 2>/dev/null || true; iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true

[Peer]
# OpenWrt VM
PublicKey = ${VM_PUB}
AllowedIPs = ${WG_VM_IP}/32, ${VMLAN}
EOF

  cat > "$KEYS_FILE" <<EOF
# 由 vps-setup.sh 生成，部署 OpenWrt 端时填到 openwrt-setup.sh 的环境变量
SERVER_PUBLIC_KEY=${SERVER_PUB}
VM_PRIVATE_KEY=${VM_PRIV}
VM_IP=${WG_VM_IP}
VMLAN=${VMLAN}
WG_VPS_IP=${WG_VPS_IP}
TUNNEL_PORT=${TUNNEL_PORT}
EOF
  umask 022
fi
systemctl enable --now wg-quick@wg0
wg show

echo "==> 4/6 安装 Xray（如已安装则跳过）"
if [ ! -x "$XRAY_BIN" ]; then
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

echo "==> 5/6 生成 REALITY 密钥、客户端 UUID 与隧道 UUID"
UUID="$(cat /proc/sys/kernel/random/uuid)"
TUNNEL_UUID="$(cat /proc/sys/kernel/random/uuid)"
SHORT_ID="$(openssl rand -hex 8)"
REALITY_OUT="$($XRAY_BIN x25519)"
REALITY_PRIV="$(echo "$REALITY_OUT" | sed -n 's/^PrivateKey: //p')"
REALITY_PUB="$(echo "$REALITY_OUT" | sed -n 's/^Password (PublicKey): //p')"

# 隧道参数落盘（已有 keys.env 时补写，不覆盖已有值）
if [ -f "$KEYS_FILE" ]; then
  grep -q '^TUNNEL_UUID=' "$KEYS_FILE" || echo "TUNNEL_UUID=${TUNNEL_UUID}" >> "$KEYS_FILE"
  grep -q '^TUNNEL_PORT=' "$KEYS_FILE" || echo "TUNNEL_PORT=${TUNNEL_PORT}" >> "$KEYS_FILE"
  grep -q '^WG_VPS_IP=' "$KEYS_FILE" || echo "WG_VPS_IP=${WG_VPS_IP}" >> "$KEYS_FILE"
  grep -q '^UUID=' "$KEYS_FILE" || echo "UUID=${UUID}" >> "$KEYS_FILE"
  grep -q '^REALITY_PUB=' "$KEYS_FILE" || echo "REALITY_PUB=${REALITY_PUB}" >> "$KEYS_FILE"
  grep -q '^SHORT_ID=' "$KEYS_FILE" || echo "SHORT_ID=${SHORT_ID}" >> "$KEYS_FILE"
  grep -q '^REALITY_SNI=' "$KEYS_FILE" || echo "REALITY_SNI=${REALITY_SNI}" >> "$KEYS_FILE"
  grep -q '^REALITY_PORT=' "$KEYS_FILE" || echo "REALITY_PORT=${REALITY_PORT}" >> "$KEYS_FILE"
else
  cat > "$KEYS_FILE" <<EOF
SERVER_PUBLIC_KEY=${SERVER_PUB:-}
VM_PRIVATE_KEY=${VM_PRIV:-}
VM_IP=${WG_VM_IP}
VMLAN=${VMLAN}
WG_VPS_IP=${WG_VPS_IP}
TUNNEL_PORT=${TUNNEL_PORT}
TUNNEL_UUID=${TUNNEL_UUID}
UUID=${UUID}
REALITY_PUB=${REALITY_PUB}
SHORT_ID=${SHORT_ID}
REALITY_SNI=${REALITY_SNI}
REALITY_PORT=${REALITY_PORT}
EOF
fi

mkdir -p "$(dirname "$XRAY_CONF")"
cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "terminal",
      "listen": "0.0.0.0",
      "port": ${REALITY_PORT},
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          { "id": "${UUID}", "flow": "xtls-rprx-vision" }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${REALITY_PRIV}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    },
    {
      "tag": "interconn",
      "listen": "${WG_VPS_IP}",
      "port": ${TUNNEL_PORT},
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          { "id": "${TUNNEL_UUID}", "reverse": { "tag": "r-tunnel" } }
        ]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["terminal"], "outboundTag": "r-tunnel" }
    ]
  }
}
EOF

# 标记文件：卸载时据此判断该 xray 配置是否属于本方案（混部面板时避免误删）
printf 'wg-reality portal\nUUID=%s\nTUNNEL_UUID=%s\n' "$UUID" "$TUNNEL_UUID" > "${XRAY_CONF}.wg-reality"

echo "==> 6/6 启动 Xray"
systemctl enable --now xray
systemctl restart xray
sleep 2
systemctl is-active xray

CLIENT_LINK="vless://${UUID}@${SERVER_PUBLIC_IP}:${REALITY_PORT}?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&flow=xtls-rprx-vision&type=tcp#foreign-relay"
printf '%s\n' "$CLIENT_LINK" > "$LINK_FILE"
chmod 600 "$LINK_FILE"

echo
echo "==================== 部署完成 ===================="
echo
echo "【中国侧客户端导入链接】"
echo "$CLIENT_LINK"
echo
echo "【OpenWrt 端部署需要填的值】（也可在 VPS 上 bash $0 show-keys 复查）"
echo "  VPS 公钥 SERVER_PUBLIC_KEY = ${SERVER_PUB:-$(grep SERVER_PUBLIC_KEY "$KEYS_FILE" | cut -d= -f2)}"
echo "  本机私钥 VM_PRIVATE_KEY    = ${VM_PRIV:-$(grep VM_PRIVATE_KEY "$KEYS_FILE" | cut -d= -f2)}"
echo "  隧道 UUID TUNNEL_UUID     = ${TUNNEL_UUID}"
echo "  隧道端口 TUNNEL_PORT      = ${TUNNEL_PORT}"
echo
echo "【自检】"
echo "  VPS: wg show                          # 等 OpenWrt 上线后应有握手"
echo "  VPS: ss -tnlp | grep ${TUNNEL_PORT}   # 应能看到 10.77.0.1:${TUNNEL_PORT} 上的隧道连接"
echo "  中国侧连上后，出口 IP 应为 OpenWrt VM 本地宽带上行 IP（不是本 VPS 的 IP）"
echo
echo "【卸载】bash $0 uninstall"

#!/bin/sh
# ============================================================
# WG-Reality 组网一键脚本（单文件 · 两类部署）
#
# 架构：PC --VLESS+REALITY--> VPS portal --反向隧道(WG)--> OpenWrt bridge
#       实际出网由 OpenWrt bridge 的 freedom 走本机宽带上行（国内 IP）。
#
# 部署类别：
#   vps      公网入口 / 中继：WG 服务端 + Xray portal（REALITY 5678 / 隧道 5679）
#   openwrt  内网 bridge：netifd wg0 客户端 + relay xray（freedom 本机宽带直出）
#
# 用法：
#   sh setup.sh                          # 自动识别系统；识别不了则先选类别
#   sh setup.sh vps [子命令]            # 直接进 VPS 端
#   sh setup.sh openwrt [子命令]         # 直接进 OpenWrt 端
#
# 子命令（各类别一致）：
#   install      部署（默认进编号菜单）
#   show-keys    查看密钥与运行状态（只读摘要，不转储完整配置）
#   show-config  查看完整 xray 配置 JSON（按需调用）
#   refresh-link  VPS：换 IP 后重建客户端链接
#   set-endpoint  OpenWrt：更换 wg0 对端地址 / 端口
#   uninstall    卸载本方案组件（不动混部的其它服务）
#   help         显示本帮助
# ============================================================
set -u

# ---------- 通用 ----------
usage() {
  sed -n '2,24p' "$0"
}

detect_role() {
  if [ -f /etc/openwrt_release ] || command -v opkg >/dev/null 2>&1 || command -v uci >/dev/null 2>&1; then
    echo openwrt
  elif command -v apt-get >/dev/null 2>&1 || command -v dpkg >/dev/null 2>&1; then
    echo vps
  else
    echo unknown
  fi
}

pause_to_menu() {
  echo
  printf "按回车返回主菜单，输入 q 退出: "
  read -r back || { echo; exit 0; }
  case "$back" in q|quit|exit) echo "Bye."; exit 0 ;; esac
}

role_picker() {
  while true; do
    clear 2>/dev/null || true
    echo "=============================================================="
    echo " WG-Reality 组网 · 选择部署类别"
    echo "=============================================================="
    echo " 1. VPS 端（公网 portal / 中继）"
    echo " 2. OpenWrt 端（内网 bridge）"
    echo " 0. 退出"
    echo "=============================================================="
    printf "请选择 (0 退出): "
    read -r r || { echo; exit 0; }
    case "$r" in
      1) ROLE=vps; return 0 ;;
      2) ROLE=openwrt; return 0 ;;
      0|q|quit|exit) echo "Bye."; exit 0 ;;
      *) echo "无此选项，请重新输入"; sleep 1 ;;
    esac
  done
}

# ==================== 类别一：VPS 端（portal） ====================
WG_PORT=${WG_PORT:-51820}
WG_NET=10.77.0.0/24
WG_VPS_IP=10.77.0.1
WG_VM_IP=10.77.0.2
VMLAN=${VMLAN:-}
WAN_IF=${WAN_IF:-}
REALITY_PORT=${REALITY_PORT:-5678}
TUNNEL_PORT=${TUNNEL_PORT:-5679}
SERVER_PUBLIC_IP=${SERVER_PUBLIC_IP:-}
REALITY_SNI=${REALITY_SNI:-www.microsoft.com}
REALITY_DEST=${REALITY_DEST:-www.microsoft.com:443}
XRAY_BIN=/usr/local/bin/xray
XRAY_CONF=/usr/local/etc/xray/config.json
KEYS_FILE=/etc/wireguard/keys.env
LINK_FILE=/etc/wireguard/client-link.txt

portal_show_keys() {
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
  echo
  echo "  xray 服务: $(systemctl is-active xray 2>/dev/null || echo 未知)"
  echo "  完整配置 : $XRAY_CONF（需要查看时执行: $0 vps show-config）"
}

portal_show_config() {
  echo "== portal 完整配置 =="
  cat "$XRAY_CONF" 2>/dev/null || echo "未部署"
}

portal_refresh_link() {
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
    echo "无法自动获取公网 IP，请手动传入: $0 vps refresh-link <IP>" >&2
    exit 1
  fi

  CLIENT_LINK="vless://${UUID}@${NEW_IP}:${REALITY_PORT}?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&flow=xtls-rprx-vision&type=tcp#foreign-relay"
  printf '%s\n' "$CLIENT_LINK" > "$LINK_FILE"
  chmod 600 "$LINK_FILE"
  echo "==> 客户端链接已更新（endpoint = ${NEW_IP}:${REALITY_PORT}，密钥不变）"
  echo "$CLIENT_LINK"
}

portal_uninstall() {
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

portal_install() {
# 收集 OpenWrt 内网网段（环境变量优先，缺则提示输入）
if [ -z "$VMLAN" ]; then
  printf "请输入 OpenWrt VM 内网网段 [192.168.4.0/24]: "; read -r VMLAN
  VMLAN=${VMLAN:-192.168.4.0/24}
fi

echo "==> 1/6 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y wireguard-tools curl openssl iptables

# 自动探测出网网卡与本机公网 IP（环境变量 WAN_IF / SERVER_PUBLIC_IP 可覆盖）
if [ -z "${WAN_IF:-}" ]; then
  DETECT_IF=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
  [ -n "$DETECT_IF" ] && WAN_IF=$DETECT_IF
fi
if [ -z "${SERVER_PUBLIC_IP:-}" ]; then
  SERVER_PUBLIC_IP=$(curl -s --max-time 5 https://ifconfig.me || true)
  [ -z "$SERVER_PUBLIC_IP" ] && SERVER_PUBLIC_IP=$(curl -s --max-time 5 https://api.ip.sb/ip || true)
  SERVER_PUBLIC_IP=$(echo "$SERVER_PUBLIC_IP" | tr -d '[:space:]')
fi
if [ -z "${SERVER_PUBLIC_IP:-}" ]; then
  echo "无法自动获取公网 IP，请先指定后重试: SERVER_PUBLIC_IP=<本VPS公网IP> $0 vps install" >&2
  exit 1
fi
echo "==> 本机公网 IP: ${SERVER_PUBLIC_IP}，出网网卡: ${WAN_IF:-未知}"

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
echo "【OpenWrt 端部署需要填的值】（也可在 VPS 上 $0 vps show-keys 复查）"
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
echo "【卸载】$0 vps uninstall"
}

portal_menu_refresh() {
  printf "请输入新的 VPS 中转 IP（回车自动探测本机公网 IP）: "; read -r ip
  portal_refresh_link "$ip"
}

vps_menu() {
  while true; do
    clear 2>/dev/null || true
    echo "=============================================================="
    echo " WG-Reality Portal · VPS 侧（Debian/Ubuntu）"
    echo "=============================================================="
    echo " 1. 安装 / 部署 portal（WireGuard + Xray）"
    echo " 2. 更换 VPS 中转 IP（重建客户端链接，密钥不变）"
    echo " 3. 查看密钥与客户端链接"
    echo " 4. 卸载 portal 与 wg0 隧道"
    echo " 0. 退出"
    echo "=============================================================="
    printf "请选择 (0 退出): "
    read -r opt || { echo; exit 0; }
    case "$opt" in
      1) portal_install; pause_to_menu ;;
      2) portal_menu_refresh; pause_to_menu ;;
      3) portal_show_keys; pause_to_menu ;;
      4) portal_uninstall; pause_to_menu ;;
      0|q|quit|exit) echo "Bye."; exit 0 ;;
      *) echo "无此选项，请重新输入"; sleep 1 ;;
    esac
  done
}

# ==================== 类别二：OpenWrt 端（bridge） ====================
RELAY_DIR=/etc/xray-relay
RELAY_BIN=${RELAY_DIR}/xray
RELAY_CONF=${RELAY_DIR}/config.json
INIT_FILE=/etc/init.d/xray-relay
FW_INCLUDE=/etc/firewall.wg-zt.sh

bridge_show_keys() {
  echo "== WireGuard 隧道 =="
  echo "  本机 IP   : $(uci -q get network.wg0.addresses)"
  echo "  对端     : $(uci -q get network.wg0peer.endpoint_host):$(uci -q get network.wg0peer.endpoint_port)"
  echo "  对端公钥 : $(uci -q get network.wg0peer.public_key)"
  if command -v wg >/dev/null 2>&1; then
    PRIV=$(uci -q get network.wg0.private_key)
    [ -n "$PRIV" ] && echo "  本机公钥 : $(echo "$PRIV" | wg pubkey)"
    EP=$(wg show wg0 endpoints 2>/dev/null | awk '{print $2}')
    HS=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}')
    echo "  当前 endpoint: ${EP:-未连接}"
    if [ -n "${HS:-}" ] && [ "$HS" != "0" ]; then
      echo "  最近握手 : epoch $HS"
    else
      echo "  最近握手 : 无"
    fi
  fi
  echo
  echo "== relay bridge =="
  [ -x "$RELAY_BIN" ] && echo "  二进制   : $RELAY_BIN 存在" || echo "  二进制   : 缺失"
  if ps 2>/dev/null | grep -E '[x]ray' >/dev/null 2>&1; then
    echo "  进程     : 运行中"
  else
    echo "  进程     : 未运行"
  fi
  echo "  完整配置 : $RELAY_CONF（需要查看时执行: $0 openwrt show-config）"
}

bridge_show_config() {
  echo "== relay bridge 完整配置 =="
  cat "$RELAY_CONF" 2>/dev/null || echo "未部署"
}

bridge_set_endpoint() {
  # 用法: openwrt-setup.sh set-endpoint <新VPS地址或域名> [端口]
  NEW_HOST=${1:-}
  NEW_PORT=${2:-$(uci -q get network.wg0peer.endpoint_port)}
  NEW_PORT=${NEW_PORT:-51820}
  if [ -z "$NEW_HOST" ]; then
    echo "用法: $0 openwrt set-endpoint <新VPS地址或域名> [端口]" >&2
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
    EP=$(wg show wg0 endpoints 2>/dev/null | awk '{print $2}')
    HS=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}')
    echo "==> endpoint: ${EP:-${NEW_HOST}:${NEW_PORT}}"
    if [ -n "${HS:-}" ] && [ "$HS" != "0" ]; then
      echo "==> 对端已有握手（epoch $HS）"
    else
      echo "==> 尚未握手，等下一次心跳"
    fi
  else
    ifup wg0 2>/dev/null || true
    echo "==> endpoint: ${NEW_HOST}:${NEW_PORT}"
  fi
}

bridge_uninstall() {
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

bridge_install() {
# ---- 1. 收集参数：环境变量优先，缺什么提示输入 ----
if [ -z "${SERVER_HOST:-}" ]; then
  printf "请输入 VPS 公网 IP: "; read -r SERVER_HOST
  [ -n "$SERVER_HOST" ] || { echo "未输入 VPS IP，已取消"; exit 1; }
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
echo "复查命令：$0 openwrt show-keys"
echo "卸载命令：$0 openwrt uninstall"
}

bridge_menu() {
  while true; do
    clear 2>/dev/null || true
    echo "=============================================================="
    echo " WG-Reality Bridge · OpenWrt VM 侧"
    echo "=============================================================="
    echo " 1. 安装 / 部署 wg0 隧道 + relay bridge"
    echo " 2. 更换 VPS 中转 IP（修改 wg0 对端 endpoint）"
    echo " 3. 查看隧道与 relay 状态"
    echo " 4. 卸载 relay 与 wg0 隧道"
    echo " 0. 退出"
    echo "=============================================================="
    printf "请选择 (0 退出): "
    read -r opt || { echo; exit 0; }
    case "$opt" in
      1) bridge_install; pause_to_menu ;;
      2) bridge_menu_endpoint; pause_to_menu ;;
      3) bridge_show_keys; pause_to_menu ;;
      4) bridge_uninstall; pause_to_menu ;;
      0|q|quit|exit) echo "Bye."; exit 0 ;;
      *) echo "无此选项，请重新输入"; sleep 1 ;;
    esac
  done
}

bridge_menu_endpoint() {
  printf "请输入新的 VPS 中转 IP 或域名（回车取消）: "; read -r h
  [ -n "$h" ] || { echo "已取消"; return 0; }
  case "$h" in
    *:*) p=${h##*:}; h=${h%:*} ;;
    *) p=51820 ;;
  esac
  printf "请输入对接端口 [%s]: " "$p"; read -r rp
  [ -n "$rp" ] && p=$rp
  bridge_set_endpoint "$h" "$p"
}

# ---------- 入口 ----------
ROLE=${1:-}
SUB=${2:-}

case "$ROLE" in
  vps|portal|v) ROLE=vps ;;
  openwrt|bridge|o|owrt) ROLE=openwrt ;;
  help|-h|--help) usage; exit 0 ;;
  "") ROLE=$(detect_role) ;;
  *) echo "未知类别: $ROLE（vps / openwrt）" >&2; usage; exit 1 ;;
esac

if [ "$ROLE" = "unknown" ]; then
  role_picker
fi

case "$ROLE" in
  vps)
    case "$SUB" in
      "") vps_menu ;;
      install) portal_install ;;
      show-keys|keys|show) portal_show_keys ;;
      show-config|config) portal_show_config ;;
      refresh-link|relink|refresh) portal_refresh_link "${3:-}" ;;
      uninstall|remove|rm) portal_uninstall ;;
      menu) vps_menu ;;
      help|-h|--help) usage ;;
      *) echo "未知子命令: $SUB" >&2; usage; exit 1 ;;
    esac
    ;;
  openwrt)
    case "$SUB" in
      "") bridge_menu ;;
      install) bridge_install ;;
      show-keys|keys|show) bridge_show_keys ;;
      show-config|config) bridge_show_config ;;
      set-endpoint|endpoint|set-ip) bridge_set_endpoint "${3:-}" "${4:-}" ;;
      uninstall|remove|rm) bridge_uninstall ;;
      menu) bridge_menu ;;
      help|-h|--help) usage ;;
      *) echo "未知子命令: $SUB" >&2; usage; exit 1 ;;
    esac
    ;;
esac

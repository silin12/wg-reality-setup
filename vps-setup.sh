#!/usr/bin/env bash
# ============================================================
# 一键脚本：VPS 侧（公网入口，Debian/Ubuntu）
# 架构：VLESS 反向代理（Portal）
#   PC --VLESS+REALITY:5678--> VPS portal --反向隧道(WG 内网)--> OpenWrt VM bridge
#   实际出网由 VM bridge 的 freedom 走它自己的本地宽带上行，VPS 只做中继。
#
# 作用：装 WireGuard 服务端 + Xray portal（REALITY 入口 + interconn 隧道入站），
#       生成密钥、UUID、客户端链接与 VM 侧需要的隧道参数。
#
# 用法：
#   bash vps-setup.sh
# 可选环境变量：
#   VMLAN=192.168.4.0/24          # OpenWrt VM 的内网网段
#   WAN_IF=ens17                  # VPS 公网网卡
#   REALITY_PORT=5678             # REALITY 入站端口（PC 连接）
#   TUNNEL_PORT=5679              # interconn 反向隧道入站（只绑 WG 内网地址）
#   SERVER_PUBLIC_IP=38.22.94.13  # VPS 公网 IP（写进客户端链接）
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

# 子命令：查询已保存的密钥与隧道参数（不改动任何配置）
case "${1:-}" in
  show-keys|keys|show)
    KEYS_FILE=/etc/wireguard/keys.env
    if [ ! -f "$KEYS_FILE" ]; then
      echo "未找到 $KEYS_FILE，请先运行本脚本完成部署" >&2
      exit 1
    fi
    echo "== WireGuard / 反向隧道参数（OpenWrt 端部署时填） =="
    grep -E '^(SERVER_PUBLIC_KEY|VM_PRIVATE_KEY|VM_IP|VMLAN|TUNNEL_UUID|TUNNEL_PORT|WG_VPS_IP)=' "$KEYS_FILE"
    LINK_FILE=/etc/wireguard/client-link.txt
    if [ -f "$LINK_FILE" ]; then
      echo
      echo "== 中国侧客户端 vless 链接 =="
      cat "$LINK_FILE"
    fi
    exit 0
    ;;
esac

# 收集 OpenWrt 内网网段（环境变量优先，缺则提示输入）
if [ -z "$VMLAN" ]; then
  printf "请输入 OpenWrt VM 内网网段 [192.168.4.0/24]: "; read VMLAN
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

  cat > /etc/wireguard/keys.env <<EOF
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

# 隧道 UUID 落盘（已有 keys.env 时补写，不覆盖已有值）
if [ -f /etc/wireguard/keys.env ]; then
  grep -q '^TUNNEL_UUID=' /etc/wireguard/keys.env || echo "TUNNEL_UUID=${TUNNEL_UUID}" >> /etc/wireguard/keys.env
  grep -q '^TUNNEL_PORT=' /etc/wireguard/keys.env || echo "TUNNEL_PORT=${TUNNEL_PORT}" >> /etc/wireguard/keys.env
  grep -q '^WG_VPS_IP=' /etc/wireguard/keys.env || echo "WG_VPS_IP=${WG_VPS_IP}" >> /etc/wireguard/keys.env
else
  cat > /etc/wireguard/keys.env <<EOF
SERVER_PUBLIC_KEY=${SERVER_PUB:-}
VM_PRIVATE_KEY=${VM_PRIV:-}
VM_IP=${WG_VM_IP}
VMLAN=${VMLAN}
WG_VPS_IP=${WG_VPS_IP}
TUNNEL_PORT=${TUNNEL_PORT}
TUNNEL_UUID=${TUNNEL_UUID}
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

echo "==> 6/6 启动 Xray"
systemctl enable --now xray
systemctl restart xray
sleep 2
systemctl is-active xray

CLIENT_LINK="vless://${UUID}@${SERVER_PUBLIC_IP}:${REALITY_PORT}?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&flow=xtls-rprx-vision&type=tcp#foreign-relay"
printf '%s\n' "$CLIENT_LINK" > /etc/wireguard/client-link.txt
chmod 600 /etc/wireguard/client-link.txt

echo
echo "==================== 部署完成 ===================="
echo
echo "【中国侧客户端导入链接】"
echo "$CLIENT_LINK"
echo
echo "【OpenWrt 端部署需要填的值】（也可在 VPS 上 bash $0 show-keys 复查）"
echo "  VPS 公钥 SERVER_PUBLIC_KEY = ${SERVER_PUB:-$(grep SERVER_PUBLIC_KEY /etc/wireguard/keys.env | cut -d= -f2)}"
echo "  本机私钥 VM_PRIVATE_KEY    = ${VM_PRIV:-$(grep VM_PRIVATE_KEY /etc/wireguard/keys.env | cut -d= -f2)}"
echo "  隧道 UUID TUNNEL_UUID     = ${TUNNEL_UUID}"
echo "  隧道端口 TUNNEL_PORT      = ${TUNNEL_PORT}"
echo
echo "【自检】"
echo "  VPS: wg show                          # 等 OpenWrt 上线后应有握手"
echo "  VPS: ss -tnlp | grep ${TUNNEL_PORT}  # 应能看到 10.77.0.1:${TUNNEL_PORT} 上的隧道连接"
echo "  中国侧连上后，出口 IP 应为 OpenWrt VM 本地宽带上行 IP（不是本 VPS 的 IP）"

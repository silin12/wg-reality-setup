#!/usr/bin/env bash
# ============================================================
# 一键脚本：VPS 侧（38.22.94.13，Debian/Ubuntu）
# 作用：装 WireGuard 服务端 + Xray REALITY 入站，生成密钥与客户端链接
# 用法：
#   bash vps-setup.sh
# 可选环境变量：
#   VMLAN=192.168.10.0/24     # 国外 OpenWrt VM 的内网网段
#   WAN_IF=ens17               # VPS 公网网卡
#   REALITY_PORT=5678          # REALITY 入站端口
#   SERVER_PUBLIC_IP=38.22.94.13  # VPS 公网 IP（写进客户端链接）
# ============================================================
set -euo pipefail

WG_PORT=${WG_PORT:-51820}
WG_NET=10.77.0.0/24
WG_VPS_IP=10.77.0.1/24
WG_VM_IP=10.77.0.2
VMLAN=${VMLAN:-192.168.10.0/24}
WAN_IF=${WAN_IF:-ens17}
REALITY_PORT=${REALITY_PORT:-5678}
SERVER_PUBLIC_IP=${SERVER_PUBLIC_IP:-38.22.94.13}
REALITY_SNI=${REALITY_SNI:-www.microsoft.com}
REALITY_DEST=${REALITY_DEST:-www.microsoft.com:443}
XRAY_DIR=/usr/local/xray
XRAY_CONF=/usr/local/etc/xray/config.json

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

echo "==> 3/6 初始化 WireGuard 服务端"
mkdir -p /etc/wireguard && chmod 600 /etc/wireguard
if [ ! -f /etc/wireguard/wg0.conf ]; then
  SERVER_PRIV="$(wg genkey)"
  VM_PRIV="$(wg genkey)"
  SERVER_PUB="$(echo "$SERVER_PRIV" | wg pubkey)"
  VM_PUB="$(echo "$VM_PRIV" | wg pubkey)"

  umask 077
  cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${WG_VPS_IP}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -s ${WG_NET} -o ${WAN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -s ${WG_NET} -o ${WAN_IF} -j MASQUERADE

[Peer]
# 国外 OpenWrt VM
PublicKey = ${VM_PUB}
AllowedIPs = ${WG_VM_IP}/32, ${VMLAN}
EOF

  cat > /etc/wireguard/keys.env <<EOF
# 由 vps-setup.sh 生成，部署 OpenWrt 端时填到 openwrt-setup.sh 的环境变量
SERVER_PUBLIC_KEY=${SERVER_PUB}
VM_PRIVATE_KEY=${VM_PRIV}
VM_IP=${WG_VM_IP}
EOF
  umask 022
fi
systemctl enable --now wg-quick@wg0
wg show

echo "==> 4/6 安装 Xray（如已安装则跳过）"
if [ ! -x "$XRAY_DIR/xray" ]; then
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

echo "==> 5/6 生成 REALITY 密钥与配置"
UUID="$(cat /proc/sys/kernel/random/uuid)"
SHORT_ID="$(openssl rand -hex 8)"
REALITY_OUT="$($XRAY_DIR/xray x25519)"
REALITY_PRIV="$(echo "$REALITY_OUT" | sed -n 's/^Private key: //p')"
REALITY_PUB="$(echo "$REALITY_OUT" | sed -n 's/^Public key: //p')"

mkdir -p "$(dirname "$XRAY_CONF")"
cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
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
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": ["${VMLAN}"], "outboundTag": "direct" }
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

echo
echo "==================== 部署完成 ===================="
echo
echo "【中国侧客户端导入链接】"
echo "$CLIENT_LINK"
echo
echo "【OpenWrt 端运行命令（把下面两个值填进去）】"
echo "SERVER_PUBLIC_KEY=${SERVER_PUB:-$(grep SERVER_PUBLIC_KEY /etc/wireguard/keys.env | cut -d= -f2)}"
echo "VM_PRIVATE_KEY=${VM_PRIV:-$(grep VM_PRIVATE_KEY /etc/wireguard/keys.env | cut -d= -f2)}"
echo
echo "【自检】"
echo "  VPS: ping ${WG_VM_IP}            # 等 OpenWrt 上线后应通"
echo "  VPS: ping <${VMLAN} 内的设备 IP>  # 验证内网可达"

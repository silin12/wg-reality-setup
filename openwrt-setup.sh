#!/bin/sh
# ============================================================
# 一键脚本：国外 OpenWrt VM 侧
# 作用：装 WireGuard 客户端配置，拨入 VPS 隧道，放行转发与 NAT
# 用法（先在 VPS 跑完 vps-setup.sh，拿到两个密钥后）：
#   SERVER_PUBLIC_KEY=<VPS 公钥> VM_PRIVATE_KEY=<VM 私钥> sh openwrt-setup.sh
# 可选环境变量：
#   SERVER_ENDPOINT=38.22.94.13:51820
#   VM_IP=10.77.0.2
#   LAN_IF=br-lan
# ============================================================
set -eu

SERVER_ENDPOINT=${SERVER_ENDPOINT:-38.22.94.13:51820}
SERVER_PUBLIC_KEY=${SERVER_PUBLIC_KEY:-}
VM_PRIVATE_KEY=${VM_PRIVATE_KEY:-}
VM_IP=${VM_IP:-10.77.0.2}
LAN_IF=${LAN_IF:-br-lan}

if [ -z "$SERVER_PUBLIC_KEY" ] || [ -z "$VM_PRIVATE_KEY" ]; then
  echo "缺少参数：先在 VPS 跑完 vps-setup.sh，然后执行："
  echo "  SERVER_PUBLIC_KEY=<VPS 公钥> VM_PRIVATE_KEY=<VM 私钥> sh openwrt-setup.sh"
  exit 1
fi

echo "==> 1/4 安装 WireGuard 组件"
opkg update
opkg install kmod-wireguard wireguard-tools luci-proto-wireguard

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

echo "==> 3/4 防火墙放行 wg0"
uci -q add_list firewall.lan.network='wg0'
uci commit firewall
/etc/init.d/firewall restart

echo "==> 4/4 配置开机自启并启动隧道"
cat > /etc/init.d/wg0 <<'INIT'
#!/bin/sh /etc/rc.common
START=99
STOP=10
start() { wg-quick up wg0 }
stop()  { wg-quick down wg0 }
INIT
chmod +x /etc/init.d/wg0
/etc/init.d/wg0 enable

wg-quick up wg0 || true

echo
echo "==================== 部署完成 ===================="
echo "自检："
echo "  ping -c 3 10.77.0.1"
if ping -c 3 10.77.0.1; then
  echo "隧道已通。回到 VPS 侧 ping 内网设备验证：ping <${VMLAN:-192.168.10.0/24} 内的 IP>"
else
  echo "隧道不通：检查 Endpoint 可达性、SERVER_PUBLIC_KEY / VM_PRIVATE_KEY 是否填反、51820/UDP 是否放行。"
fi

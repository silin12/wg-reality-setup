#!/bin/sh
# ============================================================
# 修复脚本：恢复经 ZeroTier / WireGuard 网卡访问 OpenWrt 本机
# 背景：zt*/wg0 未被防火墙划入允许区域，本机 22/80/443 被拒，
#       但转发到 LAN 其他设备正常。
# 做法：
#   1) 把 zt*/wg0 加入 lan 区域 network 列表
#   2) 注册 fw4 include，按网卡名直接 accept input/forward（兜底，兼容非 netifd 网卡）
#   3) 重启防火墙与 Web/SSH 服务
# 用法：
#   wget -O /tmp/fix.sh https://raw.githubusercontent.com/silin12/wg-reality-setup/main/openwrt-fix-access.sh
#   sh /tmp/fix.sh
# ============================================================
set -eu

echo "==> 1/3 定位 lan 防火墙区域"
LAN_ZONE=$(uci show firewall | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='lan'$/\1/p" | head -1)
ZOO=$(ls /sys/class/net 2>/dev/null | grep -E '^(zt|wg)' || true)
if [ -n "$LAN_ZONE" ]; then
  for IF in $ZOO; do
    uci -q add_list firewall.${LAN_ZONE}.network="$IF"
    echo "    加入 lan 区域: $IF"
  done
else
  echo "    未找到 lan 区域，跳过 zone 归属（靠 nft 兜底）"
fi

echo "==> 2/3 写入 fw4 include（按网卡名放行）"
cat > /etc/firewall.wg-zt.sh <<'EOF'
#!/bin/sh
for n in /sys/class/net/zt* /sys/class/net/wg0; do
  [ -e "$n" ] || continue
  n=$(basename "$n")
  nft add rule inet fw4 input iif "$n" accept 2>/dev/null
  nft add rule inet fw4 forward iif "$n" accept 2>/dev/null
done
EOF
chmod +x /etc/firewall.wg-zt.sh

uci -q delete firewall.wgztinc
uci set firewall.wgztinc=include
uci set firewall.wgztinc.type='script'
uci set firewall.wgztinc.path='/etc/firewall.wg-zt.sh'

echo "==> 3/3 重启防火墙与本机服务"
uci commit firewall
/etc/init.d/firewall restart || echo "    防火墙重启返回非零，继续"
/etc/init.d/uhttpd restart 2>/dev/null || true
/etc/init.d/dropbear restart 2>/dev/null || true

echo
echo "== 监听端口 =="
netstat -ltn 2>/dev/null | grep -E ':(22|80|443)' || echo "    未发现 22/80/443 监听"
echo "== 完成：PC 重试 http://192.168.4.1/ 与 ssh root@10.147.20.20 =="

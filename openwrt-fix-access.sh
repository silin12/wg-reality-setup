#!/bin/sh
# ============================================================
# 修复脚本：恢复经 ZeroTier / WireGuard 网卡访问 OpenWrt 本机
# 背景：zt*/wg0 未被防火墙放行，本机 22/80/443 被拒，转发 LAN 正常。
# 做法：
#   1) 把 zt*/wg0 加入 lan 区域 network 列表
#   2) 注册 fw4 include（持久化，重启后自动补规则）
#   3) 立即用 nft insert 在 input/forward 链头部插入 accept（兜底）
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

echo "==> 2/3 写入 fw4 include（持久化）"
cat > /etc/firewall.wg-zt.sh <<'EOF'
#!/bin/sh
for n in /sys/class/net/zt* /sys/class/net/wg0; do
  [ -e "$n" ] || continue
  n=$(basename "$n")
  nft insert rule inet fw4 input iifname "$n" accept
  nft insert rule inet fw4 forward iifname "$n" accept
done
EOF
chmod +x /etc/firewall.wg-zt.sh

uci -q delete firewall.wgztinc
uci set firewall.wgztinc=include
uci set firewall.wgztinc.type='script'
uci set firewall.wgztinc.path='/etc/firewall.wg-zt.sh'
uci commit firewall

echo "==> 3/3 重启防火墙并立即插入放行规则"
/etc/init.d/firewall restart || echo "    防火墙重启返回非零，继续"

for IF in $ZOO wg0; do
  [ -d "/sys/class/net/$IF" ] || continue
  nft insert rule inet fw4 input iifname "$IF" accept 2>/dev/null || true
  nft insert rule inet fw4 forward iifname "$IF" accept 2>/dev/null || true
  echo "    已放行: $IF"
done

echo
echo "== input 链中 zt/wg 规则 =="
nft list chain inet fw4 input 2>/dev/null | grep -E 'zt|wg0' || echo "    未找到"
echo "== 监听端口 =="
netstat -ltn 2>/dev/null | grep -E ':(22|80|443)' || echo "    未发现 22/80/443 监听"
echo "== 完成：PC 重试 http://192.168.4.1/ 与 ssh root@10.147.20.20 =="

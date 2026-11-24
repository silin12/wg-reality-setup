#!/bin/sh
# 诊断脚本（只读）：收集 OpenWrt 本机服务监听、防火墙区域、nft 规则与进程
# 用法：sh openwrt-diag.sh

echo '===== 1. 监听端口 ====='
netstat -ltn 2>/dev/null || ss -ltn

echo '===== 2. 本机自访问 ====='
curl -s -m3 -o /dev/null -w 'uhttpd_4.1=%{http_code}\n' http://192.168.4.1/ 2>/dev/null
curl -s -m3 -o /dev/null -w 'uhttpd_zt=%{http_code}\n' http://10.147.20.20/ 2>/dev/null

echo '===== 3. 防火墙区域与 include ====='
uci show firewall | grep -E 'zone|include'

echo '===== 3b. include 文件内容 ====='
cat /etc/firewall.wg-zt.sh 2>/dev/null || echo 'missing'

echo '===== 4. nft 表与 input 链 ====='
nft list tables 2>/dev/null
nft list chain inet fw4 input 2>/dev/null | head -40

echo '===== 4c. input 链 iifname 规则 ====='
nft list chain inet fw4 input 2>/dev/null | grep iifname

echo '===== 5. iptables-legacy INPUT ====='
iptables-legacy -L INPUT -n -v 2>/dev/null | head -20

echo '===== 6. 服务进程 ====='
ps | grep -E 'uhttpd|dropbear|fw4|nft|xray' | grep -v grep

echo '===== 7. 网卡地址 ====='
ip -4 addr show | grep -E '^[0-9]|inet '

echo '===== 诊断结束 ====='

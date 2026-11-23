# 跨境组网：VPS REALITY 入口 + WireGuard 到国外 OpenWrt VM

## 拓扑

```
中国侧设备(手机/电脑)
   │  VLESS + REALITY (TCP/5678, 伪装成访问 www.microsoft.com)
   ▼
VPS 38.22.94.13 (ens17)
   ├─ Xray REALITY 入站 :5678
   ├─ WireGuard 服务端 wg0 :51820/UDP  10.77.0.1/24
   ▼  WireGuard 隧道
国外 OpenWrt VM (bridge)
   ├─ wg0 10.77.0.2/24
   └─ 出口到它自己的内网 LAN：192.168.10.0/24  ← 占位，按实际网段改
```

- 中国侧连 VPS 的 5678；要访问国外 VM 内网时，客户端把 `192.168.10.0/24` 路由走代理，VPS 经 WireGuard 送到 VM。
- 不做「全局从 VM 出口」：默认流量从 VPS 自己出网；只把目标是国外网段的流量甩给 WireGuard。

## 一键脚本

### 第一步：VPS 上执行（Debian/Ubuntu）

自动装 WireGuard + Xray，生成密钥、UUID、客户端链接：

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/silin12/wg-reality-setup/main/vps-setup.sh)
```

带参数（按 VM 实际网段改）：

```sh
VMLAN=192.168.10.0/24 bash <(curl -fsSL https://raw.githubusercontent.com/silin12/wg-reality-setup/main/vps-setup.sh)
```

跑完输出：中国侧客户端 vless 链接，以及 `SERVER_PUBLIC_KEY`、`VM_PRIVATE_KEY` 两个值。

### 第二步：国外 OpenWrt VM 上执行

先下载脚本（OpenWrt ash 不支持进程替换），再把上一步两个值填进去：

```sh
wget -O /tmp/openwrt-setup.sh https://raw.githubusercontent.com/silin12/wg-reality-setup/main/openwrt-setup.sh
SERVER_PUBLIC_KEY=<VPS 公钥> VM_PRIVATE_KEY=<VM 私钥> sh /tmp/openwrt-setup.sh
```

## 环境变量

### vps-setup.sh

| 变量 | 默认值 | 说明 |
|---|---|---|
| `VMLAN` | `192.168.10.0/24` | 国外 OpenWrt VM 的内网网段 |
| `WAN_IF` | `ens17` | VPS 公网网卡 |
| `REALITY_PORT` | `5678` | REALITY 入站端口 |
| `SERVER_PUBLIC_IP` | `38.22.94.13` | VPS 公网 IP，写进客户端链接 |
| `WG_PORT` | `51820` | WireGuard 服务端端口 |

### openwrt-setup.sh

| 变量 | 默认值 | 说明 |
|---|---|---|
| `SERVER_PUBLIC_KEY` | （必填） | VPS WireGuard 公钥 |
| `VM_PRIVATE_KEY` | （必填） | VM WireGuard 私钥 |
| `SERVER_ENDPOINT` | `38.22.94.13:51820` | VPS 隧道地址 |
| `VM_IP` | `10.77.0.2` | VM 隧道 IP |
| `LAN_IF` | `br-lan` | OpenWrt LAN 网卡 |

## 端口与地址规划

| 项目 | 值 | 说明 |
|---|---|---|
| VPS 公网 | `38.22.94.13` | 网卡 `ens17` |
| REALITY 入站 | TCP `5678` | 中国侧客户端连接 |
| WireGuard 服务端 | UDP `51820` | VM 拨入 |
| WG 隧道网段 | `10.77.0.0/24` | VPS `.1`，VM `.2` |
| 国外 VM 内网段 | `192.168.10.0/24` | **占位，按 VM 实际 LAN 改** |
| REALITY 伪装站 | `www.microsoft.com:443` | 可换 `dl.google.com:443` 等可达大站 |

## 部署前待确认

1. 国外 OpenWrt VM 的实际内网网段（`192.168.x.0/24`）和 LAN 网卡名（通常 `br-lan`）
2. 中国侧设备类型：Windows（v2rayN / Karing 桌面版）还是 Android（v2rayNG / Karing）
3. 是否整段国外内网都走代理（默认是），还是只放行个别 IP

## 连通性自检

1. VPS `wg show` 能看到 VM 握手（latest handshake 非空）
2. VPS `ping 10.77.0.2` 通；VM `ping 10.77.0.1` 通
3. VPS `ping 192.168.10.<VM 内网 IP>` 通
4. 中国侧连上 REALITY 后，浏览器打开 `http://192.168.10.<VM 内网 IP>`

## 客户端

- 手机端：Karing / v2rayNG；Windows 端：Karing 桌面版 / v2rayN
- 导入 vless 链接后，把国外内网段加进「走代理」规则；其余流量直连

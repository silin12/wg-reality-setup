# 跨境组网配置包：VPS REALITY 入口 + WireGuard 到国外 OpenWrt VM

## 拓扑

```
中国侧设备(手机/电脑)
   │  VLESS + REALITY (TCP/5678, 伪装成访问 www.microsoft.com)
   ▼
VPS 38.22.94.13 (ens17)
   ├─ Xray REALITY 入站 :5678
   ├─ WireGuard 服务端 wg0 :51820/UDP
   │     10.77.0.1/24
   ▼  WireGuard 隧道
国外 OpenWrt VM (bridge)
   ├─ wg0 10.77.0.2/24
   └─ 出口到它自己的内网 LAN：192.168.10.0/24  ← 占位，按实际网段改
```

- 中国侧连 VPS 的 5678；要访问国外 VM 内网时，客户端把 `192.168.10.0/24` 路由走代理，VPS 经 WireGuard 送到 VM。
- 不做「全局从 VM 出口」：默认流量从 VPS 自己出网；只把目标是国外网段的流量甩给 WireGuard。要全局走 VM 出口需要另外在 VPS 上改默认路由 + SNAT，风险高，本方案不做。

## 一键脚本

脚本已上架 GitHub 独立仓库 `silin12/wg-reality-setup`，直接用 raw 链接跑。

**第一步：在 VPS 上跑**（自动装 WG + Xray，生成密钥、UUID、客户端链接）

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/silin12/wg-reality-setup/main/vps-setup.sh)
# 可选：VMLAN=192.168.10.0/24 bash <(curl -fsSL https://raw.githubusercontent.com/silin12/wg-reality-setup/main/vps-setup.sh)
```

跑完输出两段东西：中国侧客户端 vless 链接，以及 `SERVER_PUBLIC_KEY`、`VM_PRIVATE_KEY` 两个值。

**第二步：在国外 OpenWrt VM 上跑**（先下载；脚本会逐项提示输入 VPS IP、端口、密钥，直接回车走默认值）

```sh
wget -O /tmp/openwrt-setup.sh https://raw.githubusercontent.com/silin12/wg-reality-setup/main/openwrt-setup.sh
sh /tmp/openwrt-setup.sh
```

也支持环境变量预填、非交互执行：

```sh
SERVER_HOST=38.22.94.13 SERVER_PORT=51820 \
SERVER_PUBLIC_KEY=<VPS 公钥> VM_PRIVATE_KEY=<VM 私钥> sh /tmp/openwrt-setup.sh
```

### OpenWrt 脚本参数

| 变量 | 默认值 | 说明 |
|---|---|---|
| `SERVER_HOST` | `38.22.94.13` | VPS 公网 IP（交互时提示输入） |
| `SERVER_PORT` | `51820` | VPS WireGuard 端口（交互时提示输入） |
| `SERVER_PUBLIC_KEY` | （必填） | VPS WireGuard 公钥 |
| `VM_PRIVATE_KEY` | （必填） | 本机 WireGuard 私钥 |
| `VM_IP` | `10.77.0.2` | 隧道本机 IP |
| `LAN_IF` | `br-lan` | OpenWrt LAN 网卡名 |
| `SKIP_INSTALL` | `0` | 设 `1` 跳过 opkg 装包（内核模块/工具已自带时用） |
| `DRY_RUN` | `0` | 设 `1` 只生成配置，不装包/不重启服务，用于校验 |

### 事后查询密钥

部署完成后，随时可以用脚本的 `show-keys` 子命令复查已保存的密钥，不会改动任何配置：

```sh
# VPS 上查 WireGuard 公钥 / OpenWrt 私钥
bash /root/vps-setup.sh show-keys
# 或走 raw：bash <(curl -fsSL https://raw.githubusercontent.com/silin12/wg-reality-setup/main/vps-setup.sh) show-keys

# OpenWrt 上查本机隧道配置（含本机公钥）
sh /tmp/openwrt-setup.sh show-keys
```

> GitHub 仓库：`silin12/wg-reality-setup`，根目录 `vps-setup.sh`（VPS）、`openwrt-setup.sh`（OpenWrt VM）。手工拆分的模板仍在 `server/`、`openwrt/` 目录备查。

## 端口与地址规划

| 项目 | 值 | 说明 |
|---|---|---|
| VPS 公网 | `38.22.94.13` | 网卡 `ens17` |
| REALITY 入站 | TCP `5678` | 中国侧客户端连接 |
| WireGuard 服务端 | UDP `51820` | VM 拨入 |
| WG 隧道网段 | `10.77.0.0/24` | VPS `.1`，VM `.2` |
| 国外 VM 内网段 | `192.168.10.0/24` | **占位，按 VM 实际 LAN 改** |
| REALITY 伪装站 | `www.microsoft.com:443` | 可换 `dl.google.com:443` 等可达大站 |

## 待补参数（部署前确认）

1. 国外 OpenWrt VM 的实际内网网段（`192.168.x.0/24`）和它 LAN 网卡名（通常 `br-lan`）
2. 中国侧设备类型：Windows（v2rayN / Karing 桌面版）还是 Android（v2rayNG / Karing）
3. 是否需要在客户端把整段国外内网都走代理（默认是），还是只放行个别 IP

## 文件

- `server/wireguard.sh` — VPS 上装 WireGuard、写 `wg0.conf`、开转发和 NAT（参数占位，跑完生成密钥）
- `server/xray-config.json` — VPS 上 Xray REALITY 入站配置模板
- `openwrt/wg0.conf` — 国外 OpenWrt VM 上的 WireGuard 客户端配置模板
- 客户端订阅链接见文末「中国侧客户端」

## 部署顺序

1. VPS：跑 `server/wireguard.sh`，拿到 VM 需要的公钥
2. VPS：装 Xray，填 `server/xray-config.json`，systemd 起服务
3. 国外 VM：装 `kmod-wireguard wireguard-tools luci-proto-wireguard`，填 `openwrt/wg0.conf`，起 wg0，放行转发与 NAT
4. 验证：VPS `ping 10.77.0.2`；VM `ping 10.77.0.1`；从 VPS `ping 192.168.10.x`
5. 中国侧：导入 vless 链接，把国外内网段加到代理路由规则

## VPS 上 Xray 安装与出客户端链接

```sh
# 1. 安装 Xray（官方脚本，装到 /usr/local/bin/xray）
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 2. 生成 REALITY 密钥对，私钥填 config，公钥给客户端
/usr/local/bin/xray x25519

# 3. 生成 UUID 与 shortId
cat /proc/sys/kernel/random/uuid
openssl rand -hex 8

# 4. 把 server/xray-config.json 填好后放到 /usr/local/etc/xray/config.json
systemctl enable --now xray
systemctl status xray
```

客户端分享链接（占位符替换后导入 Karing / v2rayNG / v2rayN）：

```
vless://<UUID>@38.22.94.13:5678?security=reality&sni=www.microsoft.com&fp=chrome&pbk=<REALITY_PUBLIC_KEY>&sid=<SHORT_ID>&flow=xtls-rprx-vision&type=tcp#foreign-relay
```

## 中国侧客户端路由

- 默认：访问国外 VM 内网时，把 `192.168.10.0/24` 加进「走代理」规则；其余流量直连
- 想整体走 VPS 出口：客户端开全局模式（注意这时出口是 VPS 所在地，不是 VM）
- 手机端 Karing / v2rayNG；Windows 端 Karing 桌面版 / v2rayN，导入链接即可

## 连通性自检顺序

1. VPS `wg show` 能看到 VM 握手（latest handshake 非空）
2. VPS `ping 10.77.0.2` 通；VM `ping 10.77.0.1` 通
3. VPS `ping 192.168.10.<VM 内网 IP>` 通
4. 中国侧连上 REALITY 后，浏览器打开 `http://192.168.10.<VM 内网 IP>`


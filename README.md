# 跨境组网：VLESS 反向代理，出口走 OpenWrt 本机宽带

## 这个方案做什么

PC / 手机连上 VPS 的 REALITY 入口后，**VPS 只做中继**；流量经反向隧道回到内网的 OpenWrt VM，由 VM 用它自己的宽带上行出网。也就是「上网就相当于 OpenWrt 那边的人在上网」——出口 IP 是 VM 本地宽带的公网 IP，不是 VPS 的 IP。

- VPS 不做最终出口；VM 上跑的 clash / 代理节点**不参与**本隧道。
- 这是内网穿透式中继，不是科学上网方案：被墙站点在这条国内宽带上本来就打不开。

## 拓扑

```
中国侧 PC（v2rayN / Karing）
  │  VLESS + REALITY  TCP/5678（SNI www.microsoft.com）
  ▼
VPS 公网（portal）
  ├─ terminal 入站  :5678          ← PC 接入
  ├─ interconn 入站 10.77.0.1:5679 ← VM bridge 反向隧道
  └─ 路由 terminal → r-tunnel
  │  WireGuard 底层 10.77.0.0/24（仅承载隧道内层，不跑默认路由）
  ▼
OpenWrt VM（bridge）
  ├─ wg0 10.77.0.2
  ├─ relay xray：tunnel 出站连回 VPS；r-tunnel 入站 → freedom 直出
  └─ freedom → eth1 本地宽带上行（出口 = VM 宽带公网 IP）
```

## 部署分工：哪台装什么

| 组件 / 配置 | VPS（`setup.sh vps`，公网入口/中继） | OpenWrt VM（`setup.sh openwrt`，内网 bridge） |
|---|---|---|
| 系统依赖 | `wireguard-tools`、`curl`、`openssl`、`iptables`；官方 Xray 安装包 | opkg 装 wireguard 内核模块 / kmod、`curl`、`openssl`（已自带可 `SKIP_INSTALL=1`） |
| WireGuard | 服务端 `wg0` `10.77.0.1`，UDP `51820`，`wg-quick@wg0` 自启 | netifd 原生 `wg0` 客户端 `10.77.0.2`，endpoint 指向 VPS `51820` |
| Xray 核心 | 系统 `/usr/local/bin/xray` + systemd `xray.service` | 静态二进制 `/etc/xray-relay/xray` + procd `/etc/init.d/xray-relay` 自启/崩溃重启 |
| 入站 | `terminal` VLESS+REALITY `0.0.0.0:5678`（PC 接入）；`interconn` `10.77.0.1:5679`（反向隧道） | 无公网入站；relay 只经隧道连回 VPS |
| 出站 / 路由 | freedom `direct` 占位；`terminal → r-tunnel` | `tunnel` 出站 → `10.77.0.1:5679`（`reverse.tag`）；`r-tunnel → freedom` 本机宽带直出 |
| 网络 / 防火墙 | `ip_forward=1`；iptables FORWARD / SNAT（wg0 PostUp/PostDown） | lan 区域纳管 `wg0`；firewall include 放行 `wg0` / `zt*` |
| 落盘文件 | `/etc/wireguard/wg0.conf`、`keys.env`、`client-link.txt`、`/usr/local/etc/xray/config.json` | `/etc/config/network`（wg0/wg0peer）、`/etc/xray-relay/`、`/etc/firewall.wg-zt.sh` |
| 明确不装 | relay bridge、procd、Clash 配置 | 官方 Xray 包、systemd、REALITY 公网入口 |

> PC 侧（v2rayN / Karing）只导入 VPS 生成的 vless 链接，不属于这两个服务端脚本。

## 关键实现要点（实测已验证，Xray 26.11.9）

1. 用新版 **VLESS Reverse Proxy**：入站用户 / 出站里带 `reverse.tag`。旧版顶层 `reverse.portals / bridges`（v2ray legacy reverse）在 26.x 已被核心移除，不能再照搬老仓库的 `reverse` 段配置。
2. portal 侧：`terminal` 入站路由到反向出站 `r-tunnel`；`interconn` 入站的 UUID 用户带 `reverse.tag: r-tunnel`。
3. bridge 侧：`tunnel` 出站带 `reverse.tag: r-tunnel`；`r-tunnel` 入站的流量走 `freedom` 出站直连。
4. **freedom 默认安全策略**：反向代理来源的流量默认全黑洞，freedom 必须显式配 `finalRules: [{ "action": "allow" }]` 放行，否则连接全部被 blackhole。
5. bridge DNS 用国内 UDP（`223.5.5.5` / `119.29.29.29`），避开 VM 上 clash 的 fake-ip 劫持；`sockopt.domainStrategy = UseIPv4`。
6. WireGuard 只做隧道底层：`AllowedIPs` 只保留 VM 内网地址，不写 `0.0.0.0/0`；VPS 不做全局默认路由 / SNAT 转发。
7. OpenWrt relay 用 procd（`/etc/init.d/xray-relay`）开机自启、崩溃自动重启。

## 一键部署

### 脚本主菜单

单文件 `setup.sh` 分两个类别：`setup.sh vps`（VPS 端）、`setup.sh openwrt`（OpenWrt 端）；不带类别直接运行会自动识别系统，识别不了则先在类别菜单里选择。进入类别后是统一编号子菜单（`1` 安装 / `2` 查询 / `3` 改 IP / `4` 卸载 / `0` 退出），也可用子命令非交互调用：

| 编号 | 动作 | VPS 子命令 | OpenWrt 子命令 |
|---|---|---|---|
| 1 | 安装 / 部署 | `install` | `install` |
| 2 | 查看密钥与配置 | `show-keys` | `show-keys` |
| 3 | 更换 VPS IP | `refresh-link [IP]` | `set-endpoint <IP> [端口]` |
| 4 | 卸载 | `uninstall` | `uninstall` |
| 0 | 退出 | — | — |

### 一键命令（VPS / OpenWrt 同一条）

两台机器都用下面这一条，脚本自动识别当前是 VPS（Debian/Ubuntu）还是 OpenWrt，进入对应类别菜单：

```sh
(curl -fsSL https://raw.githubusercontent.com/silin12/wg-reality-setup/main/setup.sh -o /root/setup.sh || wget -O /root/setup.sh https://raw.githubusercontent.com/silin12/wg-reality-setup/main/setup.sh) && sh /root/setup.sh
```

- 识别为 **VPS**：装 WG 服务端 + Xray portal（REALITY `5678` / 隧道 `5679`）；
- 识别为 **OpenWrt**：装 netifd `wg0` 客户端 + relay bridge（freedom 本机宽带直出）；
- 识别不了时会先弹类别菜单手动选；也可显式指定类别覆盖识别：`sh /root/setup.sh vps` 或 `sh /root/setup.sh openwrt`。

### VPS 端可选环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `VMLAN` | `192.168.4.0/24` | OpenWrt VM 内网网段 |
| `WAN_IF` | `ens17` | VPS 公网网卡 |
| `REALITY_PORT` | `5678` | REALITY 入站端口（PC 连接） |
| `TUNNEL_PORT` | `5679` | interconn 反向隧道端口（只绑 WG 内网地址） |
| `SERVER_PUBLIC_IP` | `38.22.94.13` | 写进客户端链接的 VPS 公网 IP |

跑完输出：PC 用的 vless 链接，以及 `SERVER_PUBLIC_KEY`、`VM_PRIVATE_KEY`、`TUNNEL_UUID`、`TUNNEL_PORT`（给 OpenWrt 端填）。

### OpenWrt 端环境变量预填、非交互

```sh
SERVER_HOST=38.22.94.13 SERVER_PORT=51820 \
SERVER_PUBLIC_KEY=<VPS 公钥> VM_PRIVATE_KEY=<VM 私钥> TUNNEL_UUID=<隧道 UUID> \
sh /root/setup.sh openwrt install
```

脚本完成：netifd 原生 `wg0` 接口、防火墙放行 `wg0/zt*`、下载 Xray 静态二进制到 `/etc/xray-relay/`、写 bridge 配置与 procd 自启。

可选环境变量：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `VM_IP` | `10.77.0.2` | 隧道本机 IP |
| `TUNNEL_PORT` | `5679` | 对端 interconn 端口（与 VPS 一致） |
| `KEEPALIVE` | `25` | WG 心跳秒数 |
| `XRAY_ARCH` | `64` | Xray 发布包架构后缀（`64` / `arm64`） |
| `SKIP_INSTALL` | `0` | 设 `1` 跳过 opkg 装包 |
| `DRY_RUN` | `0` | 设 `1` 只生成配置，不重载服务 |

### 第三步：Windows 客户端（浏览器打不开 LuCI 时再跑）

```powershell
irm https://raw.githubusercontent.com/silin12/wg-reality-setup/main/pc-fix-luci.ps1 -OutFile $env:TEMP\pc-fix-luci.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\pc-fix-luci.ps1
```

### 复查密钥 / 参数

```sh
# VPS 上查 WireGuard 公钥、隧道 UUID、客户端链接
bash /root/setup.sh vps show-keys

# OpenWrt 上查本机隧道配置与 relay 配置
sh /root/setup.sh openwrt show-keys
```

### 更换 VPS IP

VPS 换公网 IP 后不用重装，按下面三步改：

```sh
# 1. VPS 上重建客户端链接（密钥 / 端口 / 配置不变；不传 IP 则自动探测本机公网 IP）
bash setup.sh vps refresh-link [新IP]

# 2. OpenWrt 上把 WG 对端指向新 IP（保留密钥、peer 与 relay 配置）
sh setup.sh openwrt set-endpoint <新IP> [51820]

# 3. PC 侧用第 1 步输出的新 vless 链接重新导入 v2rayN
```

- VPS 本机监听均为 `0.0.0.0` / 隧道内网地址，WG peer 支持漫游，VPS 侧无需改配置；只需确认新 IP 的防火墙放行 TCP `5678`、UDP `51820`。
- 菜单里选「更换 VPS IP」后直接输入新 IP（OpenWrt 可写 `IP:端口`，默认 `51820`；VPS 回车则自动探测本机公网 IP）；`set-endpoint` 同时写持久化 UCI 并下发到运行中的 `wg0`，`refresh-link` 只更新 `/etc/wireguard/client-link.txt`，不动 xray 配置与隧道密钥；改完只回显 endpoint 与握手状态，不打印整份配置。

### 卸载

两个脚本都带 `uninstall` 子命令，默认二次确认（`ASSUME_YES=1` 跳过提示）：

```sh
# VPS：停止 xray、删除 portal 配置与 wg0 隧道；默认保留 xray 二进制
bash setup.sh vps uninstall
# 连 xray 二进制与服务一并删除：
PURGE_XRAY=1 bash setup.sh vps uninstall

# OpenWrt：停止 relay、删除 /etc/xray-relay、移除 wg0 配置与防火墙归属
sh /root/setup.sh openwrt uninstall
```

- VPS 的 portal 配置删除前会另存 `config.json.bak-uninstall`；脚本靠 `.wg-reality` 标记识别本方案配置，缺标记会跳过 xray 服务/配置删除，避免误删混部的其它实例。
- **混部 Trojan Panel**：面板跑在 Docker 容器里、自带核心在 `/tpdata/.../bin`，卸载不触碰容器、`/tpdata`、面板/数据库/缓存服务；混部机器上**不要**用 `PURGE_XRAY=1`。
- OpenWrt 卸载只清理本方案的 relay / wg0 / 防火墙 include，不动 ZeroTier、OpenClash 及其它服务。

## 端口与地址规划

| 项目 | 值 | 说明 |
|---|---|---|
| VPS 公网 | `38.22.94.13` | 网卡 `ens17` |
| REALITY 入站 | TCP `5678` | 中国侧客户端连接 |
| 反向隧道入站 | TCP `5679` | 只绑 `10.77.0.1`，VM bridge 拨入 |
| WG 底层 | UDP `51820` | 隧道网段 `10.77.0.0/24`，VPS `.1`，VM `.2` |
| VM 内网段 | `192.168.4.0/24` | 按 VM 实际 LAN 改 |
| REALITY 伪装站 | `www.microsoft.com:443` | 可换其他可达大站 |

## 验证顺序

1. VPS `wg show` 能看到 VM 握手；`ss -tnlp | grep 5679` 有 `10.77.0.1:5679 ↔ 10.77.0.2` 的 ESTAB 连接。
2. PC 连上代理后查 IP：应为 **VM 本地宽带公网 IP（国内归属地）**，不是 VPS 的 `38.22.94.13`。
3. 浏览器打开 `http://192.168.4.1/`（LuCI）返回 200。
4. 国内站点正常访问；被墙站点在这条国内宽带上不可达属预期。

## 客户端路由说明

- 全局模式：所有代理流量都从 VM 宽带出网。
- **v2rayN 注意**：系统代理例外 / `ProxyOverride` 里不能保留 `192.168.*`，否则浏览器访问 LuCI 会被判定为内网直连、绕过代理超时。
- **TUN 模式**：远程桌面（mstsc）等不读系统代理 / SOCKS 的程序，只会按物理网卡路由直连，不会进隧道；要让这类程序访问 `192.168.4.0/24`，需以管理员身份运行 v2rayN 并开启 TUN 模式，由虚拟网卡全局接管流量。
- 本方案不往 VM 的 clash 转发；需要走代理节点是另一套配置，不在本包内。

## 文件

- `setup.sh` — 单文件一键脚本，两类部署：
  - `setup.sh vps` — VPS：WG 服务端 + Xray portal；子命令 `install` / `show-keys` / `refresh-link` / `uninstall`
  - `setup.sh openwrt` — OpenWrt：WG netifd + relay bridge（xray + procd 自启）；子命令 `install` / `show-keys` / `set-endpoint` / `uninstall`
- `pc-fix-luci.ps1` — Windows：清理代理例外里的 `192.168.*`，重启 v2rayN / ZT
- `openwrt-diag.sh` — 只读自检：监听端口、防火墙 zone / include、nft 规则、进程
- `openwrt-fix-access.sh` — 修复 `zt*/wg0` 本机访问被拒

## 已知事项

- WG 底层 UDP 如果被 VM 上的 OpenClash 劫持到代理节点，隧道会绕行海外节点、延迟升高；必要时在 OpenClash 规则里把 VPS IP 加为 DIRECT 旁路。
- relay 二进制由脚本从 Xray 官方 release 拉取；若 OpenWrt 无法访问 GitHub，可手动把同架构 `xray` 二进制放到 `/etc/xray-relay/xray` 再跑脚本。

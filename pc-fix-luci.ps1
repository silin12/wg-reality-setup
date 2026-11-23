# pc-fix-luci.ps1 — 修复 PC 浏览器经代理访问 OpenWrt LuCI(192.168.4.1)
# 根因：系统代理例外含 192.168.*，浏览器把 .4.1 当内网绕过代理直连；直连备用 ZT 通道已断
# 用法：在 PC 上打开 PowerShell，粘贴本文件内容执行（或右键“使用 PowerShell 运行”）
$ErrorActionPreference = 'Continue'
$v2  = 'C:\Users\Nickstation\Desktop\v2rayN-windows-64'
$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

function Test-Port($h, $p) {
  try { $c = New-Object Net.Sockets.TcpClient; $c.Connect($h, $p); $c.Close(); $true }
  catch { $false }
}

# 1) 停掉残留本地代理进程
Get-Process v2rayN, xray -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# 2) v2rayN 配置：例外列表移除 192.168.*
$cfg = Join-Path $v2 'guiConfigs\guiNConfig.json'
if (Test-Path $cfg) {
  $j = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
  $ex = ($j.SystemProxyItem.SystemProxyExceptions -split ';') |
        Where-Object { $_ -and $_.Trim() -ne '192.168.*' }
  $j.SystemProxyItem.SystemProxyExceptions = ($ex -join ';')
  $j | ConvertTo-Json -Depth 100 | Set-Content $cfg -Encoding UTF8
  "[ok] v2rayN 例外列表: $($j.SystemProxyItem.SystemProxyExceptions)"
} else {
  "[warn] 未找到 $cfg"
}

# 3) 注册表例外同步去掉 192.168.*
$ov = ((Get-ItemProperty $reg).ProxyOverride -split ';') |
      Where-Object { $_ -and $_.Trim() -ne '192.168.*' }
Set-ItemProperty $reg ProxyOverride ($ov -join ';')

# 4) 重启 v2rayN，拉起 xray 并应用系统代理
Start-Process (Join-Path $v2 'v2rayN.exe')
Start-Sleep -Seconds 8

# 5) 兜底：10808 没起来就临时关系统代理，避免整机走死代理断网
if (-not (Test-Port '127.0.0.1' 10808)) {
  Set-ItemProperty $reg ProxyEnable 0
  "[warn] 10808 未监听，已临时关闭系统代理；请手动启动 v2rayN 后再开系统代理"
} else {
  "[ok] 本地代理 10808 已监听"
}

# 6) 重启 ZeroTier 备用通道
Restart-Service ZeroTierOne -ErrorAction SilentlyContinue

# 7) 验证：经本地代理访问 LuCI
curl.exe -s -o NUL -w "LuCI 经代理: HTTP %{http_code}  耗时 %{time_total}s`n" --proxy 127.0.0.1:10808 http://192.168.4.1/
"注册表例外: " + (Get-ItemProperty $reg).ProxyOverride

# ============================================================
# Kiro 网络环境检查工具 v1.0 (Windows PowerShell)
# 检测项:
#   1. 系统/浏览器代理配置
#   2. 互联网出口 IP 所在区域及连接风险
#   3. Kiro IDE 的 http.proxy 配置及其所在区域和风险评估
# ============================================================
# 用法: 右键以 PowerShell 运行, 或在终端执行:
#   powershell -ExecutionPolicy Bypass -File CheckKiroNetwork.ps1
# ============================================================

$ErrorActionPreference = "SilentlyContinue"

# ===== 存在连接风险的区域代码 =====
$RiskRegions = @("CN", "HK", "MO")

# ===== 全局结论变量(供汇总使用) 取值: OK / RISK / UNKNOWN =====
$script:LoginVerdict = "UNKNOWN"
$script:LoginDesc = ""
$script:IdeVerdict = "UNKNOWN"
$script:IdeDesc = ""

# ===== 区域代码对应中文名 =====
function Get-RegionName($code) {
    switch ($code.ToUpper()) {
        "CN" { "中国大陆" }
        "HK" { "中国香港" }
        "MO" { "中国澳门" }
        "US" { "美国" }
        "JP" { "日本" }
        "SG" { "新加坡" }
        "DE" { "德国" }
        "KR" { "韩国" }
        "GB" { "英国" }
        "AU" { "澳大利亚" }
        "CA" { "加拿大" }
        "IN" { "印度" }
        "TW" { "中国台湾" }
        default { $code }
    }
}

# ===== Kiro IDE settings.json 路径 (Windows) =====
$KiroSettings = "$env:APPDATA\Kiro\User\settings.json"

# ============================================================
# 工具函数
# ============================================================

function Write-Header($text) {
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
}

function Write-Pass($text)  { Write-Host "  ✓ $text" -ForegroundColor Green }
function Write-Fail($text)  { Write-Host "  ✗ $text" -ForegroundColor Red }
function Write-Warn($text)  { Write-Host "  ⚠ $text" -ForegroundColor Yellow }
function Write-Info($text)  { Write-Host "  ℹ $text" -ForegroundColor Cyan }

function Test-RiskRegion($region) {
    return $RiskRegions -contains $region.ToUpper()
}

# 查询 IP 地理位置 (返回国家代码)
function Get-IpCountry($ip, $proxyUrl) {
    # 方法1: ipinfo.io 直连(国内可达)
    try {
        $c = (Invoke-WebRequest -Uri "https://ipinfo.io/${ip}/country" -TimeoutSec 5 -UseBasicParsing 2>$null).Content.Trim()
        if ($c -and $c.Length -eq 2) { return $c.ToUpper() }
    } catch {}

    # 方法2: ip-api.com 通过代理
    if ($proxyUrl) {
        try {
            $resp = Invoke-RestMethod -Uri "http://ip-api.com/json/${ip}?fields=countryCode" `
                -Proxy $proxyUrl -TimeoutSec 5 2>$null
            if ($resp.countryCode) { return $resp.countryCode }
        } catch {}
    }

    # 方法3: ip-api.com 直连
    try {
        $resp = Invoke-RestMethod -Uri "http://ip-api.com/json/${ip}?fields=countryCode" -TimeoutSec 5 2>$null
        if ($resp.countryCode) { return $resp.countryCode }
    } catch {}

    # 方法4: whois 命令 (如果可用)
    try {
        $whoisResult = & whois $ip 2>$null | Out-String
        $match = [regex]::Match($whoisResult, '(?im)^Country:\s*(\w{2})')
        if ($match.Success) { return $match.Groups[1].Value.ToUpper() }
    } catch {}

    return "UNKNOWN"
}

# 获取 IP 详细信息
function Get-IpDetail($ip, $proxyUrl) {
    if ($proxyUrl) {
        try {
            return Invoke-RestMethod -Uri "http://ip-api.com/json/${ip}?fields=country,city,org,countryCode" `
                -Proxy $proxyUrl -TimeoutSec 5 2>$null
        } catch {}
    }
    try {
        return Invoke-RestMethod -Uri "http://ip-api.com/json/${ip}?fields=country,city,org,countryCode" -TimeoutSec 5 2>$null
    } catch {}
    return $null
}

# 获取出口 IP
function Get-ExitIp {
    # 直连尝试
    $services = @("https://ifconfig.me", "https://api.ipify.org", "https://icanhazip.com")
    foreach ($svc in $services) {
        try {
            $ip = (Invoke-WebRequest -Uri $svc -TimeoutSec 5 -UseBasicParsing 2>$null).Content.Trim()
            if ($ip -match '^\d+\.\d+\.\d+\.\d+$') { return $ip }
        } catch {}
    }

    # 通过代理
    $proxy = if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } elseif ($env:HTTP_PROXY) { $env:HTTP_PROXY } else { $null }
    if ($proxy) {
        try {
            $resp = Invoke-RestMethod -Uri "http://ip-api.com/json/?fields=query" -Proxy $proxy -TimeoutSec 5 2>$null
            if ($resp.query) { return $resp.query }
        } catch {}

        # 白名单模式下用代理 IP
        $proxyHost = Get-ProxyHost $proxy
        $proxyIp = Resolve-ProxyHost $proxyHost
        if ($proxyIp) { return $proxyIp }
    }

    return $null
}

# 从代理 URL 提取 host
function Get-ProxyHost($proxyUrl) {
    $uri = $proxyUrl -replace '^https?://', ''
    if ($uri -match '@') { $uri = ($uri -split '@')[1] }
    $uri = $uri -replace ':\d+/?$', ''
    return $uri
}

# 解析主机名为 IP
function Resolve-ProxyHost($host) {
    if ($host -match '^\d+\.\d+\.\d+\.\d+$') { return $host }
    try {
        $result = [System.Net.Dns]::GetHostAddresses($host) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if ($result) { return $result.IPAddressToString }
    } catch {}
    return $null
}

# 直连方式获取出口 IP (checkip.amazonaws.com 国内可直连)
function Get-IpDirect {
    $services = @("https://checkip.amazonaws.com", "https://ipinfo.io/ip", "https://api.ip.sb/ip")
    foreach ($svc in $services) {
        try {
            $raw = (Invoke-WebRequest -Uri $svc -TimeoutSec 5 -UseBasicParsing 2>$null).Content
            $m = [regex]::Match($raw, '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}')
            if ($m.Success) { return $m.Value }
        } catch {}
    }
    return $null
}

# 获取系统级代理 URL (Windows 系统代理 或 环境变量),供 Kiro IDE 回退判断
function Get-SystemProxyUrl {
    # 1) Windows 系统代理
    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        $proxyEnable = (Get-ItemProperty -Path $regPath -Name ProxyEnable -ErrorAction Stop).ProxyEnable
        $proxyServer = (Get-ItemProperty -Path $regPath -Name ProxyServer -ErrorAction Stop).ProxyServer
        if ($proxyEnable -eq 1 -and $proxyServer) {
            # ProxyServer 可能是 "host:port" 或 "http=host:port;https=host:port"
            if ($proxyServer -match 'https?=([^;]+)') {
                return "http://$($matches[1])"
            }
            return "http://$proxyServer"
        }
    } catch {}
    # 2) 环境变量代理
    if ($env:HTTPS_PROXY) { return $env:HTTPS_PROXY }
    if ($env:HTTP_PROXY)  { return $env:HTTP_PROXY }
    return $null
}

# ============================================================
# 检查1: 网络代理配置
# ============================================================
function Check-SystemProxy {
    Write-Header "检查 1: 网络代理配置"

    $hasProxy = $false

    # Windows 系统代理 (Internet Explorer / 系统设置)
    Write-Info "Windows 系统代理设置:"
    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        $proxyEnable = (Get-ItemProperty -Path $regPath -Name ProxyEnable -ErrorAction Stop).ProxyEnable
        $proxyServer = (Get-ItemProperty -Path $regPath -Name ProxyServer -ErrorAction Stop).ProxyServer
        $autoConfig = (Get-ItemProperty -Path $regPath -Name AutoConfigURL -ErrorAction SilentlyContinue).AutoConfigURL

        if ($proxyEnable -eq 1 -and $proxyServer) {
            Write-Pass "系统代理已开启: $proxyServer"
            $hasProxy = $true
        } else {
            Write-Warn "系统代理未开启"
        }

        if ($autoConfig) {
            Write-Pass "PAC 自动代理: $autoConfig"
            $hasProxy = $true
        }
    } catch {
        Write-Warn "无法读取系统代理设置"
    }

    # 环境变量代理
    Write-Host ""
    Write-Info "环境变量代理:"
    if ($env:HTTP_PROXY)  { Write-Pass "HTTP_PROXY=$($env:HTTP_PROXY)";   $hasProxy = $true }
    if ($env:HTTPS_PROXY) { Write-Pass "HTTPS_PROXY=$($env:HTTPS_PROXY)"; $hasProxy = $true }
    if ($env:http_proxy)  { Write-Pass "http_proxy=$($env:http_proxy)";   $hasProxy = $true }
    if ($env:https_proxy) { Write-Pass "https_proxy=$($env:https_proxy)"; $hasProxy = $true }

    if (-not $env:HTTP_PROXY -and -not $env:HTTPS_PROXY -and -not $env:http_proxy -and -not $env:https_proxy) {
        Write-Warn "未设置代理环境变量"
    }

    Write-Host ""
    if ($hasProxy) {
        Write-Pass "结论: 检测到代理配置"
    } else {
        Write-Fail "结论: 未检测到任何代理配置"
    }
}

# ============================================================
# 检查2: 互联网出口 IP 区域检测
# ============================================================
function Check-ExitIp {
    Write-Header "检查 2: 互联网出口 IP 区域检测（用于 Kiro 登录）"

    # --- 检测默认浏览器 ---
    $browserName = "未知"
    try {
        $progId = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice" -ErrorAction Stop).ProgId
        switch -Wildcard ($progId) {
            "*Chrome*"  { $browserName = "Google Chrome" }
            "*Edge*"    { $browserName = "Microsoft Edge" }
            "*Firefox*" { $browserName = "Firefox" }
            "*Opera*"   { $browserName = "Opera" }
            "*IE*"      { $browserName = "Internet Explorer" }
            default     { $browserName = $progId }
        }
    } catch {}
    Write-Info "默认浏览器: $browserName"

    # --- 检测 Windows 系统代理 (浏览器通常跟随) ---
    $systemProxyUrl = $null
    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        $proxyEnable = (Get-ItemProperty -Path $regPath -Name ProxyEnable -ErrorAction Stop).ProxyEnable
        $proxyServer = (Get-ItemProperty -Path $regPath -Name ProxyServer -ErrorAction Stop).ProxyServer
        $autoConfig = (Get-ItemProperty -Path $regPath -Name AutoConfigURL -ErrorAction SilentlyContinue).AutoConfigURL

        if ($proxyEnable -eq 1 -and $proxyServer) {
            Write-Pass "系统代理已开启: $proxyServer (浏览器跟随此设置)"
            $systemProxyUrl = "http://$proxyServer"
        } else {
            Write-Warn "系统代理未开启（浏览器将直连或使用扩展代理）"
        }

        if ($autoConfig) {
            Write-Pass "PAC 自动代理: $autoConfig"
        }
    } catch {
        Write-Warn "无法读取系统代理设置"
    }

    # --- 获取出口 IP (模拟浏览器网络路径) ---
    Write-Host ""
    Write-Info "正在获取出口 IP（模拟浏览器网络路径）..."
    $exitIp = $null
    $exitMethod = ""

    # 路径1: 通过系统代理
    if ($systemProxyUrl) {
        try {
            $resp = Invoke-RestMethod -Uri "http://ip-api.com/json/?fields=query" -Proxy $systemProxyUrl -TimeoutSec 5 2>$null
            if ($resp.query) { $exitIp = $resp.query; $exitMethod = "通过系统代理 ($proxyServer)" }
        } catch {}
    }

    # 路径2: 直连 (checkip.amazonaws.com 为 AWS 官方,国内可直连)
    if (-not $exitIp) {
        $services = @("https://checkip.amazonaws.com", "https://ipinfo.io/ip", "https://api.ip.sb/ip")
        foreach ($svc in $services) {
            try {
                $raw = (Invoke-WebRequest -Uri $svc -TimeoutSec 5 -UseBasicParsing 2>$null).Content
                $m = [regex]::Match($raw, '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}')
                if ($m.Success) { $exitIp = $m.Value; $exitMethod = "系统直连出口"; break }
            } catch {}
        }
    }

    # 路径3: 通过环境变量代理
    if (-not $exitIp) {
        $envProxy = if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } elseif ($env:HTTP_PROXY) { $env:HTTP_PROXY } else { $null }
        if ($envProxy) {
            try {
                $resp = Invoke-RestMethod -Uri "http://ip-api.com/json/?fields=query" -Proxy $envProxy -TimeoutSec 5 2>$null
                if ($resp.query) { $exitIp = $resp.query; $exitMethod = "通过环境变量代理" }
            } catch {}
        }
    }

    # 路径4: 代理白名单模式,取代理 IP
    if (-not $exitIp) {
        $envProxy = if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } elseif ($env:HTTP_PROXY) { $env:HTTP_PROXY } else { $null }
        if ($envProxy) {
            $proxyHost = Get-ProxyHost $envProxy
            $proxyIp = Resolve-ProxyHost $proxyHost
            if ($proxyIp) { $exitIp = $proxyIp; $exitMethod = "代理服务器地址（代理为白名单模式,无法直接探测出口）" }
        }
    }

    if (-not $exitIp) {
        Write-Fail "无法获取出口 IP"
        Write-Fail "浏览器未配置代理且直连网络无法访问外部服务"
        Write-Warn "Kiro 登录需要浏览器能够访问海外服务,请检查网络或代理配置"
        $script:LoginVerdict = "UNKNOWN"
        $script:LoginDesc = "无法获取浏览器出口 IP，可能浏览器使用了扩展代理(脚本探测不到),请手动在浏览器打开 checkip.amazonaws.com 确认"
        return
    }

    Write-Info "出口 IP: $exitIp"
    Write-Info "获取方式: $exitMethod"
    Write-Info "正在识别所在区域..."

    $proxy = if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } elseif ($env:HTTP_PROXY) { $env:HTTP_PROXY } else { $null }
    $country = Get-IpCountry $exitIp $proxy
    $countryZh = Get-RegionName $country
    Write-Info "所在区域: $countryZh ($country)"

    $detail = Get-IpDetail $exitIp $proxy
    if ($detail -and $detail.org) {
        Write-Info "运营商: $($detail.org)"
    }

    Write-Host ""
    if ($country -eq "UNKNOWN") {
        Write-Warn "结论: 无法识别出口 IP 所在区域"
        $script:LoginVerdict = "UNKNOWN"
        $script:LoginDesc = "无法识别浏览器出口区域"
    } elseif (Test-RiskRegion $country) {
        Write-Fail "结论: 系统直连出口位于 $countryZh ($country)，存在连接风险 — Kiro 登录可能被封号"
        Write-Host ""
        Write-Warn "注意: 若你的浏览器使用了扩展代理(如 SwitchyOmega),该代理运行在浏览器内部,"
        Write-Warn "      本脚本无法探测其真实出口。请在浏览器中打开 https://checkip.amazonaws.com"
        Write-Warn "      自行确认浏览器实际出口 IP 是否为海外。"
        Write-Host ""
        Write-Warn "如浏览器也走直连,请开启海外代理(系统代理/浏览器扩展/VPN)后再登录 Kiro。"
        $script:LoginVerdict = "RISK"
        $script:LoginDesc = "系统直连出口位于 $countryZh ($country)，登录有封号风险(若浏览器用扩展代理请手动确认)"
    } else {
        Write-Pass "结论: 系统直连出口位于 $countryZh ($country)，无连接风险"
        $script:LoginVerdict = "OK"
        $script:LoginDesc = "出口位于 $countryZh ($country)，合规"
    }
}

# ============================================================
# 检查3: Kiro IDE 网络配置
# ============================================================
function Check-KiroProxy {
    Write-Header "检查 3: Kiro IDE 网络配置"

    if (-not (Test-Path $KiroSettings)) {
        Write-Fail "Kiro IDE settings.json 不存在: $KiroSettings"
        Write-Fail "Kiro IDE 可能未安装或未配置"
        $script:IdeVerdict = "UNKNOWN"
        $script:IdeDesc = "未找到 Kiro IDE 配置文件,可能未安装"
        return
    }

    Write-Info "配置文件: $KiroSettings"

    # 读取并提取 http.proxy
    $content = Get-Content $KiroSettings -Raw
    $match = [regex]::Match($content, '"http\.proxy"\s*:\s*"([^"]+)"')

    $proxyUrl = $null
    $proxySource = ""
    if ($match.Success) {
        $proxyUrl = $match.Groups[1].Value
        $proxyDisplay = $proxyUrl -replace '(//[^:]*:)[^@]*(@)', '$1****$2'
        Write-Pass "Kiro IDE 已配置 http.proxy: $proxyDisplay"
        $proxySource = "Kiro IDE http.proxy"
    } else {
        # 未配置 → Kiro IDE (Electron) 回退到系统代理
        Write-Warn "Kiro IDE 未配置 http.proxy，将回退使用系统代理"
        $proxyUrl = Get-SystemProxyUrl
        if ($proxyUrl) {
            $proxyDisplay = $proxyUrl -replace '(//[^:]*:)[^@]*(@)', '$1****$2'
            Write-Pass "检测到系统代理: $proxyDisplay（Kiro IDE 将使用它）"
            $proxySource = "系统代理（回退）"
        } else {
            Write-Warn "系统代理也未配置，Kiro IDE 将走直连"
            $proxySource = "直连"
        }
    }

    # --- 情况: 直连(无任何代理) ---
    if ($proxySource -eq "直连") {
        Write-Info "正在检测直连出口区域..."
        $exitIp = Get-IpDirect
        if (-not $exitIp) {
            Write-Warn "无法获取直连出口 IP，无法判断风险"
            $script:IdeVerdict = "UNKNOWN"
            $script:IdeDesc = "Kiro IDE 走直连,但无法获取出口 IP"
            return
        }
        $country = Get-IpCountry $exitIp $null
        $countryZh = Get-RegionName $country
        Write-Info "直连出口 IP: $exitIp"
        Write-Info "所在区域: $countryZh ($country)"
        Write-Host ""
        if ($country -eq "UNKNOWN") {
            Write-Warn "结论: 无法识别直连出口区域"
            $script:IdeVerdict = "UNKNOWN"
            $script:IdeDesc = "Kiro IDE 走直连,无法识别出口区域"
        } elseif (Test-RiskRegion $country) {
            Write-Fail "结论: Kiro IDE 走直连,出口位于 $countryZh ($country)，不合规 — 存在封号风险"
            Write-Host ""
            Write-Warn "建议: 为 Kiro IDE 配置 http.proxy 海外节点,或开启海外系统代理"
            $script:IdeVerdict = "RISK"
            $script:IdeDesc = "未配任何代理,走直连且出口位于 $countryZh ($country)，有封号风险"
        } else {
            Write-Pass "结论: Kiro IDE 走直连,出口位于 $countryZh ($country)，合规 — 无风险"
            $script:IdeVerdict = "OK"
            $script:IdeDesc = "走直连,出口位于 $countryZh ($country)，合规"
        }
        return
    }

    # --- 情况: 有代理(IDE 自身 或 系统回退) ---
    Write-Info "代理来源: $proxySource"

    # 提取代理 host
    $proxyHost = Get-ProxyHost $proxyUrl
    Write-Info "代理主机: $proxyHost"

    # 解析为 IP
    $proxyIp = Resolve-ProxyHost $proxyHost
    if (-not $proxyIp) {
        Write-Fail "无法解析代理主机 $proxyHost 的 IP 地址"
        return
    }
    Write-Info "代理 IP: $proxyIp"

    # 查询代理 IP 地理位置
    Write-Info "正在识别代理所在区域..."
    $country = Get-IpCountry $proxyIp $proxyUrl
    $countryZh = Get-RegionName $country
    Write-Info "所在区域: $countryZh ($country)"

    $detail = Get-IpDetail $proxyIp $proxyUrl
    if ($detail -and $detail.org) {
        Write-Info "运营商: $($detail.org)"
    }

    # 测试代理连通性
    Write-Host ""
    Write-Info "测试连通性 (连接 app.kiro.dev)..."
    try {
        $response = Invoke-WebRequest -Uri "https://app.kiro.dev" -Proxy $proxyUrl `
            -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        Write-Pass "连通正常: HTTPS → app.kiro.dev (HTTP $($response.StatusCode))"
    } catch {
        try {
            $response = Invoke-WebRequest -Uri "https://app.kiro.dev" -Proxy $proxyUrl `
                -ProxyUseDefaultCredentials -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
            Write-Pass "连通正常: HTTPS → app.kiro.dev (HTTP $($response.StatusCode))"
        } catch {
            Write-Fail "连接失败: 无法通过代理连接 app.kiro.dev"
        }
    }

    Write-Host ""
    if ($country -eq "UNKNOWN") {
        Write-Warn "结论: 无法识别代理所在区域"
        $script:IdeVerdict = "UNKNOWN"
        $script:IdeDesc = "生效代理($proxySource)区域无法识别"
    } elseif (Test-RiskRegion $country) {
        if ($proxySource -eq "Kiro IDE http.proxy") {
            Write-Fail "结论: Kiro IDE proxy 位于 $countryZh ($country)，不合规 — 存在封号风险"
            $sysProxy = Get-SystemProxyUrl
            if ($sysProxy) {
                Write-Host ""
                Write-Warn "IDE proxy 优先级最高,即使系统代理合规也不会被使用 — 请直接修正 Kiro IDE 的 http.proxy 为海外节点"
            }
            $script:IdeVerdict = "RISK"
            $script:IdeDesc = "Kiro IDE http.proxy 位于 $countryZh ($country)，不合规,有封号风险(优先级最高,系统代理救不了)"
        } else {
            Write-Fail "结论: 系统代理位于 $countryZh ($country)，不合规 — Kiro IDE 回退使用它,存在封号风险"
            $script:IdeVerdict = "RISK"
            $script:IdeDesc = "IDE 未配代理,回退的系统代理位于 $countryZh ($country)，不合规,有封号风险"
        }
    } else {
        Write-Pass "结论: 生效代理($proxySource)位于 $countryZh ($country)，合规 — 无风险"
        $script:IdeVerdict = "OK"
        $script:IdeDesc = "生效代理($proxySource)位于 $countryZh ($country)，合规"
    }
}

# ============================================================
# 汇总
# ============================================================
function Write-Summary {
    Write-Header "总结: Kiro 使用风险结论"

    switch ($script:LoginVerdict) {
        "OK"   { $loginIcon = "✓ 无风险";     $loginColor = "Green" }
        "RISK" { $loginIcon = "✗ 有封号风险"; $loginColor = "Red" }
        default{ $loginIcon = "⚠ 待确认";     $loginColor = "Yellow" }
    }
    switch ($script:IdeVerdict) {
        "OK"   { $ideIcon = "✓ 无风险";     $ideColor = "Green" }
        "RISK" { $ideIcon = "✗ 有封号风险"; $ideColor = "Red" }
        default{ $ideIcon = "⚠ 待确认";     $ideColor = "Yellow" }
    }

    Write-Host ""
    Write-Host "  【Kiro 登录】(默认浏览器出口)   " -NoNewline
    Write-Host $loginIcon -ForegroundColor $loginColor
    Write-Host "     $($script:LoginDesc)"
    Write-Host ""
    Write-Host "  【Kiro IDE】(生效代理出口)      " -NoNewline
    Write-Host $ideIcon -ForegroundColor $ideColor
    Write-Host "     $($script:IdeDesc)"
    Write-Host ""

    Write-Host "──────────────────────────────────────────────────" -ForegroundColor Cyan
    if ($script:LoginVerdict -eq "RISK" -or $script:IdeVerdict -eq "RISK") {
        Write-Host "  总体: 存在封号风险，请先修正后再使用 Kiro！" -ForegroundColor Red
    } elseif ($script:LoginVerdict -eq "OK" -and $script:IdeVerdict -eq "OK") {
        Write-Host "  总体: 登录与 IDE 出口均合规，可安全使用 Kiro。" -ForegroundColor Green
    } else {
        Write-Host "  总体: 存在无法确认的项，请按上方提示手动核实。" -ForegroundColor Yellow
    }
    Write-Host "──────────────────────────────────────────────────" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "  处置建议:"
    Write-Host "  • Kiro 登录 → 让默认浏览器走海外出口(系统代理/浏览器扩展/VPN)"
    Write-Host "  • Kiro IDE  → 配置 Kiro IDE 的 http.proxy 为海外节点(优先级最高)"
    Write-Host "                Settings (Ctrl+,) → 搜索 http.proxy"
    Write-Host "  • 自检浏览器真实出口: 浏览器打开 https://checkip.amazonaws.com"
    Write-Host ""
}

# ============================================================
# 主流程
# ============================================================
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║       Kiro 网络环境检查工具 v1.0 (Windows)      ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Green

Check-SystemProxy
Check-ExitIp
Check-KiroProxy
Write-Summary

Write-Host "按任意键退出..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

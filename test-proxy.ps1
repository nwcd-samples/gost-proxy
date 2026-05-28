# 测试 Gost 代理是否正常工作
# 用法: .\test-proxy.ps1 [-Proxy "http://user1:pass123@IP:8080"]

param(
    [string]$Proxy = "http://user1:pass123@localhost:8080"
)

Write-Host "代理地址: $Proxy" -ForegroundColor Cyan
Write-Host "================================"

# 白名单域名（应该通过）
$AllowDomains = @(
    "https://app.kiro.dev",
    "https://prod.us-east-1.auth.desktop.kiro.dev",
    "https://q.us-east-1.amazonaws.com",
    "https://github.com",
    "https://open-vsx.org"
)

# 非白名单域名（应该被拒绝）
$DenyDomains = @(
    "https://www.google.com",
    "https://www.baidu.com",
    "https://example.com"
)

function Test-Url($url, $proxy) {
    try {
        $response = Invoke-WebRequest -Uri $url -Proxy $proxy -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        return $response.StatusCode
    } catch {
        if ($_.Exception.Response) {
            return [int]$_.Exception.Response.StatusCode
        }
        return 0
    }
}

Write-Host "`n✅ 白名单域名测试（应返回 HTTP 状态码）:" -ForegroundColor Green
Write-Host "--------------------------------"
foreach ($url in $AllowDomains) {
    $code = Test-Url $url $Proxy
    if ($code -ne 0) {
        Write-Host "  ✓ $url → $code" -ForegroundColor Green
    } else {
        Write-Host "  ✗ $url → 连接失败（应该通过）" -ForegroundColor Red
    }
}

Write-Host "`n🚫 非白名单域名测试（应被拒绝）:" -ForegroundColor Yellow
Write-Host "--------------------------------"
foreach ($url in $DenyDomains) {
    $code = Test-Url $url $Proxy
    if ($code -eq 0) {
        Write-Host "  ✓ $url → 已拒绝" -ForegroundColor Green
    } else {
        Write-Host "  ✗ $url → $code（不应通过）" -ForegroundColor Red
    }
}

Write-Host "`n🔑 认证测试（错误密码应被拒绝）:" -ForegroundColor Yellow
Write-Host "--------------------------------"
$BadProxy = $Proxy -replace ":[^:@]+@", ":wrongpass@"
$code = Test-Url "https://app.kiro.dev" $BadProxy
if ($code -eq 0 -or $code -eq 407) {
    Write-Host "  ✓ 错误密码被拒绝 → $code" -ForegroundColor Green
} else {
    Write-Host "  ✗ 错误密码未被拒绝 → $code" -ForegroundColor Red
}

Write-Host "`n================================"
Write-Host "测试完成"

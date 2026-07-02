#!/bin/bash
# ============================================================
# Kiro 网络环境检查脚本
# 检测项:
#   1. 系统/浏览器代理配置
#   2. 互联网出口 IP 所在区域及连接风险
#   3. Kiro IDE 的 http.proxy 配置及其所在区域和风险评估
# ============================================================

set -uo pipefail

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ===== 存在连接风险的区域代码 =====
RISK_REGIONS=("CN" "HK" "MO")

# ===== 全局结论变量(供汇总使用) =====
# 取值: OK / RISK / UNKNOWN
LOGIN_VERDICT="UNKNOWN"
LOGIN_DESC=""
IDE_VERDICT="UNKNOWN"
IDE_DESC=""

# ===== 区域代码对应中文名 =====
region_name() {
    case "$1" in
        CN) echo "中国大陆" ;;
        HK) echo "中国香港" ;;
        MO) echo "中国澳门" ;;
        US) echo "美国" ;;
        JP) echo "日本" ;;
        SG) echo "新加坡" ;;
        DE) echo "德国" ;;
        KR) echo "韩国" ;;
        GB) echo "英国" ;;
        AU) echo "澳大利亚" ;;
        CA) echo "加拿大" ;;
        IN) echo "印度" ;;
        TW) echo "中国台湾" ;;
        *) echo "$1" ;;
    esac
}

# ===== Kiro IDE settings.json 路径(macOS) =====
KIRO_SETTINGS="$HOME/Library/Application Support/Kiro/User/settings.json"

# ============================================================
# 工具函数
# ============================================================

print_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

pass() { echo -e "  ${GREEN}✓ $1${NC}"; }
fail() { echo -e "  ${RED}✗ $1${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $1${NC}"; }
info() { echo -e "  ${BLUE}ℹ $1${NC}"; }

# 判断区域是否有连接风险
is_risk_region() {
    local region=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    for r in "${RISK_REGIONS[@]}"; do
        if [[ "$region" == "$r" ]]; then
            return 0  # 有风险
        fi
    done
    return 1  # 无风险
}

# 查询 IP 的地理位置,返回国家代码
# 策略: whois (本地) → ipinfo.io (国内可达) → ip-api.com (通过代理) → ip-api.com (直连)
get_ip_country() {
    local ip="$1"
    local proxy_opt=""
    if [[ -n "${2:-}" ]]; then
        proxy_opt="-x $2"
    fi
    local country=""

    # 方法1: whois 本地查询(最可靠,不需要联网到海外)
    country=$(whois "$ip" 2>/dev/null | grep -i "^Country:" | head -1 | awk '{print $2}' | tr -d '\r\n' | tr '[:lower:]' '[:upper:]' || true)
    if [[ -n "$country" && ${#country} -eq 2 ]]; then
        echo "$country"
        return
    fi

    # 方法2: ipinfo.io 直连(国内可达)
    country=$(curl -s --connect-timeout 5 --noproxy '*' "https://ipinfo.io/${ip}/country" 2>/dev/null | tr -d '\r\n ' || true)
    if [[ -n "$country" && ${#country} -eq 2 ]]; then
        echo "$country"
        return
    fi

    # 方法3: ip-api.com 通过代理
    if [[ -n "$proxy_opt" ]]; then
        country=$(curl -s --connect-timeout 5 $proxy_opt "http://ip-api.com/json/${ip}?fields=countryCode" 2>/dev/null | grep -o '"countryCode":"[^"]*"' | cut -d'"' -f4 || true)
        if [[ -n "$country" ]]; then
            echo "$country"
            return
        fi
    fi

    # 方法4: ip-api.com 直连
    country=$(curl -s --connect-timeout 5 --noproxy '*' "http://ip-api.com/json/${ip}?fields=countryCode" 2>/dev/null | grep -o '"countryCode":"[^"]*"' | cut -d'"' -f4 || true)
    if [[ -n "$country" ]]; then
        echo "$country"
        return
    fi

    echo "UNKNOWN"
}

# 获取 IP 的详细位置信息
get_ip_detail() {
    local ip="$1"
    local proxy_opt=""
    if [[ -n "${2:-}" ]]; then
        proxy_opt="-x $2"
    fi

    # whois 提取详细信息
    local whois_result=$(whois "$ip" 2>/dev/null)
    local org=$(echo "$whois_result" | grep -i "^OrgName:" | head -1 | sed 's/^OrgName:[[:space:]]*//')
    local country=$(echo "$whois_result" | grep -i "^Country:" | head -1 | awk '{print $2}')

    if [[ -n "$org" ]]; then
        echo "{\"country\":\"$country\",\"city\":\"\",\"org\":\"$org\"}"
        return
    fi

    # fallback to ip-api
    curl -s --connect-timeout 5 $proxy_opt "http://ip-api.com/json/${ip}?fields=country,regionName,city,org,countryCode" 2>/dev/null || \
    curl -s --connect-timeout 5 --noproxy '*' "http://ip-api.com/json/${ip}?fields=country,regionName,city,org,countryCode" 2>/dev/null || \
    echo ""
}

# 获取当前出口 IP
get_exit_ip() {
    local ip=""
    # 直连尝试
    ip=$(curl -s --connect-timeout 5 --noproxy '*' https://ifconfig.me 2>/dev/null)
    if [[ -n "$ip" ]]; then echo "$ip"; return; fi

    ip=$(curl -s --connect-timeout 5 --noproxy '*' https://api.ipify.org 2>/dev/null)
    if [[ -n "$ip" ]]; then echo "$ip"; return; fi

    # 通过代理获取
    local proxy="${HTTPS_PROXY:-${HTTP_PROXY:-}}"
    if [[ -n "$proxy" ]]; then
        ip=$(curl -s --connect-timeout 5 -x "$proxy" https://ifconfig.me 2>/dev/null)
        if [[ -n "$ip" ]]; then echo "$ip"; return; fi

        ip=$(curl -s --connect-timeout 5 -x "$proxy" http://ip-api.com/json/?fields=query 2>/dev/null | grep -o '"query":"[^"]*"' | cut -d'"' -f4)
        if [[ -n "$ip" ]]; then echo "$ip"; return; fi

        # 代理白名单模式下,直接用代理IP作为出口
        local proxy_host=$(extract_proxy_host "$proxy")
        local proxy_ip=$(resolve_host "$proxy_host")
        if [[ -n "$proxy_ip" ]]; then
            echo "$proxy_ip"
            return
        fi
    fi

    echo ""
}

# 从代理 URL 中提取 host
extract_proxy_host() {
    local proxy_url="$1"
    echo "$proxy_url" | sed -E 's|^https?://||' | sed -E 's|^[^@]*@||' | sed -E 's|:[0-9]+/?$||'
}

# 解析主机名为 IP
resolve_host() {
    local host="$1"
    if echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "$host"
        return
    fi
    local ip=""
    ip=$(dig +short "$host" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
    if [[ -z "$ip" ]]; then
        ip=$(nslookup "$host" 2>/dev/null | awk '/^Address: / { print $2 }' | grep -E '^[0-9]' | head -1 || true)
    fi
    echo "$ip"
}

# 直连方式获取出口 IP(使用国内可达的 checkip.amazonaws.com 等)
fetch_ip_direct() {
    local svc raw ip
    for svc in "https://checkip.amazonaws.com" "https://ipinfo.io/ip" "https://api.ip.sb/ip" "https://myip.ipip.net"; do
        raw=$(curl -s --connect-timeout 5 --noproxy '*' "$svc" 2>/dev/null || true)
        ip=$(echo "$raw" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1 || true)
        if [[ -n "$ip" ]]; then echo "$ip"; return; fi
    done
    echo ""
}

# 获取系统级代理 URL(macOS 网络接口 或 环境变量),供 Kiro IDE 回退判断
# 返回可用于 curl -x 的代理 URL,无则返回空
get_system_proxy_url() {
    # 1) 系统网络接口代理
    for svc in "Wi-Fi" "Ethernet" "USB 10/100/1000 LAN" "WT12" "Thunderbolt Bridge"; do
        local secure_enabled=$(networksetup -getsecurewebproxy "$svc" 2>/dev/null | grep "^Enabled:" | awk '{print $2}' || true)
        local web_enabled=$(networksetup -getwebproxy "$svc" 2>/dev/null | grep "^Enabled:" | awk '{print $2}' || true)
        if [[ "$secure_enabled" == "Yes" ]]; then
            local phost=$(networksetup -getsecurewebproxy "$svc" | grep "^Server:" | awk '{print $2}')
            local pport=$(networksetup -getsecurewebproxy "$svc" | grep "^Port:" | awk '{print $2}')
            echo "http://${phost}:${pport}"
            return
        elif [[ "$web_enabled" == "Yes" ]]; then
            local phost=$(networksetup -getwebproxy "$svc" | grep "^Server:" | awk '{print $2}')
            local pport=$(networksetup -getwebproxy "$svc" | grep "^Port:" | awk '{print $2}')
            echo "http://${phost}:${pport}"
            return
        fi
    done
    # 2) 环境变量代理
    if [[ -n "${HTTPS_PROXY:-}" ]]; then echo "$HTTPS_PROXY"; return; fi
    if [[ -n "${HTTP_PROXY:-}" ]]; then echo "$HTTP_PROXY"; return; fi
    echo ""
}

# ============================================================
# 检查1: 系统代理 / 浏览器代理
# ============================================================
check_system_proxy() {
    print_header "检查 1: 网络代理配置"

    local has_proxy=false

    # macOS 系统代理
    info "macOS 系统代理设置:"
    local http_enabled=$(scutil --proxy 2>/dev/null | grep "HTTPEnable" | awk '{print $3}')
    local https_enabled=$(scutil --proxy 2>/dev/null | grep "HTTPSEnable" | awk '{print $3}')
    local socks_enabled=$(scutil --proxy 2>/dev/null | grep "SOCKSEnable" | awk '{print $3}')
    local pac_enabled=$(scutil --proxy 2>/dev/null | grep "ProxyAutoConfigEnable" | awk '{print $3}')

    if [[ "$http_enabled" == "1" ]]; then
        local http_proxy_host=$(scutil --proxy | grep "HTTPProxy" | awk '{print $3}')
        local http_proxy_port=$(scutil --proxy | grep "HTTPPort" | awk '{print $3}')
        pass "HTTP 代理已开启: ${http_proxy_host}:${http_proxy_port}"
        has_proxy=true
    else
        warn "HTTP 代理未开启"
    fi

    if [[ "$https_enabled" == "1" ]]; then
        local https_proxy_host=$(scutil --proxy | grep "HTTPSProxy" | awk '{print $3}')
        local https_proxy_port=$(scutil --proxy | grep "HTTPSPort" | awk '{print $3}')
        pass "HTTPS 代理已开启: ${https_proxy_host}:${https_proxy_port}"
        has_proxy=true
    else
        warn "HTTPS 代理未开启"
    fi

    if [[ "$socks_enabled" == "1" ]]; then
        local socks_host=$(scutil --proxy | grep "SOCKSProxy" | awk '{print $3}')
        local socks_port=$(scutil --proxy | grep "SOCKSPort" | awk '{print $3}')
        pass "SOCKS 代理已开启: ${socks_host}:${socks_port}"
        has_proxy=true
    fi

    if [[ "$pac_enabled" == "1" ]]; then
        local pac_url=$(scutil --proxy | grep "ProxyAutoConfigURLString" | awk '{print $3}')
        pass "PAC 自动代理已开启: ${pac_url}"
        has_proxy=true
    fi

    # 环境变量代理
    echo ""
    info "环境变量代理:"
    if [[ -n "${HTTP_PROXY:-}" ]]; then
        pass "HTTP_PROXY=${HTTP_PROXY}"
        has_proxy=true
    fi
    if [[ -n "${HTTPS_PROXY:-}" ]]; then
        pass "HTTPS_PROXY=${HTTPS_PROXY}"
        has_proxy=true
    fi
    if [[ -n "${http_proxy:-}" ]]; then
        pass "http_proxy=${http_proxy}"
        has_proxy=true
    fi
    if [[ -n "${https_proxy:-}" ]]; then
        pass "https_proxy=${https_proxy}"
        has_proxy=true
    fi

    if [[ -z "${HTTP_PROXY:-}" && -z "${HTTPS_PROXY:-}" && -z "${http_proxy:-}" && -z "${https_proxy:-}" ]]; then
        warn "未设置代理环境变量"
    fi

    echo ""
    if $has_proxy; then
        pass "结论: 检测到代理配置"
    else
        fail "结论: 未检测到任何代理配置"
    fi
}

# ============================================================
# 检查2: 互联网出口 IP 区域检测（用于 Kiro 登录）
# ============================================================
check_exit_ip() {
    print_header "检查 2: 互联网出口 IP 区域检测（用于 Kiro 登录）"

    # --- 检测默认浏览器 ---
    local default_browser=""
    local browser_name=""
    default_browser=$(defaults read com.apple.LaunchServices/com.apple.launchservices.secure 2>/dev/null | grep -B2 "LSHandlerURLScheme.*https" | grep "LSHandlerRoleAll" | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
    case "$default_browser" in
        com.google.chrome*) browser_name="Google Chrome" ;;
        com.apple.safari*)  browser_name="Safari" ;;
        org.mozilla.firefox*) browser_name="Firefox" ;;
        com.microsoft.edgemac*) browser_name="Microsoft Edge" ;;
        *) browser_name="${default_browser:-未知}" ;;
    esac
    info "默认浏览器: ${browser_name}"

    # --- 检测当前网络接口的代理设置(浏览器通常跟随此设置) ---
    local interface_proxy=""
    local interface_proxy_url=""
    local found_interface=""

    for svc in "Wi-Fi" "Ethernet" "USB 10/100/1000 LAN" "WT12" "Thunderbolt Bridge"; do
        local web_enabled=$(networksetup -getwebproxy "$svc" 2>/dev/null | grep "^Enabled:" | awk '{print $2}')
        local secure_enabled=$(networksetup -getsecurewebproxy "$svc" 2>/dev/null | grep "^Enabled:" | awk '{print $2}')
        local socks_enabled=$(networksetup -getsocksfirewallproxy "$svc" 2>/dev/null | grep "^Enabled:" | awk '{print $2}')
        local pac_enabled=$(networksetup -getautoproxyurl "$svc" 2>/dev/null | grep "^Enabled:" | awk '{print $2}')

        if [[ "$web_enabled" == "Yes" || "$secure_enabled" == "Yes" || "$socks_enabled" == "Yes" || "$pac_enabled" == "Yes" ]]; then
            found_interface="$svc"
            if [[ "$secure_enabled" == "Yes" ]]; then
                local phost=$(networksetup -getsecurewebproxy "$svc" | grep "^Server:" | awk '{print $2}')
                local pport=$(networksetup -getsecurewebproxy "$svc" | grep "^Port:" | awk '{print $2}')
                interface_proxy="${phost}:${pport}"
                interface_proxy_url="http://${phost}:${pport}"
                pass "网络接口 [${svc}] HTTPS 代理已开启: ${interface_proxy}"
            elif [[ "$web_enabled" == "Yes" ]]; then
                local phost=$(networksetup -getwebproxy "$svc" | grep "^Server:" | awk '{print $2}')
                local pport=$(networksetup -getwebproxy "$svc" | grep "^Port:" | awk '{print $2}')
                interface_proxy="${phost}:${pport}"
                interface_proxy_url="http://${phost}:${pport}"
                pass "网络接口 [${svc}] HTTP 代理已开启: ${interface_proxy}"
            fi
            if [[ "$socks_enabled" == "Yes" ]]; then
                local phost=$(networksetup -getsocksfirewallproxy "$svc" | grep "^Server:" | awk '{print $2}')
                local pport=$(networksetup -getsocksfirewallproxy "$svc" | grep "^Port:" | awk '{print $2}')
                info "网络接口 [${svc}] SOCKS 代理: ${phost}:${pport}"
            fi
            if [[ "$pac_enabled" == "Yes" ]]; then
                local pac_url=$(networksetup -getautoproxyurl "$svc" | grep "^URL:" | awk '{print $2}')
                pass "网络接口 [${svc}] PAC 自动代理: ${pac_url}"
            fi
            break
        fi
    done

    if [[ -z "$found_interface" ]]; then
        warn "系统网络接口代理: 未开启（浏览器将直连或使用扩展代理）"
    fi

    # --- 获取出口 IP (按浏览器实际路径尝试) ---
    echo ""
    info "正在获取出口 IP（模拟浏览器网络路径）..."
    local exit_ip=""
    local exit_method=""

    # IP 回显服务列表(checkip.amazonaws.com 为 AWS 官方,国内可直连;其余为备用)
    local ip_services=("https://checkip.amazonaws.com" "https://ipinfo.io/ip" "https://api.ip.sb/ip" "https://myip.ipip.net")

    # 提取纯 IP 的辅助函数
    fetch_ip() {
        local proxy_arg="$1"
        local svc raw ip
        for svc in "${ip_services[@]}"; do
            if [[ -n "$proxy_arg" ]]; then
                raw=$(curl -s --connect-timeout 5 -x "$proxy_arg" "$svc" 2>/dev/null || true)
            else
                raw=$(curl -s --connect-timeout 5 --noproxy '*' "$svc" 2>/dev/null || true)
            fi
            # 从返回内容中提取第一个 IPv4
            ip=$(echo "$raw" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1 || true)
            if [[ -n "$ip" ]]; then
                echo "$ip"
                return
            fi
        done
        echo ""
    }

    # 路径1: 通过系统网络接口代理 (浏览器通常跟随)
    if [[ -n "$interface_proxy_url" ]]; then
        exit_ip=$(fetch_ip "$interface_proxy_url")
        if [[ -n "$exit_ip" ]]; then exit_method="通过系统网络接口代理 (${interface_proxy})"; fi
    fi

    # 路径2: 直连 (无系统代理时浏览器的实际出口)
    if [[ -z "$exit_ip" ]]; then
        exit_ip=$(fetch_ip "")
        if [[ -n "$exit_ip" ]]; then exit_method="系统直连出口"; fi
    fi

    # 路径3: 通过环境变量代理
    if [[ -z "$exit_ip" ]]; then
        local env_proxy="${HTTPS_PROXY:-${HTTP_PROXY:-}}"
        if [[ -n "$env_proxy" ]]; then
            exit_ip=$(fetch_ip "$env_proxy")
            if [[ -n "$exit_ip" ]]; then exit_method="通过环境变量代理"; fi
        fi
    fi

    # 路径4: 代理白名单模式,取代理服务器 IP 作为出口
    if [[ -z "$exit_ip" ]]; then
        local env_proxy="${HTTPS_PROXY:-${HTTP_PROXY:-}}"
        if [[ -n "$env_proxy" ]]; then
            local proxy_host=$(extract_proxy_host "$env_proxy")
            exit_ip=$(resolve_host "$proxy_host")
            if [[ -n "$exit_ip" ]]; then exit_method="代理服务器地址（代理为白名单模式,无法直接探测出口）"; fi
        fi
    fi

    if [[ -z "$exit_ip" ]]; then
        fail "无法获取出口 IP（连 checkip.amazonaws.com 等服务都无法访问）"
        echo ""
        warn "Kiro 登录时浏览器需要能访问 app.kiro.dev 等海外服务"
        warn "请检查网络连接或代理配置"
        LOGIN_VERDICT="UNKNOWN"
        LOGIN_DESC="无法获取浏览器出口 IP，可能浏览器使用了扩展代理(脚本探测不到),请手动在浏览器打开 checkip.amazonaws.com 确认"
        return
    fi

    info "出口 IP: ${exit_ip}"
    info "获取方式: ${exit_method}"
    info "正在识别所在区域..."

    local proxy_for_query="${HTTPS_PROXY:-${HTTP_PROXY:-}}"
    local country=$(get_ip_country "$exit_ip" "$proxy_for_query")
    local country_zh=$(region_name "$country")
    info "所在区域: ${country_zh} (${country})"

    # 详细位置
    local detail=$(get_ip_detail "$exit_ip" "$proxy_for_query")
    local org=$(echo "$detail" | grep -o '"org":"[^"]*"' | cut -d'"' -f4)
    if [[ -n "$org" ]]; then
        info "运营商: ${org}"
    fi

    echo ""
    if [[ "$country" == "UNKNOWN" ]]; then
        warn "结论: 无法识别出口 IP 所在区域"
        LOGIN_VERDICT="UNKNOWN"
        LOGIN_DESC="无法识别浏览器出口区域"
    elif is_risk_region "$country"; then
        fail "结论: 系统直连出口位于 ${country_zh} (${country})，存在连接风险 — Kiro 登录可能被封号"
        echo ""
        warn "注意: 若你的浏览器使用了扩展代理(如 SwitchyOmega),该代理运行在浏览器内部,"
        warn "      本脚本无法探测其真实出口。请在浏览器中打开 https://checkip.amazonaws.com"
        warn "      自行确认浏览器实际出口 IP 是否为海外。"
        echo ""
        warn "如浏览器也走直连,请开启海外代理(系统代理/浏览器扩展/VPN)后再登录 Kiro。"
        LOGIN_VERDICT="RISK"
        LOGIN_DESC="系统直连出口位于 ${country_zh} (${country})，登录有封号风险(若浏览器用扩展代理请手动确认)"
    else
        pass "结论: 系统直连出口位于 ${country_zh} (${country})，无连接风险"
        LOGIN_VERDICT="OK"
        LOGIN_DESC="出口位于 ${country_zh} (${country})，合规"
    fi
}

# ============================================================
# 检查3: Kiro IDE proxy 配置
# ============================================================
check_kiro_proxy() {
    print_header "检查 3: Kiro IDE 网络配置"

    # 检查 settings.json 是否存在
    if [[ ! -f "$KIRO_SETTINGS" ]]; then
        fail "Kiro IDE settings.json 不存在: $KIRO_SETTINGS"
        fail "Kiro IDE 可能未安装或未配置"
        IDE_VERDICT="UNKNOWN"
        IDE_DESC="未找到 Kiro IDE 配置文件,可能未安装"
        return
    fi

    info "配置文件: ${KIRO_SETTINGS}"

    # 提取 http.proxy 值
    local proxy_url=""
    proxy_url=$(grep -o '"http\.proxy"[[:space:]]*:[[:space:]]*"[^"]*"' "$KIRO_SETTINGS" | head -1 | sed -E 's/.*"http\.proxy"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)

    local proxy_source=""
    if [[ -n "$proxy_url" ]]; then
        # Kiro IDE 自身配置了代理
        local proxy_display=$(echo "$proxy_url" | sed -E 's|(//[^:]*:)[^@]*(@)|\1****\2|')
        pass "Kiro IDE 已配置 http.proxy: ${proxy_display}"
        proxy_source="Kiro IDE http.proxy"
    else
        # 未配置 → Kiro IDE (Electron) 回退到系统代理
        warn "Kiro IDE 未配置 http.proxy，将回退使用系统代理"
        proxy_url=$(get_system_proxy_url)
        if [[ -n "$proxy_url" ]]; then
            local proxy_display=$(echo "$proxy_url" | sed -E 's|(//[^:]*:)[^@]*(@)|\1****\2|')
            pass "检测到系统代理: ${proxy_display}（Kiro IDE 将使用它）"
            proxy_source="系统代理（回退）"
        else
            # 既无 IDE 代理也无系统代理 → 直连
            warn "系统代理也未配置，Kiro IDE 将走直连"
            proxy_source="直连"
        fi
    fi

    # --- 情况: 直连(无任何代理) ---
    if [[ "$proxy_source" == "直连" ]]; then
        info "正在检测直连出口区域..."
        local exit_ip=$(fetch_ip_direct)
        if [[ -z "$exit_ip" ]]; then
            warn "无法获取直连出口 IP，无法判断风险"
            IDE_VERDICT="UNKNOWN"
            IDE_DESC="Kiro IDE 走直连,但无法获取出口 IP"
            return
        fi
        local country=$(get_ip_country "$exit_ip" "")
        local country_zh=$(region_name "$country")
        info "直连出口 IP: ${exit_ip}"
        info "所在区域: ${country_zh} (${country})"
        echo ""
        if [[ "$country" == "UNKNOWN" ]]; then
            warn "结论: 无法识别直连出口区域"
            IDE_VERDICT="UNKNOWN"
            IDE_DESC="Kiro IDE 走直连,无法识别出口区域"
        elif is_risk_region "$country"; then
            fail "结论: Kiro IDE 走直连,出口位于 ${country_zh} (${country})，不合规 — 存在封号风险"
            echo ""
            warn "建议: 为 Kiro IDE 配置 http.proxy 海外节点,或开启海外系统代理"
            IDE_VERDICT="RISK"
            IDE_DESC="未配任何代理,走直连且出口位于 ${country_zh} (${country})，有封号风险"
        else
            pass "结论: Kiro IDE 走直连,出口位于 ${country_zh} (${country})，合规 — 无风险"
            IDE_VERDICT="OK"
            IDE_DESC="走直连,出口位于 ${country_zh} (${country})，合规"
        fi
        return
    fi

    # --- 情况: 有代理(IDE 自身 或 系统回退) ---
    info "代理来源: ${proxy_source}"

    # 提取代理 host
    local proxy_host=$(extract_proxy_host "$proxy_url")
    info "代理主机: ${proxy_host}"

    # 解析为 IP
    local proxy_ip=$(resolve_host "$proxy_host")
    if [[ -z "$proxy_ip" ]]; then
        fail "无法解析代理主机 ${proxy_host} 的 IP 地址"
        return
    fi
    info "代理 IP: ${proxy_ip}"

    # 查询代理 IP 地理位置
    info "正在识别代理所在区域..."
    local country=$(get_ip_country "$proxy_ip" "$proxy_url")
    local country_zh=$(region_name "$country")
    info "所在区域: ${country_zh} (${country})"

    local detail=$(get_ip_detail "$proxy_ip" "$proxy_url")
    local org=$(echo "$detail" | grep -o '"org":"[^"]*"' | cut -d'"' -f4)
    if [[ -n "$org" ]]; then
        info "运营商: ${org}"
    fi

    # 测试代理连通性
    echo ""
    info "测试连通性 (连接 app.kiro.dev)..."
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 -x "$proxy_url" "https://app.kiro.dev" 2>/dev/null || echo "000")
    if [[ "$http_code" != "000" ]]; then
        pass "连通正常: HTTPS → app.kiro.dev (HTTP ${http_code})"
    else
        fail "连接失败: 无法通过代理连接 app.kiro.dev"
    fi

    echo ""
    if [[ "$country" == "UNKNOWN" ]]; then
        warn "结论: 无法识别代理所在区域"
        IDE_VERDICT="UNKNOWN"
        IDE_DESC="生效代理(${proxy_source})区域无法识别"
    elif is_risk_region "$country"; then
        if [[ "$proxy_source" == "Kiro IDE http.proxy" ]]; then
            fail "结论: Kiro IDE proxy 位于 ${country_zh} (${country})，不合规 — 存在封号风险"
            local sys_proxy=$(get_system_proxy_url)
            if [[ -n "$sys_proxy" ]]; then
                echo ""
                warn "IDE proxy 优先级最高,即使系统代理合规也不会被使用 — 请直接修正 Kiro IDE 的 http.proxy 为海外节点"
            fi
            IDE_VERDICT="RISK"
            IDE_DESC="Kiro IDE http.proxy 位于 ${country_zh} (${country})，不合规,有封号风险(优先级最高,系统代理救不了)"
        else
            fail "结论: 系统代理位于 ${country_zh} (${country})，不合规 — Kiro IDE 回退使用它,存在封号风险"
            IDE_VERDICT="RISK"
            IDE_DESC="IDE 未配代理,回退的系统代理位于 ${country_zh} (${country})，不合规,有封号风险"
        fi
    else
        pass "结论: 生效代理(${proxy_source})位于 ${country_zh} (${country})，合规 — 无风险"
        IDE_VERDICT="OK"
        IDE_DESC="生效代理(${proxy_source})位于 ${country_zh} (${country})，合规"
    fi
}

# ============================================================
# 汇总
# ============================================================
print_summary() {
    print_header "总结: Kiro 使用风险结论"

    # 图标辅助
    local login_icon ide_icon
    case "$LOGIN_VERDICT" in
        OK)   login_icon="${GREEN}✓ 无风险${NC}" ;;
        RISK) login_icon="${RED}✗ 有封号风险${NC}" ;;
        *)    login_icon="${YELLOW}⚠ 待确认${NC}" ;;
    esac
    case "$IDE_VERDICT" in
        OK)   ide_icon="${GREEN}✓ 无风险${NC}" ;;
        RISK) ide_icon="${RED}✗ 有封号风险${NC}" ;;
        *)    ide_icon="${YELLOW}⚠ 待确认${NC}" ;;
    esac

    echo ""
    echo -e "  【Kiro 登录】(默认浏览器出口)   $login_icon"
    echo -e "     ${LOGIN_DESC}"
    echo ""
    echo -e "  【Kiro IDE】(生效代理出口)      $ide_icon"
    echo -e "     ${IDE_DESC}"
    echo ""

    # 总体结论
    echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
    if [[ "$LOGIN_VERDICT" == "RISK" || "$IDE_VERDICT" == "RISK" ]]; then
        echo -e "  ${RED}总体: 存在封号风险，请先修正后再使用 Kiro！${NC}"
    elif [[ "$LOGIN_VERDICT" == "OK" && "$IDE_VERDICT" == "OK" ]]; then
        echo -e "  ${GREEN}总体: 登录与 IDE 出口均合规，可安全使用 Kiro。${NC}"
    else
        echo -e "  ${YELLOW}总体: 存在无法确认的项，请按上方提示手动核实。${NC}"
    fi
    echo -e "${BLUE}──────────────────────────────────────────────────${NC}"

    echo ""
    echo -e "  处置建议:"
    echo -e "  • Kiro 登录 → 让默认浏览器走海外出口(系统代理/浏览器扩展/VPN)"
    echo -e "  • Kiro IDE  → 配置 Kiro IDE 的 http.proxy 为海外节点(优先级最高)"
    echo -e "                Settings (⌘,/Ctrl+,) → 搜索 http.proxy"
    echo -e "  • 自检浏览器真实出口: 浏览器打开 https://checkip.amazonaws.com"
    echo ""
}

# ============================================================
# 主流程
# ============================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       Kiro 网络环境检查工具 v1.0                ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"

check_system_proxy
check_exit_ip
check_kiro_proxy
print_summary

#!/bin/bash
# 测试 Gost 代理是否正常工作
# 用法: ./test-proxy.sh [proxy_url]
# 示例: ./test-proxy.sh http://user1:pass123@localhost:8080

PROXY=${1:-"http://user1:pass123@localhost:8080"}
echo "代理地址: $PROXY"
echo "================================"

# 白名单域名（应该通过）
ALLOW_DOMAINS=(
  "https://app.kiro.dev"
  "https://prod.us-east-1.auth.desktop.kiro.dev"
  "https://q.us-east-1.amazonaws.com"
  "https://github.com"
  "https://open-vsx.org"
)

# 非白名单域名（应该被拒绝）
DENY_DOMAINS=(
  "https://www.google.com"
  "https://www.baidu.com"
  "https://example.com"
)

echo ""
echo "✅ 白名单域名测试（应返回 HTTP 状态码）:"
echo "--------------------------------"
for url in "${ALLOW_DOMAINS[@]}"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -x "$PROXY" "$url")
  if [ "$code" != "000" ]; then
    echo "  ✓ $url → $code"
  else
    echo "  ✗ $url → 连接失败（应该通过）"
  fi
done

echo ""
echo "🚫 非白名单域名测试（应被拒绝，返回 000）:"
echo "--------------------------------"
for url in "${DENY_DOMAINS[@]}"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -x "$PROXY" "$url")
  if [ "$code" = "000" ]; then
    echo "  ✓ $url → 已拒绝"
  else
    echo "  ✗ $url → $code（不应通过）"
  fi
done

echo ""
echo "🔑 认证测试（错误密码应被拒绝）:"
echo "--------------------------------"
BAD_PROXY=$(echo "$PROXY" | sed 's/:pass123@/:wrongpass@/')
code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -x "$BAD_PROXY" "https://app.kiro.dev")
if [ "$code" = "407" ] || [ "$code" = "000" ]; then
  echo "  ✓ 错误密码被拒绝 → $code"
else
  echo "  ✗ 错误密码未被拒绝 → $code"
fi

echo ""
echo "================================"
echo "测试完成"

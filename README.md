# Gost HTTP 代理服务器（Kiro IDE 代理）

基于 Docker 的 Gost 代理服务器，为 Kiro IDE/CLI 提供 HTTP 代理服务，内置自定义用户管理 WebUI 和域名白名单。

---

## ✨ 功能特性

- 🔐 **用户管理 WebUI** - 添加/删除用户、修改密码、重置密码、批量创建
- 🌐 **域名白名单** - 仅放行 Kiro 所需域名，其余拒绝
- 📥 **用户导出** - 导出 CSV（用户名、密码、Kiro 配置）
- 🖥️ **原版 UI** - 同时保留 Gost 官方管理界面
- 🐳 **一键部署** - CloudFormation 模板，开箱即用
- 🔒 **安全加固** - SSH 端口关闭、API 端口不对外、EIP 固定 IP

---

## 📁 项目结构

```
gost-proxy/
├── cloudformation.yaml     # AWS CloudFormation 部署模板
├── webui/
│   ├── Dockerfile          # 自定义 WebUI 镜像
│   ├── index.html          # 用户管理页面
│   └── default.conf        # Nginx 配置（反代 API + 原版 UI）
├── test/
│   ├── docker-compose.yml  # 本地测试编排
│   └── gost.yaml           # 本地测试配置
└── README.md
```

---

## 🚀 快速部署（CloudFormation）

### 一键部署

```bash
aws cloudformation create-stack \
  --stack-name gost-proxy \
  --template-body file://cloudformation.yaml \
  --parameters \
    ParameterKey=InstanceType,ParameterValue=t3.large \
    ParameterKey=KeyPairName,ParameterValue=<your-keypair> \
  --region us-east-1
```

### 部署参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| InstanceType | t3.large | EC2 实例类型 |
| KeyPairName | - | SSH 密钥对 |
| AllowedCIDR | 0.0.0.0/0 | 允许访问代理的 CIDR |
| AdminCIDR | 0.0.0.0/0 | 允许访问 WebUI 的 CIDR |
| ProxyUser | user1 | 代理用户名 |
| ProxyPass | pass123 | 代理密码 |
| ApiUser | admin | WebUI 管理员用户名 |
| ApiPass | Kir0@Gost2026!Proxy | WebUI 管理员密码 |

### 部署输出

| 输出 | 说明 |
|------|------|
| PublicIP | EIP 固定公网 IP |
| WebUI | 用户管理界面 (`:3000`) |
| WebUIOriginal | 原版 Gost UI (`:3000/ui/`) |
| ProxyEndpoint | 代理地址 |
| KiroConfig | Kiro CLI 环境变量配置 |

---

## 🖥️ 本地测试

```bash
cd test/
docker compose up -d
# 访问 http://localhost:3000
```

---

## 🌐 域名白名单

代理仅放行以下 Kiro 所需域名，其余域名被拒绝：

| 域名 | 用途 |
|------|------|
| `*.kiro.dev` | Kiro 核心服务 |
| `q.us-east-1.amazonaws.com` | Kiro 服务 (US) |
| `q.eu-central-1.amazonaws.com` | Kiro 服务 (EU) |
| `cognito-identity.us-east-1.amazonaws.com` | 社交登录 |
| `*.signin.aws` | AWS 登录 |
| `*.awsapps.com` | IAM Identity Center |
| `portal.sso.us-east-1.amazonaws.com` | SSO 门户 |
| `oidc.us-east-1.amazonaws.com` | OIDC Token |
| `login.microsoftonline.com` | Entra ID |
| `open-vsx.org` / `*.eclipsecontent.org` | 扩展 |
| `github.com` / `raw.githubusercontent.com` | Powers/MCP |
| `billing.stripe.com` / `checkout.stripe.com` | 订阅管理 |

参考: [Kiro 防火墙配置文档](https://kiro.dev/docs/privacy-and-security/firewalls/)

---

## 🔧 配置 Kiro 使用代理

```bash
export HTTP_PROXY=http://user1:pass123@<EIP>:8080
export HTTPS_PROXY=http://user1:pass123@<EIP>:8080
```

> ⚠️ Kiro 登录时浏览器流量不走代理，确保浏览器能直接访问 `app.kiro.dev`。

---

## 🔒 安全配置

- **SSH 端口**: 安全组不开放（密钥对保留，需要时手动添加规则）
- **API 端口 (18080)**: 不对外开放，仅容器内部通信
- **WebUI (3000)**: 通过 AdminCIDR 限制访问
- **代理 (8080)**: 通过 AllowedCIDR 限制访问

---

## 🐳 Docker 镜像

自定义 WebUI 镜像: [`aiworkspaces/gost-webui:latest`](https://hub.docker.com/r/aiworkspaces/gost-webui)

---

## 📚 相关链接

- [Gost 官方文档](https://gost.run/)
- [Kiro 防火墙配置](https://kiro.dev/docs/privacy-and-security/firewalls/)
- [Docker Hub 镜像](https://hub.docker.com/r/aiworkspaces/gost-webui)

---

## 🙏 致谢

This project uses [GOST](https://github.com/go-gost/gost) (MIT License, Copyright (c) 2016 ginuerzh)

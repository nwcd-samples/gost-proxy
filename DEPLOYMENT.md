# Gost 代理服务器部署手册 (Amazon Linux 2023)

本文档介绍如何在 Amazon Linux 2023 上部署 Gost HTTP 代理服务器，用于 Kiro IDE/CLI 代理。

---

## 📋 目录

1. [系统要求](#系统要求)
2. [安装 Docker](#安装-docker)
3. [部署代理服务](#部署代理服务)
4. [使用 Gost UI 管理界面](#使用-gost-ui-管理界面)
5. [配置 Kiro 使用代理](#配置-kiro-使用代理)
6. [AWS 安全组配置](#aws-安全组配置)
7. [常见问题](#常见问题)

---

## 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Amazon Linux 2023 |
| 内存 | 最低 512MB，推荐 1GB+ |
| 存储 | 最低 10GB |
| 权限 | root 或 sudo 权限 |

---

## 安装 Docker

```bash
# 安装 Docker
sudo dnf install -y docker
sudo systemctl start docker
sudo systemctl enable docker

# 安装 Docker Compose 插件
sudo dnf install -y docker-compose-plugin

# 将当前用户添加到 docker 组（可选）
sudo usermod -aG docker $USER
newgrp docker

# 验证
docker --version
docker compose version
```

---

## 部署代理服务

### 1. 克隆项目

```bash
git clone https://github.com/ywyang/kiro-demos.git
cd kiro-demos/gost-proxy
```

### 2. 配置环境变量

```bash
cp .env.example .env
vim .env  # 修改 API 认证密码
```

### 3. 启动服务

```bash
docker compose up -d
docker compose ps
```

### 4. 验证服务

```bash
# 检查端口
ss -tlnp | grep -E '8080|3000|18080'

# 测试代理
curl -x http://user1:pass123@localhost:8080 http://httpbin.org/ip
```

---

## 使用 Gost UI 管理界面

1. 打开浏览器访问：`http://服务器IP:3000`
2. 填写连接信息：
   - **API 地址**: `http://服务器IP:18080`
   - **用户名**: `admin`
   - **密码**: `gost.yaml` 中设置的密码
3. 点击 **连接**

连接后可以：
- 动态添加/删除代理用户
- 管理代理服务
- 查看运行状态

---

## 配置 Kiro 使用代理

Kiro CLI 支持标准代理环境变量：

```bash
export HTTP_PROXY=http://user1:pass123@代理服务器IP:8080
export HTTPS_PROXY=http://user1:pass123@代理服务器IP:8080
kiro-cli chat
```

> ⚠️ **重要**: Kiro 登录时浏览器流量不走代理，需确保浏览器能直接访问 `app.kiro.dev`。

### Kiro 需要代理转发的域名

代理服务器出站需能访问：

- `*.kiro.dev`
- `q.us-east-1.amazonaws.com`
- `q.eu-central-1.amazonaws.com`
- `runtime.us-east-1.kiro.dev`
- `runtime.eu-central-1.kiro.dev`
- `prod.us-east-1.auth.desktop.kiro.dev`
- `prod.download.desktop.kiro.dev`

完整列表: https://kiro.dev/docs/cli/privacy-and-security/firewalls/

---

## AWS 安全组配置

| 类型 | 端口 | 源 | 说明 |
|------|------|-----|------|
| Custom TCP | 8080 | 客户端 IP | HTTP 代理 |
| Custom TCP | 3000 | 仅管理 IP | Gost UI 管理界面 |
| Custom TCP | 18080 | 仅管理 IP | Gost API |

> ⚠️ 18080 和 3000 端口务必限制访问 IP。

---

## 服务管理

```bash
# 启动/停止/重启
docker compose up -d
docker compose down
docker compose restart

# 查看日志
docker compose logs -f gost

# 更新镜像
docker compose pull && docker compose up -d
```

---

## 常见问题

### 1. Kiro 连接超时

检查代理服务器是否能访问 Kiro 域名：

```bash
curl -I https://q.us-east-1.amazonaws.com
curl -I https://runtime.us-east-1.kiro.dev
```

### 2. Web UI 无法连接 API

```bash
curl http://localhost:18080/api/services
# 检查 AWS 安全组是否开放 18080 端口
```

### 3. 代理认证失败

```bash
docker compose logs gost | grep -i auth
```

---

## 相关链接

- [Gost 官方文档](https://gost.run/)
- [Gost UI GitHub](https://github.com/go-gost/gost-ui)
- [Kiro 防火墙/代理文档](https://kiro.dev/docs/cli/privacy-and-security/firewalls/)

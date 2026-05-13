# CoEvo 部署检查清单

## 服务器信息

| 项目 | 值 |
|:--|:--|
| VPS IP | `<OLD_VPS_IP>` |
| 配置 | 2C1G / 40GB SSD / 200Mbps |
| OS | Ubuntu 22.04 LTS |
| 主机名 | CoEvo_1 |
| 域名 | `keyievolution.fun` |
| DeepSeek Key | ✅ 已备好 |

## 状态

- [ ] SSH 访问就绪（root 密码或密钥已配置）
- [ ] 域名 DNS 解析已配置
- [ ] 服务器安全组（防火墙）放通 8080 端口

## 部署方式

### 当前架构（MVP）
VPS 运行完整 Rust 后端，Flutter APK 后期待嵌入。

```bash
# 本地开发机运行部署脚本
cd backend
bash deploy.sh <OLD_VPS_IP>
```

### 后续架构（APK）
VPS 仅作为 LLM 代理网关，业务逻辑在 APK 内部。

## 环境变量

| 变量 | 值 |
|:--|:--|
| `DEEPSEEK_API_KEY` | `sk-***REDACTED***` |
| `COEVO_ADMIN_KEY` | `coevo-admin-2026` |

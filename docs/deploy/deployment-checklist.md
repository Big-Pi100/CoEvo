> ⛔ **本文已过时** —— 文中 **VPS IP / SSH 配置为旧值**，且部署方式已变更
> （现为 WSL 原生构建 ELF + systemd + nginx 反代 + certbot）。
> 当前部署方式见 `docs/design/coevo-vps-deployment-assessment-2026-09-29.md`（`coevo-vps-*`）。
> **保留原文作历史记录；实际部署不要照本文操作。**

# CoEvo 部署检查清单

## 服务器信息

| 项目 | 值 |
|:--|:--|
| VPS IP | `<VPS_IP>` |
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
bash deploy.sh <VPS_IP>
```

## SEO 文件（2026-06-15 新增）
```bash
# robots.txt + sitemap.xml 位于 landing/ 根目录
# 新增内容页后务必更新 sitemap.xml
# 详见 web-deploy-guide.md 5.6 节
# ⚠️ sitemap 提交因百度主体资质验证暂受阻，已反馈百度
```

### 后续架构（APK）
VPS 仅作为 LLM 代理网关，业务逻辑在 APK 内部。

## 环境变量

| 变量 | 值 |
|:--|:--|
| `DEEPSEEK_API_KEY` | 见服务器 `/opt/coevo/.env`（**不在仓库里写值**）|
| `COEVO_ADMIN_KEY` | 见服务器 `/opt/coevo/.env`（**不在仓库里写值**）|
| `COEVO_K12_DATA_DIR` | `/opt/coevo/data/curriculum/v4` |

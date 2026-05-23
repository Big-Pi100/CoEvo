# CoEvo 后端部署指南

> ⚠️ 本文件包含 VPS 连接配置信息，**不要提交到 Git 仓库**。
> 实际部署前请将 `<PLACEHOLDER>` 替换为真实值。

---

## 1. VPS 基本信息

| 项目 | 值 |
|:--|:--|
| IP 地址 | `<OLD_VPS_IP>` |
| SSH 用户 | `ubuntu` |
| SSH 密钥文件 | `~/.ssh/coevo_key`（RSA 2048 位） |
| SSH 密钥口令 | `<SSH_KEY_PASSPHRASE>` |
| 操作系统 | Ubuntu（OpenSSH_8.9p1） |
| 工作目录 | `/opt/coevo` |
| 服务管理器 | systemd |
| 服务名 | `coevo` |
| API 端口 | 8080 |
| 健康检查 | `http://<OLD_VPS_IP>:8080/health` |

## 2. SSH 连接

### 2.1 前置条件

- 密钥文件 `~/.ssh/coevo_key`（PEM 格式 RSA 私钥）
- 密钥口令（部署时手动输入或通过 ssh-agent 缓存）

### 2.2 手动登录

```bash
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP>
# 提示输入密钥口令，输入 <SSH_KEY_PASSPHRASE>
```

### 2.3 非交互环境（CI / 自动化工具）

在无 TTY 的非交互环境中无法弹出口令输入框。解决方案：

```bash
# 1. 创建临时无口令密钥副本
cp ~/.ssh/coevo_key /tmp/coevo_key_temp
ssh-keygen -p -P "<SSH_KEY_PASSPHRASE>" -N "" -f /tmp/coevo_key_temp

# 2. 使用临时密钥连接
ssh -i /tmp/coevo_key_temp ubuntu@<OLD_VPS_IP> "命令"

# 3. 用完删除
rm -f /tmp/coevo_key_temp
```

### 2.4 常见问题

| 症状 | 原因 |
|:--|:--|
| `Permission denied (publickey)` | 用户名错误（用 `ubuntu` 不是 `root`），或密钥未在 VPS 上注册 |
| 连接超时 | VPS 关机或防火墙拦截 |
| 自动部署失败 | 缺少 `ServerAliveInterval=30` 参数（编译耗时较长，连接可能断开） |

## 3. 后端部署流程

### 3.1 完整部署命令

```bash
# 本地：打包源码
cd /path/to/CoEvo
tar czf /tmp/coevo-deploy.tar.gz \
  backend/Cargo.toml \
  backend/Cargo.lock \
  backend/src/ \
  backend/crates/

# 上传到 VPS
scp -i ~/.ssh/coevo_key /tmp/coevo-deploy.tar.gz ubuntu@<OLD_VPS_IP>:~/

# VPS 上编译 + 部署
ssh -i ~/.ssh/coevo_key -o ServerAliveInterval=30 ubuntu@<OLD_VPS_IP> "
  cd ~ &&
  rm -rf backend &&
  tar xzf coevo-deploy.tar.gz &&
  export PATH=\$HOME/.cargo/bin:\$PATH &&
  cd backend &&
  cargo build --release 2>&1 &&
  sudo systemctl stop coevo &&
  sudo cp target/release/coevo_backend /opt/coevo/coevo_server &&
  sudo chmod +x /opt/coevo/coevo_server &&
  sudo systemctl restart coevo &&
  sleep 3 &&
  curl -s http://127.0.0.1:8080/health
"
```

### 3.2 快速重启（仅替换二进制，不重新编译）

如果本地已有编译好的 Linux 二进制文件：

```bash
scp -i ~/.ssh/coevo_key ./coevo_backend ubuntu@<OLD_VPS_IP>:/tmp/
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> "
  sudo systemctl stop coevo &&
  sudo cp /tmp/coevo_backend /opt/coevo/coevo_server &&
  sudo chmod +x /opt/coevo/coevo_server &&
  sudo systemctl restart coevo
"
```

> **注意**：需要在 Linux 上编译或使用交叉编译工具链，Windows 编译的 `.exe` 不能在 VPS 上运行。

## 4. 编译规范

### 4.1 本地编译（开发调试）

```bash
cd backend
cargo build               # debug 模式
cargo build --release     # release 模式
```

### 4.2 VPS 远程编译（生产部署）

VPS 上需要安装 Rust 工具链：

```bash
# 首次安装
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"

# 后续直接用 cargo
export PATH=$HOME/.cargo/bin:$PATH
cd backend
cargo build --release
```

编译时间（估算）：
- 首次：5–10 分钟（依赖下载 + 编译）
- 增量：30 秒–2 分钟

## 5. Systemd 服务管理

### 5.1 服务文件位置

`/etc/systemd/system/coevo.service`

### 5.2 服务文件内容

```ini
[Unit]
Description=CoEvo Learning Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/coevo
EnvironmentFile=/opt/coevo/.env
ExecStart=/opt/coevo/coevo_server
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### 5.3 常用命令

```bash
sudo systemctl status coevo    # 查看状态
sudo systemctl restart coevo   # 重启
sudo systemctl stop coevo      # 停止
sudo systemctl start coevo     # 启动
sudo journalctl -u coevo -f    # 查看实时日志
sudo journalctl -u coevo --since "5 min ago"  # 最近 5 分钟日志
```

## 6. 环境变量

位于 `/opt/coevo/.env`，包含 API 密钥等敏感信息，**不要提交到 Git**。

参考格式：

```env
DEEPSEEK_API_KEY=<DEEPSEEK_API_KEY>
COEVO_ADMIN_KEY=<COEVO_ADMIN_KEY>
IFLYTEK_APPID=<IFLYTEK_APPID>
IFLYTEK_API_KEY=<IFLYTEK_API_KEY>
IFLYTEK_API_SECRET=<IFLYTEK_API_SECRET>
```

## 7. 文件与目录结构

```
/opt/coevo/
├── coevo_server        # 后端二进制（可执行文件）
├── .env                # 环境变量配置
├── data/
│   └── avatars/        # 用户头像
├── prompts/            # prompt 模板
│   └── *.md
└── cefr_catalog.json   # CEFR 分级数据
```

## 8. 故障排查

### 8.1 查看后端日志

```bash
# 实时日志
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> "sudo journalctl -u coevo -f"

# 最近 N 条
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> "sudo journalctl -u coevo --since '30 min ago' --no-pager"

# 搜索 STT 相关
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> "sudo journalctl -u coevo --since '1 hour ago' --no-pager | grep -i 'stt\|iflytek\|ffmpeg\|audio'"
```

### 8.2 服务启动失败

```bash
# 检查状态和错误
sudo systemctl status coevo --no-pager

# 常见错误码
# - 203/EXEC: 二进制文件不可执行或架构不匹配
# - 1: 程序崩溃，查看 journalctl 获取详细错误
```

### 8.3 健康检查

```bash
curl http://<OLD_VPS_IP>:8080/health
# 期望: "CoEvo API — OK"
```

---

> 最后更新: 2026-05-13
> 维护者: DevOps

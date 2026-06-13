# CoEvo 部署指南

> Flutter Web 前端 + Rust 后端完整部署流程，涵盖构建、上传、替换、验证与回滚。

---

## 1. VPS 信息

| 项目 | 值 |
|:--|:--|
| IP 地址 | `<OLD_VPS_IP>` |
| SSH 用户 | `ubuntu` |
| SSH 密钥 | `~/.ssh/coevo_key` |
| 域名 | `keyievolution.fun`（已备案：粤ICP备2026061557号-1） |
| SSL | Let's Encrypt（certbot），自动续期 |
| **前端** | |
| Web 目录 | `/opt/coevo/admin-web/` |
| 访问入口 | `https://keyievolution.fun/app/` |
| **后端** | |
| 后端目录 | `/opt/coevo/` |
| 二进制路径 | `/opt/coevo/coevo_server` |
| systemd 服务 | `coevo.service` |
| 后端端口 | `8080` |
| **环境变量** | |
| `COEVO_PII_KEY` | **2026-05-20 新增**：64 位十六进制字符串，用于 AES-256-GCM 加密 PII 字段（见 5.7 节） |
| `COEVO_K12_DATA_DIR` | **2026-06-08 修正**：指向 `/opt/coevo/data/curriculum/v3`（注意不是 `prebuilt`，`v3` 目录才包含 `plans/` 和 `cards/` 子目录） |

---

## 2. 架构说明

```
用户浏览器
    │  http://<OLD_VPS_IP>/app/
    ▼
┌─ Nginx :80 (coevo-landing) ─────────────────────────┐
│                                                      │
│  location /      → /var/www/coevo-landing/  落地页    │
│  location /app/  → proxy_pass http://127.0.0.1:3000  │
│  location /api/  → proxy_pass http://127.0.0.1:8080  │
│  location /ws    → proxy_pass http://127.0.0.1:8080  │
└──────────────────────────────────────────────────────┘
                           │
          ┌────────────────┼────────────────┐
          ▼                                 ▼
┌─ Nginx :3000 (coevo-admin) ───┐  ┌─ coevo.service :8080 ──┐
│  root /opt/coevo/admin-web/   │  │  /opt/coevo/coevo_server │
│  Flutter Web 静态文件          │  │  Rust axum + SQLite      │
│  /app/ → rewrite 剥离前缀      │  │  WorkingDirectory:       │
│  /api/ → :8080                │  │  /opt/coevo              │
│  /ws   → :8080/ws             │  │                          │
└───────────────────────────────┘  └─────────────────────────┘
```

> Nginx 配置文件位置：
> - `/etc/nginx/sites-available/coevo`（主入口，443 SSL + 80 redirect + 80 IP direct）
> - `/etc/nginx/sites-available/coevo-admin`（port 3000，内部）
> - **⚠️ `sites-enabled/coevo` 是普通文件副本，不是 symlink，更新后必须手动同步**（见 7.11 节）
>
> **关键设计说明**：
> - Flutter 构建时使用 `--base-href /app/`，所有资源请求会带 `/app/` 前缀。
> - Port 80 通过 `proxy_pass` 将 `/app/` 路由到 port 3000，资源路径自然匹配。
> - Port 3000 Nginx 配置了 `/app/` location，通过 `rewrite` 剥离前缀后正确提供文件。
> - **部署时必须确保 port 3000 的 `/app/` location 配置存在**，否则直连 port 3000 时所有 JS/CSS 资源会错误返回 HTML，导致白屏。

### 2.1 SSL / HTTPS

**2026-05-31 更新**：正式域名 `keyievolution.fun` 已启用 HTTPS。

```bash
# 首次申请证书
sudo certbot --nginx -d keyievolution.fun --agree-tos --email admin@keyievolution.fun

# 证书自动续期（certbot 已设置 systemd timer，无需手动操作）
sudo certbot renew --dry-run
```

证书路径：
- `/etc/letsencrypt/live/keyievolution.fun/fullchain.pem`
- `/etc/letsencrypt/live/keyievolution.fun/privkey.pem`

部署后 Nginx 配置自动包含：
- 443 HTTPS（SSL）
- 80 HTTP → 301 跳转 HTTPS

---

## 3. 本地构建

### 3.1 环境要求

- Flutter SDK: `D:\flutter_flutter\bin\flutter.bat`（3.27.5 社区版，支持华为 SDK）
- **注意**：
  - `D:\flutter_flutter` 是社区版（含华为 SDK 支持），**这是当前使用的版本**
  - `D:\flutter` 是标准版 Flutter，通常也可用，但构建时需确认 API_HOST 正确注入

### 3.2 构建命令

```bash
cd E:\CoEvo\app
D:\flutter_flutter\bin\flutter.bat build web --base-href /app/ \
  --dart-define=API_HOST=keyievolution.fun
```

| 参数 | 说明 |
|:--|:--|
| `--base-href /app/` | 设置资源基础路径，匹配 Nginx 的 `/app/` 路由 |
| `--dart-define=API_HOST=...` | **2026-05-15 新增**：编译时注入 API 服务器地址（见 3.2.1 节） |
| `--dart-define=API_PORT=...` | API 端口，VPS 上为 `8080` |

> **注意**：旧版文档中的 `--no-wasm-dry-run` 在新版 Flutter 中已废弃，不再使用。

### 3.2.1 API 地址配置机制

> `app/lib/api/api_config.dart` 中 `baseUrl` 使用 Dart 编译时常量，**不再硬编码**。

```dart
// app/lib/api/api_config.dart
static const String _host = String.fromEnvironment('API_HOST', defaultValue: 'localhost');
static const String _port = String.fromEnvironment('API_PORT', defaultValue: '8080');
static String get baseUrl {
  if (_host.contains('.')) {
    return 'https://$_host';  // 域名 → HTTPS 443
  }
  return 'http://$_host:$_port';  // IP/localhost → HTTP + 端口
}
```

| 场景 | 命令 |
|:--|:--|
| **VPS 部署（Web）** | `flutter build web --base-href /app/ --dart-define=API_HOST=keyievolution.fun` |
| **VPS 部署（Android APK）** | `flutter build apk --release --dart-define=API_HOST=keyievolution.fun` |
| **本地测试（默认）** | `flutter run`（默认连接 `localhost:8080`） |
| **真机调试** | `flutter run --dart-define=API_HOST=<电脑局域网IP>` |

> ⚠️ 部署到 VPS 时必须显式传入 `API_HOST`，否则前端会尝试连接 `localhost:8080` 导致 API 请求失败。

### 3.3 构建输出

```
app/build/web/
├── index.html               # 入口页面（base href="/app/"）
├── main.dart.js             # 主 JS 文件（~3.6MB，已压缩）
├── flutter_bootstrap.js     # Flutter 引导脚本
├── flutter.js               # Flutter 引擎 JS
├── flutter_service_worker.js
├── canvaskit/               # CanvasKit 渲染器（CDN 托管）
├── assets/                  # 字体、素材等
├── icons/                   # PWA 图标
├── favicon.png
└── manifest.json
```

---

## 4. 部署到 VPS

### 4.1 打包上传

```bash
# 1. 打包构建产物
cd E:\CoEvo\app\build\web
tar czf /tmp/coevo-web.tar.gz .

# 2. 上传到 VPS
scp -i ~/.ssh/coevo_key -o StrictHostKeyChecking=no \
  /tmp/coevo-web.tar.gz \
  ubuntu@<OLD_VPS_IP>:/tmp/
```

### 4.2 VPS 端部署

```bash
# 3. 替换文件
ssh -i ~/.ssh/coevo_key -o StrictHostKeyChecking=no ubuntu@<OLD_VPS_IP> "
  sudo rm -rf /opt/coevo/admin-web/* &&
  sudo tar xzf /tmp/coevo-web.tar.gz -C /opt/coevo/admin-web/ &&
  sudo chown -R ubuntu:ubuntu /opt/coevo/admin-web/ &&
  sudo nginx -s reload
"
```

> **说明**：Nginx 热重载（`nginx -s reload`）零停机，不影响在线用户。

### 4.3 清理

```bash
# 本地和 VPS 临时文件
rm -f /tmp/coevo-web.tar.gz
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> "rm -f /tmp/coevo-web.tar.gz"
```

---

## 5. Rust 后端部署

> 后端使用 Rust (axum + tokio + rusqlite)，由 systemd 管理 `coevo.service`。

### 5.1 环境说明

| 项目 | 值 |
|:--|:--|
| VPS OS | Ubuntu 22.04 LTS (x86_64) |
| VPS 规格 | 2 核 / 1 GB RAM / 2 GB swap |
| Rust 版本 | 1.95.0（通过 rustup 安装） |
| 二进制名 | `coevo_backend` → 部署后重命名为 `coevo_server` |
| 本地 OS | Windows（无法直接交叉编译 Linux 目标） |

> **关键约束**：本地 Windows 无 Linux 链接器，无法交叉编译。必须将源码上传到 VPS 原地编译。VPS 仅 1 GB RAM，编译需使用 `-j 1` 限制单线程，避免 OOM。

### 5.2 源码打包上传

```bash
# 1. 本地打包
# ⚠️ 注意：必须从 backend/ 目录打包，这样 VPS 上解压后可直接进入 backend/ 子目录
# ⚠️ 注意：包含 cefr_catalog.json 和 achievements.toml（会被二进制读取）
cd E:\CoEvo\backend
tar czf /tmp/coevo-backend-src.tar.gz \
  --exclude=target \
  --exclude='data/test_*' \
  --exclude='data/eval_runs' \
  src/ Cargo.toml Cargo.lock crates/ prompts/

# 2. 上传到 VPS
scp -i ~/.ssh/coevo_key -o StrictHostKeyChecking=no \
  /tmp/coevo-backend-src.tar.gz \
  ubuntu@<OLD_VPS_IP>:/tmp/

# 3. 课程数据打包上传（必需，编译时路径与运行时路径不同）
# ⚠️ 注意：数据在 data/curriculum/v3/ 目录，不是 data/curriculum/prebuilt/
cd E:\CoEvo
tar czf /tmp/curriculum-v3.tar.gz -C data/curriculum/v3 .
scp -i ~/.ssh/coevo_key /tmp/curriculum-v3.tar.gz \
  ubuntu@<OLD_VPS_IP>:/tmp/

# 4. 上传数据库（本地覆盖 VPS）
scp -i ~/.ssh/coevo_key backend/data/coevo.db \
  ubuntu@<OLD_VPS_IP>:/tmp/coevo.db

# 5. 上传落地页
cd E:\CoEvo\landing
tar czf /tmp/coevo-landing.tar.gz .
scp -i ~/.ssh/coevo_key /tmp/coevo-landing.tar.gz \
  ubuntu@<OLD_VPS_IP>:/tmp/
```

> **注意**：课程数据必须单独上传，不能依赖编译时路径（CARGO_MANIFEST_DIR）。见 5.4 节。

### 5.3 VPS 端编译

```bash
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> '
  # 解压源码
  sudo rm -rf /tmp/coevo-build
  mkdir -p /tmp/coevo-build/backend
  sudo tar xzf /tmp/coevo-backend-src.tar.gz -C /tmp/coevo-build/backend/
  sudo chown -R ubuntu:ubuntu /tmp/coevo-build

  # 编译（-j 1 防 OOM，首次约 5-10 分钟，增量更快）
  # ⚠️ 使用完整路径：SSH 非交互式 shell 下 $PATH 可能不包含 ~/.cargo/bin
  export PATH="$HOME/.cargo/bin:$PATH"
  cd /tmp/coevo-build/backend
  cargo build --release -j 1
'
```

> **⚠️ 常见陷阱（2026-05-30 更新）**：
> - **nohup 和 PATH**：如需后台编译（`nohup cargo build &`），务必使用完整路径 `/home/ubuntu/.cargo/bin/cargo`，因为 `nohup` 不继承 SSH 的 PATH。
> - **SSH 超时断连**：SSH 会话断开后前台进程会被 SIGTERM 杀死。如需避免，使用 screen/tmux 或 `nohup`，不要依赖 SSH 保活（`ServerAliveInterval` 不阻止断连）。
> - **首次编译**：需下载并编译所有依赖，比较耗时。后续增量编译快很多。
> - 如果 VPS 上 Rust 未安装，先执行：
>   `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y`

### 5.3.1 首次部署 AES-256 密钥生成

> **2026-05-20 新增**：CoEvo 使用 AES-256-GCM 对用户 PII（真实姓名、手机号、身份证号等）进行加密存储，密钥由环境变量 `COEVO_PII_KEY` 提供。

首次部署或从旧版本升级时执行：

```bash
# 生成 64 位十六进制密钥（32 bytes = 256 bits）
openssl rand -hex 32

# 写入 .env 文件（与二进制同目录）
echo 'COEVO_PII_KEY=<上面生成的密钥>' >> /opt/coevo/.env

# 写入 systemd 服务（可选，推荐写 .env 以便后续修改）
sudo systemctl edit coevo  # 添加 Environment=COEVO_PII_KEY=...
```

### 5.4 替换二进制并重启（全量部署）

```bash
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> '
  set -e

  # 0. 停止服务
  sudo systemctl stop coevo

  # 1. 备份旧数据
  sudo mkdir -p /opt/coevo.bak.$(date +%Y%m%d-%H%M%S)
  sudo mv /opt/coevo/coevo_server /opt/coevo.bak.*/ 2>/dev/null || true
  sudo mv /opt/coevo/data /opt/coevo.bak.*/ 2>/dev/null || true
  sudo mv /opt/coevo/prompts /opt/coevo.bak.*/ 2>/dev/null || true

  # 2. 创建新目录
  sudo mkdir -p /opt/coevo/data/curriculum/v3
  sudo mkdir -p /opt/coevo/prompts
  sudo mkdir -p /opt/coevo/data/logs

  # 3. 部署新二进制
  sudo cp /tmp/coevo-build/backend/target/release/coevo_backend /opt/coevo/coevo_server
  sudo chmod +x /opt/coevo/coevo_server

  # 4. 部署数据库
  sudo cp /tmp/coevo.db /opt/coevo/data/coevo.db

  # 5. ⚠️ 部署 K12 数据到 v3/ （不是 prebuilt/）
  sudo tar xzf /tmp/curriculum-v3.tar.gz -C /opt/coevo/data/curriculum/v3/

  # 6. 部署 prompts（递归复制）
  sudo cp -r /tmp/coevo-build/backend/prompts/* /opt/coevo/prompts/

  # 7. ⚠️ 部署 cefr_catalog.json 和 achievements.toml（二进制会读取）
  sudo cp /tmp/cefr_catalog.json /opt/coevo/
  sudo cp /tmp/achievements.toml /opt/coevo/

  # 8. 写入 .env
  sudo tee /opt/coevo/.env > /dev/null <<ENVEOF
DEEPSEEK_API_KEY=sk-xxx
COEVO_ADMIN_KEY=xxx
COEVO_PII_KEY=xxx
COEVO_K12_DATA_DIR=/opt/coevo/data/curriculum/v3
ENVEOF
  sudo chmod 600 /opt/coevo/.env

  # 9. 部署 Flutter Web 前端
  sudo rm -rf /opt/coevo/admin-web/*
  sudo tar xzf /tmp/coevo-web.tar.gz -C /opt/coevo/admin-web/

  # 10. 部署落地页
  sudo tar xzf /tmp/coevo-landing.tar.gz -C /var/www/coevo-landing/

  # 11. 启动服务
  sudo systemctl daemon-reload
  sudo systemctl start coevo
  sleep 3
  echo "Service: $(sudo systemctl is-active coevo)"

  # 12. ⚠️ Nginx 同步（sites-enabled 是文件副本，不是 symlink）
  sudo cp /etc/nginx/sites-available/coevo /etc/nginx/sites-enabled/coevo
  sudo nginx -t && sudo nginx -s reload
  echo "Nginx: OK"

  # 13. 健康检查
  echo "Health: $(curl -s http://127.0.0.1:8080/health)"
'
```

> **⚠️ 关键路径说明（2026-06-08 更新）**：
> - Rust 代码中 `reading_loader.rs` 和 `curriculum_loader.rs` 在开发阶段通过 `CARGO_MANIFEST_DIR` 查找 `data/curriculum/v3`。但编译后在 VPS 上运行，`CARGO_MANIFEST_DIR` 指向的是编译机器上的路径（如 `/tmp/coevo-build/...`），而非 VPS 上的 `/opt/coevo/`。
> - **解决方案**：设置 `COEVO_K12_DATA_DIR=/opt/coevo/data/curriculum/v3` 环境变量。loader 代码会优先读此变量，只有未设置时才回退到 `CARGO_MANIFEST_DIR` 路径。
> - **⚠️ 注意**：数据目录是 `v3/` 不是 `prebuilt/`。`prebuilt/` 下没有 `plans/` 和 `cards/` 子目录，加载会失败。
> - 每次部署后检查启动日志确认数据加载正常：
>   ```bash
>   sudo journalctl -u coevo -n 20 --no-pager | grep -E 'K12|READING|init done'
>   # 期望看到:
>   # [K12] loaded 14 card sets from /opt/coevo/data/curriculum/v3/cards
>   # [K12] loaded 14 plans from /opt/coevo/data/curriculum/v3/plans
>   ```

### 5.5 清理

```bash
# VPS 端
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> \
  "rm -rf /tmp/coevo-build /tmp/coevo-backend-src.tar.gz /tmp/curriculum-prebuilt.tar.gz /tmp/build.log"

# 本地
rm -f /tmp/coevo-backend-src.tar.gz /tmp/curriculum-prebuilt.tar.gz
```

### 5.6 systemd 服务参考

```ini
# /etc/systemd/system/coevo.service
[Unit]
Description=CoEvo Learning Service
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/coevo
ExecStart=/opt/coevo/coevo_server
Restart=always
RestartSec=5
Environment=RUST_LOG=info
Environment=COEVO_K12_DATA_DIR=/opt/coevo/data/curriculum/v3

[Install]
WantedBy=multi-user.target
```

常用管理命令：

```bash
sudo systemctl status coevo     # 查看状态
sudo systemctl stop coevo       # 停止
sudo systemctl start coevo      # 启动
sudo systemctl restart coevo    # 重启
sudo journalctl -u coevo -f     # 实时日志
```

---

## 6. 验证部署

### 6.1 快速检查

```bash
# App 入口
curl -s -o /dev/null -w "HTTP %{http_code}" http://<OLD_VPS_IP>/app/

# 主 JS 文件
curl -s -o /dev/null -w "HTTP %{http_code} | %{size_download} bytes" \
  http://<OLD_VPS_IP>/app/main.dart.js

# 落地页
curl -s -o /dev/null -w "HTTP %{http_code}" http://<OLD_VPS_IP>/

# API 健康检查
curl -s http://<OLD_VPS_IP>:8080/health
```

期望输出：

| 检查项 | 期望 |
|:--|:--|
| App 入口 | HTTP 200 |
| main.dart.js | HTTP 200, ~3.6MB |
| 落地页 | HTTP 200 |
| API 健康 | `CoEvo API — OK` |

### 6.2 服务状态

```bash
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> "
  echo 'nginx:' \$(sudo systemctl is-active nginx) &&
  echo 'coevo:' \$(sudo systemctl is-active coevo)
"
```

### 6.3 课程数据加载验证（2026-05-30 新增）

```bash
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> "
  echo 'K12 plans:' \$(ls /opt/coevo/data/curriculum/v3/plans/ | wc -l)
  echo 'K12 cards:' \$(ls /opt/coevo/data/curriculum/v3/cards/*.json | wc -l)
  sudo journalctl -u coevo -n 5 --no-pager --no-hostname | grep -E 'K12|READING'
"
# 期望:
#   K12 plans: 14
#   K12 cards: 14
#   [K12] loaded 14 card sets from /opt/coevo/data/curriculum/v3/cards
```

---

## 7. 故障排查

### 7.1 App 页面空白 / JS 404

**症状**：访问 `/app/` 返回 HTML 但页面白屏

**原因**：`base href` 设置错误或 Nginx 路径不匹配

**检查**：

```bash
# 确认 index.html 中 base href 为 /app/
curl -s http://<OLD_VPS_IP>/app/ | grep "base href"
# 期望: <base href="/app/">

# 确认 main.dart.js 可访问
curl -s -o /dev/null -w "%{http_code}" http://<OLD_VPS_IP>/app/main.dart.js
# 期望: 200
```

### 7.2 API 请求失败

**症状**：App 加载正常但 API 调用返回错误

**检查清单**：

1. **API 地址是否匹配部署环境**（2026-05-15 新增）：
   ```bash
   # 查看构建产物中注入的 API 地址
   grep -o '"http://[^"]*"' /opt/coevo/admin-web/main.dart.js | head -5
   # 期望 VPS 部署：http://<OLD_VPS_IP>:8080
   # 如出现 localhost:8080 或 keyievolution.fun:8080 说明构建时忘记传 --dart-define=API_HOST
   ```

2. **后端服务是否正常**：

**检查**：

```bash
# 直连后端
curl http://<OLD_VPS_IP>:8080/health

# 通过 Nginx 代理
curl http://<OLD_VPS_IP>/api/health
```

如果直连正常但代理失败，检查 Nginx 配置：

```bash
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> "
  sudo nginx -t &&          # 检查配置语法
  sudo systemctl restart nginx
"
```

### 7.3 后端崩溃

```bash
# 查看日志
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> \
  "sudo journalctl -u coevo --since '10 min ago' --no-pager"

# 重启
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> \
  "sudo systemctl restart coevo"
```

### 7.4 后端编译 OOM

**症状**：`cargo build --release` 被系统 kill，日志中出现 `Killed` 或内存不足

**原因**：VPS 仅 1 GB RAM，Rust 编译（尤其是 rusqlite bundled 编译 SQLite C 源码）内存消耗大

**解决**：

```bash
# 使用 -j 1 限制单线程编译
cargo build --release -j 1

# 如果仍然 OOM，临时增加 swap
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

### 7.5 编译成功但课程数据加载失败（2026-05-30 新增）

**症状**：服务启动日志显示 `[K12] ERR: plans dir not found: /tmp/coevo-build/.../data/curriculum/prebuilt/plans` 或 `[READING] init done: 0 plans, 0 cards`

**根因**：Rust 代码中的 `CARGO_MANIFEST_DIR` 是编译时路径（指向 `/tmp/coevo-build/`），部署到 `/opt/coevo/` 后这个路径不再存在。或 `COEVO_K12_DATA_DIR` 指向了错误的目录（如 `prebuilt/` 而非 `v3/`）。

**解决**：（见 5.4 节第 8 步）

```bash
# 检查 .env
grep COEVO_K12_DATA_DIR /opt/coevo/.env

# ⚠️ 确保指向 v3/ 目录（不是 prebuilt/）
echo 'COEVO_K12_DATA_DIR=/opt/coevo/data/curriculum/v3' >> /opt/coevo/.env

# 确保数据在正确位置
ls /opt/coevo/data/curriculum/v3/plans/  # 应有 14 个文件
ls /opt/coevo/data/curriculum/v3/cards/  # 应有 14 个文件

# 重启
sudo systemctl restart coevo

# 验证加载
sudo journalctl -u coevo -n 10 --no-pager | grep -E 'K12|READING'
```

### 7.6 SSH 断连导致编译中断（2026-05-30 新增）

**症状**：远程启动编译后 SSH 断连重连，发现编译进程已消失

**根因**：SSH 会话退出时会向其启用的进程组发送 SIGHUP/SIGTERM。即使设置了 `SSH ServerAliveInterval`，网络断开或超时仍会导致会话结束。

**解决**：

```bash
# 方案一：nohup（推荐，最简单）
nohup /home/ubuntu/.cargo/bin/cargo build --release -j 1 > /tmp/build.log 2>&1 &

# 方案二：tmux（适合需要交互监控的场景）
tmux new-session -s build
cargo build --release -j 1   # 在 tmux 内运行
# Ctrl+B D 断开但不结束 session
# tmux attach -t build 重新连接

# 方案三：screen
screen -S build
cargo build --release -j 1
# Ctrl+A D 断开，screen -r build 重新连接
```

> **注意**：使用 `nohup` 时必须用完整路径 `/home/ubuntu/.cargo/bin/cargo`，因为 SSH 非交互式 shell 和 `nohup` 环境中的 `$PATH` 可能不包含 cargo。

### 7.7 域名被拦截

**症状**：`keyievolution.fun` 返回 DNSPod 拦截页面

**原因**：域名未在腾讯云备案

**解决**：登录 [DNSPod 控制台](https://console.dnspod.cn/)，检查域名状态和备案信息。备案完成前请使用 IP 直连。

### 7.8 直连 Port 3000 白屏 / 管理员后台打不开

**症状**：`http://<OLD_VPS_IP>:3000/` 或 `:3000/admin` 页面白屏，浏览器 Console 报 JS 语法错误（`Unexpected token '<'`）

**原因**：Flutter 构建时使用 `--base-href /app/`，`index.html` 中 `<base href="/app/">` 导致所有资源请求带 `/app/` 前缀。Port 3000 Nginx 若缺少 `/app/` location，`try_files` 会将不存在的文件回退到 `index.html`，使 JS/CSS 请求返回 HTML 内容。

**检查**：

```bash
# 验证 — 正确应返回 application/javascript，而非 text/html
curl -sI http://<OLD_VPS_IP>:3000/app/main.dart.js | grep Content-Type
# 期望: Content-Type: application/javascript
```

**修复**：确保 port 3000 Nginx 配置包含 `/app/` location：

```nginx
location /app/ {
    rewrite ^/app/(.*)$ /$1 break;
    try_files $uri $uri/ /index.html;
}
```

应用修复后重载：

```bash
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> '
  sudo nginx -t && sudo nginx -s reload
'
```
---

### 7.9 WebSocket 长时间空闲后断连

**症状**：闲置几分钟后再次发送消息无响应，需要刷新页面才能恢复

**原因**：Nginx 默认 `proxy_read_timeout = 60s`，超过 60 秒无数据传输即关闭 WebSocket 连接

**修复（2026-05-23 更新：补充 proxy_send_timeout + 后端心跳代码已上线）**：

1. **Nginx 层**：同时设置 `proxy_read_timeout` 和 `proxy_send_timeout` 到 86400s（24 小时）：
```bash
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> '
  # port 80 入口
  sudo sed -i "/location \/ws {/,/}/ {
    /proxy_pass.*8080\/ws/ a\
        proxy_read_timeout 86400s;\
        proxy_send_timeout 86400s;
  }" /etc/nginx/sites-available/coevo-landing
  # port 3000 内部
  sudo sed -i "/location \/ws {/,/}/ {
    /proxy_pass.*8080\/ws/ a\
        proxy_read_timeout 86400s;\
        proxy_send_timeout 86400s;
  }" /etc/nginx/sites-available/coevo-admin
  sudo nginx -t && sudo nginx -s reload
'
```

2. **后端层**（2026-05-23 新增代码已合并到仓库）：
   - **Heartbeat 心跳检测**：每 60s 发送 WS Ping 帧检测连接活性，断连时自动退出
   - **ws.send() 错误检查**：所有关键发送点检查 Result，发送失败立即 break + 日志告警
   - **双重保护**：即使 Nginx/中间件静默切断连接，最长 60s 内即可检测断开并清理
   - 部署新版二进制后自动生效，无需额外配置

### 7.10 PII 解密失败 / 用户信息显示乱码

**症状**：管理员后台用户姓名/手机号显示为 `***` 或乱码字符

**原因**：`COEVO_PII_KEY` 环境变量未设置或与加密时使用的密钥不一致

**诊断**：
```bash
# 检查环境变量是否已设置
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> "
  sudo systemctl show coevo --property=Environment | grep COEVO_PII_KEY
  grep COEVO_PII_KEY /opt/coevo/.env 2>/dev/null || echo '未在 .env 中找到'
"
```

**解决**：
- 若从未设置：按 5.3.1 节生成密钥并写入 .env，重启服务。启动时自动重新加密。
- 若密钥已变更：恢复旧的密钥值，或提供原密钥后重新加密。
- 测试密钥是否可用：`openssl enc -d -aes-256-gcm -K <密钥> -iv <iv> -in /dev/null`

> ⚠️ **警告**：更换密钥后现有加密数据将不可读，必须保持密钥不变或从备份恢复旧密钥。

### 7.11 Nginx 配置更新不生效：`sites-enabled` 是文件副本不是 symlink（2026-06-08 新增）

**症状**：修改 `/etc/nginx/sites-available/coevo` 后执行 `nginx -s reload`，但新配置不生效。`nginx -T` 输出显示旧配置。

**根因**：正常情况下 `sites-enabled` 下的文件是到 `sites-available` 的符号链接。但 CoEvo VPS 上 `sites-enabled/coevo` 是一个**普通文件副本**（`-rw-r--r--`），不是 symlink（`lrwxrwxrwx`）。修改 `sites-available/coevo` 后，nginx 不会看到变化。

```bash
# 检查是否 symlink
ls -la /etc/nginx/sites-enabled/coevo
# -rw-r--r--  → 是文件副本（有问题）
# lrwxrwxrwx  → 是 symlink（正常）
```

**解决**：手动复制文件到 `sites-enabled`：

```bash
sudo cp /etc/nginx/sites-available/coevo /etc/nginx/sites-enabled/coevo
sudo nginx -t && sudo nginx -s reload
```

### 7.12 Certbot 导致 Port 80 返回 404（2026-06-08 新增）

**症状**：访问 `http://<OLD_VPS_IP>/` 返回 404，但 `http://<OLD_VPS_IP>:3000/` 正常。

**根因**：Certbot 在配置 port 80 的 HTTP→HTTPS 重定向时，添加了 `return 404; # managed by Certbot` 作为兜底。这个返回适用于任何没有匹配 `server_name` 的请求——包括直接通过 IP 访问。

**解决**：为 IP 直连创建独立的 server block，不经过 Certbot 的 `return 404` 逻辑：

```nginx
# Port 80 direct access (for IP users)
server {
    listen 80;
    listen [::]:80;
    server_name <OLD_VPS_IP>;

    root /var/www/coevo-landing;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }
    location /app/ { proxy_pass http://127.0.0.1:3000/; }
    location /api/ { proxy_pass http://127.0.0.1:8080; }
    location /ws   { proxy_pass http://127.0.0.1:8080/ws; proxy_http_version 1.1;
                     proxy_set_header Upgrade $http_upgrade;
                     proxy_set_header Connection "upgrade"; }
}
```

### 7.13 缺少 cefr_catalog.json 或 achievements.toml（2026-06-08 新增）

**症状**：启动日志中出现 `Word bank: 0 words` 或 `成就引擎 TOML 加载失败`。

**原因**：这 2 个文件在部署时容易被遗漏。它们不随 Rust 二进制一起编译，需要单独上传到 `/opt/coevo/`。

**检查**：
```bash
ls -la /opt/coevo/cefr_catalog.json /opt/coevo/achievements.toml
```

**解决**：从本地上传：
```bash
scp backend/cefr_catalog.json backend/achievements.toml \
  ubuntu@<OLD_VPS_IP>:/tmp/
ssh ubuntu@<OLD_VPS_IP> "sudo cp /tmp/cefr_catalog.json /opt/coevo/ && \
  sudo cp /tmp/achievements.toml /opt/coevo/ && \
  sudo systemctl restart coevo"
```

---

## 8. 平台兼容注意事项

### 8.1 代码修改清单

`flutter build web` 前需确认以下兼容处理：

| 文件 | 修改内容 |
|:--|:--|
| `lib/api/api_config.dart` | **2026-05-15**：`baseUrl` 改为 `--dart-define` 注入，默认 `localhost:8080` |
| `lib/services/stt_service.dart` | 条件导出：`dart.library.io` → native，否则 → web 桩 |
| `lib/services/stt_service_web.dart` | Web 平台桩实现（语音不可用，用文本输入替代） |
| `lib/services/stt_service_native.dart` | 原生平台实现（MediaRecorder + 讯飞 API） |
| `pubspec.yaml` | 需包含 `flutter_web_plugins` 依赖 |
| `backend/crates/api_server/src/encryption.rs` | **2026-05-20 新增**：AES-256-GCM PII 加密模块，需要 `COEVO_PII_KEY` 环境变量 |
| `backend/crates/api_server/src/ws.rs` | **2026-05-23 修复**：添加 WS 心跳检测（60s Ping）、ws.send() 错误检查、ColdPath 2 改用 tokio::spawn<br>**2026-05-30 更新**：新增每次请求后 `WS turn completed` 结构化日志（latency/token/plan/cards） |
| `backend/crates/api_server/src/plan_handler.rs` | **2026-05-30 修复**：`apply_plan_mutations` 始终同步 `plan_content`；`unlock_next_cards` 支持词卡+课文卡；reading 模式 CP2 推进后调用 `unlock_next_cards`；`upsert_learning_plan` 自动激活首任务 |
| `backend/crates/api_server/src/db_pool.rs` | **2026-05-30 修复**：`init()` 改为幂等（OnceLock 检查），多次调用不 panic |
| `landing/coevo-nginx.conf` | **2026-05-23 修复**：WebSocket location 添加 `proxy_read_timeout 86400s; proxy_send_timeout 86400s;` |

## SDK 版本说明（2026-05-30 更新）

当前使用的 Flutter SDK 为 **社区版 3.27.5**（路径 `D:\flutter_flutter`），支持华为 SDK 扩展。
此版本已移除 `--no-wasm-dry-run` 参数，构建时无需传入。
如有多个 Flutter SDK，构建前确认 PATH 或指定完整路径到正确的 SDK。`D:\flutter_ohos` 为鸿蒙定制版，不用于 Web 构建。

### 8.2 不可用于 Web 的插件

| 插件 | Web 状态 | 处理方式 |
|:--|:--|:--|
| `flutter_tts` | ⚠️ 有限支持 | Web 上 TTS 可能不工作，UI 需降级处理 |
| `image_picker` | ⚠️ 有限支持 | 浏览器文件选择可用，原生相机不可用 |
| `path_provider` | ✅ 支持 | 使用浏览器 IndexedDB 模拟 |
| `shared_preferences` | ✅ 支持 | 使用浏览器 localStorage |

---

## 9. 回滚

### 9.1 前端回滚

如遇严重问题，可恢复上一版本：

```bash
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> "
  # 查看备份
  ls -d /opt/coevo/admin-web.bak.* 2>/dev/null &&
  # 回滚到指定备份（替换日期时间）
  sudo rm -rf /opt/coevo/admin-web &&
  sudo cp -r /opt/coevo/admin-web.bak.20260514-134300 /opt/coevo/admin-web &&
  sudo nginx -s reload
"
```

### 9.2 后端回滚

```bash
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> '
  # 列出可用备份
  ls -la /opt/coevo/coevo_server.bak.*

  # 停止 → 回滚 → 启动
  sudo systemctl stop coevo
  sudo cp /opt/coevo/coevo_server.bak.20260530-111727 /opt/coevo/coevo_server
  sudo systemctl start coevo

  # 验证
  curl -s http://127.0.0.1:8080/health
'
```

---

## 10. 部署检查清单

> 每次部署后逐项验证，避免遗漏。**部署后端时不要忘记检查前端和管理后台。**

| # | 检查项 | 命令 | 期望 |
|:--|:--|:--|:--|
| 1 | 后端健康 | `curl -s http://<OLD_VPS_IP>:8080/health` | `CoEvo API — OK` |
| 2 | 落地页 | `curl -sI http://<OLD_VPS_IP>/` | HTTP 200 |
| 3 | App 入口 (port 80) | `curl -sI http://<OLD_VPS_IP>/app/` | HTTP 200 |
| 4 | App 入口 (port 3000) | `curl -sI http://<OLD_VPS_IP>:3000/` | HTTP 200 |
| 5 | 管理后台 (SPA 路由) | `curl -sI http://<OLD_VPS_IP>:3000/admin` | HTTP 200 |
| 6 | JS 资源 MIME 类型 | `curl -sI http://<OLD_VPS_IP>:3000/app/main.dart.js \| grep Content-Type` | `application/javascript` |
| 7 | coevo 服务 | `ssh ... "systemctl is-active coevo"` | `active` |
| 8 | Nginx 服务 | `ssh ... "systemctl is-active nginx"` | `active` |
| 9 | 服务日志无异常 | `ssh ... "journalctl -u coevo --since '1 min ago'"` | 无 ERROR |
| 10 | API_HOST 正确注入 | `grep -o 'keyievolution.fun' /opt/coevo/admin-web/main.dart.js \| head -1` | 匹配域名 |
| 11 | **2026-05-20**: PII 密钥已设置 | `ssh ... "sudo systemctl show coevo --property=Environment \| grep COEVO_PII_KEY"` | 输出含 64 位 hex 密钥 |
| 12 | **2026-06-08**: 课程数据加载 (v3) | `ssh ... "journalctl -u coevo --no-pager \| grep -E 'K12' \| tail -3"` | `14 card sets from /opt/coevo/data/curriculum/v3/cards` |
| 13 | **2026-06-08**: COEVO_K12_DATA_DIR 指向 v3 | `grep COEVO_K12_DATA_DIR /opt/coevo/.env` | `/opt/coevo/data/curriculum/v3` |
| 14 | **2026-06-08**: 二进制版本 | `ssh ... "ls -lh /opt/coevo/coevo_server"` | `14M Jun 8` (或当天日期) |
| 15 | **2026-06-08**: cefr_catalog.json 存在 | `ssh ... "ls -lh /opt/coevo/cefr_catalog.json"` | 文件存在 |
| 16 | **2026-06-08**: achievements.toml 存在 | `ssh ... "ls -lh /opt/coevo/achievements.toml"` | 文件存在 |
| 17 | **2026-06-08**: Nginx sites-enabled 已同步 | `ssh ... "diff /etc/nginx/sites-available/coevo /etc/nginx/sites-enabled/coevo"` | 无输出（文件一致） |
| 18 | **2026-06-08**: LLM warmup 成功 | `ssh ... "journalctl -u coevo --no-pager \| grep 'LLM warmup: OK'"` | 有匹配行 |

### 完整验证脚本

```bash
#!/bin/bash
# coevo-deploy-check.sh — 部署后一键验证

VPS="ubuntu@<OLD_VPS_IP>"
KEY="~/.ssh/coevo_key"

echo "=== CoEvo 部署验证 ==="

# 1. 后端健康
echo -n "1. Backend health: "
curl -s http://<OLD_VPS_IP>:8080/health
echo ""

# 2-6. 前端页面
for url in \
  "http://<OLD_VPS_IP>/|Landing" \
  "http://<OLD_VPS_IP>/app/|App (p80)" \
  "http://<OLD_VPS_IP>:3000/|App (p3000)" \
  "http://<OLD_VPS_IP>:3000/admin|Admin"
do
  u="${url%%|*}"; label="${url##*|}"
  code=$(curl -s -o /dev/null -w "%{http_code}" "$u")
  echo "$label: HTTP $code"
done

# 7. JS MIME
mime=$(curl -sI http://<OLD_VPS_IP>:3000/app/main.dart.js | grep Content-Type | tr -d '\r')
echo "main.dart.js: $mime"

# 8-9. 服务状态
ssh -i "$KEY" "$VPS" "
  echo 'coevo:' \$(systemctl is-active coevo)
  echo 'nginx:' \$(systemctl is-active nginx)
  echo 'K12 plans:' \$(ls /opt/coevo/data/curriculum/prebuilt/plans/ | wc -l)
  echo 'Binary date:' \$(ls -lh /opt/coevo/coevo_server | awk '{print \$6,\$7,\$8}')
"
echo "=== Done ==="
```

---

## 11. Port 3000 Nginx 完整配置参考

```nginx
# /etc/nginx/sites-available/coevo-admin
server {
    listen 3000;
    root /opt/coevo/admin-web;
    index index.html;

    # 关键：剥离 /app/ 前缀，匹配 Flutter --base-href /app/
    # 缺少此配置会导致直连 port 3000 时白屏
    location /app/ {
        rewrite ^/app/(.*)$ /$1 break;
        try_files $uri $uri/ /index.html;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }

    location /ws {
        proxy_pass http://127.0.0.1:8080/ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
```

---

## 附录：2026-05-30 部署问题汇总

本次部署遇到了以下问题，均已修复或记录了避免方法：

| 问题 | 根因 | 解决方案 | 相关章节 |
|:----|:-----|:---------|:--------|
| SSH 断连杀死编译进程 | SSH 会话退出时发送 SIGHUP | 使用 `nohup` 或 tmux/screen | 7.6 |
| `nohup` 下找不到 cargo | SSH 非交互式 shell 无 `$HOME/.cargo/bin` 在 PATH 中 | 使用完整路径 `/home/ubuntu/.cargo/bin/cargo` | 7.6 |
| 课程数据加载失败 (0 plans, 0 cards) | `CARGO_MANIFEST_DIR` 指向编译目录 `/tmp/coevo-build/` | 设置 `COEVO_K12_DATA_DIR` 环境变量 | 7.5 |
| 课程数据 tarball 损坏 (222MB) | SCP 上传大文件断连导致 | 只打包 `prebuilt/` (5.7MB)，排除 `raw/cleaned/gold` | 5.2 |
| tarball 目录结构不匹配 | 从 `backend/` 打包缺少子目录前缀 | 解压到 `mkdir -p /tmp/coevo-build/backend` | 5.3 |
| DB pool 多次 init panic | 测试并发初始化 | `init()` 改为幂等 OnceLock | 已在代码中修复 |

## 2026-06-08 部署问题汇总

本次是 VPS 全量重部署，从头编译 + 清空数据，遇到了以下问题：

| 问题 | 根因 | 解决方案 | 相关章节 |
|:----|:-----|:---------|:--------|
| K12 数据加载 0 plans | `COEVO_K12_DATA_DIR` 指向 `prebuilt/`（无 plans/cards 子目录） | 修正为 `v3/` 目录 | 7.5 |
| 词库 0 words / 成就引擎加载失败 | 缺少 `cefr_catalog.json` 和 `achievements.toml` | 单独上传到 `/opt/coevo/` | 7.13 |
| Nginx 配置更新不生效 | `sites-enabled/coevo` 是旧文件副本，不是 symlink | 手动 `cp` 同步 | 7.11 |
| Port 80 IP 访问返回 404 | Certbot 添加了 `return 404` 兜底 | 创建独立的 IP 直连 server block | 7.12 |
| 前端 API_HOST 连接 localhost | 构建时未传 `--dart-define=API_HOST=keyievolution.fun` | 构建时显式传入 | 3.2.1 |

---

---

## 附录: 相关文档

| 文档 | 用途 |
|:----|:-----|
| `docs/operations/maintenance-spec.md` | 生产环境维护规范（必读） |
| `docs/architecture/cp2-eval-report-2026-05-30.md` | CP2 修复评估报告 |

> 最后更新：2026-06-08（全量重部署，修正 K12 数据路径为 v3、新增 Nginx sites-enabled 同步说明、Certbot port 80 404 修复、部署问题汇总更新）

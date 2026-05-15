# CoEvo 部署指南

> Flutter Web 前端 + Rust 后端完整部署流程，涵盖构建、上传、替换、验证与回滚。

---

## 1. VPS 信息

| 项目 | 值 |
|:--|:--|
| IP 地址 | `<OLD_VPS_IP>` |
| SSH 用户 | `ubuntu` |
| SSH 密钥 | `~/.ssh/coevo_key` |
| 域名 | `keyievolution.fun`（待备案） |
| **前端** | |
| Web 目录 | `/opt/coevo/admin-web/` |
| 访问入口 | `http://<OLD_VPS_IP>/app/` |
| **后端** | |
| 后端目录 | `/opt/coevo/` |
| 二进制路径 | `/opt/coevo/coevo_server` |
| systemd 服务 | `coevo.service` |
| 后端端口 | `8080` |

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
> - `/etc/nginx/sites-available/coevo-landing`（port 80，入口）
> - `/etc/nginx/sites-available/coevo-admin`（port 3000，内部）
>
> **关键设计说明**：
> - Flutter 构建时使用 `--base-href /app/`，所有资源请求会带 `/app/` 前缀。
> - Port 80 通过 `proxy_pass` 将 `/app/` 路由到 port 3000，资源路径自然匹配。
> - Port 3000 Nginx 配置了 `/app/` location，通过 `rewrite` 剥离前缀后正确提供文件。
> - **部署时必须确保 port 3000 的 `/app/` location 配置存在**，否则直连 port 3000 时所有 JS/CSS 资源会错误返回 HTML，导致白屏。

---

## 3. 本地构建

### 3.1 环境要求

- Flutter SDK: `D:\flutter\flutter\bin\flutter.bat`（3.41.1 stable）
- **注意**：不要使用 `D:\flutter_ohos`（该版本为鸿蒙定制 SDK）

### 3.2 构建命令

```bash
cd E:\CoEvo\app
D:\flutter\flutter\bin\flutter build web --no-wasm-dry-run --base-href /app/ \
  --dart-define=API_HOST=<OLD_VPS_IP> --dart-define=API_PORT=8080
```

| 参数 | 说明 |
|:--|:--|
| `--no-wasm-dry-run` | 跳过 WASM 干运行（避免 URI 解析错误） |
| `--base-href /app/` | 设置资源基础路径，匹配 Nginx 的 `/app/` 路由 |
| `--dart-define=API_HOST=...` | **2026-05-15 新增**：编译时注入 API 服务器地址（见 3.2.1 节） |
| `--dart-define=API_PORT=...` | API 端口，VPS 上为 `8080` |

### 3.2.1 API 地址配置机制

> `app/lib/api/api_config.dart` 中 `baseUrl` 使用 Dart 编译时常量，**不再硬编码**。

```dart
// app/lib/api/api_config.dart
static const String _host = String.fromEnvironment('API_HOST', defaultValue: 'localhost');
static const String _port = String.fromEnvironment('API_PORT', defaultValue: '8080');
static String get baseUrl => 'http://$_host:$_port';
```

| 场景 | 命令 |
|:--|:--|
| **VPS 部署（Web）** | `flutter build web --dart-define=API_HOST=<OLD_VPS_IP> --dart-define=API_PORT=8080` |
| **VPS 部署（Android APK）** | `flutter build apk --release --dart-define=API_HOST=<OLD_VPS_IP> --dart-define=API_PORT=8080` |
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
# 1. 本地打包（排除 target/ 和 data/ 目录）
cd E:\CoEvo
tar czf /tmp/coevo-backend-src.tar.gz \
  --exclude='backend/target' \
  --exclude='backend/data' \
  backend/

# 2. 上传到 VPS
scp -i ~/.ssh/coevo_key -o StrictHostKeyChecking=no \
  /tmp/coevo-backend-src.tar.gz \
  ubuntu@<OLD_VPS_IP>:/tmp/
```

### 5.3 VPS 端编译

```bash
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> '
  # 解压源码
  sudo rm -rf /tmp/coevo-build
  sudo mkdir -p /tmp/coevo-build
  sudo tar xzf /tmp/coevo-backend-src.tar.gz -C /tmp/coevo-build/
  sudo chown -R ubuntu:ubuntu /tmp/coevo-build

  # 编译（-j 1 防 OOM，首次约 5-10 分钟，增量更快）
  export PATH="$HOME/.cargo/bin:$PATH"
  cd /tmp/coevo-build/backend
  cargo build --release -j 1
'
```

> **注意**：
> - 首次编译耗时较长（需下载并编译所有依赖），后续增量编译会快很多。
> - 如果 VPS 上 Rust 未安装，先执行：  
>   `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y`

### 5.4 替换二进制并重启

```bash
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> '
  # 停止服务
  sudo systemctl stop coevo

  # 备份旧二进制（前端更新也要备份）
  sudo cp /opt/coevo/coevo_server \
    /opt/coevo/coevo_server.bak.$(date +%Y%m%d-%H%M%S)

  # 替换新二进制
  sudo cp /tmp/coevo-build/backend/target/release/coevo_backend \
    /opt/coevo/coevo_server
  sudo chmod +x /opt/coevo/coevo_server
  sudo chown ubuntu:ubuntu /opt/coevo/coevo_server

  # 启动服务
  sudo systemctl start coevo
  sleep 2
  echo "Service: $(sudo systemctl is-active coevo)"
'
```

### 5.5 清理

```bash
# VPS 端
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> \
  "rm -rf /tmp/coevo-build /tmp/coevo-backend-src.tar.gz"

# 本地
rm -f /tmp/coevo-backend-src.tar.gz
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

### 5.1 快速检查

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

### 5.2 服务状态

```bash
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> "
  echo 'nginx:' \$(sudo systemctl is-active nginx) &&
  echo 'coevo:' \$(sudo systemctl is-active coevo)
"
```

---

## 7. 故障排查

### 6.1 App 页面空白 / JS 404

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

### 6.2 API 请求失败

**症状**：App 加载正常但 API 调用返回错误

**检查清单**：

1. **API 地址是否匹配部署环境**（2026-05-15 新增）：
   ```bash
   # 查看构建产物中注入的 API 地址
   grep -o '"http://[^"]*"' /opt/coevo/admin-web/main.dart.js | head -5
   # 期望 VPS 部署：http://<OLD_VPS_IP>:8080
   # 如出现 localhost:8080 说明构建时忘记传 --dart-define=API_HOST=<OLD_VPS_IP>
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

### 6.3 后端崩溃

```bash
# 查看日志
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> \
  "sudo journalctl -u coevo --since '10 min ago' --no-pager"

# 重启
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> \
  "sudo systemctl restart coevo"
```

### 6.4 后端编译 OOM

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

### 6.5 域名被拦截

**症状**：`keyievolution.fun` 返回 DNSPod 拦截页面

**原因**：域名未在腾讯云备案

**解决**：登录 [DNSPod 控制台](https://console.dnspod.cn/)，检查域名状态和备案信息。备案完成前请使用 IP 直连。

### 6.6 直连 Port 3000 白屏 / 管理员后台打不开

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

## 8. 平台兼容注意事项

### 7.1 代码修改清单

`flutter build web` 前需确认以下兼容处理：

| 文件 | 修改内容 |
|:--|:--|
| `lib/api/api_config.dart` | **2026-05-15**：`baseUrl` 改为 `--dart-define` 注入，默认 `localhost:8080` |
| `lib/services/stt_service.dart` | 条件导出：`dart.library.io` → native，否则 → web 桩 |
| `lib/services/stt_service_web.dart` | Web 平台桩实现（语音不可用，用文本输入替代） |
| `lib/services/stt_service_native.dart` | 原生平台实现（MediaRecorder + 讯飞 API） |
| `pubspec.yaml` | 需包含 `flutter_web_plugins` 依赖 |

### 7.2 不可用于 Web 的插件

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
  sudo cp /opt/coevo/coevo_server.bak.20260514-163157 /opt/coevo/coevo_server
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
| 10 | API_HOST 正确注入 | `grep -o 'http://<OLD_VPS_IP>' /opt/coevo/admin-web/main.dart.js \| head -1` | 匹配 VPS IP |

> **部署后端后特别注意第 4-6 项**：后端部署不会触碰前端文件，但如果 Nginx 配置曾因故回滚或丢失 `/app/` location，管理后台会白屏。

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
    }
}
```

---

> 最后更新：2026-05-15（新增 `--dart-define=API_HOST` 编译时 API 地址注入机制；更新构建命令和代码清单）

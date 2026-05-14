# CoEvo Web 部署指南

> 将 Flutter Web 前端部署到 VPS，通过 Nginx 提供服务。

---

## 1. VPS 信息

| 项目 | 值 |
|:--|:--|
| IP 地址 | `<OLD_VPS_IP>` |
| SSH 用户 | `ubuntu` |
| SSH 密钥 | `~/.ssh/coevo_key` |
| 域名 | `keyievolution.fun`（待备案） |
| Web 目录 | `/opt/coevo/admin-web/` |
| 访问入口 | `http://<OLD_VPS_IP>/app/` |

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
                           ▼
┌─ Nginx :3000 (coevo-admin) ─────────────────────────┐
│  root /opt/coevo/admin-web/                          │
│  Flutter Web 静态文件                                 │
│  location /api/ → http://127.0.0.1:8080              │
│  location /ws   → http://127.0.0.1:8080/ws           │
└──────────────────────────────────────────────────────┘
```

> Nginx 配置文件位置：
> - `/etc/nginx/sites-available/coevo-landing`（port 80，入口）
> - `/etc/nginx/sites-available/coevo-admin`（port 3000，内部）

---

## 3. 本地构建

### 3.1 环境要求

- Flutter SDK: `D:\flutter\flutter\bin\flutter.bat`（3.41.1 stable）
- **注意**：不要使用 `D:\flutter_ohos`（该版本为鸿蒙定制 SDK）

### 3.2 构建命令

```bash
cd E:\CoEvo\app
D:\flutter\flutter\bin\flutter build web --no-wasm-dry-run --base-href /app/
```

| 参数 | 说明 |
|:--|:--|
| `--no-wasm-dry-run` | 跳过 WASM 干运行（避免 URI 解析错误） |
| `--base-href /app/` | 设置资源基础路径，匹配 Nginx 的 `/app/` 路由 |

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

## 5. 验证部署

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

## 6. 故障排查

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

### 6.4 域名被拦截

**症状**：`keyievolution.fun` 返回 DNSPod 拦截页面

**原因**：域名未在腾讯云备案

**解决**：登录 [DNSPod 控制台](https://console.dnspod.cn/)，检查域名状态和备案信息。备案完成前请使用 IP 直连。

---

## 7. 平台兼容注意事项

### 7.1 代码修改清单

`flutter build web` 前需确认以下兼容处理：

| 文件 | 修改内容 |
|:--|:--|
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

## 8. 回滚

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

---

> 最后更新：2026-05-14

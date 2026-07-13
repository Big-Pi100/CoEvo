# CoEvo 微信小程序 — WebView 包装版

## 项目说明

采用 **WebView 方案** 将现有 Flutter Web 应用嵌入微信小程序，快速验证小程序渠道可行性。后端零改动，前端无需重写。

### 架构

```
用户 → 微信小程序 → web-view <iframe> → CoEvo Flutter Web (keyievolution.fun/app/)
                                                │
                                                └─→ API 后端 (keyievolution.fun/api/)
```

### 文件结构

```
miniprogram/
├── app.json                 # 小程序配置
├── app.js                   # App 生命周期
├── app.wxss                 # 全局样式
├── project.config.json      # 项目配置（含 appid 占位）
├── sitemap.json             # 搜索索引
├── pages/
│   ├── index/
│   │   ├── index.wxml       # WebView 主页面
│   │   ├── index.js         # 主页面逻辑（WeChat登录/分享中转）
│   │   ├── index.wxss       # 页面样式
│   │   └── index.json       # 页面配置
│   └── auth/
│       ├── auth.wxml        # 微信登录授权页
│       ├── auth.js          # 登录逻辑
│       ├── auth.wxss        # 样式
│       └── auth.json        # 配置
└── utils/
    └── auth.js              # 认证工具函数
```

---

## 部署步骤

### 第一步：注册小程序

1. 登录 [微信公众平台](https://mp.weixin.qq.com/)（用已有的开放平台账号）
2. 在"小程序管理"中创建一个新的小程序
3. 获取 **AppID**（在"开发 → 开发设置"中）
4. 更新 `project.config.json` 中的 `appid` 为实际值

### 第二步：配置业务域名

1. 在微信公众平台 → "开发" → "开发设置" → "业务域名"
2. 点击"添加"，输入 `keyievolution.fun`
3. 下载微信生成的校验文件（`MP_verify_xxxxxxxxxxxxx.txt`）
4. 上传到 VPS：
   ```bash
   scp -i ~/.ssh/coevo_key MP_verify_*.txt ubuntu@<OLD_VPS_IP>:/tmp/
   ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> \
     "sudo cp /tmp/MP_verify_*.txt /var/www/coevo-landing/ && sudo chown www-data:www-data /var/www/coevo-landing/MP_verify_*.txt"
   ```
5. 验证可访问：
   ```bash
   curl -sk https://www.keyievolution.fun/MP_verify_xxxxxxxxxxxxx.txt
   # 应返回校验文件内容
   ```
6. 返回微信后台，点击"校验"
7. nginx 已配置好 `MP_verify_*.txt` 路由（自动）——无需重复操作

### 第三步：构建小程序

在微信开发者工具中：
1. 打开项目目录 `miniprogram/`
2. 填入 AppID
3. 点击"编译"预览
4. 在手机上扫码体验版

### 第四步：提交审核

1. 在开发者工具中点击"上传"
2. 登录微信公众平台 → "版本管理" → 提交审核
3. 审核通过后发布

---

## 功能清单

| 功能 | 状态 | 说明 |
|:-----|:----:|:-----|
| WebView 嵌入 Flutter Web | ✅ | 已完成 |
| 业务域名 nginx 路由 | ✅ | 已配置 |
| 小程序更新提示 | ✅ | app.js 自带 |
| 用户体验版 | ⚠️ | 需微信开发者工具 |
| WeChat 登录 | 🔲 | API 尚未实现（暂走 trial/claim）|
| 分享 | 🔲 | wx.shareAppMessage 需注册分享互调 |
| 原生加载页 | 🔲 | 可替换为 CoEvo 品牌骨架屏 |

---

## 小程序 vs Web 的差异

| 维度 | Web | 小程序 WebView |
|:-----|:---|:----------------|
| 加载 | 浏览器 + 缓存 | 微信内嵌浏览器，首次约 5-15s |
| 分享 | URL 链接 | 小程序卡片（标题+图片+路径） |
| 登录 | trial + claim | 支持 wx.login（未来） |
| 推送 | 无 | 模板消息 / 订阅消息（未来） |
| 支付 | 微信扫码支付 | 小程序内支付（未来） |
| 域名要求 | 无特殊要求 | ICP备案 + HTTPS + 业务域名白名单 |
| 审核 | 不需要 | 每次版本更新需微信审核 |

---

## 后续优化方向

1. **加载速度**：在小程序中显示品牌加载页替代白屏
2. **WeChat 登录**：后端新增 `/api/auth/wechat/login` 端点，Flutter 端处理 `wx_code` 参数
3. **分享**：注册小程序分享按钮，用户可分享小程序卡片给好友
4. **订阅消息**：考试提醒、复习提醒等

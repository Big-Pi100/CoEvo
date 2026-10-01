> ⛔ **本文已作废** —— 它属于**旧产品形态**（Web 落地页/SEO），与当前项目（**仅 iOS 的英语学习 App**）无关。
> **保留原文仅作历史记录，不要照本文操作。**
> 当前形态以 `docs/design/v1-final-design-authoritative-2026-09-25.md` 与**代码**为准。

# SEO + 免费试用转化方案

> 2026-06-23 v3 | 临时账户方案 — **代码实现完成，待部署**

> **进度总览**：后端 4 文件 ✅ → Flutter 9 文件 ✅ → 文档更新 ✅ → 部署 3 项 ❌

---

## 一、核心决策

| 决策 | 结论 |
|------|------|
| **单入口** | Flutter Web App 直接部署在根路径（`keyievolution.fun/`），替换独立 landing page。SEO 信息通过 `app/web/index.html` 的 meta/FAQ Schema 提供，百度可正常爬取首页。`landing/` 目录不再维护。 |
| 注册改为弹窗 | 对话中触发，不跳转页面，上下文不断 |
| 注册前后数据一致 | **创建临时真实账户**，注册即补全字段，零迁移 |
| 临时账户清理 | 7 天软删除未认领账户，37 天硬清理关联数据 |
| 防滥用 | 同设备限制 + 临时账户 TTL |

---

## 二、用户流程

```
用户访问 keyievolution.fun/app/

      ↓ GET /api/trial/start

  ┌─────────────────────────────────┐
  │ 后端创建真实用户                  │
  │ username = "trial_xxxxx"         │
  │ password_hash = 空（不可登录）    │
  │ → 返回 user_id + token           │
  └──────────┬──────────────────────┘
             ↓ Flutter 存 token，正常连接 WS

  ┌─────────────────────────────────┐
  │ 教学对话 — 全部真实写入          │
  │ 概念提取 ✅                     │
  │ 卡片创建 ✅                     │
  │ 对话历史 ✅                     │
  │ 学习进度 ✅                     │
  └──────────┬──────────────────────┘
             ↓ 首次进入产品 / 点击个人图标 / 每次完成学习 task

  ┌─────────────────────────────────┐
  │ 弹窗："注册后可保存全部进度"     │
  │ （可关闭，继续使用）             │
  │                                 │
  │ 硬拦截由 1 天订阅到期自动触发     │
  │ → 现有订阅横幅："订阅已到期"     │
  └─────────────────────────────────┘
             ↓ 点击弹窗注册

  ┌─────────────────────────────────┐
  │ 弹窗注册                        │
  │ 设 username + 密码              │
  │ → PUT /api/trial/claim          │
  │ → UPDATE users SET username=?,   │
  │   password_hash=?               │
  │ → 返回新 token                  │
  │ → Flutter 更新 token            │
  │ → 继续正常使用，数据全部保留     │
  └─────────────────────────────────┘
```

**关键**：用户始终是同一个数据库用户，注册只是补全信息。无迁移、无断层、无对话丢失。

---

## 三、截断策略

### 核心原则：弹窗提醒 + 订阅硬拦截

两层独立机制，各司其职：

| 机制 | 作用 | 实现 |
|------|------|------|
| **进度提醒**（前端） | 每次 learning plan task 完成时弹窗引导注册 | 监听 `user_plan_progress` 每出现一条 `status='done'` 都触发 |
| **订阅硬拦截**（后端） | 1 天临时订阅到期后，`ws.rs` 的 `is_subscription_active()` 自动拦截所有 WS 消息 | 现有 `subscription_expires` 字段 |

```
首次进入产品 → 弹窗提醒注册（可关闭）
点击个人图标 → 弹窗提醒注册（可关闭）
每次完成一个学习任务 → 弹窗提醒注册（可关闭）
                                  ← 任何时候 1 天订阅到期，后端自动拦截
                                      现有订阅横幅显示 "订阅已到期"
```

| 触发时机 | 弹窗强度 | 能否关闭 |
|----------|----------|----------|
| 首次进入产品 | 轻 | ✅ 可关闭 |
| 点击个人图标 | 轻 | ✅ 可关闭 |
| 每次 task done | 轻 | ✅ 可关闭 |

### 7 天软删除

```sql
-- campaign_scheduler.rs 中每 5 分钟执行
UPDATE users SET deleted_at = datetime('now')
WHERE username LIKE 'trial_%'
AND deleted_at IS NULL
AND created_at < datetime('now', '-7 days');
```

软删除后数据保留 30 天，超期硬删除（清理关联表 + 归档，见 3.4 节）。

---

### 3.1 POST /api/trial/start — 创建临时账户

```rust
// 1. 生成唯一 username = "trial_" + uuid 前 8 位
// 2. 生成推广码 referral_code = "CoEvo_trial_" + uuid 前 4 位
// 3. 写入不可登录密码（非空，防止 login 入口异常）
//    password_hash = bcrypt("trial_no_login_" + uuid)
// 4. 设置 1 天试用订阅（复用现有 subscription 检查机制，无需改 ws.rs）
//    subscription_expires = datetime('now', '+1 day')
// 5. INSERT INTO users (id, username, password_hash, referral_code, subscription_expires, created_at)
// 6. INSERT INTO tokens (id, user_id, token, created_at)
// 7. 返回 { "user_id": "...", "token": "..." }
// 8. 防滥用校验：同 IP 每日限 3 次
```

~30 行。

### 3.2 PUT /api/trial/claim — 认领账户

```rust
// 1. 校验 token 有效
// 2. 校验 username 唯一（TRIAL 前缀暂不检查重名）
// 3. 校验密码复杂度（6位以上英数组合）
// 4. UPDATE users SET username=?, password_hash=?
// 5. 删除旧 token，创建新 token
// 6. 返回 { "token": "..." }
```

~25 行。

### 3.3 注册弹窗触发

注册弹窗由前端在以下时机触发，不涉及后端改动：

- 首次进入聊天页
- 点击个人图标
- 每次 `user_plan_progress` 出现 `status='done'`

→ **后端 0 行改动。** 前端通过 SharedPreferences `claimed` 标记判断是否已注册。

### 3.4 清理策略

两层机制，全自动：

```
创建临时账户 → 第 7 天未认领 → 软删除（SET deleted_at）
                               → 数据不可访问，DB 保留
                               → 第 37 天（软删+30天）→ 硬删除（物理清理+归档）
```

| 阶段 | 时间 | 动作 | 行数 |
|------|------|------|------|
| **软删除** | 创建后 7 天 | `UPDATE users SET deleted_at=datetime('now') WHERE username LIKE 'trial_%' AND deleted_at IS NULL AND created_at<datetime('now','-7 days')` | ~3 |
| **硬删除** | 软删后 30 天 | 级联 DELETE 12 张关联表后 DELETE users | ~15 |

两级都在 `campaign_scheduler.rs` 中新增，每 5 分钟执行一次。

### 3.5 后端合计

| 变动 | 行数 |
|------|------|
| 新建 `trial_handler.rs`（start + claim） | ~55 行 |
| 路由注册（routes.rs + lib.rs） | ~3 行 |
| 定时清理（campaign_scheduler.rs） | ~18 行（软删除 + 硬删除） |
| **合计** | **~75 行** |

**不需要改**：ws.rs（现有订阅检查自动通过）、campaign_executor.rs、pay_handlers.rs、prompt、schema。

---

## 四、Flutter 前端改动

### 4.1 首屏入口行为

| 访问来源 | 行为 |
|----------|------|
| 新用户（无 token） | 白底加载页（spinner + 一行品牌文案）→ 自动调 `POST /api/trial/start` → 完成后进入 HomeScreen |
| 已有 token 用户 | 直接进入 HomeScreen |
| 已有账户用户 | auth_screen 底部保留"已有账户？登录"入口 |

### 4.2 首屏加载页

删除了 5 页幻灯片设计，改为简单的白底加载页：

```
┌─────────────────────────────────────┐
│                                     │
│                                     │
│            ◌ (旋转 spinner)          │   36px
│                                     │
│    CoEvo AI特级教师——不遗忘·不跑偏·不瞎编    │   14px 灰色
│                                     │
│                                     │
└─────────────────────────────────────┘
```

- 背景：纯白 `Colors.white`
- Spinner：标准 `CircularProgressIndicator`（36x36）
- 文案：14px `Colors.grey[500]`
- 操作：`auth_screen.initState` 立即调 `trial/start`，完成后自动跳转主页

`widgets/first_run_carousel.dart` 已删除。

### 4.3 改动清单

| 改动 | 位置 | 说明 |
|------|------|------|
| 首屏调 trial/start | `auth_screen.dart` — 不再展示登录表单，直接调 API 创建临时账户 | ✅ **已完成** |
| 存 token + user_id | 复用现有 token 存储逻辑 | ✅ **已完成** |
| 正常连接 WS | 复用现有 `ws_service.dart`，与正式用户无区别 | **0 行** |
| 首次进入弹注册窗 | `chat_screen.dart` — 进入聊天页后立即弹注册 Dialog（trial && !claimed） | ✅ **已完成** |
| 点击个人图标弹注册窗 | `profile_screen.dart` — 点击时检测 trial && !claimed 则弹注册 Dialog | ✅ **已完成** |
| 监听 task 完成弹窗 | `chat_screen.dart` — 轮询 plan 中 task 状态，`status='done'` 增量弹注册 Dialog | ✅ **已完成** |
| 注册弹窗 | 新 widget `widgets/claim_dialog.dart` | ✅ **已完成** |
| 调 claim API | `claim_dialog.dart` — 调 `PUT /api/trial/claim` | ✅ **已完成** |
| 更新 token | 用新 token 替换本地存储 | ✅ **已完成** |
| **注册后关闭轮次提醒** | `chat_screen.dart` — claim 成功后存 `claimed=true` 到 `SharedPreferences`，轮次提醒不再弹出 | ✅ **已完成** |

### 4.4 注册完成判断方式

claim API 成功后，前端写 `SharedPreferences` 标记 `claimed=true`。`chat_screen.dart` 的轮次提醒只在 `isTrial && !isClaimed` 时触发：

```dart
// auth_provider.dart
bool get isClaimed => prefs.getBool('claimed') ?? false;

// chat_screen.dart — 注册弹窗显示条件
if (!isTrialAccount(userId) || isClaimed) return;  // 不显示弹窗
```

后端清理策略中也使用 `password_hash IS NOT NULL` 作为"已认领"判断依据：已认领的临时账户不做清理。

```sql
-- 只清理未认领的临时账户
UPDATE users SET deleted_at = datetime('now')
WHERE username LIKE 'trial_%'
AND password_hash IS NULL        -- 未认领
AND deleted_at IS NULL
AND created_at < datetime('now', '-7 days');
```

### 4.5 PC 端响应式适配

**问题**：Flutter Web 默认弹性布局，宽屏下 K12 入口、成就日历、卡片等元素等比例放大，内容过大。

**方案**：在 `MaterialApp.router` 的 `builder` 中加全局宽度约束。

**影响范围**：

| 项目 | 内容 |
|------|------|
| 涉及文件 | 1 个：`app/lib/app.dart` |
| 改动位置 | `MaterialApp.router` 的 `builder` 参数（第 366 行） |
| 影响页面 | 全部 17 个路由（全局约束，无需逐个修改） |
| 不影响的 | 移动端（< 768px 直接返回 child，零变化） |

**当前代码：**
```dart
builder: (context, child) => Stack(
  children: [
    child!,
    const AchievementOverlay(),
    _buildSubExpiredOverlay(),
  ],
),
```

**改为：**
```dart
builder: (context, child) {
  final isWide = MediaQuery.of(context).size.width > 768;
  final content = Stack(
    children: [
      child!,
      const AchievementOverlay(),
      _buildSubExpiredOverlay(),
    ],
  );
  if (!isWide) return content;
  return Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1200),
      child: content,
    ),
  );
},
```

| 设备 | 效果 |
|------|------|
| 手机（< 768px） | 不变，全屏 |
| 平板/笔记本 | 内容宽度 ≤ 1200px，居中 |
| 宽屏桌面 | 内容居中，两边留白 |

---

## 五、数据策略

| 阶段 | DB 行为 | 区别 |
|------|---------|------|
| 创建临时账户 | 写 users + tokens | **写入 subscription_expires = 1 天**，复用现有订阅检查 |
| 试用期教学 | 写 user_cards + card_memory + conversations | **与正式用户完全一致**，含订阅检查 |
| 注册认领 | UPDATE username + password_hash | **原有数据全部保留**，后续通过活动获得新订阅 |
| 注册后 | 继续使用，无任何变化 | **零迁移** |

**为何用 1 天订阅而非移除检查**：
- 现有 `ws.rs` 第 401 行检查 `is_subscription_active()`，trial 账号无订阅则立即拦截
- 给 1 天临时订阅后，现有检查自动通过，**无需改任何现有代码**
- 1 天订阅到期后自动拦截试用用户
- 注册后通过营销活动（拼团/砍价/折扣）获得正式订阅，继续使用

---

## 六、防滥用

| 层级 | 措施 |
|------|------|
| 同设备 | localStorage 标记 `trial_created`（限制创建）+ `claimed`（注册后防重复弹窗）|
| IP | 同 IP 每日最多创建 3 个临时账户 |
| TTL | 7 天软删除 → 37 天硬删除 |

---

## 七、SEO 关键词规划

### 7.1 关键词矩阵

**类型 A：问题型搜索（最高转化意向）** ← 主攻

| 关键词 | 竞争强度 | 对应位置 |
|--------|----------|---------|
| "AI 能替代老师吗" | 低 | `<meta description>` 中自然嵌入 |
| "孩子记不住怎么办" | 中 | 同上 |
| "AI 一对一辅导 价格" | 低 | 同上 |
| "AI 特级教师" | 极低 | `<title>` 和 `<h1>` |
| "刻意练习 学习方法" | 高 | `<meta description>` |
| "AI 学习助手" | 中 | 标题候选 |

**类型 B：比较型搜索（捕获竞品流量）** ← 次攻

| 关键词 | 对应位置 |
|--------|----------|
| "豆包 教学 vs" | `<meta description>` 中自然出现 |
| "ChatGPT 能教孩子吗" | 同上 |

### 7.2 标题方案（3 选 1）

| 方案 | 标题 |
|------|------|
| A | `CoEvo 刻意进化 — AI 特级教师·一对一辅导` |
| B | `AI 特级教师 · CoEvo — 不遗忘 · 不跑偏 · 不瞎编` |
| C | `CoEvo — AI 学习助手，一对一辅导+科学复习` |

### 7.3 Meta Description

```
CoEvo AI 特级教师——不遗忘、不跑偏、不瞎编。
AI 一对一辅导，FSRS 科学复习，学习效果看得见。
比豆包/ChatGPT 更会教，比辅导班更便宜。
免费试用，30 天不满意全额退。
```

### 7.4 实施

| # | 改动 | 文件 |
|---|------|------|
| 1 | 优化 `<title>` + `<meta description>` | `app/web/index.html` | ✅ **已批准** |
| 2 | `<meta name="description">` 替换 | 同上 |
| 3 | FAQ Schema JSON-LD 结构化数据 | 同上 |

---

## 八、部署架构（Flutter 入口）

### 8.1 架构说明

```
百度搜索 → www.keyievolution.fun（Flutter Web App，根路径）
              ↓ Flutter 加载
         无 token → 5 页幻灯片 → "免费试学" → POST /api/trial/start → 进入产品
         有 token → 直接进入产品
```

| 层级 | 路径 | 百度爬取 | 说明 |
|------|------|----------|------|
| **SEO 入口** | Flutter Web → Nginx `/` | ✅ 可读 `<title>` + `<meta>` + FAQ Schema | 搜索结果展现 |
| **产品端** | Flutter Web 内部路由 | ❌ SPA 不可爬 | 试用→注册→使用全流程 |

**不再维护 `landing/` 目录**。`www.keyievolution.fun` 直接指向 Flutter Web 构建产物，Nginx 配置改为：

```nginx
# 当前：
root /var/www/coevo-landing;                     # landing page
location /app/ { proxy_pass http://127.0.0.1:3000/; }  # Flutter

# 改为：
root /opt/coevo/admin-web;                       # Flutter 构建产物
# 移除所有 /app/ 的 proxy 和 redirect
# SPA fallback: try_files $uri $uri/ /index.html;
```

### 8.2 Flutter 构建调整

```bash
# 当前（--base-href /app/ 表示 Flutter 跑在子路径）
flutter build web --base-href /app/ --dart-define=API_HOST=<OLD_VPS_IP>

# 改为（不加 base-href，Flutter 跑在根路径）
flutter build web --dart-define=API_HOST=<OLD_VPS_IP>
```

### 8.3 SEO 配置

SEO 信息全部放在 `app/web/index.html`（已有 `<title>` 和 `<meta description>`，需补充 FAQ Schema）：

| 项目 | 文件 | 状态 |
|------|------|------|
| `<title>` | `app/web/index.html` | ✅ 已有，可优化 |
| `<meta description>` | 同上 | ✅ 已有，可优化 |
| FAQ Schema JSON-LD | 同上 | ❌ 需添加 |
| 百度统计 | 同上 | ✅ 已有 |
| sitemap.xml | VPS `/var/www/` | ✅ 已部署（指向 `keyievolution.fun/`） |

### 8.4 页面改动清单

| # | 改动 | 文件 | 状态 |
|---|------|------|------|
| 1 | 优化 `<title>` + `<meta description>` | `app/web/index.html` | ✅ **已完成** |
| 2 | 添加 FAQ Schema JSON-LD | `app/web/index.html` | ✅ **已完成** |
| 3 | ~~首屏幻灯片 widget~~ 改为白底加载页 | `auth_screen.dart` | ✅ **已完成**（`first_run_carousel.dart` 已删除） |
| 4 | auth_screen 首屏逻辑（调 trial/start） | `auth_screen.dart` | ✅ **已完成** |
| 5 | 首次进入弹注册窗 | `chat_screen.dart` | ✅ **已完成** |
| 6 | 点击个人图标弹注册窗 | `profile_screen.dart` | ✅ **已完成** |
| 7 | 监听 task 完成弹注册窗 | `chat_screen.dart` | ✅ **已完成** |
| 8 | 注册弹窗 claim_dialog | `widgets/claim_dialog.dart` | ✅ **已完成** |
| 9 | 修改 Nginx 配置 | VPS `sites-enabled/coevo` | ❌ **待部署** |
| 10 | 重建 Flutter Web（去掉 `--base-href /app/`） | 构建命令 | ❌ **待部署** |
| 11 | 删除 `landing/` 目录 | 本地 + VPS | ❌ **待清理** |

### 8.5 Title / Meta Description 方案

**当前：**
```html
<title>刻意进化学习 · CoEvo — AI 特级教师</title>
<meta name="description" content="CoEvo 刻意进化学习 — AI 特级教师。不遗忘 · 不跑偏 · 不瞎编。">
```

**优化为：**
```html
<title>CoEvo AI特级教师 — 主动式一对一学习，不遗忘不跑偏</title>
<meta name="description" content="CoEvo刻意进化学习，基于FSRS记忆算法的AI特级教师。不遗忘·不跑偏·不瞎编·效果看得见。免费试用，30天不满意全额退。">
```
---

---

## 九、本地手动测试流程

> 测试环境：本地后端 `cargo run` + Flutter `flutter run -d chrome --web-renderer html --dart-define=API_HOST=localhost --dart-define=API_PORT=8080`

### TC01：首屏幻灯片 → 免费试学

| 项目 | 内容 |
|:-----|:------|
| **前置** | 清除浏览器 localStorage，访问 `localhost:3000`（或 Flutter 端口）|
| **步骤** | ① 页面显示 5 页幻灯片自动轮播 ② 每页 5 秒切换，一页一句文案 ③ 支持左右滑动翻页 ④ 最后一页有"免费试学"按钮 ⑤ 点击后调 `POST /api/trial/start` |
| **预期** | 幻灯片正常播放，点击"免费试学"后进入聊天页，无登录表单出现 |
| **通过** | □ |

### TC02：首次进入弹注册窗

| 项目 | 内容 |
|:-----|:------|
| **前置** | TC01 通过，trial 账户已创建 |
| **步骤** | ① 进入聊天页后观察 ② 查看注册弹窗内容 ③ 点击关闭 |
| **预期** | 进入聊天页立即弹出注册 Dialog（文案："注册后可保存全部进度"），可关闭，关闭后正常使用 |
| **通过** | □ |

### TC03：个人图标弹注册窗

| 项目 | 内容 |
|:-----|:------|
| **前置** | TC02 已关闭弹窗，处于聊天页 |
| **步骤** | ① 点击底部导航栏"个人"或右上角个人图标 ② 观察是否弹出注册 Dialog |
| **预期** | 弹出注册 Dialog（文案同 TC02），可关闭，关闭后进入个人页 |
| **通过** | □ |

### TC04：task 完成弹注册窗

| 项目 | 内容 |
|:-----|:------|
| **前置** | trial 用户在聊天 |
| **步骤** | ① 正常对话，AI 生成学习计划 ② 完成一个学习 task ③ 观察 `user_plan_progress` 出现 `status='done'` ④ 观察是否弹出注册 Dialog |
| **预期** | task 完成后弹出注册 Dialog，可关闭继续使用 |
| **通过** | □ |

### TC05：注册认领 → 弹窗停止

| 项目 | 内容 |
|:-----|:------|
| **前置** | trial 用户，弹窗中 |
| **步骤** | ① 注册弹窗中填写 username + 密码 ② 点击确认 ③ 调 `PUT /api/trial/claim` ④ 成功后继续使用 ⑤ 刷新页面再次进入 |
| **预期** | 注册成功，弹窗关闭。`SharedPreferences` 中 `claimed=true`。刷新后不再弹出任何注册 Dialog。所有学习数据保留。 |
| **通过** | □ |

### TC06：1 天订阅到期硬拦截

| 项目 | 内容 |
|:-----|:------|
| **前置** | trial 用户的 `subscription_expires` 已过期（可 SQL 直接修改：`UPDATE users SET subscription_expires=datetime('now','-1 hour') WHERE username LIKE 'trial_%'`）|
| **步骤** | ① 发送一条聊天消息 ② 观察 |
| **预期** | `ws.rs` 的 `is_subscription_active()` 返回 false，后端返回 `{"type":"error","content":"subscription_required"}` 事件。前端显示"需要订阅"横幅。无法继续聊天。 |
| **通过** | □ |

### TC07：清理验证

| 项目 | 内容 |
|:-----|:------|
| **前置** | 有超过 7 天的未认领 trial 账户（可 SQL 修改创建时间）|
| **步骤** | ① 执行清理 SQL ② 查 `SELECT deleted_at FROM users WHERE username LIKE 'trial_%' AND ...` |
| **预期** | `deleted_at` 不为空。已认领的账户（`password_hash IS NOT NULL`）未被标记删除。 |
| **通过** | □ |

### 测试结果表

| 编号 | 测试项 | 结果 |
|:-----|:-------|:-----|
| TC01 | 首屏幻灯片 → 免费试学 | □ |
| TC02 | 首次进入弹注册窗 | □ |
| TC03 | 个人图标弹注册窗 | □ |
| TC04 | task 完成弹注册窗 | □ |
| TC05 | 注册认领 → 弹窗停止 | □ |
| TC06 | 1 天订阅到期硬拦截 | □ |
| TC07 | 清理验证 | □ |

---

## 十、付费广告

| 渠道 | 落地目标 | 预算建议 |
|------|----------|----------|
| 百度 SEM | `keyievolution.fun/` | ¥200/天 × 7 天测试 |
| 朋友圈广告 | `keyievolution.fun/` | ¥300/天 × 7 天测试 |

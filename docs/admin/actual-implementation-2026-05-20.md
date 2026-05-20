# 管理后台 · 实际实现文档

> 日期: 2026-05-20 · 反映当前运行代码的实际状态

---

## 一、Tab 结构

```
仪表盘 | 用户管理 | 管理员管理 | 操作日志
                           ↑ 仅 super 显示
```

| Tab | 可见角色 | 说明 |
|-----|---------|------|
| 仪表盘 | 全部 | 今日统计 + 即将到期用户 |
| 用户管理 | 全部 | 用户搜索 + 订阅管理 + 审批 |
| 管理员管理 | super | 管理员列表/分配管理 + 分级授权 |
| 操作日志 | super/service | 搜索审计日志 |

> 旧版的「监护管理」Tab 已移除，分配关系嵌入管理员卡片中。

---

## 二、登录方式

### 2.1 密钥登录 (X-Admin-Key)

```
POST /api/admin/users?q=test   ← 用任意合法请求验证
Header: X-Admin-Key: <COEVO_ADMIN_KEY>
```

- 校验 `X-Admin-Key` header 与 `.env` 中的 `COEVO_ADMIN_KEY` 是否一致
- 登录成功 → 身份设为 `super`（最高权限）

### 2.2 账号登录 (Bearer token)

```
POST /api/admin/login  { username, password }
→ 返回 { token, role, admin_id }

后续请求 Header: Authorization: Bearer <token>
```

- 密码用 bcrypt 校验
- token 即 password_hash 本身（简单方案）
- 角色: `super` / `service` / `guardian` / `tutor`

---

## 三、角色权限矩阵

| 操作 | super | service | guardian | tutor |
|------|:-----:|:-------:|:--------:|:-----:|
| 仪表盘查看 | ✅ | ✅ | ❌ | ❌ |
| 用户搜索/查看 | ✅ | ✅ | ❌ | ❌ |
| 用户详情（卡片+对话） | ✅ | ✅ | ❌ | ❌ |
| 设置到期日 | ✅直接 | ⚠️ 需权限+审批 | ❌ | ❌ |
| +7d | ✅直接 | ⚠️ 需权限+审批 | ❌ | ❌ |
| +30d | ✅直接 | ⚠️ 需权限+审批 | ❌ | ❌ |
| +365d | ✅直接 | ⚠️ 需权限+审批 | ❌ | ❌ |
| 批量延期 | ✅ | ❌ | ❌ | ❌ |
| 订阅审批 | ✅ | 需 can_approve 权限 | ❌ | ❌ |
| 查看手机号(用户) | ✅ | ✅(需service) | ❌ | ❌ |
| 查看手机号(家长/老师) | ✅ | ✅ | ❌ | ❌ |
| 管理员管理 | ✅ | ❌ | ❌ | ❌ |
| 创建管理员 | ✅ | ❌ | ❌ | ❌ |
| 重置管理员密码 | ✅ | ❌ | ❌ | ❌ |
| 禁用/启用管理员 | ✅ | ❌ | ❌ | ❌ |
| 绑定学生 | ✅ | ✅ | 自己 | 自己 |
| 操作日志 | ✅ | ✅ | ❌ | ❌ |
| 查看自己学生卡片 | ❌ | ❌ | ✅ | ✅ |
| 查看自己学生对话 | ❌ | ❌ | ✅ | ✅ |
| 导出 CSV | ✅ | ✅ | ❌ | ❌ |

> ⚠️ service 的扩展操作由分级权限控制（见第五节）

---

## 四、用户管理 Tab 功能

### 4.1 页面布局

```
┌─ 搜索框 ──────────── [查找] [📥] ┐
├──────────────────────────────────┤
│ 选择用户后可操作   [设置到期]      │  ← 固定操作栏
│                     [+7d][+30d]   │
│                     [+365d] [🗑️] │  ← 选中后显示人数
├──────────────────────────────────┤
│ 共 N 人 · 显示 M 人 [显示已删除]   │
├──────────────────────────────────┤
│ ☐ 用户卡片 ───────────── 到期日 ┐ │
│   卡片:N 复习:N · N天 · 家长:X    │ │
│   姓名: 张X · 手机: 123****8910 👁️│ │
│   家长: 张X · 123****8910  👁️     │ │
│   老师: 王X · 123****8910  👁️     │ │
│   [详情]                          │ │
│ ☐ 用户卡片2 ──────────────────────│ │
└──────────────────────────────────┘
```

### 4.2 操作详情

| 操作 | 功能 | 后端端点 |
|------|------|---------|
| 设置到期 | 弹窗输入具体日期 `yyyy-mm-dd` | `PUT /api/admin/users/{id}/subscription` |
| +7d/+30d/+365d | 从到期日延伸 N 天 | `POST /api/admin/users/{id}/quick-extend` |
| 批量延期 | 选中多人 → 从各自到期日延伸 | `POST /api/admin/users/batch-subscription` |
| 删除用户 | 软删除（设置 deleted_at） | `DELETE /api/admin/users/{id}` |
| 恢复用户 | 清除 deleted_at | `POST /api/admin/users/{id}/restore` |
| 查看手机号👁️ | 两步揭看（先脱敏后完整） | `POST /api/admin/users/{id}/reveal-phone` |
| 查看家长/老师👁️ | 查看关联 admin 手机号 | `POST /api/admin/guardian/reveal-phone/{admin_id}` |

### 4.3 搜索

- 默认 `include_deleted=false`（已删除用户不显示）
- 勾选「显示已删除」切换为 `include_deleted=true`
- 搜索字段: `username`, `display_name`, `u.id` (LIKE 模糊匹配)
- ⚠️ 手机号和真实姓名加密存储，不支持搜索

### 4.4 订阅审批

```
服务人员提交申请 → 超级管理员审批 → 自动延长到期日
       ↓                    ↓
  写入 pending         更新 user_preferences
  subscription_requests  + 写入 audit_log
```

| 方法 | 路由 | 说明 |
|------|------|------|
| POST | `/api/admin/subscription-requests` | 提交开通申请 |
| GET | `/api/admin/subscription-requests?status=` | 查看列表 |
| POST | `.../{req_id}/approve` | 通过 |
| POST | `.../{req_id}/reject` | 拒绝 |

---

## 五、分级权限体系

### 5.1 权限键

| 权限键 | 控制操作 | 默认 |
|--------|---------|:----:|
| `can_approve` | 审批订阅请求 | false |
| `set_expiry` | 设置到期日期 | false |
| `extend_7d` | +7天延期 | false |
| `extend_30d` | +30天延期 | false |
| `extend_365d` | +365天延期 | false |

### 5.2 权限检查流程

```
service 操作 → 检查 has_permission(admin_id, perm_key)
  ├─ 有权限 → 直达执行（同 super）
  └─ 无权限 → 403 no_permission
```

### 5.3 权限设置

超级管理员点击管理员卡片上的 🛠️ 图标设置权限：

```
┌────────── 权限设置 ─────────────────┐
│  ☐ 审批订阅请求    (can_approve)     │
│  ☑ 设置到期日期    (set_expiry)      │
│  ☑ +7天延期       (extend_7d)       │
│  ☐ +30天延期      (extend_30d)      │
│  ☐ +365天延期     (extend_365d)     │
│                         [取消] [保存]│
└──────────────────────────────────────┘
```

### 5.4 审批流程中的延期计算

审批通过后，系统查询当前 `user_preferences` 中的到期日，**从到期日基础上**计算新的日期：

```
当前到期日: 2026-06-16, 申请 +30d
→ 新到期日: 2026-07-16
```

> ⚠️ 之前存在 `从今天算起` 的 bug，已修复

---

## 六、管理员管理 Tab（super 专享）

### 6.1 角色分类

```
┌─ 管理员 (12) ──────── [新建] [刷新] ─┐
│ [全部(12)] [服务人员(2)] [家长(8)]    │
│                     [辅导老师(2)]     │
├──────────────────────────────────────┤
│  👤 张老师 · service · 正常          │
│  👤 李家长 · guardian · 已禁用      │
│     学生: 张小狗  [解除]             │
│     [+ 绑定学生]                     │
└──────────────────────────────────────┘
```

### 6.2 功能

| 操作 | 位置 | 说明 |
|------|------|------|
| 新建 | Tab 顶部 | 创建 service/super 账号 |
| 刷新 | Tab 顶部 | 重新加载 |
| 重置密码 | 卡片右 | 设置新密码 |
| 禁用/启用 | 卡片右 | 切换 active/disabled |
| 🛠️ 权限设置 | service 卡片 | 设置细分权限 |
| [+ 绑定学生] | guardian/tutor 卡片 | 搜索并绑定学生 |
| [解除] | 学生名右侧 | 解除分配关系 |

### 6.3 绑定学生

```
点击 [+ 绑定学生] → 弹出搜索框:
输入用户名/昵称 → 实时搜索结果 (300ms debounce)
→ 点击选中 → 自动调用 POST /api/admin/guardian/assignments
  { guardian_admin_id, student_user_id }
```

### 6.4 管理员端点

| 方法 | 路由 | 说明 |
|------|------|------|
| GET | `/api/admin/admins` | 列表（不含 super）|
| POST | `/api/admin/admins` | 创建 |
| POST | `.../{aid}/password` | 重置密码 |
| PUT | `.../{aid}/permissions` | 设置权限 |
| DELETE | `.../{aid}/disable` | 禁用 |
| POST | `.../{aid}/enable` | 启用 |
| GET/POST | `.../guardian/assignments` | 分配关系 |
| DELETE | `.../guardian/assignments/{id}` | 解除分配 |

---

## 七、软删除机制

### 7.1 数据库

```sql
ALTER TABLE users ADD COLUMN deleted_at TEXT;
```

### 7.2 API

| 方法 | 路由 | 说明 |
|------|------|------|
| DELETE | `/api/admin/users/{id}` | 设置 deleted_at = now() |
| POST | `/api/admin/users/{id}/restore` | 清除 deleted_at = NULL |
| GET | `.../users?include_deleted=true` | 含已删除 |

### 7.3 UI

```
已删除的用户:
- 卡片标题灰色 + 删除线
- 标签显示「已删除」(红色)
- 操作栏显示 ♻️ 恢复按钮
- 默认不显示，通过过滤器切换
```

---

## 八、后端关键修复记录

| 问题 | 原因 | 修复 |
|------|------|------|
| API 返回字段不全 | routes.rs 有旧版重复 handler（只查 3 列） | 删除重复 handler |
| 搜索时后端崩溃 | `ORDER BY` 前缺少 `ORDER BY` 关键词 | 补全 |
| 删除用户不生效 | FK 约束、删除顺序不对、缺 `achievements` 表 | 整理 13 张表删除顺序 |
| 详情页崩溃 | `SingleTickerProvider` → 多 TabController 冲突 | 改为 `TickerProvider` |
| 到期日从今天算 | 前后端均以 `DateTime.now()` 为基数 | 改为从数据库到期日加天数 |
| 审批不增加时间 | 审批函数中 package="extend" 落默认 30d | 改为 "7d"/"30d"/"365d" 格式 |
| 家长老师看不了手机号 | guardian_reveal_phone 只允许 tutor | 放开 super/service |
| 服务人员 +d 显示失败 | 前端只检查 `request_id`，忽略 `status:"ok"` | 增加 `status == 'ok'` 判断 |
| 编译缓存不更新 | `cargo build` 检测不到文件变化 | 需 `cargo clean` 或 `touch` 后重建 |

---

## 九、技术栈

- 前端: Flutter (Riverpod + GoRouter + Material3)
- 后端: Rust (axum 0.8 + tokio + rusqlite + r2d2)
- 加密: AES-256-GCM (用户 PII 数据)
- 密码: bcrypt (admin 账号)
- 数据库: SQLite (WAL mode, FK enabled)

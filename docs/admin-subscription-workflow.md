# 管理后台 · 订阅审批流程设计

> 日期: 2026-05-19 · 聚焦付费权限管理

---

## 一、核心流程

```
用户联系客服 → 服务人员提交申请 → 超级管理员审批 → 自动开通/延长 → 通知用户
```

### 角色

| 角色 | 能做什么 | 不能做什么 |
|------|---------|-----------|
| **服务人员** | 搜索用户、查看状态、**提交开通申请** | 不能直接修改到期日 |
| **超级管理员** | 审批/拒绝申请、直接修改到期日、管理服务人员 | — |
| **观察者** | 查看仪表盘、用户列表、审批记录 | 不能操作 |

---

## 二、操作流程

### 服务人员视角

```
┌──────────────────────────────────────┐
│  用户管理                             │
│  ┌──────────────────────────────────┐ │
│  │ 搜索: [________]                  │ │
│  │                                  │ │
│  │ 张三 (user_abc)                  │ │
│  │ 📅 到期 2026-06-15   🟢 已激活   │ │
│  │ 📇 卡片:15 复习:48 连续:12天     │ │
│  │ [提交开通申请]                    │ │
│  └──────────────────────────────────┘ │
│                                      │
│  点「提交开通申请」→ 弹窗:             │
│  ┌──────────────────────────────────┐ │
│  │ 为 张三 申请开通                  │ │
│  │                                  │ │
│  │ 套餐时长:                         │ │
│  │  ○ 30 天                         │ │
│  │  ● 365 天  (推荐)                │ │
│  │  ○ 终身 (公开课特惠)             │ │
│  │                                  │ │
│  │ 接入渠道:                         │ │
│  │  ○ 公开课  ○ 转介绍  ○ 自然流量   │ │
│  │  ○ 其他: [________]              │ │
│  │                                  │ │
│  │ 备注:                             │ │
│  │  [_______________]               │ │
│  │                                  │ │
│  │  [取消]  [提交申请]              │ │
│  └──────────────────────────────────┘ │
└──────────────────────────────────────┘
```

### 超级管理员视角

```
┌──────────────────────────────────────┐
│  审批中心                    🔔 3条待审│
├──────────────────────────────────────┤
│  ┌──────────────────────────────────┐ │
│  │ ⏳ 待审批                        │ │
│  │ 张三 · 365天 · 申请: 李服务      │ │
│  │ 渠道: 公开课 · 备注: 已付费      │ │
│  │ 2026-05-19 14:30                 │ │
│  │ [通过] [拒绝]                    │ │
│  │──────────────────────────────────│ │
│  │ 王五 · 30天 · 申请: 李服务       │ │
│  │ 渠道: 转介绍                     │ │
│  │ 2026-05-19 15:00                 │ │
│  │ [通过] [拒绝]                    │ │
│  └──────────────────────────────────┘ │
│                                      │
│  Tab: [待审批(3)] [已通过] [已拒绝]  │
└──────────────────────────────────────┘
```

### 审批后自动生效

```
通过 → 更新 user_preferences(subscription_expires)
     → 写入 audit_log
     → 服务人员可见审批结果

拒绝 → 写入 audit_log + 拒绝原因
      → 服务人员可见拒绝原因
```

---

## 三、数据库设计

```sql
-- 管理员表
CREATE TABLE admin_users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,     -- bcrypt
    role TEXT NOT NULL,              -- "super" | "service" | "observer"
    created_by TEXT,                 -- 创建人 admin_id
    created_at INTEGER NOT NULL,
    is_active INTEGER DEFAULT 1
);

-- 订阅申请审批表
CREATE TABLE subscription_requests (
    id TEXT PRIMARY KEY,
    target_user_id TEXT NOT NULL,
    requested_by TEXT NOT NULL,      -- 服务人员 admin_id
    reviewed_by TEXT,                -- 超级管理员 admin_id（审批后填入）
    package TEXT NOT NULL,           -- "30d" | "365d" | "lifetime"
    channel TEXT,                    -- 接入渠道
    note TEXT,                       -- 备注
    status TEXT NOT NULL DEFAULT 'pending',  -- pending | approved | rejected
    reject_reason TEXT,
    requested_at INTEGER NOT NULL,
    reviewed_at INTEGER
);

-- 操作审计日志（扩展现有概念）
CREATE TABLE admin_audit_log (
    id TEXT PRIMARY KEY,
    admin_id TEXT NOT NULL,
    action TEXT NOT NULL,            -- "create_request" | "approve" | "reject" | "direct_set"
    target_user_id TEXT,
    request_id TEXT,                 -- 关联 subscription_requests
    detail TEXT,                     -- JSON
    created_at INTEGER NOT NULL
);
```

---

## 四、API 设计

### 管理员认证

| 方法 | 路由 | 说明 |
|------|------|------|
| POST | `/api/admin/login` | 服务人员/观察者登录 {username, password} → token |
| POST | `/api/admin/verify-key` | 超级管理员用 COEVO_ADMIN_KEY 验证 |

所有管理 API 使用 `X-Admin-Key`(超管) 或 `Authorization: Bearer <token>`(服务人员)。

### 用户管理

| 方法 | 路由 | 说明 |
|------|------|------|
| GET | `/api/admin/users?q=` | 搜索（含卡片数、复习数） |
| GET | `/api/admin/users/:id` | 用户详情 |

### 订阅申请（服务人员）

| 方法 | 路由 | 说明 | 角色 |
|------|------|------|------|
| POST | `/api/admin/subscription-requests` | 提交开通申请 | service |
| GET | `/api/admin/subscription-requests?status=pending` | 查看申请列表 | all |

### 审批（超级管理员）

| 方法 | 路由 | 说明 |
|------|------|------|
| POST | `/api/admin/subscription-requests/:id/approve` | 通过 |
| POST | `/api/admin/subscription-requests/:id/reject` | 拒绝 {reason} |
| PUT | `/api/admin/users/:id/subscription` | 直接修改（超管直达） |

### 管理员管理（超级管理员）

| 方法 | 路由 | 说明 |
|------|------|------|
| POST | `/api/admin/admins` | 创建服务人员 |
| GET | `/api/admin/admins` | 管理员列表 |
| DELETE | `/api/admin/admins/:id` | 禁用 |

### 审计

| 方法 | 路由 | 说明 |
|------|------|------|
| GET | `/api/admin/audit-log?user_id=&admin_id=&action=` | 操作日志查询 |

---

## 五、前端页面结构

```
/admin 进入 → 密钥验证（超管）或登录（服务人员）
  │
  ├─ 仪表盘
  │   审批待处理数、今日申请数、本月通过率
  │
  ├─ 用户管理（服务人员+超管）
  │   搜索 → 列表 → 提交申请
  │
  ├─ 审批中心（仅超管可见）
  │   [待审批] [已通过] [已拒绝]
  │
  └─ 管理员管理（仅超管可见）
      创建/禁用服务人员
```

---

## 六、工作量

| 阶段 | 内容 | 时间 |
|------|------|:--:|
| 后端: 3 张表 migration | admin_users + subscription_requests + audit_log | 0.5h |
| 后端: 认证中间件 | admin token 验证 + 角色检查 | 1h |
| 后端: 14 个 API | 订阅申请 CRUD + 审批 + 管理员管理 | 2h |
| 前端: admin 重构 | 4 页 + 审批流 UI | 3h |
| 联调 | 端到端 | 1h |
| **合计** | | **7.5h** |

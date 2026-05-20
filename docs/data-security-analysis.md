# 管理后台 · 数据结构与数据流安全分析

> 日期: 2026-05-19

---

## 一、全量表结构

### 1.1 users 表（扩展后）

| 字段 | 类型 | 敏感级 | 加密 | 说明 |
|------|------|:--:|:--:|------|
| id | TEXT PK | 🟢 内部 | — | 用户唯一 ID，对内使用 |
| username | TEXT | 🟢 内部 | — | 登录名 |
| password_hash | TEXT | 🔴 机密 | bcrypt | 不可逆 |
| real_name | TEXT | 🟡 PII | AES-256 | 真实姓名 |
| phone | TEXT | 🟡 PII | AES-256 | 手机号 |
| id_number | TEXT | 🔴 PII | AES-256 | 身份证号 |
| display_name | TEXT | 🟢 公开 | — | 会话中显示的昵称 |
| streak_days | INTEGER | 🟢 统计 | — | 连续学习天数 |
| last_active_date | TEXT | 🟢 统计 | — | 最后活跃日期 |
| created_at | TEXT | 🟢 公开 | — | 注册时间 |

### 1.2 admin_users 表

| 字段 | 类型 | 敏感级 | 加密 | 说明 |
|------|------|:--:|:--:|------|
| id | TEXT PK | 🟢 内部 | — | 管理员 ID |
| username | TEXT | 🟢 内部 | — | 登录名 |
| password_hash | TEXT | 🔴 机密 | bcrypt | 不可逆 |
| role | TEXT | 🟢 内部 | — | super / service / tutor / guardian / observer |
| status | TEXT | 🟢 内部 | — | pending / active / rejected / disabled |
| real_name | TEXT | 🟡 PII | AES-256 | 实名 |
| phone | TEXT | 🟡 PII | AES-256 | 手机号 |
| id_number | TEXT | 🔴 PII | AES-256 | 身份证号（service/tutor 必填） |
| guardian_declaration | TEXT | 🟡 PII | AES-256 | 监护人声明（JSON: 关系、同意条款） |
| apply_reason | TEXT | 🟢 内部 | — | 申请理由 |
| registered_from | TEXT | 🟢 内部 | — | "parent" / "admin" |

### 1.3 guardian_assignments 表

| 字段 | 类型 | 敏感级 | 说明 |
|------|------|:--:|------|
| id | TEXT PK | 🟢 | 绑定 ID |
| guardian_admin_id | TEXT FK | 🟢 | → admin_users.id |
| student_user_id | TEXT FK | 🟢 | → users.id |
| bind_key | TEXT | 🟡 | "real_name_hash:phone_hash" 索引，不存明文 |
| assigned_by | TEXT | 🟢 | 审批人 admin_id 或 "self" |
| is_active | INTEGER | 🟢 | 是否有效 |

### 1.4 现有业务表（仅列出安全相关）

| 表 | 敏感字段 | 风险 |
|------|---------|------|
| conversations | user_id, title | 对话标题可能含真实信息 |
| conversation_turns | role, content | 对话内容 = 最高敏感性，含学习弱点 |
| cards | user_id, front, back, source_sentence | back 含知识点完整内容 |
| card_memory | card_id, state, reps, lapses | 暴露学生的掌握度弱点 |
| review_log | card_id, quality, user_response | 暴露学生的回答正确/错误 |
| subscription_requests | target_user_id, note | 含业务备注 |
| admin_audit_log | admin_id, target_user_id, detail | 操作记录，需脱敏 |

---

## 二、角色数据可见性矩阵

| 数据 | 超管 | 服务人员 | 辅导老师 | 家长 | 观察者 |
|------|:--:|:--:|:--:|:--:|:--:|
| **自己的 profile** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **用户列表（搜索）** | 全字段 | username + display_name + 订阅 | ❌ | ❌ | username + display_name |
| **用户真实姓名** | 可查看 | 脱敏 `张*`，可点"查看"揭开 | ❌ | ❌ | ❌ |
| **用户手机号** | 可查看（写日志） | 脱敏 `138****1234`，可点"查看"揭开（写日志） | ❌ | ❌ | ❌ |
| **用户身份证** | 可查看（写日志） | ❌ | ❌ | ❌ | ❌ |
| **管理员列表** | 全字段 | ❌ | ❌ | ❌ | 仅姓名+角色 |
| **管理员身份证** | 明文 | ❌ | ❌ | ❌ | ❌ |
| **对话内容** | ❌ | ❌ | 仅分配学生 | 仅自己学生 | ❌ |
| **卡片+复习数据** | ❌ | ❌ | 仅分配学生 | 仅自己学生 | ❌ |
| **订阅申请列表** | 全部 | 仅自己提交的 | ❌ | ❌ | 全部（只读） |
| **审批记录** | 全部 | 仅涉及自己的 | ❌ | ❌ | 全部（只读） |
| **监护关系** | 全部 | ❌ | ❌ | ❌ | 全部（只读） |

---

## 三、数据流追踪

### 3.1 监护绑定数据流

```
家长注册
  │
  ├─ 输入: 学生姓名(明文) + 手机号(明文)
  │
  ▼
POST /api/user/bind-lookup
  │ 加密 phone → AES(phone)
  │ 加密 real_name → AES(real_name)
  │
  ▼
SELECT id FROM users WHERE real_name_enc=? AND phone_enc=?
  │
  ├─ 匹配成功 → 返回 { user_id, display_name }（仅返回 display_name，不返回 real_name + phone）
  │   └─ 创建 guardian_assignments: bind_key=hash(name+phone)（不存明文）
  │
  └─ 未匹配 → 返回 { found: false }
```

### 3.2 服务人员搜索数据流

```
服务人员搜索 "张三"
  │
  ▼
GET /api/admin/users?q=张三
  │
  ▼
SELECT id, username, display_name FROM users WHERE username LIKE '%张三%' OR display_name LIKE '%张三%'
  │  ← 按用户名和 display_name 搜索，不搜 real_name
  │
  ▼
返回:
  {
    user_id: "user_abc",
    username: "zhangsan123",
    display_name: "张三",
    subscription_expires: "2027-12-31",
    phone_masked: "138****1234",    // 仅后4位脱敏
    real_name_masked: null           // 服务人员不可见
  }
```

### 3.3 监护者查看学生对话数据流

```
家长查看学生详情
  │
  ▼
GET /api/admin/guardian/students/:id/conversations
  │
  ▼
验证: guardian_admin_id ← guardian_assignments → student_user_id
  │
  ├─ 未授权 → 403
  │
  └─ 已授权 →
      SELECT * FROM conversation_turns WHERE conversation_id IN (
        SELECT id FROM conversations WHERE user_id=?
      )
      ORDER BY created_at
      → 返回完整对话流
```

### 3.4 审计日志数据流

```
任何管理操作
  │
  ▼
写入 admin_audit_log:
  {
    admin_id: "admin_svc_001",
    action: "create_subscription_request",
    target_user_id: "user_abc",
    detail: {                            // 只记操作，不记敏感内容
      package: "365d",
      channel: "公开课"
      // ❌ 不记录: target_user 的姓名、手机、对话内容
    }
  }
```

### 3.5 姓名/手机号揭看数据流

**姓名**：脱敏 `张*`，一键揭开，无需记录。

**手机号**：脱敏 `138****1234`，揭开需写审计日志。

```
服务人员/超管点击"查看手机号"
  │
  ▼
POST /api/admin/users/:id/reveal-phone
  │ 验证: role ∈ {super, service}
  │
  ▼
写入 admin_audit_log:
  {
    admin_id: "admin_svc_001",
    action: "reveal_phone",
    target_user_id: "user_abc",
    detail: {
      ip: "xxx.xxx.xxx.xxx",
      user_agent: "Mozilla/5.0 ..."
    }
  }
  │
  ▼
解密: AES_decrypt(users.phone, COEVO_PII_KEY)
  │
  ▼
返回: { phone: "138****1234" }     // 首次返回脱敏
  
前端再次点击"查看完整号码" → 二次确认弹窗 → 返回明文
  │
  ▼
再次写入 audit_log:
  {
    action: "reveal_phone_full",
    ...
  }
```

**规则**：
- 每次揭看独立写一条日志，不合并
- 揭看日志不可删除（即使超管）
- 超过 30 天未揭看的脱敏数据自动降级为 `***`（提醒联系超管）
- 审计日志展示"谁在何时看了谁的手机号"

---

## 四、风险点与缓解

### 4.1 PII 泄露风险

| 风险 | 场景 | 缓解 |
|------|------|------|
| 手机号暴力匹配 | 家长注册时不断尝试不同手机号 | 限流: 5次/分钟/IP；仅匹配已完善 profile 的学生 |
| 真实姓名泄露 | API 返回完整 real_name | 服务人员只返脱敏 `张*`，家长看不到 |
| 身份证泄露 | 数据库被拖库 | AES-256 加密存储，密钥存环境变量 |
| 对话内容外泄 | 越权访问 | guardian_assignments 表做权限网关 |

### 4.2 数据污染风险

| 风险 | 场景 | 缓解 |
|------|------|------|
| 重复绑定 | 同一学生被多个家长绑定 | UNIQUE(guardian_admin_id, student_user_id) |
| 虚假绑定 | 恶意注册家长号绑定他人学生 | 超管审批环节人工审核 |
| 孤儿数据 | 学生账号删除后绑定残留 | ON DELETE CASCADE |
| bind_key 不一致 | real_name/phone 修改后旧绑定失效 | bind_key 存 hash，修改 profile 后需重新绑定 |

### 4.3 权限越界风险

| 风险 | 场景 | 缓解 |
|------|------|------|
| 服务人员偷看对话 | 通过用户详情 API 获取 | 后端按 role 过滤字段，非监护人角色不返回对话 |
| 辅导老师看非分配学生 | 直接改 URL 参数 | 后端验证 guardian_admin_id ↔ student_user_id |
| 观察者修改数据 | 通过 API 直接操作 | 后端所有写操作检查 role != observer |
| 手机号被偷偷揭看 | 服务人员/超管揭看后无记录 | 每次揭看独立写 audit_log，不可删除 |
| 审计日志被清除 | 超管恶意删除日志 | admin_audit_log 表仅 INSERT + SELECT，无 DELETE

---

## 五、监护者列表数据展示规范

### 家长/辅导老师看到的「学生列表」

```json
{
  "students": [{
    "student_user_id": "user_abc",
    "display_name": "张三",
    "real_name_masked": "张*",        // 家长可见脱敏名（已通过审批，确认关系）
    "phone_masked": null,             // 家长不可见手机号
    "card_count": 12,
    "review_count": 48,
    "streak_days": 12,
    "mastery_rate": 0.67,
    "weak_topics": ["一次函数图象", "韦达定理"],
    "last_active": "2026-05-19T14:30:00Z"
  }]
}
```

### 超管看到的「监护关系管理列表」

```json
{
  "assignments": [{
    "id": "bind_001",
    "guardian": {
      "admin_id": "adm_001",
      "real_name": "张父",
      "phone_masked": "139****5678",
      "role": "guardian",
      "registered_from": "parent",
      "guardian_declaration": {
        "relation": "父亲",
        "consented_at": "2026-05-19"
      }
    },
    "student": {
      "user_id": "user_abc",
      "display_name": "张三",
      "real_name": "张三",
      "phone": "13812345678"
    },
    "bound_at": "2026-05-19T12:00:00Z",
    "is_active": true
  }]
}
```

---

## 六、加密策略

| 数据 | 算法 | 密钥来源 | 存储格式 |
|------|------|---------|---------|
| password_hash | bcrypt(12) | 自动盐 | `$2b$12$...` |
| real_name | AES-256-GCM | `COEVO_PII_KEY` 环境变量 | Base64(iv+ciphertext+tag) |
| phone | AES-256-GCM | `COEVO_PII_KEY` | Base64(iv+ciphertext+tag) |
| id_number | AES-256-GCM | `COEVO_PII_KEY` | Base64(iv+ciphertext+tag) |
| guardian_declaration | AES-256-GCM | `COEVO_PII_KEY` | Base64(iv+ciphertext+tag) |
| bind_key | SHA-256 | — | hex(hash) |

---

## 七、API 安全清单

| API | 认证 | 授权检查 | 字段过滤 | 限流 |
|------|:--:|------|:--:|:--:|
| `/api/user/bind-lookup` | 监护人 token | — | 仅返回 display_name | 5/min/IP |
| `/api/admin/users?q=` | admin key/token | role≠guardian | 按角色脱敏 | 30/min |
| `/api/admin/users/:id/reveal-phone` | admin key/token | role∈{super,service} | 首次脱敏，二次明文 | 单次操作写日志 |
| `/api/admin/audit-log/reveals` | admin key/token | 仅超管+观察者 | 展示谁在何时看了谁手机号 | 20/min |
| `/api/admin/guardian/students/:id/conversations` | 监护人 token | guardian_assignments | 全量返回对话 | 10/min |
| `/api/admin/guardian/students/:id/cards` | 监护人 token | guardian_assignments | 全量返回卡片 | 10/min |
| `/api/admin/subscription-requests` | admin key/token | 仅超管可见全部 | — | 30/min |
| `/api/admin/audit-log` | admin key/token | 仅超管+观察者 | — | 20/min |

---

## 八、实现状态（2026-05-20 更新）

### 已实现
| 措施 | 状态 | 文件位置 |
|------|:----:|---------|
| bcrypt(12) 密码哈希 | ✅ | `admin_handlers.rs:84`, `auth.rs:31-36` |
| 角色可见性矩阵后端过滤 | ✅ | `admin_handlers.rs:97-122` |
| guardian_assignments 权限网关 | ✅ | `admin_handlers.rs:301-303` |
| 审计日志只追加 | ✅ | 仅 INSERT + SELECT |
| 手机号两步揭看 + 审计日志 | ✅ | `admin_handlers.rs:139-160`, `admin_screen.dart:162-192` |
| bind-lookup IP 限流 5/min | ✅ | `rate_limiter.rs` |
| admin/users API 限流 30/min | ✅ | `admin_handlers.rs:97-98` |
| bind_key SHA-256 | ✅ | `admin_handlers.rs:239-244` |

### 待实现（与本文档设计差距）
| 设计 | 现状 | 说明 |
|------|------|------|
| AES-256-GCM 加密 PII | ❌ | 所有 PII 字段明文存储在 SQLite 中。`COEVO_PII_KEY` 环境变量不存在。 |
| API 限流全覆盖 | ⚠️ 部分 | 已覆盖 bind-lookup(5/min)、admin/users(30/min)、reveal-phone(20/min) |
| 手机号 30 天自动降级`***` | ❌ | 未实现自动降级逻辑 |
| 揭看日志不可删除 | ✅ 隐含 | 后端无 DELETE API，但 SQLite 级别可删除 |

### 关于加密的决策建议
当前 SQLite 数据库运行在 VPS (Ubuntu 22.04, 2C1G)，磁盘级加密（云盘默认）+ 访问控制已经提供了基本的防护层。AES-256 字段级加密的主要价值场景是"数据库文件被拖出服务器后仍不可读"。如果此风险在可接受范围内，建议**同步修正本文档描述**而非实现加密。


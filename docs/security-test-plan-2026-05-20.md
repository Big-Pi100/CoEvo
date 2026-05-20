# 安全功能测试计划

> 基于 `data-security-analysis.md` 与代码逐条 trace 的结果设计
> 日期: 2026-05-20 | 覆盖: 后端 Rust + 前端 Dart

---

## 测试分类

| 层级 | 测试类型 | 工具 |
|:----:|---------|------|
| **单元** | 加密/解密/限流/权限函数 | `cargo test` |
| **集成** | API 请求→响应全链路 | `cargo test` (e2e) |
| **前端** | UI 逻辑/脱敏显示 | `flutter test` |

---

## T1: AES-256-GCM 加密单元测试 ← 已实现 ✅

**文件**: `backend/crates/api_server/src/encryption.rs`

| # | 测试 | 验证点 | 状态 |
|:-:|------|-------|:----:|
| 1 | `test_encrypt_decrypt_roundtrip` | encrypt("/K4K/")→密文→decrypt→"/K4K/" | ✅ 已通过 |
| 2 | `test_encrypt_different_each_time` | 同一明文两次加密结果不同（随机 nonce） | ✅ 已通过 |
| 3 | `test_bind_hash_consistent` | 相同输入输出一致 | ✅ 已通过 |
| 4 | `test_bind_hash_different` | 不同输入输出不同 | ✅ 已通过 |
| 5 | `test_decrypt_empty_on_garbage` | 无效密文返回空字符串 | ✅ 已通过 |
| 6 | `test_is_encrypted` | 正确识别加密/非加密字符串 | ✅ 已通过 |

---

## T2: 限流单元测试 ← 已实现 ✅

**文件**: `backend/crates/api_server/src/rate_limiter.rs`

| # | 测试 | 验证点 | 状态 |
|:-:|------|-------|:----:|
| 1 | `test_rate_limiter_allows_within_limit` | 5次内允许 | ✅ |
| 2 | `test_rate_limiter_blocks_excess` | 第6次拒绝 | ✅ |
| 3 | `test_rate_limiter_per_ip_independent` | 不同 IP 独立计数 | ✅ |

---

## T3: 认证模块单元测试 ← 已实现 ✅

**文件**: `backend/crates/api_server/src/auth.rs` — 6 个测试，含注册/登录/密码验证/令牌验证

---

## T4: 集成测试 — 需要新增

### T4.1 PII 加密写路径 — 每个写 handler 验证

| # | 端点 | 测试 | 断言 |
|:-:|------|------|------|
| 1 | `POST /api/admin/register` | 注册后查 DB，`real_name`/`phone` 为 base64 密文（非原文） | 非明文，is_encrypted=true |
| 2 | `POST /api/auth/register` | 同上，`users` 表 | 非明文，is_encrypted=true |
| 3 | `PUT /api/user/:id/profile` | 更新后查 DB | 非明文 |
| 4 | `POST /api/admin/guardian/assignments` | 创建后查 `guardian_assignments.bind_key` 为 64 位 hex (SHA-256) | 格式匹配 `^[a-f0-9]{64}$` |

### T4.2 PII 解密读路径 — 每个读 handler 验证

| # | 端点 | 测试 | 断言 |
|:-:|------|------|------|
| 5 | `GET /api/admin/users?q=` (super) | 返回的 `real_name` 和 `phone` 是明文原文 | 非 base64 密文 |
| 6 | `GET /api/admin/users?q=` (service) | 返回 `real_name` 为脱敏 `张*`，`phone` 为脱敏 `138****1234` | match pattern |
| 7 | `GET /api/admin/users/:id` (super) | `real_name`/`phone` 为明文 | 可读中文 |
| 8 | `POST /api/admin/users/:id/reveal-phone` | 返回 `phone` 为明文 | 可读 |
| 9 | `GET /api/admin/admins` | `real_name`/`phone` 为明文 | 可读 |
| 10 | `GET /api/user/:id/profile` | `real_name`/`phone` 为明文 | 可读中文 |
| 11 | `GET /api/admin/guardian/students` | `real_name_masked` 为 `张*` 格式 | match pattern |

### T4.3 bind-lookup 数据流

| # | 测试 | 断言 |
|:-:|------|------|
| 12 | 注册用户 A（姓名"张三"手机"13800138000"），调用 bind-lookup(张三,13800138000) | `found: true`, 返回 `display_name` |
| 13 | 调用 bind-lookup(张三,13900139000) | `found: false` |
| 14 | 同一 IP 连续调用 6 次 bind-lookup | 第 6 次返回 429 |

### T4.4 可见性矩阵验证

| # | 角色 | API | 断言 |
|:-:|:----:|-----|------|
| 15 | guardian | `GET /api/admin/users?q=` | 403 forbidden |
| 16 | observer | `POST /api/admin/admins/:id/approve` | 403 "observer_readonly" |
| 17 | observer | `POST /api/admin/admins/:id/reject` | 403 "observer_readonly" |
| 18 | 未授权 | `GET /api/user/:id/profile` (不同用户 token) | 401 |
| 19 | tutor | `GET /api/admin/subscription-requests` | 403 (不在此 role 的 allowed 列表) |

### T4.5 权限网关验证

| # | 场景 | 断言 |
|:-:|------|------|
| 20 | 家长 A 查看学生 B 的卡片（B 未绑定给 A） | 403 |
| 21 | 家长 A 查看学生 B 的对话（B 未绑定给 A） | 403 |
| 22 | 家长 A 查看学生 A 的卡片（A 绑定给 A） | 200 + 卡片数据 |

### T4.6 审计日志完整性

| # | 操作 | 断言审计日志存在 |
|:-:|------|---------------|
| 23 | 创建订阅申请 | 日志 action='create_request' |
| 24 | 批准订阅 | 日志 action='approved_subscription' |
| 25 | 拒绝订阅 | 日志 action='rejected_subscription' |
| 26 | 设置到期日 | 日志 action='set_subscription' |
| 27 | 揭看手机号(step1) | 日志 action='reveal_phone_masked' |
| 28 | 揭看手机号(step2) | 日志 action='reveal_phone_full' |
| 29 | 批准管理员 | 日志（检查是否写入） |
| 30 | 拒绝管理员 | 日志（检查是否写入） |
| 31 | 监护分配 | 日志（检查是否写入） |

### T4.7 API 限流验证

| # | API | 限流阈值 | 验证 |
|:-:|-----|:--------:|------|
| 32 | `/api/user/bind-lookup` | 5/min | 连续 6 次 → 第 6 次 429 |
| 33 | `/api/admin/users?q=` | 30/min | 连续 31 次 → 第 31 次 429 (未实现) |
| 34 | `/api/admin/users/:id/reveal-phone` | 20/min | 连续 21 次 → 第 21 次 429 (未实现) |

---

## T5: 前端测试 — 需要新增

**文件**: `app/lib/screens/admin_screen.dart`

| # | 测试 | 验证点 |
|:-:|------|-------|
| 1 | 手机号两步揭看流 | 首次点击显示脱敏号 + "查看完整号码"按钮；二次点击显示明文 |
| 2 | 角色 Tab 可见性 | super=5Tab, service=2Tab, observer=2Tab, guardian 不显示 admin |
| 3 | 用户列表脱敏 | 非 super 看到 `real_name: "张*"`, `phone: "138****1234"` |
| 4 | 审计日志展示 | detail 字段中的 target 和 masked 信息正确渲染 |

---

## T6: 已知未覆盖的安全缺口

来自 trace 结果：

| 缺口 | 影响 | 建议 |
|------|------|------|
| **`profile_handler` 原无认证** | 任何人可查任意用户资料 | ✅ **已修复**（本日补丁） |
| `update_user_profile_handler` 忽略验证 | 无认证+无授权，任何人可改任意用户资料 | 需增加 token 验证 |
| **30 天自动降级 `***`** | 未实现 | 文档设计但未落地 |
| **审计日志对 admin_approve/admin_reject 不完整** | 未确认是否每条管理操作都写日志 | 检查 `admin_approve_admin` 和 `admin_reject_admin` handler |
| **AES 密钥无轮换机制** | 无 | 属于运维策略，非代码问题 |

---

## 测试执行计划

```bash
# 1. 运行已有单元测试
cd E:\CoEvo\backend
cargo test --package api_server -- encryption  # 6 tests
cargo test --package api_server -- auth        # 6 tests
cargo test --package api_server -- rate_limiter # 3 tests

# 2. T4 集成测试需要新增 e2e 测试文件
# 建议: backend/crates/api_server/tests/security_e2e.rs
# 测试框架: 使用 rusqlite::Connection::open_in_memory() + 自定义 schema

# 3. 前端测试
cd E:\CoEvo\app
flutter test test/widget/admin_screen_test.dart  # 待创建
```

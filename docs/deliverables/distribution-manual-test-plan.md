# 分销营销模块 — 手动测试流程

> 测试环境：本地开发环境（后端 `cargo run` + 前端 `flutter run -d chrome`）
> 测试账号：admin（管理端）+ test1/test2/test3（用户端）
> 日期：2026-06-18

---

## 准备工作

### 1. 环境确认
```bash
# 确保 DB schema 包含新表
cd backend
cargo run    # 启动后端，自动创建新表
# 新开终端
cd app
flutter run -d chrome --dart-define=API_HOST=localhost
```

### 2. 数据初始化（可选）
```bash
# 确保有多个测试用户，且有推广关系
sqlite3 data/coevo.db "
UPDATE users SET referral_code = 'CoEvo_TEST1' WHERE username = 'test1';
UPDATE users SET referral_code = 'CoEvo_TEST2' WHERE username = 'test2';"
```

---

## 测试用例

### TC01：管理员创建活动

| 项目 | 内容 |
|:-----|:------|
| **前置** | 以 admin 身份登录管理端 |
| **步骤** | ① 进入营销中心 → 活动管理 → 点击"新建活动" ② 填写活动名称"测试活动-手工验证" ③ 触发事件选 `registration` ④ 奖励 JSON 填 `[{"type":"subscription_days","party":"self","value":3,"trigger":"registration"}]` ⑤ 目标角色选 `student` ⑥ 点击提交 |
| **预期** | 活动创建成功，列表页显示新卡片，状态为"draft" |
| **通过** | □ |

### TC02：管理员启停活动 + 触发验证

| 项目 | 内容 |
|:-----|:------|
| **前置** | TC01 通过，活动处于 draft 状态 |
| **步骤** | ① 点击活动卡片进入详情 ② 点击"启停切换"按钮 ③ 选择 `active` ④ SQL 验证触发：注册新用户 → 查 `SELECT subscription_expires FROM users WHERE username='新用户'` 应比注册时间晚 3 天；`SELECT * FROM reward_fulfillments` 应有 fulfilled 记录；`SELECT * FROM user_notifications` 应有"获得会员天数"通知 |
| **预期** | 状态变为 active。新用户注册后自动获 3 天会员，reward_fulfillments + user_notifications 有对应记录。同用户重复注册不会重复发放。 |
| **通过** | □ |

### TC03：幂等保护验证

| 项目 | 内容 |
|:-----|:------|
| **前置** | TC02 已触发注册送3天活动 |
| **步骤** | ① 用同一用户再次调注册 API（模拟异常重复请求） ② 查 `reward_fulfillments` 同用户同活动的记录数 |
| **预期** | 奖励只发放一次，`reward_fulfillments` 无第二条记录 |
| **通过** | □ |

### TC04：复习完成弹分享

| 项目 | 内容 |
|:-----|:------|
| **前置** | 已创建 `push_trigger='after_complete_review'` 的活动（如"每天进化1%"），且用户有卡片可复习 |
| **步骤** | ① 用户登录 → 进入复习 ② 完成全部待复习卡片 ③ 看到复习完成弹窗 ④ 等待 0.5 秒后弹出分享引导弹窗 |
| **预期** | 复习完成弹窗先显示 → 点"继续"关闭 → 0.5 秒后弹出"分享给好友"弹窗 → 点击"去分享"弹出 ShareWidget → 可正常生成海报和 H5 链接 |
| **通过** | □ |

### TC05：用户查看推广码

| 项目 | 内容 |
|:-----|:------|
| **前置** | 以 test1 登录用户端 |
| **步骤** | ① 进入个人页 ② 查找"我的推广码"区域 |
| **预期** | 显示推广码（格式如 `CoEvo_XXXX`）+ 复制按钮 + "分享给朋友"按钮 |
| **通过** | □ |

### TC06：用户分享统计

| 项目 | 内容 |
|:-----|:------|
| **前置** | test1 已登录，已知推广码 |
| **步骤** | ① 从浏览器地址栏直接访问 `http://localhost:8080/api/referral/my-stats?user_id=test1的id` ② 检查返回数据 |
| **预期** | 返回 JSON：`{ total_clicks: 0, total_registrations: 0, total_earned: 0 }` |
| **通过** | □ |

### TC07：模拟点击测试

| 项目 | 内容 |
|:-----|:------|
| **前置** | 已知 test1 的推广码（如 `CoEvo_TEST1`）和 campaign_id |
| **步骤** | ① 用 curl 或浏览器 DevTools Console 模拟点击：```javascript fetch('/api/referral/click', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({ campaign_id:'camp_xxx', referrer_code:'CoEvo_TEST1', clicker_anonymous_id:'anon_device_001', share_channel:'profile' }) })``` ② 记录返回的 click_id |
| **预期** | 返回 `{ id: "xxx" }`，状态码 200 |
| **通过** | □ |

### TC08：用户注册携带推广码

| 项目 | 内容 |
|:-----|:------|
| **前置** | 有一个未注册的浏览器标签页（或清除 localStorage 后） |
| **步骤** | ① 打开注册页 ② 填写注册信息 ③ 在 referral 字段填入 test1 的推广码 `CoEvo_TEST1` ④ 提交注册 ⑤ 注册成功后，以新用户登录 |
| **预期** | 注册成功。查询该新用户的 referred_by 应为 test1 的 id。注册后该用户自动获得 3 天试用会员（subscription_expires 更新）。 |
| **通过** | □ |

### TC09：查看团队树

| 项目 | 内容 |
|:-----|:------|
| **前置** | test1 已通过 TC08 推广了至少一个用户 |
| **步骤** | ① 以 test1 登录 ② 进入"我的团队"页面 |
| **预期** | 显示二级下线列表，包括刚注册的新用户 |
| **通过** | □ |

### TC10：支付页折扣展示

| 项目 | 内容 |
|:-----|:------|
| **前置** | 用推广来的用户（TC08 注册的用户）登录 |
| **步骤** | ① 进入购买套餐页 ② 查看套餐列表 |
| **预期** | 顶部显示"🎉 好友邀请专属优惠"横幅，套餐卡片显示原价（划线）和折后价 |
| **通过** | □ |

### TC11：管理端查看分销团队

| 项目 | 内容 |
|:-----|:------|
| **前置** | admin 登录 |
| **步骤** | ① 进入营销中心 → 分销团队 ② 搜索 test1 ③ 点击查看详情 |
| **预期** | 显示 test1 的统计信息：点击数、下线人数、佣金总额。点击记录列表有内容 |
| **通过** | □ |

### TC12：管理端数据统计

| 项目 | 内容 |
|:-----|:------|
| **前置** | admin 登录，已有活动数据 |
| **步骤** | ① 进入营销中心 → 数据统计 |
| **预期** | 显示指标卡（活动数/点击数/注册数/待结算佣金）和漏斗数据 |
| **通过** | □ |

### TC13：创建结算批次（管理员）

| 项目 | 内容 |
|:-----|:------|
| **前置** | 有一条 distribution_commissions 处于 `available` 状态（可通过 mock 或等待 30 天解锁，或直接 SQL 更新：`UPDATE distribution_commissions SET status='available' WHERE status='locked' LIMIT 1`）|
| **步骤** | ① admin 登录 → 进入营销中心 → 佣金结算 ② 在"待结算佣金" tab 勾选一条或多条佣金 ③ 点击"创建结算批次" |
| **预期** | 批次创建成功，显示 batch_no（格式 ST20260618-001），佣金状态变为 settled。批次列表出现新批次。 |
| **通过** | □ |

### TC14：标记批次已打款

| 项目 | 内容 |
|:-----|:------|
| **前置** | TC13 通过，有一个 pending 的结算批次 |
| **步骤** | ① 点击批次 → 进入批次明细页 ② 点击"标记已打款" ③ 输入备注"测试转账" ④ 确认 |
| **预期** | 批次状态变为 paid，批次内所有佣金状态变为 paid，佣金明细中 paid_at 不为空 |
| **通过** | □ |

### TC15：用户通知中心

| 项目 | 内容 |
|:-----|:------|
| **前置** | 系统中有生成的 user_notifications（通过手动推送活动或注册触发活动） |
| **步骤** | ① 用户登录 ② 进入通知中心 ③ 查看通知列表 |
| **预期** | 显示通知列表，有 type 图标（营销/收益/提现）、标题、内容、时间。未读通知有红点。奖励通知文案含活动名称和天数/金额。 |
| **通过** | □ |

### TC16：订阅到期日迁移验证

| 项目 | 内容 |
|:-----|:------|
| **前置** | 已有用户有 subscription_expires 数据 |
| **步骤** | ① 运行迁移 SQL：`sqlite3 data/coevo.db < backend/scripts/migrate_subscription_expires.sql` ② 查询：`SELECT id, subscription_expires FROM users WHERE subscription_expires IS NOT NULL LIMIT 5` ③ 验证订阅查询结果一致 |
| **预期** | users 表中有 subscription_expires 数据，和之前 user_preferences 中的一致。用户订阅状态不受影响。 |
| **通过** | □ |

---

## 回归测试

### RT01：现有注册流程不受影响
- 不填推广码注册一个用户 → 注册成功，referred_by 为 NULL ✅  □
- 填非法推广码注册一个用户 → 注册成功，静默跳过绑定 ✅  □

### RT02：管理端原有功能不受影响
- 查看用户列表 → 列表正常显示 ✅  □
- 设置/修改用户订阅 → 订阅记录在 users.subscription_expires 中 ✅  □

### RT03：支付流程不受影响
- 无推广关系的用户购买套餐 → 支付成功，无佣金生成 ✅  □
- 有推广关系的用户购买套餐 → 支付成功，佣金生成（status=locked） ✅  □

---

## 测试结果记录

| 编号 | 测试项 | 结果 | 备注 |
|:-----|:-------|:-----|:------|
| TC01 | 创建活动（新奖励格式） | □ □ |
| TC02 | 启停活动 + 触发验证 | □ □ |
| TC03 | 幂等保护验证 | □ □ |
| TC04 | 复习完成弹分享 | □ □ |
| TC05 | 用户查看推广码 | □ □ |
| TC06 | 分享统计 | □ □ |
| TC07 | 模拟点击 | □ □ |
| TC08 | 注册带推广码（含自动试用） | □ □ |
| TC09 | 团队树 | □ □ |
| TC10 | 支付页折扣 | □ □ |
| TC11 | 管理团队搜索 | □ □ |
| TC12 | 数据统计 | □ □ |
| TC13 | 创建结算批次 | □ □ |
| TC14 | 标记已打款 | □ □ |
| TC15 | 通知中心（含奖励通知） | □ □ |
| TC16 | 订阅到期日迁移 | □ □ |
| RT01 | 注册回归 | □ □ |
| RT02 | 管理端回归 | □ □ |
| RT03 | 支付回归 | □ □ |

**测试人**: ________   **日期**: ________   **通过率**: ___/19

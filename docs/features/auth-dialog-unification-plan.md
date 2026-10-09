# 推广码绑定 + 弹窗统一方案

> ## 🔴 2026-10-09 标注：本文**整体失效**（两半都死了）
>
> | 本文的前提 | 现状 |
> |---|---|
> | 「创建临时账户时后端绑定推广关系」（`trialStart(referral_code)`）| 🔴 **分销/推广链 2026-10-06 已整体退役**（`/api/referral/*`、`/api/campaign*` 路由已删）|
> | `POST /api/trial/start` / `trialClaim` | 🔴 **试用账号机制 2026-10-09 已整体退役**（两个路由 + `trial_handler` 已删）|
>
> ⇒ **本文保留仅供追溯**，不要按它实现任何东西。
> 📄 `docs/review/trial-account-removal-2026-10-09.md` ·
>    `docs/review/backend-dead-route-cleanup-2026-10-06.md`

## 核心思路

推广关系不在注册表单里手动填写，而是在创建临时账户时由后端直接绑定。

```
用户打开 /home?ref=CoEvo_trial_75b5
  ↓
trialStart(refCode: "CoEvo_trial_75b5")    ← 前端把推广码带到后端
  ↓
后端 POST /api/trial/start + referral_code
  ↓
解析推广码 → 写入 DB users.referred_by
  ↓
用户在任何页面触发 trialClaim → DB 已有 referred_by → 无需前端传参
```

## 最终状态：一套弹窗 + 后端绑定

### 弹窗

只保留 `widgets/claim_dialog.dart`（`ClaimDialog`），删除 `home_screen.dart` 中的 `_AuthDialog`。

`ClaimDialog` 删除：
- `_inviteCodeController` 和相关输入框
- `_loadPendingRef()` 读 SharedPreferences
- 注册成功后清理 `pending_ref_code`

### 三处触发点统一使用 ClaimDialog

| # | 位置 | 触发条件 | 触发方式 |
|:-:|:-----|:---------|:---------|
| 1 | 首页 `_initAuth` | trial 未认领 | `showDialog(builder: (_) => const ClaimDialog())` |
| 2 | 首页 AppBar 头像 | `hasUsedTrial && !isAuthenticated` | 同上 |
| 3 | 聊天页（4 子入口） | subscription_required / 横幅 | `showDialog(builder: (_) => const ClaimDialog())`（已有） |
| 4 | 个人页 build（首次） | trial 未认领 | `showDialog(builder: (_) => const ClaimDialog())`（已有） |

### 数据流

```
URL ?ref=xxx
  → HomeScreen._initAuth 读取一次
  → AuthNotifier.trialStart(refCode: xxx)
  → AuthClient.trialStart(referralCode: xxx)
  → POST /api/trial/start {referral_code: "xxx"}
  → 后端解析 referral_code → 写入 users.referred_by
  → 完成
```

任何页面的 `trialClaim()` 直接从 DB 取 `referred_by`，不再需要前端传递。

## 文件变更清单

| 文件 | 改动 |
|:-----|:------|
| `backend/.../trial_handler.rs` | `start()` 接受可选 `referral_code` 请求体，解析后写入 `referred_by` |
| `app/lib/api/auth_client.dart` | `trialStart()` 接受可选 `referralCode` 参数 |
| `app/lib/providers/auth_provider.dart` | `trialStart()` 透传 `refCode` |
| `app/lib/widgets/claim_dialog.dart` | 删除 `_inviteCodeController`、`_loadPendingRef`、邀请码输入框、`pending_ref_code` 清理 |
| `app/lib/screens/home_screen.dart` | `_initAuth` 调用 `trialStart(refCode: ...)`；删除 `_AuthDialog` 私有类（~160 行）；`_showAuthDialog` 改为弹出 `ClaimDialog` |
| `app/lib/screens/chat_screen.dart` | 无改动（已用 `ClaimDialog`） |
| `app/lib/screens/profile_screen.dart` | 无改动（已用 `ClaimDialog`） |
| `app/lib/widgets/claim_dialog.dart` 导入 | 无改动 |

## 删除的代码

- `_AuthDialog` 整个类 ~160 行
- `_readRefCode()` 方法
- `_refCode` 状态字段
- `initialRefCode` 构造参数
- `_inviteCodeController` 和邀请码输入框
- `_loadPendingRef()` 方法
- `pending_ref_code` SharedPreferences 读写
- URL 推广码在注册表单中回填的逻辑

# 注册改用「邮箱 + 密码」· 去掉实名与手机号

- 日期：2026-09-29
- 触发：白哥「**注册不要真实姓名和手机号，用邮箱注册+密码注册吧**」
- 范围：**后端（含 DB schema）+ 前端 + 一个回归修复**
- 状态：✅ 实施完 · 本地验证通过 · 🔴 **未部署**

---

## 一、这与既定设计一致（不是我新发明的）

`ui-ux-refactor-assessment-2026-09-25.md` §4.2 原文就写着：

> 「『我的』→ 大幅精简：…；**删实名** / K12 / 分销 / 学习设置 / 数据导出」

`users` 表的 `real_name` / `phone` / `phone_hash` / `id_number` / `bind_hash` 五列
是**微信时代的实名制遗留**（当时为 K12 与未成年人保护设计；产品已定**不做 K12**）。
本次是把它落地。

---

## 二、关键决策（白哥 2026-09-29 定）

| 决策点 | 选项 | 白哥选 | 理由 |
|---|---|---|---|
| 邮箱存哪 | A 存进 `users.username` / **B 新增 `email` 列** | **B** | 语义干净；**后端零真实用户**（91 行全是 `test*`/`trial_*`）→ 迁移成本≈0，将来做邮箱验证/找回密码不用再迁 |
| 那 5 个死列 | 保留 / **一并删除** | **删** | 留着会成为「语义残留」，后续开发会不断把实名相关的代码加回来 |

---

## 三、影响面（**扫全**，这次不按印象列）

### 后端（13 个文件）

| 文件 | 改动 |
|---|---|
| `schema.rs` | users 建表删 5 列 + 加 `email`；**删 `idx_users_phone_hash`**；迁移段加「条件删列 + email 列 + email 唯一索引」；+`drop_column_if_exists`；测试断言加**反向断言** |
| `auth.rs` | `RegisterRequest`/`LoginRequest`/`AuthResponse` 字段改 email；`register` 改邮箱校验与唯一性；`login` **删手机号分支**、改按 email 查；+`is_valid_email` / `default_display_name`（`pub(crate)`） |
| `trial_handler.rs` | `ClaimRequest` 改 email；删手机号唯一校验；**推广关系判据换掉**；UPDATE 改「只设 email/密码，不动 username」 |
| `routes.rs` | `AuthInput` 改 email；`auth_verify` 返回 email；profile 接口去掉实名/手机、加 email；**删 2 条路由**（`PUT /api/user/{id}/profile`、`POST /api/user/bind-lookup`） |
| `admin_handlers.rs` | 用户列表/详情/搜索/导出改 email；**删 `bind_lookup_handler` + `update_user_profile_handler` + `admin_reveal_phone`**；+`mask_email`（`pub(crate)`） |
| `campaign_executor.rs` | **奖励发放判据换掉**；测试辅助函数与用例改名并改判据 |
| `distribution_handler.rs` | 5 处分销列表/CSV 的 `real_name`+`phone` → `email`（**索引整体前移**）；删本地 `mask_email`，改用 `admin_handlers` 的 |
| `share_data.rs` | 删 `real_name` 字段与「AES 解密」段 |
| `poster_template.rs` / `h5_template.rs` | 删 `real_name` 字段；**保留 `{real_name}` 占位符的替换**（值降级为昵称） |
| `referral_handler.rs` | 删 `real_name` 构造 |
| `encryption.rs` | **删 `bind_hash` 函数 + 2 个测试**（死代码） |
| `backend/src/main.rs` | 🔴 **删 6 条会「把列加回来」的迁移**（见 §5.1） |
| 🆕 `examples/migrate_probe.rs` | 迁移演练工具（部署前拿生产副本验） |

### 前端（6 个文件）

| 文件 | 改动 |
|---|---|
| `utils/validators.dart` | +`email`；删 `username`/`realName`/`phone`/`idNumber` |
| `api/auth_client.dart` | `register`/`login`/`trialClaim` 参数改 email |
| `providers/auth_provider.dart` | `AuthState.realName` → `email` + `isRegistered` getter；`register`/`login`/`trialClaim` 改 email；`trialClaim` **加未登录前置检查**；删 `isTrialAccount` |
| `widgets/claim_dialog.dart` | 字段改「邮箱 + 密码」（删姓名/手机号）；**注册分流**（见 §4） |
| `screens/home_screen.dart` | `auth.realName` → `auth.isRegistered`（2 处） |
| `screens/profile_screen.dart` | 「绑定邮箱」→ **显示已绑定邮箱**；`isTrialAccount` → `isRegistered` |

---

## 四、🔴 顺带修掉两个真问题

### 4.1 未登录点「注册」→ 用户看到一句英文机器话

**根因**：`ClaimDialog` 的注册分支调 `trialClaim`，而它内部用 `state.userId!` / `state.token!`——
未登录时是 `null` → 抛 `Null check operator used on a null value`，
而 `_friendlyError` **映射不到**这种字符串 → 原样透传给用户。

**它为什么会变得可达**：2026-09-29 上一轮把「登录入口接回『我的』页」时，
未登录用户首次能打开这个弹窗了（此前只在「已登录但无姓名」分支打开，`userId` 必然有值）。

**修法（不是打补丁，是换对接口）**：

| 场景 | 走哪 | 语义 |
|---|---|---|
| **未登录** | `register`（`/api/auth/register`） | **新建**一个账号 |
| **已登录的匿名试用账号** | `trialClaim`（`/api/trial/claim`） | **认领/升级**这个账号（保留已有学习记录） |

🔑 两者语义本就不同 —— 原来混用是**接口选错了**，不是参数写错了。
🔑 附带收益：`/api/auth/register` 从「零消费者」变回真实入口。
🛡 双保险：`authProvider.trialClaim` 内部也加了显式前置检查（万一将来有人从别处调它）。

### 4.2 两处「真实用户」判据会静默失效

| 位置 | 原判据 | 后果（若不改） |
|---|---|---|
| `trial_handler.claim` | `real_name.is_some() && phone.is_some()` | **推荐关系永远不记录** |
| `campaign_executor` 奖励发放 | `real_name IS NOT NULL AND phone_hash IS NOT NULL` | **奖励永远不发放** |

两者都是「**用代理指标（填了实名+手机号）判断用户真实性**」。
去掉那两个字段后条件恒为 false → **静默失效，不报错**（分销数据全空，没人会发现）。

**✅ 换成 `email IS NOT NULL`** —— 更直接，且**不是放宽**：
唯一可靠的「真实用户」标志就是**注册完成**（`claim`/`register` 会给账号写入 email）；
匿名试用账号的 email 仍为 NULL → 依然被挡在外面，**原意图不变**。

> 📄 判据：「**删一个元素前，先查它还承担什么职责**」——
> `real_name`/`phone` 除显示外，还兼任「判定用户是否真实」的开关。

---

## 五、DB 迁移（🔴 部署时会自动执行）

### 5.1 两处「还会把列加回来」的地方（**差点漏掉**）

`CREATE TABLE IF NOT EXISTS` 对**已存在的库完全无效** —— 所以「改 schema」存在两条路径：

| 库 | 谁生效 |
|---|---|
| 全新库 | `schema.rs` 的建表语句 |
| **已存在的库**（本地 + 生产 91 行） | **`run_migrations_inner` 的迁移段** |

🔴 **`backend/src/main.rs` 里还有第二份迁移列表**，含
`ALTER TABLE users ADD COLUMN real_name/phone/id_number/bind_hash`
—— 它跑在 `init_database` **之后** ⇒ **前脚删掉、后脚加回来**。
本轮删掉了那 4 条 + 2 条 `phone_hash` 相关（`UPDATE` 去重 + 建索引）。

> 📄 判据：「删数据」**≠**「让它不再产生」—— 建表语句与**迁移列表**都要一起清。

### 5.2 顺序陷阱：先删索引，再删列

SQLite 规定「**列被索引引用时不可 DROP**」，而 `idx_users_phone_hash` 正引用 `phone_hash`。
⇒ 迁移里先 `DROP INDEX idx_users_phone_hash`，再删列。
（新建索引的那一行也已从 `init_database` 移除 —— 否则新库会因「列不存在」而启动失败。）

### 5.3 🔑 为什么用「条件删列」而不是「吞 `no such column`」

若写成 `ALTER TABLE ... DROP COLUMN x` + 把 `no such column` 加进容错白名单，
它会**连「列名拼错」一起吞掉**（写错一个字母 → 静默跳过 → 以为删成功了）。
⇒ 改为 `drop_column_if_exists()`：先查 `PRAGMA table_info`，列存在才删。
**幂等，且拼错会炸。**
> 📄 判据：**容错必须在「真的已经改过」时才放行。**

### 5.4 ✅ 迁移演练（真实 91 行库的副本）

```bash
cd backend
cargo run --example migrate_probe -- <副本路径>
```

| 项 | 迁移前 → 后 |
|---|---|
| users 列数 | 17 → **13** |
| 5 个已删列 | **全部消失** ✅ |
| `email` 列 | **已加** ✅ |
| users 行数 | 91 → **91**（**数据无损**）✅ |
| 索引 | `idx_users_phone_hash` → **`idx_users_email`** ✅ |
| 外键引用 users 处 | 12 → **12**（完好）✅ |
| `PRAGMA integrity_check` | **ok** ✅ |
| 幂等（再跑一次） | **通过** ✅ |
| 新增表 | `generated_card_cache`/`generated_card_hit` —— 本地库落后于代码的**预期补齐**，非本次引入 |

> ⚠️ 做副本时**必须用 SQLite backup API**（或带上 `-wal`），
> 不能只 `cp` 主库文件；也**必须统一用同一绝对路径** ——
> 否则会在「另一个文件」上演练，得出假结论（本轮实际踩过，见 §7）。
> 🔑 生产库的迁移在**部署后首次启动**时自动执行（`db_pool::init` 无条件调 `init_database`）。

---

## 六、验证汇总

| 项 | 结果 |
|---|---|
| `cargo check --workspace` | ✅ 0 error |
| `cargo test --workspace` | ✅ **api_server 85 passed** · chat_engine 20 passed · 0 failed |
| 其中新增/重写的用例 | 迁移演练（旧结构→新结构+数据保留+幂等）· 邮箱注册/登录 · **大小写不敏感唯一性** · 邮箱格式边界（正反）· 默认昵称 · **手机号登录已失效** · 奖励只发已注册账号 |
| 迁移演练（真实库副本） | ✅ 见 §5.4 |
| 前端 `verify_resolution` | ✅ 85 文件 · 1 error + 1 warning **均为既有**（→ 我的改动 0） |
| `verify_auth_entry.dart` | ✅ **40 / 40**（含本轮新增的邮箱/分流/防回归断言） |
| 真机 | ⏳ **待白哥** |

---

## 七、⚠️ 本轮踩到的坑（如实记录）

### 7.1 演练时「迁移没生效」是我把路径搞混了，不是迁移坏了

现象：副本跑完迁移后，5 列还在、`email` 没加 —— 看起来迁移**完全没生效**。

🔴 **真因**：Git Bash 的 `/tmp` = `C:\Users\...\AppData\Local\Temp`，
而 **Windows 版 Python 把 `/tmp/...` 解析成 `E:\tmp\...`**
⇒ 建副本（Python）与跑迁移（`cygpath` 转出的路径）操作的是**两个不同文件**。

🔑 判据：**跨工具（bash / Python / Rust）传路径时，只用全绝对路径**，不要用 `/tmp` 这类 shell 别名。
🔑 附带教训：`sqlite3.connect()` 对不存在的路径**静默建空库** →
「路径写错」会伪装成「表不存在」（本轮第一次检查就撞上了）。

⚠️ 我当时的第一个推断是「WAL 模式导致 `cp` 丢数据」—— **那是错的**，
而且我没有先验证就写进了结论。**假说必须先验证再采信。**

### 7.2 「编译通过」在这里几乎没有证明力

`cargo check` 通过**不代表**后端是好的 —— 那 18 处 `SELECT real_name FROM users`
是**字符串**，编译器看不见。删列后它们会在**运行时**才报 `no such column`。
⇒ 本轮靠 **grep 扫全 + `cargo test` + 副本演练**三层兜住，不靠编译器。

（同族：`cargo check` **不编译 `#[cfg(test)]`** → 测试代码里的旧字段名，
只有 `cargo test` 才报得出来 —— 本轮确实这样抓到 2 处漏改。）

---

## 八、遗留 / 待办

| 项 | 说明 |
|---|---|
| 🔴 **未部署** | 按铁律，需白哥明确指示。部署后首次启动会**自动迁移生产库** |
| 邮箱验证 / 找回密码 | 属**登录页批次**（与 `sign_in_with_apple` 同批）。当前邮箱只做登录标识，**不可修改** |
| 修改邮箱 | 后端无端点；「我的」页那行点了提示「即将开放」 |
| `admin_users` 表的 `real_name`/`phone` | **保留** —— 那是**管理端账号**（内部人员），与用户实名无关 |
| `main.rs` 与 `schema.rs` 两份迁移列表 | 本轮只清了涉及已删列的 6 条；**整体合并**属另一清理（`main.rs` 自己也写着「改 schema 请去 schema.rs」） |
| 存量 91 行账号 | 无邮箱 → 无法用邮箱登录。**有意**：那是内测/测试账号，生产零真实用户 |

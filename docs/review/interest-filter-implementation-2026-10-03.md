# 兴趣筛选：后端多值 + 前端界面（2026-10-03）

> **白哥指示**：「① `trace-verify` 绿 ② 改 ③ 先做界面，空类显示 ④ 下拉刷新、分页正常」
>
> **本轮产出**：后端 `category` 多值支持 · 前端兴趣筛选界面 · `verify_feed_wiring` 修复并进 CI
> **⏳ 未部署 / 未出包**（部署需单独指令；且**部署顺序有硬约束**，见 §六）

---

## 一、白哥四条的回执

| # | 指示 | 处理 |
|---|---|---|
| 1 | `trace-verify` 绿 | ✅ 收到 —— 我本机验不了的 Dart 代码在官方 Flutter 下通过了 |
| 2 | 「改」 | ✅ 已改：`fsrs-verify` 的 `sdk: stable` → **`3.11.0`**（与另两个 job 一致）|
| 3 | 先做界面，空类显示 | ✅ 已实施（§四）·「空类显示」= **12 类全显示** + **勾了空类有解释与出口** |
| 4 | 下拉刷新、分页正常 | ✅ 收到 —— 上一轮的改动**在真机上验证通过** |

---

## 二、🔴 做界面时**必须先解决**的前提：后端只支持单值

动手前先核实现状（不凭记忆），发现**硬约束**：

```rust
// content_handler.rs（改前）
let category: Option<&str> = q.category.as_deref().filter(|c| !c.trim().is_empty());
WHERE (?1 IS NULL OR p.category = ?1)      // ← 单值相等
```

而白哥定的语义是**筛选**（勾 N 类 ⇒ 只显示这 N 类）⇒ **必须支持多值**。

### 为什么不能在前端「多次请求再合并」

| 方案 | 问题 |
|---|---|
| 前端每类发一次请求再合并 | 🔴 **排序与分页会错** —— 后端按 `published_at DESC` 返回，客户端合并后要重排，但 `loadMore` 时新取的条目可能插到已显示列表**中间** ⇒ 表现为「上拉加载后列表顺序乱」 |
| `total` 累加 | 这个可行（category 互斥，无重叠），但解决不了排序 |
| **后端支持 `IN`** ⭐ | 排序/分页/`total` **全部原生正确**，一次请求 |

⇒ 结论：**多选筛选必须有后端配合**，没有干净的前端替代方案。

### 实现（照 `parse_ids` 的安全模式，但用**改动面更小**的方案）

```sql
-- 单参数 + INSTR（逗号包裹 = 精确成员判定）
WHERE (?1 IS NULL OR INSTR(?1, ',' || p.category || ',') > 0)
```

| 决策 | 理由 |
|---|---|
| **单参数**而非 `IN (?,?,?)` 动态占位符 | SQL 结构**完全不变** ⇒ 参数个数/顺序不变 ⇒ 不必靠断言守「占位符数 == 参数数」。⚠️ 代价：用不上索引（当前 990 行，毫秒级）—— **已写下触发条件**：规模上来换 `IN` + 加索引 |
| **逗号包裹** (`',tech,'`) | 直接 `INSTR('tech,science', cat)` 会**误匹配** `technology` |
| **白名单过滤**（`CONTENT_CATEGORIES`） | 拼进参数的值**只能来自代码常量** ⇒ 无注入面（与 `parse_ids` 同约定）|
| 🔴 **区分「没传」与「全非法」** | 没传 → `None` → **不筛**；全非法 → `Some(",")` → **空结果**。⚠️ 若把后者归成 `None`，就变成「用户传了筛选条件却拿到未筛选的全部」= **静默行为反转** |

**🔴 第二处必须同步**：`total` 的 `COUNT(*)` 用了**同一个筛选条件** —— 不同步的话 `total` 与 `items` 对不上 ⇒ 端侧 `hasMore`（`fetched < total`）**永远为真** ⇒ 无限上拉、每次白请求。（已改，并在注释里锁死理由。）

---

## 三、清障：`verify_feed_wiring` 修 3 项红 + 进 CI

### 3.1 🔴 发现：它**已经红了 3 项**，没人知道

因为它**不在 CI 里**。3 项里 **2 项是我上一轮改动的回归**：

| 红项 | 根因 | 性质 |
|---|---|---|
| 【1】断言写死 `feedProvider('')` | 我把硬编码提成了常量 `_kFeedCategory` | **我上轮的回归** |
| 【7】断言找 `int? score`/`comments` | HN 弃用 ⇒ 字段已删（端侧+后端都删了）| **断言过时** |
| 【8】断言写死 `FutureProvider.family` | 我改成了 `AsyncNotifierProvider.family` | **我上轮的回归** |

### 3.2 🔑 共同病根与修法：**锁语义形状，不锁标识符拼写**

脚本自己的注释早就点出「只匹配裸名字 ⇒ 假绿」，但那只是**一半**：
- 写太松 ⇒ **假绿**（换 mock 也不红）
- 写太死 ⇒ **假红**（纯重构就红）—— 🔴 **危害不只是误报**：一条「合理改动就报警」的断言**会训练人忽略红灯**，真回归来了也一起被忽略。

| 处 | 改法 |
|---|---|
| 【1】 | 正则 `ref\.watch\(\s*feedProvider\([^)]*\)\s*\)\s*\.when\(` —— 锁形状，参数名不限 |
| 【7】 | **翻成反向断言**：模型**已删** `score`/`comments`（删功能要清语义残留 + 防回退）|
| 【8】 | **截出 `feedProvider` 自己的声明块** + 反向断言「块内无 `autoDispose`」（「不该有的不存在」对实现更换**天然免疫**）|

⚠️ 一处**我自己先写错**的断言：我加了「注释里保留兼容说明」—— 但该脚本用 `readNoComment(...)`（**剥注释再断言**），所以**必然找不到**。那不是实现错，是**我的断言方法错了**（断言锁行为，不锁注释文本）⇒ 删掉。

### 3.3 进 CI

它是 `query_verify` 里**唯一**能进 CI 的（只 `import dart:io` + 只读源码；**不需要 `pub get`** —— 已在干净检出下实测）。同目录其他 ~19 个要连**真库** ⇒ 不能进。

---

## 四、前端实施

| 文件 | 内容 |
|---|---|
| 🆕 `app/lib/services/interest_selection.dart` | 选择集合（**零 import 纯 Dart** · 可本地验证）|
| 🆕 `app/lib/providers/interest_provider.dart` | Riverpod 接线 + `SharedPreferences` 持久化 |
| `app/lib/models/feed_item.dart` | `_categoryLabels` → **`kCategoryLabels`**（公开，供兴趣界面复用）|
| `app/lib/screens/profile_screen.dart` | 新增「**内容偏好**」分组 + 12 个 pill |
| `app/lib/screens/home_screen.dart` | `feedProvider` 接上兴趣 key + 空状态分两态 |
| `docs/design/profile-redesign-2026-09-29.html` | 🔴 修正语义矛盾（见 §五）|
| `scripts/trace_verify/bin/verify_interest_selection.dart` | 🆕 38 项断言 |

### 4.1 `InterestSelection` 的唯一职责：**同一集合 ⇒ 同一 key**

这是本环节唯一会**静默出错**的地方：

`feedProvider` 是 `family`，**参数参与相等性比较**：
- 传 `Set` ⇒ `==` 是引用比较 ⇒ 每次新实例都重新请求（同 `feedByIdsProvider` 踩过的坑）
- 传 `'tech,science'` ⇒ 值相等 ✅ 但**顺序必须确定**：`'tech,science'` 与 `'science,tech'` 是**两个 key** ⇒ 「先勾 A 再勾 B」与「先勾 B 再勾 A」**各发一次请求**，且旧实例不复用 —— **不报错**

⇒ 所以 **`..sort()` 不是优化，是正确性要求**。

### 4.2 空集 = 「全部」（与 `feedProvider('')` 天然衔接）

`normalizedKey` 空串 ⇒ 与「全部」**同一个 key** —— 语义上正好正确：**没选兴趣 = 不筛 = 全部**。

### 4.3 「空类显示」的两半

| 半 | 实现 |
|---|---|
| 界面**不隐藏**任何类 | 12 个 pill 全部渲染（不置灰、不隐藏）⇒ 用户能**发现**这个类存在 |
| 勾了空类**有解释** | 信息流空状态分两态：**没筛为空**（「还没有内容」，不给按钮）/ **筛选后为空**（「这一类还没有内容」+ **「查看全部」出口**）|

⚠️ **已知取舍**：**暂未标注「哪几类是空的」** —— 那需要每类的条数，而当前后端**没有**分类计数接口。不为这个标注新增接口（本轮的克制），勾了之后由空状态兜住。

### 4.4 显示名复用 `kCategoryLabels`（不新建第二份中文映射）

界面锚点画的 pill 是中文（科技/环境/…）且含我们**没有**的「环境」——
那是 2026-09-29 的示意值。🔑 真实显示名以 `kCategoryLabels` 为准（**与卡片元信息行同一个映射**）——
两个口径必然漂移，而 `verify_feed_wiring` 的【9】组断言正是为防这个而存在。

### 4.5 「全部」出口（筛选语义的必要组成）

选「筛选」就必须回答「**用户怎么回到全部**」：
- 一个都不勾 = 全部
- 有勾选时右上角出现「**清除**」
- 空状态给「**查看全部**」

📌 判据：没有出口的筛选，用户会以为「App 里就只有这一类的文章」。

---

## 五、🔴 修正一处语义矛盾（锚点 vs 定案）

界面锚点 `profile-redesign-2026-09-29.html` 写的是：

> 🎯 兴趣筛选 · **决定信息流的内容权重**

「**权重**」= 排序语义，与白哥 2026-10-03 定的「**筛选**」**矛盾**。
⇒ 已改为「决定信息流**显示哪些类别**」，并给 pills 块加注（示意值过时 + 显示名口径 + 语义）。
⇒ 同时把示意 pills 从（科技/环境/商业/文化/体育）换成真实显示名（News/Tech/Business/Science/Sports）。

📌 依据：「**撤回/修正已定案 = 一组动作**」（实现 / 锚点 / spec / 断言 / 设计稿要一起改）。

---

## 六、⏳🔴 部署顺序（**硬约束**，必须先看这条）

```
① 先部署后端（v0.1.4）  ← 支持 category 多值
② 再出 App 包           ← 多选筛选才可用
```

**顺序错会怎样**（不夸大，但要说清）：
- 旧后端收到 `category=tech,science` ⇒ `p.category = 'tech,science'` ⇒ **永不匹配** ⇒ **空列表**
- ⚠️ **不是白屏**：新做的空状态会说「这一类还没有内容」+ 给「查看全部」出口
- ⇒ 表现为「筛选功能不生效（永远空）」，**不会**崩，也不会脏数据

⇒ 单独出 App 包（后端未部署）**不会有破坏性后果**，但多选筛选会一直空。**建议后端先上。**

---

## 七、验证（逐层如实）

| # | 验证项 | 结果 |
|---|---|---|
| ① | 后端「**没传 ≠ 全非法**」等 5 组单测 | ✅ **11 passed**（content_handler）|
| ② | **SQL 语义独立验证**（Python + sqlite3，不靠推理） | ✅ 单值≡旧行为 · 多值=并集 · **不误匹配 `technology`** · NULL 被过滤 · 空集⇒0 行 |
| ③ | 后端全量测试 | ✅ **176 passed / 0 failed** |
| ④ | `fmt --check` / `clippy --workspace --all-targets -D warnings` | ✅（clippy 抓到我 1 个 error，已修）|
| ⑤ | 纯 Dart 断言 | ✅ `interest_selection` **38 项** · `feed_pager` 54 · `unescape` 71 · `trace_markdown` 43 = **206 项** |
| ⑥ | 接线断言 | ✅ `verify_feed_wiring` **59 项**（修完 3 项红后）|
| ⑦ | **证伪**（见 §八）| ✅ |
| ⑧ | 接线自证（防「写了没人用」） | ✅ 7 个符号全部「有定义也有调用」|
| ⑨ | 五个改动文件语法解析 | ✅ 5/5 |
| ⑩ | 🔴 **UI 接线 / 视觉** | ❌ **本机无法验证**（见 §九）|

---

## 八、证伪（**门禁不是装饰的唯一凭据**）

| # | 注入的回归 | 期望 | 结果 |
|---|---|---|---|
| 1 | `home_screen` 去掉 `.when(` | 红 | ✅ rc=1 |
| 2 | 模型加回 `int? score` | 红 | ✅ rc=1 |
| 3 | `feedProvider` 加 `autoDispose` | 红 | ✅ rc=1 |
| 4 | **常量改名 `_kFeedCategory`→`_kFeedCat`（纯重构）** | **绿** | ✅ rc=0 —— **证明「不锁拼写」成立** |
| 5 | `InterestSelection` 去掉 `..sort()` | 红 | ✅ rc=1（8 项失败）|
| 6 | `InterestSelection` 的 `==` 改引用比较 | 红 | ✅ rc=254（编译错）|

- 全部注入**字节级还原**，收尾 `git show HEAD:` 比对三份被测源码**逐字节一致** ✅

### 🐛 证伪过程中我自己踩的坑（如实记录）

**误报「未还原」** —— 证伪 1 报「字节级还原: 🔴 未还原」，差点让我以为污染了源码。真因是：我用 `io.open(...).write(...)` 写入后**没有 `close()`** ⇒ **缓冲未 flush** ⇒ 紧接着的 `md5()` 读到**旧内容**。

- ✅ 修法：`with io.open(...) as f:`（保证 flush）
- 📌 教训：**「工具/写法错 → 静默给出错误结论」** —— 与 `heredoc` 吃反斜杠同族。**差点据此误判「我污染了仓库」**（实际三份源码一直与 HEAD 一致）。

---

## 九、🔴 本机无法验证的部分（需白哥）

**本机 Flutter 崩**（鸿蒙定制版 SDK，`CreateFile 231`）⇒ 以下**本机一律验不了**：

| 项 | 说明 |
|---|---|
| `home_screen` / `profile_screen` 的**编译** | 需 `flutter analyze`（CI 会跑，官方 3.41.1）|
| **视觉**：12 个 pill 的布局/换行/对比度 | 需真机看 |
| **交互**：点 pill → 列表是否立刻变 | 需真机 |
| 持久化：杀 App 重开是否记住选择 | 需真机 |
| 「清除」/「查看全部」是否真的回到全部 | 需真机 |

**建议验证步骤**：
```bash
cd /e/CoEvo/app
flutter analyze --no-fatal-infos
flutter build apk --release \
  --dart-define=API_HOST=api.keyievolution.fun --target-platform android-arm64
```

**重点看 6 件事**：
1. 「我的」页出现「内容偏好」分组，12 个 pill 都在
2. 勾一个 → 回信息流 → **只剩该类**
3. 勾一个**空类**（如 `family`）→ 信息流显示「这一类还没有内容」+「查看全部」
4. 点「查看全部」→ 回到全部
5. 「清除」→ 回到全部
6. 杀 App 重开 → 选择仍在

---

## 十、⏳ 待办 / 已知取舍

| # | 事项 |
|---|---|
| 1 | 🔴 **部署顺序**：后端先（§六）|
| 2 | **取舍**：已设兴趣的用户首帧会以「全部」发一次请求，prefs 就绪后切 key ⇒ **可能多发一次请求**。彻底消除需在 `main()` 预载 prefs 并 override（动启动路径，本轮**未做**）|
| 3 | **取舍**：切回已看过的分类**不会自动刷新**（provider 有缓存）—— 符合项目「不 autoDispose」的既有决策 |
| 4 | **未做**：标注「哪几类是空的」（需分类计数接口）|
| 5 | **未做**：供给不足（8/12 类近 7 天 <13 条）—— 属内容侧，与本轮 UI 解耦 |
| 6 | `fsrs-verify` 的 sdk 已改 ✅（本轮）|

---

## 十一、产出物

| 文件 | 说明 |
|---|---|
| `backend/crates/api_server/src/content_handler.rs` | `parse_categories` + SQL 两处（items/total）+ 5 组单测 |
| 🆕 `app/lib/services/interest_selection.dart` | 零 import 纯 Dart（38 项断言）|
| 🆕 `app/lib/providers/interest_provider.dart` | Riverpod + SharedPreferences |
| 🆕 `scripts/trace_verify/bin/verify_interest_selection.dart` | 断言脚本（已进 CI）|
| `app/lib/screens/profile_screen.dart` | 「内容偏好」分组 + pill |
| `app/lib/screens/home_screen.dart` | 接线 + 空状态两态 |
| `app/lib/models/feed_item.dart` | `kCategoryLabels` 公开 |
| `scripts/query_verify/bin/verify_feed_wiring.dart` | 修 3 项红（锁语义不锁拼写）|
| `.github/workflows/ci.yml` | `fsrs-verify` sdk 钉版本 · `trace-verify` 加 2 个脚本（68→206 项）|
| `docs/design/profile-redesign-2026-09-29.html` | 修正「权重」语义矛盾 + pills 加注 |

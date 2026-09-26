# FSRS 调度验收（`scripts/fsrs_verify/`）

## 三个脚本的分工

| 文件 | 验证什么 | 断言数 |
|---|---|---|
| `bin/verify.dart` | **fsrs 包本身** —— 四档单调 / elapsed / UTC / R 值 | 19 |
| `bin/verify_service.dart` | **我们自己的 `FsrsService`**（直接相对导入 `app/lib/services/fsrs_service.dart`）—— 预览==提交 / 重放 / 同日去重 / 多端合并 / 序列化 | 39 |
| `bin/debug_replay.dart` | **排查工具**（非断言）—— 逐步打印 `state / step / stability / due`，用于看清卡在哪个状态 | — |

## 怎么跑

```bash
cd scripts/fsrs_verify
dart pub get
dart run bin/verify.dart          # 验证包
dart run bin/verify_service.dart  # 验证服务层 ★ 主要看这个
dart run bin/debug_replay.dart    # 排查用
```

- **纯 Dart，零 Flutter 依赖** —— 本地 Flutter 是鸿蒙定制版、`analyze` 会因 Windows 管道耗尽崩溃，
  所以这些脚本刻意不依赖 Flutter，任何装了 Dart 的机器都能跑
- **退出码 0 = 通过；1 = 有断言失败** —— 可直接挂进 CI
- ⚠️ 需 `fsrs: ^2.0.1`（pub.dev），**只拉 2 个依赖**（对比官方 Rust crate 的 474 个）
- 🔑 `verify_service.dart` 用**相对路径直接 import app 的源码** → 验证的是**实际要发布的实现**，不是副本

## 为什么存在

2026-09-26 审计（`docs/design/fsrs-rating-and-scheduler-audit-2026-09-26.md`）发现后端自研
`backend/crates/card_engine/src/fsrs5.rs` 有两处严重错误：

| bug | 实测表现 |
|---|---|
| 公式拿 **rating** 冒充 **retrievability** | **四档单调性全反** —— 「熟练」比「一般」更早重来 |
| **`elapsed_days` 被忽略** | 间隔与「距上次多久」**完全无关**（0 天与 365 天结果一样） |

**这两个 bug 能存在，直接原因就是：没有任何测试断言过「四档单调」。**
→ 白哥 2026-09-26 决策：**四档单调性单测作为强制项**。

## 验收项（`verify_service.dart` 39 项）

| # | 断言 | 防的是什么 |
|---|---|---|
| 1 | **四档严格单调**（新卡 + 熟卡） | 🔴 审计 bug 1 —— 服务层不得破坏 fsrs 的行为 |
| 2 | ★ **预览 == 提交**（四档逐个比对秒数） | 自建确定性抖动替代 fsrs fuzz 的**唯一理由** |
| 3 | **确定性抖动**：同卡两次预览相同、异卡不同 | 抖动不能有随机性（否则预览与提交分叉） |
| 4 | **`maximumInterval` = 365 天**（连评 12 次「熟练」） | 「5.8 年后再见」 |
| 5 | **elapsed 敏感性**（1 天 ≠ 365 天） | 🔴 审计 bug 2 |
| 6 | **「忘了」< 1 天** + 进 relearning + lapses+1 | 防 `learningSteps=[]` |
| 7 | **非 UTC → `ArgumentError`** | fsrs 包只支持 UTC，线上会崩 |
| 8 | ★ **重放 + 同日去重**（reps/stability/due 三项都不同） | 白哥定的「同日只保留最后一次」 |
| 8b | **learning 阶段 due 与 stability 无关** | 见下方教训 —— 写断言的前提知识 |
| 9 | **重放幂等**（重放两次结果一致） | 多端重复拉取 |
| 10 | **多端合并幂等** | 同上 |
| 11 | **落库往返**（含「往返后仍是 UTC」） | 时间序列化踩坑 |
| 12 | **四档译名**（`Good` 译「记得」非「一般」）+ 英文副标题保留 | 白哥定案 |
| 13 | **R 值**：刚复习完 ≈1；距 = S 天 ≈ 0.9；未学 = 0 | 遗忘曲线接对 |

## ⚠️ 两个真实教训（都是「断言写错」，不是实现错）

### 教训 1：基准值必须与待测值由同一机制产生

第一版断言 #3 写「同日第 4 次 < **第 1 次** × 10」→ **失败**。看数据才发现是断言错了：

```
第1次=10 分钟  第2次=4 天  第3次=4 天  第4次=4 天     ← 稳定，不暴涨
```

**第 1 次是 `learningStep` 的固定短间隔，不能当"增长"的基准。** 正确基准是第 2 次。
更正后断言改为「第 4 次 ≤ 第 2 次 × 2」且「第 3、4 次 ≤ 第 2 次」。

### 教训 2：在 learning 状态比较 `due` 无法反映 FSRS 状态差异

第一版断言 #8 写「同日去重后 `nextReviewAt` ≠ 不去重」→ **失败**（两边都是「3 天」）。
跑 `debug_replay.dart` 才看清：

```
初始        state=0 step=0    S=null    due=09-01T09:00
again@+5h   state=1 step=0    S=0.217   due=09-01T14:01   ← learning，间隔 = learningStep
good@09-04  state=1 step=1    S=2.102   due=09-04T09:10   ← 仍在 learning！间隔 = 10 分钟
good@09-06  state=2 step=null S=5.789   due=09-12         ← 这里才毕业
```

**卡还停在 learning 时，`due` 由固定的 learningStep 决定，与 `stability` 无关**
→ 此时比 `due` 当然相同。

**修法**：① 测试数据拉长到卡片毕业（再多几次 good）；② 补上比 `reps`、`stability` 的断言
（这两个在任何状态都能反映去重效果）。修正后三项全过：

```
reps  去重=4  不去重=5
S     去重=12.848  不去重=14.027
due   去重=09-23   不去重=09-24
```

**→ 并把这条事实固化为断言 8b**，避免下次又踩。

> **通用规则：断言失败时，先分清是「实现错」还是「断言错」。
> 判据是「数据本身是否自相矛盾」—— 若数据显示行为正确，就是断言选错了观测量或被观测对象不在预期状态。**
> 排查工具：`debug_replay.dart`。

## 与 App 的关系

`verify_service.dart` 里的 `previewAll()` 就是 App 里「按钮显示下次 X 天」用的**同一段逻辑**
（直接 import 同一份源码）：

```dart
final previews = svc.previewAll(state, nowUtc);   // {忘了: 10分钟, 困难: 21天, 记得: 1.5月, 熟练: 3.5月}
```

**依据**：fsrs 的 `reviewCard()` 内部先 `copyWith()` → **不改原卡** → 对 4 个评分各调一次即可预览，
**不需要额外的预测 API**。

## 相关文档

| 文档 | 内容 |
|---|---|
| `docs/design/fsrs-rating-and-scheduler-audit-2026-09-26.md` | 审计报告（bug 定位到行 + 8 项偏差 + 三个修复方案） |
| `docs/design/fsrs-client-side-migration-plan-2026-09-26.md` | 端侧迁移设计（同步方案 / 参数取值 / 单测清单 / 实施步骤 / §十一 实施偏差） |
| `app/lib/services/fsrs_service.dart` | 被验证的实现（纯 Dart，不 import Flutter） |
| `app/assets/sql/user_db_schema.sql` | 端侧 `user.db` 表结构（已用 sqlite3 实测建表 + 约束） |
| `docs/design/visual-word-card-target-2026-09-26.html` | L1 界面锚点（v6：按钮显示「下次 X 天」+ 复习列表页） |


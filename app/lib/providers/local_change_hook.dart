// CoEvo · 「本地数据变更」的**外部钩子** —— 让写端不必知道「同步」这件事。
//
// 🔴 设计约束：**本文件零 import**（纯 Dart）⇒ 谁都能安全 import 它。
//
// # 为什么单独一个文件（而不是塞进 `user_db_provider` / `sync_provider`）
//
// 三方需要它，而**任意两方都不能互相 import**：
//   · **写端**：`user_db_provider`（user.db）· `book_provider`（book.db）
//   · **接收端**：`sync_provider` —— 它**已经 import 了**上面两个
//     （要用 `userDbRevisionProvider` / `bookDbRevisionProvider`）
// ⇒ 反向 import 会**成环**。
// ⇒ 钩子放本文件，依赖方向固定为「写端 → 本文件 ← sync_provider」**单向无环** ✅
//
// # 它解决什么（白哥 2026-10-11 问「同步的时机是什么时候」时暴露的缺口）
//
// 此前全仓**只有复习提交**调了 `scheduleSyncAfterChange()`
// （`screens/review_session_screen.dart:188`，全仓唯一调用点）⇒
// 下列本地写操作**都不会**触发自动同步，只能等「进后台 / 回前台 / 手动点云朵」：
//
//   **划线 · 写/改笔记 · 批量补译 · 查词入生词本 · 阅读进度 · 收藏 · 电子书**
//
// ⇒ 单设备用户「改了却一直没上云」；多设备来回切才**碰巧**补上
//   （切换 App 会触发「进后台」，那条路径恰好会推）。
//
// 🔑 **挂在 `bump()` 这一处，就覆盖了全部本地写操作** ——
//    因为本项目所有写端都必须 `bump()` 才能让界面刷新（既有铁律）。
//    📌 判据：**「一处覆盖全部」胜过「每个调用点各加一行」** ——
//       后者必然漏一个，而**本缺口正是这么来的**。
//
// # ⚠️ 两条禁令
//
// ① **不要**给 `settingsRevisionProvider.bump()` 接这个钩子 ——
//    它按设计**只**服务「同步 pull 写回 prefs」那一条路径（见其文档注释），
//    接上会立刻形成「同步 → bump → 再同步」的**回环**。
// ② **同步期间**（`sync_provider` 的 `_syncDepth > 0`）钩子必须**不触发**同步 ——
//    `_runSync` 拉回数据后要 `bump()`（通知读端重算），若那条 bump 又安排同步，
//    就变成 `pull → bump → 4 秒后再同步 → pull → …` **每 4 秒一次请求，永不停**。
//    ✅ 该判断在接收端实现（`sync_provider.scheduleSyncAfterChange` 开头）。
//
// ⚠️ 由 `sync_provider.registerAppSyncRef()` 在 **App 启动时**注入
//    （`app.dart` 的 `initState` 调用它）；为 `null` 时（尚未注入 / 纯 Dart 单测）
//    **静默不做事** —— 不做「未注入就报错」：那会让单测与早启动路径无谓地挂。

/// 本地数据变更后的钩子（当前实现 = `sync_provider.scheduleSyncAfterChange`）。
///
/// 可变全局是**有意**的：它是跨模块的「延时回调引用」，
/// 与 `sync_provider._appLevelRef` 同族 —— 用一个长寿命的槽传递，避免循环 import。
void Function()? onLocalDataChanged;

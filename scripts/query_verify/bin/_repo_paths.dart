// 脚本用的**路径推导**（跨平台 · 唯一一处定义）
//
// # 🔴 为什么必须有这个文件（2026-10-05 的 CI 红）
//
// 有 5 个脚本把资源路径**写成了 Windows 绝对路径**：
// ```dart
// final dbPath = args.isNotEmpty ? args[0] : r'E:\CoEvo\data\word.db';
// ```
// 本机（Windows）跑得好好的 —— 而 **CI 在 `ubuntu-latest` 上跑**，
// `E:\CoEvo\...` 不存在 ⇒ 脚本以「找不到 word.db」退出码 **2** ⇒ **整个 job 红**。
//
// 📌 判据：**「本机绿」不是「CI 绿」** —— 路径、行尾、大小写敏感性、动态库
//    都是「同一份代码在不同平台上行为不同」的来源。
//    上一轮我把这 19 个脚本接进 CI 时，**本机全绿**就以为没问题了 ——
//    而其中 3 个的路径是**只在本机成立**的。⇒ 接 CI 的价值恰恰在于此（它替我发现了）。
//
// # ⚠️ 为什么**相对路径**也不行（这是个陷阱）
//
// 直觉上写 `data/word.db` 比绝对路径好 —— 但它相对 `Directory.current`，
// 而 CI 与本机跑脚本时 **cwd 都是包根**（`scripts/query_verify`）
// ⇒ 会指到 `scripts/query_verify/data/word.db`（**不存在**）。
// 也就是说：**相对路径在这件事上同样会红**，只是红得晚一点（本地也红，更容易发现）。
//
// # ✅ 正确做法：从脚本位置**向上找**仓库根
//
// 这也是本包既有的做法（`verify_pos_display` / `verify_spelling_grader` /
// `verify_worddb_sync` 各自带了一份 `_repoRoot()`）。
// 本文件把那 3 份**收敛成一处**——因为「同一件事的口径只能一处权威」，
// 而这次要改的脚本有 5 个，再复制 5 份只会让口径继续漂。
//
// 🔑 向上找的**依据不是「层数」而是「特征文件」**（`app/pubspec.yaml`）——
//    这样无论从包根、仓库根、还是别的 cwd 启动都能命中；
//    写死「向上 N 层」会在目录结构变化时静默失效。
library;

import 'dart:io';

/// 仓库根 —— 含 `app/pubspec.yaml` 的那一层。
///
/// 从 [Directory.current] 逐级向上找，最多 8 层（够深，且不会无限循环）。
/// 找不到时**回落到 `Directory.current`**（调用方会发现文件不存在并报错，
/// 而不是静默拿到一个错的路径）。
///
/// ⚠️ 判据：**向上找的判据必须是「特征文件」，不能是「层数」** ——
///    层数写死会在目录结构变化时静默失效（正是本项目记过的「估算迟早失手」）。
String repoRoot() {
  var d = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${d.path}${Platform.pathSeparator}app'
            '${Platform.pathSeparator}pubspec.yaml')
        .existsSync()) {
      return d.path;
    }
    final parent = d.parent;
    // 到根了（parent == self）⇒ 停，避免死循环
    if (parent.path == d.path) break;
    d = parent;
  }
  return Directory.current.path;
}

/// 把**仓库内相对路径**（用 `/` 分隔，如 `data/word.db`）解析成绝对路径。
///
/// 🔑 统一用 `/` 书写、内部转成 [Platform.pathSeparator] ——
///    这样调用方不必关心平台，也不会各自写 `\\` 或 `/` 而出错。
String repoPath(String relative) {
  final parts = relative.split('/');
  return [repoRoot(), ...parts].join(Platform.pathSeparator);
}

/// 词库：`data/word.db`（**已入库**，33 MB）。
String wordDbPath() => repoPath('data/word.db');

/// 端侧 `user.db` 的建表语句（**已入库**）。
///
/// 🔑 这是脚本自建临时库时的**唯一 schema 来源** ——
///    从它建库意味着「脚本验的就是 App 真用的那张表结构」，
///    而不是脚本里手抄的第二份（那会漂）。
String userDbSchemaPath() => repoPath('app/assets/sql/user_db_schema.sql');

/// 端侧 `book.db` 的建表语句（**已入库**）。
///
/// 🔑 与 [userDbSchemaPath] 同一个理由：脚本自建临时库时的**唯一 schema 来源**。
///    （2026-10-09 加：`local_data_owner` 的「清空清单」要**逐表**核对两个库，
///      手抄第二份表清单会漂。）
String bookDbSchemaPath() => repoPath('app/assets/sql/book_db_schema.sql');

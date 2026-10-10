// 云端同步 · 阶段 1（后端 push/pull）验收 —— 表结构 · 注销覆盖 · 鉴权与订阅 · 路由
//
// 跑：cd scripts/query_verify && dart run bin/verify_sync.dart
// 🔴 退出码：0 = 全过，1 = 有失败（用 `; echo $?` 直读，别接 `| tail` ——
//    管道会让 `$?` 取到 `tail` 的退出码 = 0）。
//
// # 为什么需要它（单测覆盖不到的那一层）
//
// `sync_handlers.rs` 的 `#[cfg(test)]` 跑的是 `push_changes` / `pull_changes`
// **核心逻辑**（幂等 / 合并口径 / 多用户隔离）。
// 但 **handler 层**（`sync_push` / `sync_pull`）需要 HTTP + 全局连接池 ⇒ **单测不了**：
//   · 鉴权是否真的做了（漏了 ⇒ 任何人能读别人数据）
//   · 订阅校验是否真的做了（漏了 ⇒ 决策③ 落空 = 免费同步）
//   · 未订阅是否回 **403**（回 401 会让端侧**把用户登出**）
// ⇒ 这些**只能靠源码断言**守。📌 判据：**盲区要配不依赖它的兜底判据**。
//
// # 🔴 证伪方式（每次改断言都该跑一遍）
//
// | 改这里 | 应变红的是 |
// |---|---|
// | `schema.rs` 某张 sync 表 PK 去掉 `user_id` | 「PK 含 user_id」 |
// | `user_purge.rs` 删掉一张 sync 表 | 「注销清单覆盖 5 张」 |
// | `sync_handlers.rs` 某个 handler 去掉鉴权调用 | 「两处都调」 |
// | `sync_handlers.rs` 把 `Forbidden` 改成 `Unauthorized` | 「未订阅回 403」 |
// | `routes.rs` 删掉一条 sync 路由 | 「路由已注册」 |
//
// # ⚠️ 口径（如实标注）
// · **先剥整行注释**（注释里会提到函数名 ⇒ 不剥则计数偏大 = 假绿）。
//   ⚠️ 只能按**整行**剥 —— 切 `//` 会把 `https://` 切掉（本项目已踩）。
// · Rust 文件**先切掉 `#[cfg(test)]`** —— 测试会调用 `push_changes` 等 ⇒ 不切则计数错。
// · 查标识符**必须有词边界**（本项目已踩三次「更长标识符以前缀/后缀命中」）。

import 'dart:io';

// 🆕 2026-10-10：`sync_status.dart` 是**纯 Dart · 零 import** ⇒ 本脚本可直接 import 它
// 做**行为断言**（而不是读源码字符串）。这正是该文件被刻意写成纯 Dart 的理由。
import '../../../app/lib/services/sync_status.dart';

int _pass = 0;
final _failures = <String>[];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $label${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _failures.add('$label  $detail');
    print('  🔴 $label${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

/// 剥掉**整行注释**（只剥整行 —— 理由见文件头）。
String stripComments(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// 只取**实现部分**（切掉 `#[cfg(test)]` 之后的测试代码）。
String implOnly(String src) {
  final i = src.indexOf('#[cfg(test)]');
  return i < 0 ? src : src.substring(0, i);
}

/// 取 [a] 与 [b] 之间的切片（找不到边界返回空串 —— **宁可空宁可红，不可静默全量**）。
String between(String src, String a, String b) {
  final i = src.indexOf(a);
  if (i < 0) return '';
  final j = src.indexOf(b, i + a.length);
  return j < 0 ? src.substring(i) : src.substring(i, j);
}

void section(String title) {
  print('');
  print('─' * 74);
  print(title);
  print('─' * 74);
}

String readFile(String p) {
  final f = File(p);
  return f.existsSync() ? f.readAsStringSync() : '';
}

/// 查「标识符以完整词出现」（防「更长标识符以它为前缀/后缀」命中）。
bool hasIdent(String src, String ident) =>
    RegExp('\\b${RegExp.escape(ident)}\\b').hasMatch(src);

int countOf(String src, String needle) =>
    RegExp(RegExp.escape(needle)).allMatches(src).length;

void main() {
  print('');
  print('#' * 74);
  print('# 云端同步 · 阶段 1（后端 push/pull）验收');
  print('#' * 74);

  final schemaRaw = readFile('../../backend/crates/api_server/src/schema.rs');
  final schema = stripComments(schemaRaw);
  final purge = implOnly(
      stripComments(readFile('../../backend/crates/api_server/src/user_purge.rs')));
  final sync = implOnly(
      stripComments(readFile('../../backend/crates/api_server/src/sync_handlers.rs')));
  final routes = implOnly(
      stripComments(readFile('../../backend/crates/api_server/src/routes.rs')));
  final err = stripComments(readFile('../../backend/crates/api_server/src/error.rs'));
  final lib = stripComments(readFile('../../backend/crates/api_server/src/lib.rs'));

  const tables = <String>[
    'sync_review_log',
    'sync_user_word',
    'sync_article_read',
    'sync_bookmark',
    // 🆕 2026-10-09：划线记忆。加进这份清单后，下面的「建表存在」「主键以 user_id 打头」
    //    「pull 索引」「注销清单」四组断言**自动**覆盖它（不必逐条复制）。
    'sync_highlight',
    'sync_book_progress',
    // ⚠️ `sync_book` 此前**漏登记**（2026-10-10 补）—— 它一直在同步、却没被这组断言覆盖
    //    （「PK 含 user_id」「注销清单」都没查它）。同一条判据：**清单漏一项 = 那一项无守护**。
    'sync_book',
    // 🆕 2026-10-10：同步覆盖面补齐（审计报告 §五）—— 同样靠清单**自动**覆盖四组断言。
    'sync_lookup_event',
    'sync_book_marker',
    'sync_achievement_unlock',
    'sync_setting',
  ];

  // ══════════════════════════════════════════════════════════════════
  print('\n[①] 服务端表结构（schema.rs）');
  // ══════════════════════════════════════════════════════════════════
  final syncSql = between(schema, 'pub const SYNC_SCHEMA_SQL', '"#;');
  for (final t in tables) {
    check('建表语句存在：$t',
        syncSql.contains('CREATE TABLE IF NOT EXISTS $t'), '');
  }
  check('🔴 `init_database` 里执行了 SYNC_SCHEMA_SQL',
      between(schema, 'fn init_database', 'fn run_migrations_inner')
          .contains('execute_batch(SYNC_SCHEMA_SQL)'));

  // 🔴 每张表的 PRIMARY KEY 都必须以 user_id 打头 —— 这是「多用户隔离」的**结构基础**。
  //    单测也已覆盖（`test_multi_user_isolation_and_pk_includes_user_id`），
  //    这里守的是「**将来有人改 DDL 时**」不会静默退化。
  for (final t in tables) {
    final ddl = between(syncSql, 'CREATE TABLE IF NOT EXISTS $t', ');');
    final pk = RegExp(r'PRIMARY KEY \(([^)]*)\)').firstMatch(ddl)?.group(1) ?? '';
    check('🔴 $t 的主键以 user_id 打头', pk.trimLeft().startsWith('user_id'),
        '实得 PRIMARY KEY ($pk)');
  }

  check('🔴 `received_at` 存在于各表（pull 的时间轴）',
      countOf(syncSql, 'received_at') >= tables.length + 5,
      '出现 ${countOf(syncSql, 'received_at')} 次');
  check('🔴 `device_id` 是 NOT NULL DEFAULT \'\'（NULL 会破坏主键幂等）',
      syncSql.contains("device_id   TEXT    NOT NULL DEFAULT ''"));
  check('`rating` 有 CHECK 1..4', syncSql.contains('CHECK (rating BETWEEN 1 AND 4)'));
  check('`deleted` 有 CHECK (0,1)', syncSql.contains('CHECK (deleted IN (0, 1))'));

  final exp = between(schema, 'const EXPECTED_TABLES', '];');
  for (final t in tables) {
    check('EXPECTED_TABLES 已登记 $t', exp.contains('"$t"'));
  }

  // ══════════════════════════════════════════════════════════════════
  print('\n[②] 注销时一并删除（隐私政策 §2.1 承诺）');
  // ══════════════════════════════════════════════════════════════════
  //
  // 🔴 为什么这条必须有：隐私政策已写明「注销账号时一并删除」——
  //    漏一张表就是**政策失实**（而且用户在设置里点了注销，数据却还在服务端）。
  final del = between(purge, 'pub const DELETE_TARGETS', '];');
  for (final t in tables) {
    check('🔴 注销清单含 $t', del.contains('("$t"'), '');
  }

  // ══════════════════════════════════════════════════════════════════
  print('\n[③] 鉴权 + 订阅校验（决策③ —— 单测覆盖不到，必须在这里守）');
  // ══════════════════════════════════════════════════════════════════
  check('🔴 「鉴权+订阅」只定义一处（`authorize_with_subscription`）',
      countOf(sync, 'fn authorize_with_subscription') == 1,
      '定义 ${countOf(sync, 'fn authorize_with_subscription')} 次');

  // 🔑 锁**实参**而非函数名 —— 判据「子串断言锁不到接线」
  //    （换成别的函数名仍会通过 ⇒ 必须锁「调用形态」本身）
  check('🔴 两个 handler 都调它（push + pull）',
      countOf(sync, 'authorize_with_subscription(&headers)?') == 2,
      '调了 ${countOf(sync, 'authorize_with_subscription(&headers)?')} 次');

  check('🔴 订阅判定用既有权威实现（subscription::is_subscription_active）',
      sync.contains('crate::subscription::is_subscription_active'));
  check('🔴 未订阅回 Forbidden（403），**不是** Unauthorized（401）',
      sync.contains('AppError::Forbidden'),
      '—— 401 会让端侧判断为「token 失效」而把用户登出');
  // 🔑 锁**未订阅那一支**（不是「整个函数不许出现 Unauthorized」）——
  //    `uid_by_token` 失败用 `Unauthorized` 是**正确的**（token 无效 = 认证失败）。
  //    ⚠️ 第一版断言写成了「整个函数不含 Unauthorized」⇒ **假红**。
  //    📌 判据：**断言的切片要正好框住「需满足该约束的那一段」**。
  final subBranch =
      between(sync, 'if !crate::subscription::is_subscription_active', '}');
  check('🔴 「未订阅」分支本身回 Forbidden',
      subBranch.contains('AppError::Forbidden') &&
          !subBranch.contains('AppError::Unauthorized'),
      subBranch.isEmpty ? '⚠️ 切片为空（分支被改名了？）' : '');
  check('🔴 token→uid 用唯一实现（auth::uid_by_token）',
      sync.contains('crate::auth::uid_by_token'));

  // error.rs
  check('🔴 `AppError::Forbidden` 变体存在', hasIdent(err, 'Forbidden'));
  check('🔴 Forbidden 映射到 403',
      err.contains('AppError::Forbidden(msg) => (StatusCode::FORBIDDEN'));

  // ══════════════════════════════════════════════════════════════════
  print('\n[④] 幂等与合并口径（结构层守，行为层由 cargo test 守）');
  // ══════════════════════════════════════════════════════════════════
  check('🔴 `review_log` 用 INSERT OR IGNORE（事件不可变）',
      sync.contains('INSERT OR IGNORE INTO sync_review_log'));
  check('🔴 其余各表用条件 UPSERT（`ON CONFLICT ... DO UPDATE`）',
      countOf(sync, 'ON CONFLICT (user_id,') >= 4,
      '${countOf(sync, 'ON CONFLICT (user_id,')} 处');
  // 🔑 WHERE 子句 = 「只有真有变更才刷新 received_at」⇒ 幂等的关键
  check('🔴 条件 UPSERT 都带 `WHERE excluded...`（不刷 received_at）',
      RegExp(r'WHERE excluded\.(updated_at|added_at|read_at|bookmarked_at)')
              .allMatches(sync)
              .length >=
          4);
  check('`user_word` 的 added_at 取**较早**（MIN）',
      sync.contains('added_at   = MIN(excluded.added_at, sync_user_word.added_at)'));
  check('`article_read` 的 read_at 取**较早**（MIN + `<`）',
      sync.contains('MIN(excluded.read_at, sync_article_read.read_at)') &&
          sync.contains('WHERE excluded.read_at < sync_article_read.read_at'));
  check('`bookmark` 按 bookmarked_at 取**较新**',
      sync.contains('WHERE excluded.bookmarked_at > sync_bookmark.bookmarked_at'));
  check('🔴 `utc_day` 由服务端从 reviewed_at 推导（不信客户端）',
      sync.contains('utc_day_of') && countOf(sync, 'utc_day_of(') >= 2);

  // ══════════════════════════════════════════════════════════════════
  print('\n[⑤] 路由与模块注册');
  // ══════════════════════════════════════════════════════════════════
  check('🔴 `POST /api/sync/push` 已注册',
      routes.contains('"/api/sync/push", post(crate::sync_handlers::sync_push)'));
  check('🔴 `GET /api/sync/pull` 已注册',
      routes.contains('"/api/sync/pull", get(crate::sync_handlers::sync_pull)'));
  check('lib.rs 导出 sync_handlers', lib.contains('pub mod sync_handlers;'));

  // ═══════════════════════════════════════════════════════════
  section('【⑤】端侧**接线**（widget 层 —— 本机跑不了 flutter ⇒ 只能靠源码断言守）');

  // 这一节守的是「功能真的被接上了」。
  // 🔴 本项目已多次踩「有实现、无入口」：分析器与后端测试**都发现不了**
  //    （代码能编译、能测，只是没人调它）。
  final appDart = stripComments(readFile('../../app/lib/app.dart'));
  final profile = stripComments(readFile('../../app/lib/screens/profile_screen.dart'));
  final syncProvider = stripComments(readFile('../../app/lib/providers/sync_provider.dart'));
  final syncService = stripComments(readFile('../../app/lib/services/sync_service.dart'));
  final wordDbProvider =
      stripComments(readFile('../../app/lib/providers/word_db_provider.dart'));

  // ── 登录 → 触发同步 ──
  final loginHook = between(appDart,
      "ref.listen<String?>(authProvider.select((a) => a.userId)", '});');
  check('🔴 登录钩子里**调了** `runSyncAfterLogin`', loginHook.isNotEmpty &&
      loginHook.contains('runSyncAfterLogin(ref)'),
      '—— 挂在既有的「userId 变化」钩子上（一处覆盖 登录/注册/会话恢复 三条路径）');
  check('  且**仍然**保留了原有的订阅刷新（不是替换掉）',
      loginHook.contains('ref.fetchSubscription()'));

  // ── 登出 → 先 flush ──
  check('🔴 退出登录**前**调了 `flushBeforeLogout`',
      profile.contains('await flushBeforeLogout(ref);'));
  final logoutIdx = profile.indexOf('await ref.read(authProvider.notifier).logout();');
  final flushIdx = profile.indexOf('await flushBeforeLogout(ref);');
  check('🔴🔴 顺序正确：flush **在** logout **之前**',
      flushIdx >= 0 && logoutIdx > flushIdx,
      '—— 反了则「本地写了但没推」的数据要等下次登录才上去（可能永远不上）');
  check(
    '🔑 **注销**路径**不**调 flush（账号已删，推上去无意义）',
    profile.indexOf('flushBeforeLogout',
            profile.indexOf('_deleteAccount') > 0 ? profile.indexOf('_deleteAccount') : 0) <
        0 ||
        between(profile, '_deleteAccount', 'flushBeforeLogout').isEmpty ||
        !between(profile, 'Future<void> _deleteAccount', '/// ').contains('flushBeforeLogout'),
    '两条路径语义不同：登出 = 还会回来；注销 = 账号没了',
  );

  // ── provider 的关键约束 ──
  // 🔑 用**计数**而不是 `contains` —— 「读」与「写」是两处，
  //    只锁一处会出现「读带 userId、写不带」这种**最坏的组合**
  //    （写进固定键、读一个永远空的带 userId 键 ⇒ 永远全量拉，且不报错）。
  //    📌 判据：**「一处口径」的断言要用计数**，不能用「存在性」。
  // ⚠️ 用 `split` 计数而**不用正则** —— 要匹配的字符串里含 `$`，
  //    而正则里 `$` 是行尾锚点；转义写错会**静默匹配 0 处**
  //    （本人踩过一次：表现为「实得 0 处」的假红，看起来像实现问题，
  //      实际是断言自己坏了 —— 这正是「假红消耗门禁可信度」的典型）。
  // 🔴 2026-10-10（v11）：游标**已从 prefs 搬进 `user.db`**（`sync_cursor` 单行表）。
  //    判据随之改口径，但**意图一字未变**：「游标口径只能一处，且读、写必须同源」。
  //      · 旧：`kSyncCursorPrefsKeyPrefix` 出现 ≥2 次（readCursor + writeCursor）
  //      · 新：`sync_cursor` 出现 ≥2 次（同上）
  //    🔑 这正是「**断言跟意图走、不跟文件内容走**」——实现换落点时，
  //       断言**不该**因为「字面量变了」而假红；只有**意图**变了才该改。
  // ⚠️ 用 `split` 计数而**不用正则**（要匹配的串含 `$`，正则里它是行尾锚点；
  //    转义写错会**静默匹配 0 处** = 假红，看着像实现问题其实是断言自己坏了）。
  final cursorDbHits = syncProvider.split('sync_cursor').length - 1;
  check('🔴 游标**读、写都落在** `user.db` 的 `sync_cursor` 表（用计数锁两处）',
      cursorDbHits >= 2, '实得 $cursorDbHits 处（应为 2：readCursor + writeCursor）');
  check('🔴 旧 prefs 游标键**不再被读写**（只允许 `remove` 清遗留）',
      !syncProvider.contains(r"prefs.getString('$kLegacySyncCursorPrefsKeyPrefix") &&
          !syncProvider.contains(r"prefs.setString('$kLegacySyncCursorPrefsKeyPrefix"),
      '—— 读写 prefs 键会与 `sync_cursor` 表**形成两个真值源**，迟早分叉且不报错');
  check('🔴 token / userId 为空时**不构造** SyncService（未登录不同步）',
      syncProvider.contains("if (token.isEmpty || userId.isEmpty) return null;"));
  check('🔑 `book.db` 打不开时**降级**（不阻塞其余四类）',
      RegExp(r'bookDb = await ref\.read\(bookDbProvider\.future\);')
          .hasMatch(syncProvider) &&
      syncProvider.contains('db 不可用（跳过电子书进度）'));
  check('🔑 `device_id` 取不到时**降级为空**（只影响精确度，不影响正确性）',
      syncProvider.contains("deviceId = ''") ||
          syncProvider.contains('deviceId = \'\''));

  // ── push 时机：App 进后台（覆盖所有本地改动）──
  check('🔴 根 widget 注册了 lifecycle observer（`addObserver`）',
      appDart.contains('WidgetsBinding.instance.addObserver(this)'));
  check('🔴 且在 dispose 里**注销**（否则回调会打到已销毁的 state）',
      appDart.contains('WidgetsBinding.instance.removeObserver(this)'));
  final lifecycle = between(appDart, 'void didChangeAppLifecycleState',
      '\n  @override');
  check('🔴 只在 **`paused`** 时推（不是 `inactive`）',
      lifecycle.contains('AppLifecycleState.paused') &&
          !lifecycle.contains('AppLifecycleState.inactive'),
      '—— `inactive` 在 来电/控制中心/切换器 都会触发 ⇒ 过频');
  check('  且检查了 `mounted`（避免对已卸载的 state 操作）',
      lifecycle.contains('mounted'));
  check('🔑 provider 有 `pushWhenAppPaused`（只推不拉）',
      syncProvider.contains('void pushWhenAppPaused(WidgetRef ref)'));
  // 🔑 锁**意图**（「两个入口共用同一个执行函数」），**不锁那个函数的拼写**。
  //
  // 🔴 2026-10-09 实测踩到：该实现由 `_pushOnly` **并入** `_runSync`
  //    （新版要在同一个地方上报同步状态），而原断言写死了
  //    `=> _pushOnly(ref, '登出前 flush')` ⇒ 断言**假红**，而它要守的
  //    「口径一处」**根本没变**。
  //    📌 判据（项目已记）：**断言跟「意图」走、不跟「文件/拼写」走** ——
  //       改实现（合并两个函数）不该让「它们共用一处」这条变红。
  //    ✅ 修法：从两个函数的**各自切片**里把被调用的那个函数名抽出来，比较是否相同。
  /// 取出 `fnDecl` 这个函数体里调用的**内部执行函数名**（形如 `_runSync`）。
  String executorOf(String fnDecl) {
    final seg = between(syncProvider, fnDecl, '\n\n');
    return RegExp(r'_(\w+)\(ref, tag:').firstMatch(seg)?.group(1) ?? '';
  }

  final flushExecutor = executorOf('Future<void> flushBeforeLogout');
  final pausedExecutor = executorOf('void pushWhenAppPaused');
  check(
    '🔑 `flushBeforeLogout` 与「进后台」**共用**同一个执行函数（口径一处）',
    flushExecutor.isNotEmpty && flushExecutor == pausedExecutor,
    '实测 flush→_$flushExecutor · paused→_$pausedExecutor',
  );
  // 🔑 「进后台 = 只推不拉」由两段共同保证：**标记**（`pushOnly: true`）
  //    + **映射**（该标记必须落到 `pushOnce`，不是 `syncNow`）。
  //    ⚠️ 下面这条是**有意的形状锁定**：若把三元重构成 `if`，请连同它一起改，
  //       **不要**删掉 —— 删了就没有任何东西守着「进后台别去拉数据」了。
  final pushWhenPaused = between(syncProvider, 'void pushWhenAppPaused', '\n\n');
  check(
    '🔑 进后台标记为「只推」（`pushOnly: true` —— 进后台不是取新数据的时机）',
    pushWhenPaused.contains('pushOnly: true'),
  );
  check(
    '🔑 该标记真的落到 `pushOnce`（不是 `syncNow`）',
    syncProvider.contains('pushOnly ? await svc.pushOnce() : await svc.syncNow()'),
  );

  // ══════════════════════════════════════════════════════════════════════
  // 【2026-10-09】🔴 pull 之后**必须**通知读端（revision bump）
  //
  // # 为什么（这条是**真缺陷**的回归防线）
  //
  // pull 会把远端数据写进本地 `user.db` / `book.db`，而此前**没有任何地方**
  // 通知界面重算 ⇒ 表现是「**同步成功了，界面就是不更新**」，且**不报错**：
  //   · 云端备份被清理（`blob_size → 0`）⇒ 书架仍显示「云端有」⇒ 点下载 **404**
  //   · 别端的生词 / 复习记录 ⇒ 要等**别的动作**（下载书 / 划线 / 查词）碰巧 bump
  //     —— 而那些动作与同步毫无关系
  //
  // 🔑 判据：**「写端逐个通知读端」是必漏结构，要让读端 watch 一个 revision**
  //    （`bump()` 早就存在，只是一直没人调）。
  //
  // ⚠️ 三条都要锁到**具体表达式**：这一族是「接线」断言 ——
  //    只查「有没有出现 bump」的话，**换成一个永不触发的回调也照样通过**。
  //
  // # 证伪方式
  // · 删掉 `_runSync` 里那两行 `bump()` ⇒ 前两条必红
  // · 把 `!pushOnly &&` 去掉 ⇒ 第三条必红（进后台会白刷一遍）
  // ══════════════════════════════════════════════════════════════════════
  check(
    '🔴 pull 后 bump `userDbRevisionProvider`（生词/复习/划线等读端要重算）',
    syncProvider.contains('userDbRevisionProvider.notifier).bump()'),
    '否则拉回来的学习数据写进了库、界面却不刷新（静默）',
  );
  check(
    '🔴 pull 后 bump `bookDbRevisionProvider`（书架读端要重算）',
    syncProvider.contains('bookDbRevisionProvider.notifier).bump()'),
    '否则云端备份被清理后，书架仍显示「云端有」⇒ 点下载 404',
  );
  check(
    '🔴 只在「真拉回东西」时 bump，且 `pushOnly`（只推不拉）不 bump',
    syncProvider.contains('!pushOnly && report.pulledTotal > 0'),
    '无条件 bump ⇒ 每次后台同步都白刷；改用漏项的字段 ⇒ 书单变更会被漏掉',
  );

  // ══════════════════════════════════════════════════════════════════════
  // 【2026-10-09】🔴 复习列表标题变成内部 ID（`w000129` / `hl:<uuid>` / `ext:fixtures`）
  //
  // 根因链（详见 `docs/review/review-list-spelling-id-pollution-2026-10-09.md`）：
  //   ① 列表标题读 `card_review_state.spelling`（`review_list_query.dart`）
  //   ② pull 复习事件时逐词重算拼写，用 `INSERT OR REPLACE` **整行覆盖**
  //   ③ 旧实现解析不出时 **`return wordId`** ⇒ 占位被**持久化**成标题
  //   ④ 且 pull 里 `_applyReviewEvents` 排在 `_applyUserWords` **之前**
  //      ⇒ 同一次 pull 里那份正确拼写还没落库 ⇒ 解析**必然**失败
  //
  // ⚠️ 行为级断言在 `verify_review_spelling.dart`（真库，27 项）；
  //    这里只锁**接线**（顺序 / 谁调用谁）——那是行为断言看不到的部分。
  //
  // # 证伪方式
  // · 把 pull 两行**对调**回去 ⇒ 顺序断言必红
  // · 让 `_spellingFor` 恢复 `return wordId` ⇒ 兜底断言必红
  // · 删掉 `_repairStaleSpellings(...)` 那行 ⇒ 自愈接线断言必红
  // · 把它挪进 `if (result.didWrite) { }` 里 ⇒ 「不在块内」必红
  // ══════════════════════════════════════════════════════════════════════
  {
    final iWords =
        syncService.indexOf('r.pulledUserWords = await _applyUserWords(');
    final iEvents =
        syncService.indexOf('r.pulledReviewEvents = await _applyReviewEvents(');
    check('🔴 pull 里 `user_words` 必须**先**落库（`review_events` 要拿它当拼写来源）',
        iWords >= 0 && iEvents >= 0 && iWords < iEvents,
        'words @$iWords · events @$iEvents —— events 在前 ⇒ 同一次 pull 里必然解析失败');

    check('🔴 `_spellingFor` 委托**唯一**的解析器（不再自己查两级）',
        syncService.contains('_spellingResolver.resolve(wordId)'));

    // ⚠️ 判据要落在 `_spellingFor` 的**函数体切片**里，不能全文件扫 ——
    //    调用点有一句 `resolved ?? currentRow?.spelling ?? wordId`（那是**有意**的），
    //    全文件扫 `?? wordId` 会**假红**。
    //    🔴 而只判「签名是不是 `Future<String?>`」又**太松**：
    //       在体内写 `(await resolve(id)) ?? wordId` 签名不变、缺陷照样回来 ⇒ 假绿。
    //    ⇒ 切片 + **哨兵**（截不到就自己红，不许静默退化成「扫到文件尾」）。
    final spellingFn = between(
        syncService, 'Future<String?> _spellingFor(', '\n  ReviewEvent? _eventFromPullJson');
    check('切片有效（截到了 `_spellingFor` 函数体，没跑到文件尾）',
        spellingFn.isNotEmpty && spellingFn.contains('_spellingResolver.resolve'),
        '切片长 ${spellingFn.length}');
    check('🔴 `_spellingFor` 体内**不得**再用 `word_id` 兜底（那会把显示问题变成数据污染）',
        !spellingFn.contains('?? wordId') && !spellingFn.contains('return wordId'),
        '兜底值经 `INSERT OR REPLACE` 会被持久化成列表标题');
    check('🔴 返回类型保持可空（`Future<String?>`）—— 改回非空通常意味着兜底回来了',
        !RegExp(r'Future<String>\s+_spellingFor').hasMatch(syncService));

    check('🔴 调用点：解析不出时**保留原值**（不是把解析结果直接写进去）',
        syncService.contains('resolved ?? currentRow?.spelling ?? wordId'));

    check('🔴 拼写自愈已接线（词库就绪后跑）',
        wordDbProvider.contains('await _repairStaleSpellings(ref, service)'));

    final iDidWrite = wordDbProvider.indexOf('if (result.didWrite)');
    final iRepair = wordDbProvider.indexOf('_repairStaleSpellings(ref, service)');
    final iBlockEnd = iDidWrite >= 0 ? wordDbProvider.indexOf('}', iDidWrite) : -1;
    check('🔴 自愈**不在** `didWrite` 块内（词库没变时同样要修）',
        iDidWrite >= 0 && iRepair >= 0 && iBlockEnd >= 0 && iRepair > iBlockEnd,
        'didWrite @$iDidWrite · 块尾 @$iBlockEnd · repair @$iRepair —— '
            '进了块内 ⇒ 词库不更新时永远修不好');
  }

  // ══════════════════════════════════════════════════════════════════════
  // 【2026-10-09】🆕 划线纳入同步（`highlight` 表）
  //
  // # 为什么（这条守的是一个**真实缺口**）
  //
  // 此前 `review_log`（复习事件）参与同步，而 `highlight`（划线**本体**）不参与
  // ⇒ 重装 / 换机 / 清数据的设备会拿到「**无主划线卡**」：
  //   标题显示成 `hl:<uuid>`、点「暂停」静默无反应、界面上没有出口能去掉它。
  // 📌 判据：**同步的粒度必须覆盖「引用关系」**。
  //
  // # 🔴 证伪方式（每条都要能红）
  // · 删掉 push 里 `await hl.pending()` / `r.pushedHighlights = …` ⇒ 前两条必红
  // · 从 `_buildPushBody` 的 map 里删掉 `'highlights'` ⇒ 必红
  // · 删掉 `await hl.markSynced(…)` ⇒ 必红（会永远重推）
  // · 把 `_applyHighlights` 挪到 `_applyReviewEvents` **之后** ⇒ 顺序断言必红
  // · 把 `pulledHighlights` 从 `pulledTotal` 里删掉 ⇒ 必红
  // · 让 `_applyHighlights` 改用 `HighlightRepository.add()` ⇒ 「不借业务方法」必红
  // · 从后端 `max_received` 的表清单里删掉 `sync_highlight` ⇒ 必红
  // ══════════════════════════════════════════════════════════════════════
  {
    // ── push 侧 ──
    // 🔑 断言锁**意图**（「收集了待推划线」），**不锁拼写** ——
    //    2026-10-10 加入分批循环后调用变成 `hl.pending(limit: kMaxItemsPerTable)`，
    //    锁字面 `hl.pending()` 会**假红**（而要守的「收集了」这件事根本没变）。
    //    📌 判据（项目已记）：**断言跟「意图」走、不跟「拼写」走**。
    check('push 收集待推划线（`HighlightRepository.pending()`）',
        RegExp(r'await hl\.pending\(').hasMatch(syncService));
    // ⚠️ 同理：分批循环里计数从 `=` 变成 `+=`（累加各轮）。意图不变。
    check('push 计入 `pushedHighlights`（漏 ⇒ 「本轮只同步了笔记」被判成「什么都没做」）',
        RegExp(r'r\.pushedHighlights \+= highlights\.length').hasMatch(syncService));
    check('push 请求体带 `highlights`（键名与后端 `PushInput` 一致）',
        syncService.contains("'highlights': ["));
    check('push 成功后标记已同步（漏 ⇒ 每次同步都重推全量）',
        syncService.contains('await hl.markSynced(highlights.map((h) => h.id))'));
    check('后端对 `highlights` 也做批量上限校验（防一次传百万条）',
        sync.contains('check_batch_size("highlights"'),
        '漏了它 ⇒ 超大批次不做保护直接进事务');

    // ── pull 侧 ──
    check('pull 解析 `highlights` 字段',
        syncService.contains("_listOf(resp, 'highlights')"));
    check('pull 调用 `_applyHighlights`',
        syncService.contains('r.pulledHighlights = await _applyHighlights(highlights)'));

    // 🔴 **顺序**：划线必须排在 `_applyReviewEvents` **之前**
    //    （`ReviewSpellingResolver` 的第 ③ 级正是同库的 `highlight.text`）
    final iHl = syncService.indexOf('r.pulledHighlights = await _applyHighlights(');
    final iEv = syncService.indexOf('r.pulledReviewEvents = await _applyReviewEvents(');
    check('🔴 pull 里划线必须**先**落库（复习事件要拿 `highlight.text` 当拼写来源）',
        iHl >= 0 && iEv >= 0 && iHl < iEv,
        'highlights @$iHl · events @$iEv —— events 在前 ⇒ 新设备上标题会先显示成 `hl:<uuid>`');

    // 🔴 `pulledTotal` 必须含 `pulledHighlights`（切片 + 哨兵：截不到就自己红）
    final reportCls =
        between(syncService, 'class SyncReport {', '/// 同步编排器。');
    check('切片有效（截到了 `SyncReport` 类体，没跑到文件尾）',
        reportCls.isNotEmpty && reportCls.contains('pulledTotal'),
        '切片长 ${reportCls.length}');
    check('🔴 `pulledTotal` 含 `pulledHighlights`（漏 ⇒ 只拉回笔记时不算「有变化」）',
        reportCls.contains('pulledHighlights +'));
    check('🔴 `pushedTotal` 含 `pushedHighlights`',
        reportCls.contains('pushedHighlights +'));

    // ── `_applyHighlights` 的函数体（切片 + 哨兵）──
    final applyFn = between(
        syncService, 'Future<int> _applyHighlights(', 'Future<void> _upsertHighlight(');
    check('切片有效（截到了 `_applyHighlights` 函数体）',
        applyFn.isNotEmpty && applyFn.contains('m.mergeHighlight'),
        '切片长 ${applyFn.length}');
    check('🔴 走**直写**（`_upsertHighlight`），不借业务方法 `add()`',
        applyFn.contains('_upsertHighlight(merged)') &&
            !applyFn.contains('.add('),
        '`add()` 会把 `deleted`/`paused` 归零 ⇒ 别端取消的划线在本地**复活**');
    check('🔴 合并前**取整行**本地数据（少取一列会让「首次事实」被 `null` 静默覆盖）',
        applyFn.contains("query('highlight', where: 'id = ?'"),
        '只 SELECT 几列的话，`mergeHighlight` 读不到的键返回 `null` ⇒ 真值被覆盖');
    check('`pending_push` 由 `pendingPushAfterPull` 决定（同其余表，防回声）',
        applyFn.contains('m.pendingPushAfterPull('));

    // ── 后端 pull：`server_time` 的取数表清单必须含划线 ──
    check('🔴 `max_received` 的表清单含 `sync_highlight`',
        sync.contains('MAX(received_at) FROM sync_highlight'),
        '漏了它 ⇒ 只写划线时 `server_time` 不前进 ⇒ 同一批被**反复重拉**');

    // ── 后端 pull 查询存在（否则 pull 永远返回空数组）──
    check('后端 pull 有 `sync_highlight` 的查询',
        sync.contains('FROM sync_highlight') &&
            sync.contains('WHERE user_id = ?1 AND received_at > ?2'));

    // ── 后端 push 的 `source_type` 校验（错值要回 400 不是 500）──
    check('🔴 后端校验 `source_type` 枚举并回 400',
        sync.contains('只能是 article / book'),
        '只靠表上的 CHECK ⇒ 抛 rusqlite 错 ⇒ 映射成 500 ⇒ 客户端无限重试');
  }

  // ── 登出确认文案（同步上线后原话已不完整）──
  check(
    '🔑 登出确认文案已更新（不再说「只保存在本机」）',
    profile.contains('已同步到云端的数据也仍保留'),
    '—— 同步上线后「只保存在本机」不准确；且退出**不会**删除云端那份',
  );

  // ══════════════════════════════════════════════════════════════════════
  // 【2026-10-10】🆕 同步覆盖面补齐（审计报告 `sync-coverage-audit` §五）
  //   P0 `lookup_event` · P1 `book_marker` · P2 `achievement_unlock` · P3 `setting`
  //
  // # 证伪方式（每条都要能红）
  // · 删掉 push 里 `await uw.pendingLookups(...)` ⇒ 对应断言必红
  // · 从 `_buildPushBody` 的 map 删掉 `'lookup_events'` ⇒ 必红
  // · 删掉 `syncNow` 里某个 `..pushedXxx = ` ⇒ 「复制全部字段」必红
  // · 把 `kMaxItemsPerTable` 从 pushOnce 里去掉 ⇒ 「分批」必红
  // · 删掉 `backfillLookupUids()` 调用 ⇒ 必红（空 uid 会互相覆盖）
  // · 让 `_applyBookMarkers` 直接在没书时写 `book_marker` ⇒ 「先落 pending」必红
  // · 从后端 `max_received` 表清单删掉一张 ⇒ 必红
  // ══════════════════════════════════════════════════════════════════════
  {
    final settingsSync =
        stripComments(readFile('../../app/lib/services/settings_sync.dart'));
    final uwRepo =
        stripComments(readFile('../../app/lib/services/user_word_repository.dart'));
    final achSvc =
        stripComments(readFile('../../app/lib/services/achievement_service.dart'));

    // ── ① 服务端：四类数据的 upsert 形态与 pull 查询 ──
    check('🔴 `lookup_event` 用 INSERT OR IGNORE（日志不可变，同 review_log）',
        sync.contains('INSERT OR IGNORE INTO sync_lookup_event'));
    check('🔴 `book_marker` 的 `deleted` 取 `MAX(...)` = **OR 语义**（本表无 updated_at）',
        sync.contains('MAX(excluded.deleted, sync_book_marker.deleted)'),
        '照抄「取较新」会让取消**永远传不出去**');
    check('🔴 `achievement_unlock` 的 `unlocked_at` 取 MIN（较早 = 首次解锁）',
        sync.contains('MIN(excluded.unlocked_at, sync_achievement_unlock.unlocked_at)'));
    check('🔴 `setting` 的 `value` 取较新（LWW）',
        sync.contains('WHERE excluded.updated_at > sync_setting.updated_at'));
    check('后端对 4 张新表都做批量上限校验',
        sync.contains('check_batch_size("lookup_events"') &&
            sync.contains('check_batch_size("book_markers"') &&
            sync.contains('check_batch_size("achievement_unlocks"') &&
            sync.contains('check_batch_size("settings"'));
    check('🔴 `max_received` 的表清单含 4 张新表（漏一张 ⇒ 只写它时 server_time 不前进）',
        sync.contains('MAX(received_at) FROM sync_lookup_event') &&
            sync.contains('MAX(received_at) FROM sync_book_marker') &&
            sync.contains('MAX(received_at) FROM sync_achievement_unlock') &&
            sync.contains('MAX(received_at) FROM sync_setting'));
    check('后端 pull 有 4 张新表的查询',
        sync.contains('FROM sync_lookup_event') &&
            sync.contains('FROM sync_book_marker') &&
            sync.contains('FROM sync_achievement_unlock') &&
            sync.contains('FROM sync_setting'));

    // ── ② 端侧 push 接线 ──
    check('🔴 push 前**回填** `lookup_event.uid`（空 uid 会让服务端 PK 互相覆盖）',
        syncService.contains('await uw.backfillLookupUids()'));
    check('push 收集 4 类待推',
        syncService.contains('await uw.pendingLookups(') &&
            syncService.contains('await ach.pendingUnlocks(') &&
            syncService.contains('await _pendingBookMarkers()') &&
            syncService.contains('await _pendingSettings()'));
    check('push 请求体带 4 个新键（键名与后端 `PushInput` 一致）',
        syncService.contains("'lookup_events': lookups,") &&
            syncService.contains("'book_markers': bookMarkers,") &&
            syncService.contains("'achievement_unlocks': achievementUnlocks,") &&
            syncService.contains("'settings': settings,"));
    check('push 成功后标记 4 类已同步（漏 ⇒ 每次同步重推全量）',
        syncService.contains('await uw.markLookupsSynced(') &&
            syncService.contains('await ach.markUnlocksSynced(') &&
            syncService.contains('await markSettingsSynced('));

    // 🔴 分批循环（老库升级后 lookup_event 可能有数千条 ⇒ 一次全推 400 会拖垮整批）
    check('🔴 `pushOnce` 是**分批循环**（每表 ≤ `kMaxItemsPerTable`）',
        syncService.contains('while (true)') &&
            countOf(syncService, 'limit: kMaxItemsPerTable') >= 5,
        '实得 ${countOf(syncService, 'limit: kMaxItemsPerTable')} 处 limit');
    check('🔴 终止条件用「**有标记的表都没取满**」（不是「批量为 0」）',
        syncService.contains('anyMarkedTableFull'),
        '只靠「批量为 0」会被「设置采集每轮非空」拖成死循环');
    check('🔴 全量推的表（progress/books/markers）**只在第一轮**带（否则永不终止）',
        syncService.contains('firstRound') &&
            countOf(syncService, 'firstRound') >= 4);

    // ── ③ 端侧 pull 接线 ──
    check('pull 解析 4 个新字段',
        syncService.contains("_listOf(resp, 'lookup_events')") &&
            syncService.contains("_listOf(resp, 'book_markers')") &&
            syncService.contains("_listOf(resp, 'achievement_unlocks')") &&
            syncService.contains("_listOf(resp, 'settings')"));
    check('pull 应用 4 类',
        syncService.contains('await _applyLookupEvents(') &&
            syncService.contains('await _applyBookMarkers(') &&
            syncService.contains('await _applyAchievementUnlocks(') &&
            syncService.contains('await _applySettings('));
    check('🔴 `lookup_event` 走 `INSERT OR IGNORE`（日志幂等）且 `pending_push=0`（防回声）',
        syncService.contains('INSERT OR IGNORE INTO lookup_event'),
        '');
    // 🔴🔴 这条守的是一个**真实缺陷**（2026-10-10 被真库断言实测抓到）：
    //    `INSERT OR IGNORE` 只在**有唯一约束**时才是幂等的。本表 PK 是**自增 id**，
    //    所以必须给 `uid` 建唯一索引 —— 否则重复拉取会**每次插入新行**（查词次数虚增），
    //    而且**不报错**。
    check('🔴 `lookup_event.uid` 有**唯一索引**（`INSERT OR IGNORE` 的幂等前提）',
        stripComments(readFile('../../app/assets/sql/user_db_schema.sql'))
            .contains('CREATE UNIQUE INDEX IF NOT EXISTS idx_le_uid ON lookup_event (uid)'),
        '没有它 ⇒ 代码写着 OR IGNORE、实际不幂等（静默）；'
            'SQLite 的 UNIQUE 允许多个 NULL ⇒ 老库未回填的行不受影响');
    check('🔴 本地没有那本书时书签先进 `book_marker_pending`（FK 会失败）',
        syncService.contains("db.insert(\n            'book_marker_pending',") ||
            syncService.contains("'book_marker_pending',"),
        '');
    check('🔴 pull 后**认领**书签（否则写进交换区却永不被应用）',
        syncService.contains('await claimAllPendingMarkers(db)'));
    check('🔴 走**直写** `upsertMarkerRow`（不借 `BookMarkerRepository.add()`）',
        syncService.contains('await upsertMarkerRow(db, bookId: bookId, row: merged);') &&
            !syncService.contains('BookMarkerRepository('),
        '`add()` 会把 `deleted` 归零 ⇒ 别端取消的书签在本地**复活**');

    // ── ④ `SyncReport` 计数 + `syncNow` 逐字段复制 ──
    check('🔴 `pushedTotal` 含 4 个新计数',
        syncService.contains('pushedLookupEvents +') &&
            syncService.contains('pushedBookMarkers +') &&
            syncService.contains('pushedAchievementUnlocks +') &&
            syncService.contains('pushedSettings +'));
    check('🔴 `pulledTotal` 含 4 个新计数（+ 认领书签）',
        syncService.contains('pulledLookupEvents +') &&
            syncService.contains('pulledBookMarkers +') &&
            syncService.contains('pulledAchievementUnlocks +') &&
            syncService.contains('pulledSettings +') &&
            syncService.contains('claimedBookMarkers;'));
    // 🔴 这条守的是「加字段忘了在 `syncNow` 复制」——2026-10-10 实测**已漏两处**
    //    （`pushedHighlights` / `pulledHighlights` / `pulledBooks`）：
    //    漏了 ⇒ 该字段在 `syncNow()` 后归零 ⇒ `pulledTotal` 变小 ⇒ 不 bump ⇒ 界面不刷新。
    //    ⚠️ 用**逐字段计数**而不是「存在性」：存在性会被 `SyncReport` 类声明里的
    //       `int pushedXxx = 0;` 行兜住（那是另一处）⇒ 假绿。
    final syncNowSeg = between(syncService, 'Future<SyncReport> syncNow()', '/// **退出登录前**');
    final copiedFields = RegExp(r'\.\.(pushed|pulled)\w+ = ').allMatches(syncNowSeg).length;
    final declaredFields =
        RegExp(r'int (pushed|pulled)\w+ =').allMatches(syncService).length;
    check('切片有效（截到了 `syncNow` 函数体）',
        syncNowSeg.isNotEmpty && syncNowSeg.contains('pushReport'),
        '切片长 ${syncNowSeg.length}');
    check(
      '🔴 `syncNow` **逐字段复制了全部** pushed/pulled 计数（漏一个 ⇒ 该字段归零 ⇒ 不 bump）',
      copiedFields == declaredFields,
      '声明 $declaredFields 个 · 复制 $copiedFields 个',
    );

    // ── ⑤ 设置同步（P3）──
    check('端侧注入了 prefs 读写（`buildSyncService`）',
        syncProvider.contains('readPrefSetting: (key) async => prefs.get(key)') &&
            syncProvider.contains('writePrefSetting:'));
    check('🔴 `settings_sync.dart` 是**纯 Dart**（不 import Flutter / shared_preferences）',
        !settingsSync.contains("package:flutter") &&
            !settingsSync.contains('shared_preferences') &&
            settingsSync.contains('kSyncedSettingKeys'));
    check('🔴 换账号时**复位**同步设置 prefs（否则跨账号泄漏：字号/兴趣/显示名）',
        stripComments(readFile('../../app/lib/providers/local_data_owner_provider.dart'))
            .contains('resetSyncedSettingPrefs('));
    // 🔑 「字面量键清单」与来源一致性（本文件不能 import 那些来源 ⇒ 靠断言补编译期约束）
    final readingSrc =
        stripComments(readFile('../../app/lib/services/reading_settings.dart'));
    final interestSrc =
        stripComments(readFile('../../app/lib/providers/interest_provider.dart'));
    final ttsSrc = stripComments(readFile('../../app/lib/services/tts_service.dart'));
    for (final key in ['reading_font_size', 'reading_trace_enabled']) {
      check('设置键 `$key` 与 `reading_settings.dart` 一致', readingSrc.contains(key));
    }
    check('设置键 `interest_categories` 与 `interest_provider.dart` 一致',
        interestSrc.contains('interest_categories'));
    for (final key in ['tts_enabled', 'tts_speech_rate']) {
      check('设置键 `$key` 与 `tts_service.dart` 一致', ttsSrc.contains(key));
    }
    check('设置键 `display_name` 与 `profile_screen.dart` 一致',
        profile.contains('display_name'));
    // 每个键都要在清单里出现过一次（防「加了常量忘了加进清单」）
    for (final key in [
      'reading_font_size',
      'reading_trace_enabled',
      'interest_categories',
      'tts_enabled',
      'tts_speech_rate',
      'display_name',
    ]) {
      check('`kSyncedSettingKeys` 含 `$key`', settingsSync.contains("'$key'"));
    }
    check('🔴 `applySettings` 写回 prefs（只写表 ⇒「同步了、界面没变」）',
        settingsSync.contains('await writePref(key,'));

    // ── ⑥ 端侧仓储/服务的方法确实存在（防「接线写了、方法没写」）──
    check('`UserWordRepository` 有 `pendingLookups`/`markLookupsSynced`/`backfillLookupUids`',
        uwRepo.contains('Future<List<LookupEvent>> pendingLookups(') &&
            uwRepo.contains('Future<void> markLookupsSynced(') &&
            uwRepo.contains('Future<int> backfillLookupUids('));
    check('`AchievementService` 有 `pendingUnlocks`/`markUnlocksSynced`',
        achSvc.contains('Future<List<Map<String, Object?>>> pendingUnlocks(') &&
            achSvc.contains('Future<void> markUnlocksSynced('));
  }

  // ═══════════════════════════════════════════════════════════════════════
  section('【15】🔴 401（登录态失效）必须**可感知 + 可行动**（2026-10-10）');
  //
  // 背景（真机）：白哥在两台设备上用同一账号 ⇒ 后登录的那台把前一台的 token 清掉
  //   ⇒ 前一台**到处 401**，而 UI 只说「同步失败」（**暗示「重试就好」**）
  //   ⇒ 用户反复点，永远失败，且不知道要重新登录。
  // 📄 `docs/review/device-sync-and-profile-failure-2026-10-10.md` §一 / §四 C
  //
  // 🔑 本组守的是**「终态 vs 瞬时」必须被区分**：
  //    · 网络超时 / 5xx ⇒ 瞬时，重试有意义
  //    · 401            ⇒ **终态**，重试永远失败 ⇒ 必须给「重新登录」

  // ① 🔴 类型必须住在**纯 Dart** 文件里
  //    —— 否则捕获层（`sync_service`，纯逻辑层、要被本脚本 import）**拿不到这个类型**
  //    ⇒ 只能退化成「按字符串猜 401」⇒ 改一次文案就静默失效。
  //    ⚠️ 这正是**本次修复之前**的真实状态：`SyncUnauthorized` 被定义、被抛出，
  //       却**全仓零消费**（因为定义在带 Flutter 依赖的 `api/sync_client.dart` 里）。
  final syncErrSrc = readFile('../../app/lib/services/sync_errors.dart');
  check('🔴 `sync_errors.dart` 存在且**零 import**（纯 Dart ⇒ 捕获层才能用它判类型）',
      syncErrSrc.contains('class SyncUnauthorized') &&
          !RegExp(r'^\s*import\s', multiLine: true).hasMatch(syncErrSrc),
      '一旦引入 package: 依赖 ⇒ 捕获层 import 不到 ⇒ 401 静默退化成普通失败');
  check('🔴 两个类型**都**在纯 Dart 文件里（`SyncUnauthorized` + `SyncNotSubscribed`）',
      syncErrSrc.contains('class SyncUnauthorized') &&
          syncErrSrc.contains('class SyncNotSubscribed'));

  // ② 客户端仍抛出它，并且**只定义一份**
  final syncClientSrc = readFile('../../app/lib/api/sync_client.dart');
  check('🔴 `sync_client` 对 401 抛 `SyncUnauthorized`',
      syncClientSrc.contains('throw SyncUnauthorized('));
  check('🔴 `sync_client` **不得**再自带一份类型定义'
      '（两份同名 ⇒ `is` 判 false，而且**编译器不报**）',
      !syncClientSrc.contains('class SyncUnauthorized'));

  // ③ 捕获层把它翻成**结构化标记**（不是靠字符串匹配）
  final authExpiredHits = RegExp(r'r\.authExpired = e is SyncUnauthorized;')
      .allMatches(syncService)
      .length;
  check('🔴 push 与 pull **两处**都把 401 翻成 `authExpired`（用计数锁，不是存在性）',
      authExpiredHits == 2, '实得 $authExpiredHits 处（应为 2：pushOnce 与 pullOnce）');
  check('🔴 `SyncReport` 声明了 `authExpired` 字段',
      syncService.contains('bool authExpired = false;'));

  // ④ 上报层：两处失败路径都必须带上 `needsRelogin`
  check('🔴 上报失败时带 `needsRelogin`（**两处**：SyncReport 路径 + 异常路径）',
      (syncProvider.split('needsRelogin:').length - 1) >= 2,
      '实得 ${syncProvider.split('needsRelogin:').length - 1} 处 —— 只带一处 ⇒ 另一条路仍是「同步失败」');
  check('🔴 `_friendlySyncError` 对 `SyncUnauthorized` 有**专门文案**（含出口）',
      RegExp(r'if \(e is SyncUnauthorized\)[\s\S]{0,240}?重新登录')
          .hasMatch(syncProvider),
      '落进通用分支 ⇒ 用户看到「同步失败」而重试永远失败');

  // ⑤ 🔑 **行为断言**（可执行，不靠读源码）：
  //    401 与普通失败**必须显示不同的话**。锁「行为」而不是「某个字面量」——
  //    将来改文案时，只要两种状态仍可区分，这条就不该红。
  final nowS = DateTime(2026, 10, 10, 12, 0);
  check('🔴 胶囊文案：401 ⇒ 提「重新登录」；普通失败 ⇒ 仍是「同步失败」',
      syncChipLabel(
              const SyncStatus(phase: SyncPhase.failed, needsRelogin: true), nowS)
          .contains('重新登录') &&
          syncChipLabel(
                  const SyncStatus(phase: SyncPhase.failed), nowS) ==
              '同步失败');
  final reloginSummary = syncStatusSummary(
      const SyncStatus(
          phase: SyncPhase.failed, needsRelogin: true, lastError: '登录状态已失效'),
      nowS);
  check('🔴 401 的 summary **不得**以「同步失败」开头（否则暗示「重试即可」）',
      reloginSummary != null && !reloginSummary.startsWith('同步失败'),
      '实得：${reloginSummary ?? "(null)"}');
  check('🔑 `needsRelogin` **不粘**：切到 `syncing`/`skipped` 时会被复位',
      const SyncStatus(phase: SyncPhase.failed, needsRelogin: true)
              .copyWith(phase: SyncPhase.syncing)
              .needsRelogin ==
          false,
      '否则下次同步开始后旧提示还挂着');

  // ═══════════════════════════════════════════════════════════════════════
  section('【16】🔴 同步的「读端跟随」与「触发时机」（2026-10-10 真机两处）');
  //
  // 📄 `docs/review/sync-ui-not-refreshing-and-device-state-mismatch-2026-10-10.md`
  //   §二：成就快照不订阅 revision ⇒ 同步后 UI 不刷新、重开才对
  //   §三：自动时机里只有「登录后」会 pull ⇒ 两端永远看不到对方的改动

  // ── ① 成就快照**必须**订阅修订号 ──
  //
  // 🔴 这条断言的存在理由本身就值得记：**上一轮的报告写着「P0 = 1 行（加 watch）」并标「已实施」，
  //    而 `git log -S` 证明该标识符从未出现在那个文件里。**
  //    ⇒ 判据：**凡是「X 已修」，都要落成一条能被 CI 跑的断言**，否则它只是一句话。
  final achProv = readFile('../../app/lib/providers/achievement_provider.dart');
  // 🔑 同样**切片**：按「下一个 provider 定义」为界，不用字符数当上界
  //    （字符数当上界 = 猜一个够大的数 ⇒ 迟早越过边界，本文件刚踩过一次）。
  final snapBody = between(
      achProv, 'final achievementSnapshotProvider =',
      'final achievementUnlockTimesProvider =');
  final timesBody = between(achProv, 'final achievementUnlockTimesProvider =',
      'checkAndRefreshAchievements');
  check('🔴 切片有效（两个 provider 的函数体都截到了，**上界也真的截住了**）',
      snapBody.isNotEmpty &&
          timesBody.isNotEmpty &&
          snapBody.contains('AchievementSnapshot') &&
          !snapBody.contains('achievementUnlockTimesProvider') &&
          !timesBody.contains('checkAndRefreshAchievements'),
      'snap ${snapBody.length} · times ${timesBody.length} —— '
          '未截住上界 ⇒ 切片跑到文件尾 ⇒ 下面的断言会被**下一个 provider** 兜住（假绿）');
  check('🔴 成就快照 provider 订阅修订号（否则同步写库后**永不重算**）',
      snapBody.contains('ref.watch(userDbRevisionProvider)'));
  check('🔴 解锁时间 provider 也订阅（只改一处 ⇒ 成就墙仍显示旧日期）',
      timesBody.contains('ref.watch(userDbRevisionProvider)'));
  check('🔑 订阅写在 `await` **之前**（async gap 后 `ref` 不再安全）',
      snapBody.indexOf('ref.watch(userDbRevisionProvider)') >= 0 &&
          snapBody.indexOf('ref.watch(userDbRevisionProvider)') <
              snapBody.indexOf('await ref.watch(userDbProvider'),
      '放在 await 之后 ⇒ 可能撞上 provider 已销毁');

  // ── ② 回前台（`resumed`）必须**完整同步** ──
  final appSrc = readFile('../../app/lib/app.dart');
  check('🔴 `didChangeAppLifecycleState` 处理 `resumed`',
      RegExp(r'state\s*==\s*AppLifecycleState\.resumed')
          .hasMatch(appSrc));
  check('🔴 `resumed` 走的是**完整同步**（`syncWhenAppResumed`），不是只推',
      appSrc.contains('syncWhenAppResumed(ref)'));
  check('🔑 `paused`（进后台）仍保持**只推**（要快，不拖住退出）',
      appSrc.contains('pushWhenAppPaused(ref)'));
  final syncProvSrc3 = syncProvider;
  // 🔴 **必须切片**，不能用「函数名 + 大窗口正则」——
  //    第一版写成 `RegExp(r"void syncWhenAppResumed[\s\S]{0,320}?pushOnly: false")`，
  //    **证伪时没抓住**：把该函数里的 `false` 改成 `true`，正则**越过了函数边界**、
  //    匹配到紧接着的 `syncNowFromUi` 里的 `pushOnly: false` ⇒ **假绿**。
  //    📌 判据（本文件家族已记）：**子串断言会被别处兜住**；能切片就切片。
  //    🔑 切片的边界用「**下一个函数定义**」而不是「若干字符」——
  //       上界由结构给出，而不是猜一个够大的数字。
  final resumedBody =
      between(syncProvSrc3, 'void syncWhenAppResumed(', 'Future<void> syncNowFromUi(');
  check('🔴 切片有效（**上界真的截住了** —— 不含下一个函数的名字）',
      resumedBody.isNotEmpty &&
          resumedBody.contains('_runSync') &&
          !resumedBody.contains('syncNowFromUi'),
      '长 ${resumedBody.length} —— 🔴 未截住上界 ⇒ 切片跑到文件尾 ⇒ 下面的断言会被'
          '**下一处同名串兜住**（假绿）。⚠️ 边界串必须与真实签名逐字一致'
          '（本文件已在这上面栽过两次）');
  check('🔴 `syncWhenAppResumed` 用 `pushOnly: false`（**会拉** —— 本条的要点）',
      resumedBody.contains('pushOnly: false'),
      '写成 true ⇒ 回前台只推不拉 ⇒ 两端永远看不见对方的改动（本条的原始症状）');

  // ── ③ 复习页下拉刷新：**先拉云端**再重算本地 ──
  final reviewSrc = readFile('../../app/lib/screens/review_screen.dart');
  check('🔴 复习页有 `RefreshIndicator`（白哥要求：「下拉应该可以手动刷新才对」）',
      reviewSrc.contains('RefreshIndicator('));
  // 🔑 切片（同上）：`_pullToRefresh` 的函数体 = 从定义到下一个 `Widget ` 方法
  final pullBody = between(
      reviewSrc, 'Future<void> _pullToRefresh(', 'Widget _alwaysScrollable(');
  check('🔴 切片有效（**上界真的截住了**）',
      pullBody.isNotEmpty &&
          pullBody.contains('reviewListProvider') &&
          !pullBody.contains('_alwaysScrollable('),
      '长 ${pullBody.length} —— 未截住上界 ⇒ 切片跑到文件尾 ⇒ 会被别处兜住（假绿）');
  check('🔴 下拉**先调同步**（`syncNowFromUi`）—— 只重算本地是「骗人的仪式」',
      pullBody.contains('await syncNowFromUi(ref)'));
  check('🔑 空态/错误态也**可下拉**（否则「没有待复习」那一屏下拉失效）',
      reviewSrc.contains('_alwaysScrollable') &&
          reviewSrc.contains('AlwaysScrollableScrollPhysics'),
      '内容不满一屏时不可滚动 ⇒ RefreshIndicator 不响应');

  _report();
}

void _report() {
  print('');
  print('═' * 74);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 最可能的原因：有人动了「云端同步」的某一层 ——');
    print('    表 DDL（PK 少 user_id ⇒ **多用户互相覆盖**）· 注销清单（漏表 ⇒ 隐私政策失实）·');
    print('    handler 鉴权/订阅（漏 ⇒ anyone 能读别人数据 或 免费同步）· 路由注册。');
    print('    见本文件头部「证伪方式」表。');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}

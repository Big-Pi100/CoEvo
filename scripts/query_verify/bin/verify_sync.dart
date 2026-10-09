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
  final cursorKeys =
      syncProvider.split('kSyncCursorPrefsKeyPrefix').length - 1;
  check('🔴 游标键**读、写两处都**带 `userId`（用计数锁，不是存在性）',
      cursorKeys >= 2, '实得 $cursorKeys 处（应为 2：readCursor + writeCursor）');
  check('  且**没有**残留的固定键字面量',
      !syncProvider.contains("'coevo_sync_since'"),
      '—— 留一处就会「写固定键、读 userId 键」⇒ 永远全量拉，且不报错');
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
    check('push 收集待推划线（`HighlightRepository.pending()`）',
        syncService.contains('await hl.pending()'));
    check('push 计入 `pushedHighlights`（漏 ⇒ 「本轮只同步了笔记」被判成「什么都没做」）',
        syncService.contains('r.pushedHighlights = highlights.length'));
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

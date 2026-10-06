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

// CoEvo · 划线卡「译文提示」验收断言（v1.12 · 2026-10-11）
//
// # 它覆盖什么
// 白哥定：复习划线卡时 **译文与首字母骨架「同时」显示**（不是替换），
// 译文落进 `highlight.translation` 并**参与同步**；另提供「批量补译」入口。
//
// # 🔑 本脚本的重点是**行为断言**而不是文本断言
// `mergeHighlight` / `_pickTranslation` 是**纯函数**（`sync_merge.dart` 零 Flutter 依赖）
// ⇒ 可以**真调用来验**，比 grep 源码字符串强得多：
//   · 「有值者胜」
//   · **对称性**（`f(a,b) == f(b,a)`）—— merge 必须收敛，否则两端永远同步不完
// 文本断言只用于那些「没有可执行入口」的点（SQL 语句、UI 布局、迁移分支）。
//
// 跑法：`dart run bin/verify_highlight_translation.dart`
import 'dart:io';

import '../../../app/lib/services/sync_merge.dart' as m;

int _pass = 0;
final List<String> _failures = [];

void check(String label, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
  } else {
    _failures.add('$label${detail == null ? '' : ' —— $detail'}');
  }
}

String readFile(String rel) => File(rel).readAsStringSync();

/// 截取 `[start, end)` 之间的正文（找不到任一端 ⇒ 空串，由调用方的「切片有效」断言兜住）。
String between(String src, String startAnchor, String endAnchor) {
  final a = src.indexOf(startAnchor);
  if (a < 0) return '';
  final b = src.indexOf(endAnchor, a + startAnchor.length);
  if (b < 0) return '';
  return src.substring(a, b);
}

/// 造一行 highlight（合并测试用）。
Map<String, Object?> hl({
  String id = 'h1',
  String text = 'hello world',
  String? translation,
  String created = '2026-10-01T00:00:00.000Z',
  String updated = '2026-10-01T00:00:00.000Z',
}) =>
    {
      'id': id,
      'source_type': 'article',
      'source_id': '42',
      'chapter_idx': null,
      'start_offset': 0,
      'end_offset': 11,
      'text': text,
      'note': null,
      'paused': 0,
      'deleted': 0,
      'translation': translation,
      'created_at': created,
      'updated_at': updated,
    };

void main() {
  final schemaSql = readFile('../../app/assets/sql/user_db_schema.sql');
  final userDb = readFile('../../app/lib/services/user_db.dart');
  final repo = readFile('../../app/lib/services/highlight_repository.dart');
  final merge = readFile('../../app/lib/services/sync_merge.dart');
  final syncSvc = readFile('../../app/lib/services/sync_service.dart');
  final reviewScreen = readFile('../../app/lib/screens/review_session_screen.dart');
  final profileScreen = readFile('../../app/lib/screens/profile_screen.dart');
  final backfill = readFile('../../app/lib/providers/highlight_translate_provider.dart');
  final serverSchema = readFile('../../backend/crates/api_server/src/schema.rs');
  final serverMain = readFile('../../backend/src/main.rs');
  final serverHandlers = readFile('../../backend/crates/api_server/src/sync_handlers.rs');

  // ══════════════════════════════════════════════════════════════
  print('【1】端侧 schema v12 —— 列 / 版本号 / 迁移分支');
  // ══════════════════════════════════════════════════════════════
  final hlTable = between(schemaSql, 'CREATE TABLE IF NOT EXISTS highlight (', '\n);');
  check('① highlight 表已包含 translation 列', hlTable.contains('translation'));
  check(
    '🔴 且它是**最后一列**（ALTER 只能追加 ⇒ 新库/升级库列顺序必须一致）',
    // ⚠️ `between()` 的 end 锚点是 `\n);` ⇒ **切片不含** `);`
    //    ⇒ 判据要写成「切片的**最后一行**就是这一列」，不能再要求后面有 `);`
    //   （本人第一版就是这么写错的：断言要求 `\);`，而它根本不在切片里 ⇒ **假红**）。
    RegExp(r'translation\s+TEXT\s*$').hasMatch(hlTable.trimRight()),
    '若中间还插了别的列，老库 ALTER 追加后顺序会与新库不同',
  );
  check('② 版本号已升到 12（不升 ⇒ 老库不触发 onUpgrade ⇒ 列加不上，静默）',
      userDb.contains('const int kUserDbVersion = 12;'));
  check('③ onUpgrade 有 `oldVersion < 12` 分支', userDb.contains('if (oldVersion < 12) {'));
  final upgradeBlock = between(userDb, 'if (oldVersion < 12) {', '\n        }');
  check('④ 该分支里真的 ADD COLUMN translation（不是空分支）',
      upgradeBlock.contains("column: 'translation'"), '实得切片长 ${upgradeBlock.length}');
  check(
    '⑤ 🔴 `TEXT` 且**不带 NOT NULL / DEFAULT** —— NULL 是「还没译文」的可辨识状态',
    RegExp(r"ddl: 'TEXT'").hasMatch(upgradeBlock),
    '给了 DEFAULT 就分不出「没有译文」与「译文是空的」',
  );

  // ══════════════════════════════════════════════════════════════
  print('');
  print('【2】端侧仓储 —— 序列化 / 写入刷新 / 缺译文查询口径');
  // ══════════════════════════════════════════════════════════════
  final pushRow = between(repo, 'Map<String, Object?> toPushRow() => {', '};');
  check("① toPushRow 带 'translation'（漏了 ⇒ 同步静默传空）",
      pushRow.contains("'translation': translation"));

  check('② Highlight 模型有 translation 字段', repo.contains('final String? translation;'));
  final withNote = between(repo, 'Highlight withNote(String? newNote) => Highlight(', ');');
  check(
    '🔴 ③ `withNote` 复制了 translation（漏 ⇒ **改笔记会把译文清空**）',
    withNote.contains('translation: translation'),
    '不可变模型的副本必须逐字段复制',
  );

  final setTr = between(repo, 'Future<void> setTranslation(', '\n  }');
  check('④ setTranslation 存在', setTr.isNotEmpty, '切片长 ${setTr.length}');
  check(
    '🔴🔴 ⑤ setTranslation **刷 updated_at** —— 不刷则服务端 upsert 的 WHERE 不成立 ⇒ 整条更新被跳过'
        '（静默：本地有译文、云端永远没有）',
    setTr.contains('updated_at = \$kSqlNowUtc'),
  );
  check('🔴 ⑥ setTranslation **刷 pending_push** —— 不刷则这次变更永远不会被推送',
      setTr.contains('pending_push = 1'));
  check('⑦ setTranslation 落库前 trim（空白按「没有」处理）', setTr.contains('.trim()'));

  final without = between(repo, 'Future<List<Highlight>> withoutTranslation(', '\n  }');
  check('⑧ withoutTranslation 存在', without.isNotEmpty);
  check(
    '🔴 ⑨ 判空口径 = `NULL` **或 TRIM 后为空串**（与消费点/服务端三处必须一致）',
    without.contains('translation IS NULL') && without.contains("TRIM(translation) = ''"),
    '只判 NULL ⇒ 空串会被当成「有译文」⇒ 复习页永远显示空白提示',
  );
  check('⑩ 只取未删除的（已取消的划线补译是白花钱）', without.contains('deleted = 0'));

  // ══════════════════════════════════════════════════════════════
  print('');
  print('【3】合并口径 —— **真调用**验证（不是 grep）');
  // ══════════════════════════════════════════════════════════════
  // ① 一端有值、一端为 null ⇒ 取有值的那个
  final onlyLocal = m.mergeHighlight(hl(translation: '你好'), hl(translation: null));
  check('① 本地有译文、远端没有 ⇒ 结果保留译文', onlyLocal['translation'] == '你好',
      '实得 ${onlyLocal['translation']}');
  final onlyRemote = m.mergeHighlight(hl(translation: null), hl(translation: '你好'));
  check('② 远端有译文、本地没有 ⇒ 结果保留译文', onlyRemote['translation'] == '你好',
      '实得 ${onlyRemote['translation']}');

  // ③ 两端都有值 ⇒ 结果**必须与参数顺序无关**（对称 ⇒ merge 收敛）
  final both1 = m.mergeHighlight(
      hl(translation: 'AAA', updated: '2026-10-02T00:00:00.000Z'),
      hl(translation: 'BBB', updated: '2026-10-01T00:00:00.000Z'));
  final both2 = m.mergeHighlight(
      hl(translation: 'BBB', updated: '2026-10-01T00:00:00.000Z'),
      hl(translation: 'AAA', updated: '2026-10-02T00:00:00.000Z'));
  check(
    '🔴🔴 ③ 两端都有值时，结果**与参数顺序无关**（对称 ⇒ 两端 merge 收敛）',
    both1['translation'] == both2['translation'],
    'left=${both1['translation']} · right=${both2['translation']}'
        ' —— 不对称 ⇒ 每次同步都认为「对方有新东西」⇒ **永远同步不完**',
  );

  // ④ 空串按「没有」处理（不能把别端的译文抹成空）
  final withBlank = m.mergeHighlight(hl(translation: '   '), hl(translation: '你好'));
  check('④ 空白串按「没有」处理 ⇒ 不会把另一端的译文抹掉',
      withBlank['translation'] == '你好', '实得 ${withBlank['translation']}');

  // ⑤ 都不存在 ⇒ null（不是空串）
  final noneBoth = m.mergeHighlight(hl(translation: null), hl(translation: null));
  check('⑤ 两端都没有 ⇒ null（**不是空串** —— 空串会与消费口径打架）',
      noneBoth['translation'] == null, '实得 ${noneBoth['translation']}');

  // ══════════════════════════════════════════════════════════════
  print('');
  print('【4】同步契约 —— 三个 JSON 映射 + 写入列 + 服务端');
  // ══════════════════════════════════════════════════════════════
  final toPush = between(merge, 'Map<String, Object?> highlightToPushJson(', '};');
  check("① highlightToPushJson 带 'translation'", toPush.contains("'translation': r['translation']"));
  final fromPull = between(merge, 'Map<String, Object?> highlightFromPullJson(', '};');
  check("② highlightFromPullJson 带 'translation'", fromPull.contains("'translation': j['translation']"));
  check('③ `kSyncFieldSources` 登记了 highlight.translation',
      merge.contains("('highlight', 'translation')"));
  check('④ `kPushJsonContract` 的 highlight 契约含 translation',
      RegExp(r"'highlight': \[[\s\S]*?'translation'").hasMatch(merge));

  final upsert = between(syncSvc, 'Future<void> _upsertHighlight(', '\n  }');
  check('⑤ `_upsertHighlight` 的列清单含 translation',
      upsert.contains('paused, translation)'), '实得切片长 ${upsert.length}');
  check('⑥ 且 ON CONFLICT 里也写 translation = excluded.translation',
      upsert.contains('translation  = excluded.translation'));

  check('⑦ 服务端 `HighlightInput` 有 translation 且 `#[serde(default)]`'
      '（缺它 ⇒ 老端侧推上来的批次**整个 400**）',
      RegExp(r'#\[serde\(default\)\]\s*\n\s*pub translation: Option<String>')
          .hasMatch(serverHandlers));
  check('⑧ 服务端 pull 的 SELECT 含 translation',
      serverHandlers.contains('updated_at, translation'));
  check(
    '🔴 ⑨ 服务端 upsert 用 `COALESCE(NULLIF(TRIM(...)))` 而**不是**直取'
        '（直取 ⇒ 一端没有译文时会把别端刚补的抹掉）',
    serverHandlers.contains('COALESCE(NULLIF(TRIM(excluded.translation)'),
    '这是本批最容易写错的一处',
  );
  check('⑩ 服务端 `schema.rs` 的新库 DDL 也有该列',
      between(serverSchema, 'CREATE TABLE IF NOT EXISTS sync_highlight (', '\n);')
          .contains('translation'));
  check('🔴 ⑪ 服务端 `main.rs` 有老库的 ALTER（只改 schema.rs ⇒ 线上库里没有这列）',
      serverMain.contains('ALTER TABLE sync_highlight ADD COLUMN translation TEXT'));

  // ══════════════════════════════════════════════════════════════
  print('');
  print('【5】复习页 —— 译文与骨架**同时**显示（不是替换）');
  // ══════════════════════════════════════════════════════════════
  final prompt = between(reviewScreen, 'class _HighlightPrompt', '\n/// 划线卡的**结果');
  check('① 切片有效（截到 `_HighlightPrompt` 类体）',
      prompt.length > 500 && prompt.contains('skeletonFor'), '切片长 ${prompt.length}');
  check('② 读了 highlight.translation', prompt.contains('highlight.translation'));
  check('🔴 ③ **同时**渲染译文与骨架（两者都在 children 里，不是二选一）',
      prompt.contains('if (hasTranslation)') && prompt.contains('skeleton,'),
      '白哥定的是「同时存在」，不是「有译文就不显示骨架」');
  check('④ 没有译文时**不占位、不显示提示文案**（空态不是错误态）',
      // 🔴 只能用「`Text(...)` 的实参」作判据 —— 不能写 `!prompt.contains('暂无译文')`：
      //    本项目**注释里**恰好写着「不显示『暂无译文』」⇒ 那种写法会被**自己的注释**触发 ⇒ **假红**
      //    （判据：注释里的提及**既会假绿也会假红**，第一版就是这么错的）。
      !RegExp(r"""Text\(\s*'[^']*暂无译文""").hasMatch(prompt),
      '空态画一句「暂无译文」会让用户以为坏了');

  // ══════════════════════════════════════════════════════════════
  print('');
  print('【6】批量补译 —— 成本护栏与如实回报');
  // ══════════════════════════════════════════════════════════════
  check('① 逐条**串行**（for 循环逐个 await，不是 Future.wait 并发）',
      backfill.contains('for (var i = 0; i < pending.length; i++)') &&
          !backfill.contains('Future.wait'));
  check('🔴 ② 额度用尽 ⇒ **停止**（继续只会连续 403，浪费时间且提示混乱）',
      backfill.contains('case TranslateQuotaExceeded') && backfill.contains('break'));
  check('③ 登录失效 ⇒ 也停止（让用户去登录，而不是逐条失败）',
      backfill.contains('case TranslateNeedLogin'));
  check('🔴 ④ 结果**区分三种结局**（全成 / 额度中断 / 部分失败），不收成一句「完成了」',
      backfill.contains('bool get allDone') && backfill.contains('bool get stopped'));
  check('⑤ 复用 `translateWithCache`（缓存命中不花钱 ⇒ 重复点不会重复扣额度）',
      backfill.contains('translateWithCache(ref,'));
  check('⑥ 写完译文调 `setTranslation`（走仓储，保证刷 updated_at/pending_push）',
      backfill.contains('repo.setTranslation('));

  final tile = between(profileScreen, 'Widget _buildMemoryTile()', '\n  /// 退出前二次确认');
  check('🔴 ⑦ 入口在「记忆」卡片里（语义归属 = 记忆；低频 ⇒ 设置页，不占主界面）',
      tile.contains('_buildBackfillRow'));
  check('⑧ 补译完成后**重算条数**（否则那一行还停在旧数字）',
      profileScreen.contains('ref.invalidate(highlightTranslationPendingCountProvider)'));
  check('⑨ 计数 provider 订阅了 revision（写库后自动重算）',
      backfill.contains('ref.watch(userDbRevisionProvider)'));

  // ══════════════════════════════════════════════════════════════
  print('');
  print('─' * 74);
  if (_failures.isEmpty) {
    print('🎉 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 共 ${_pass + _failures.length} 项');
    for (final f in _failures) {
      print('    · $f');
    }
    exit(1);
  }
}

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
import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/highlight_repository.dart';
import '../../../app/lib/services/sync_merge.dart' as m;
import '../../../app/lib/services/translate_parse.dart' as tp;
import '../../../app/lib/services/user_db.dart' show executeSqlScript;

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

/// 数 [needle] 在 [src] 里出现的次数（用于「只有一处」这类判据）。
int countOf(String src, String needle) {
  var n = 0;
  var i = 0;
  while (true) {
    final k = src.indexOf(needle, i);
    if (k < 0) return n;
    n++;
    i = k + needle.length;
  }
}

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

Future<void> main() async {
  // 🔴 初始化一次即可（§8 要用**真库**验证 `add()` 的译文语义）
  sqfliteFfiInit();

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
  print('【7】🔴 「翻译浮层 → 划线」把译文带进库（本组是 2026-10-11 真机反馈的守护）');
  // ══════════════════════════════════════════════════════════════
  // 白哥真机：「划线后笔记中没有记录译文，复习时也没有译文提示」。
  // 根因：**译文根本没有写入路径** —— 全仓只有「批量补译」会写 `setTranslation`，
  //       而翻译浮层点「划线记住这段」时**译文当场被丢**（`onRemember` 是无参回调）。
  final ts = readFile('../../app/lib/widgets/translation_sheet.dart');
  final sel = readFile('../../app/lib/widgets/word_lookup_selection.dart');
  final enq = readFile('../../app/lib/services/highlight_enqueue.dart');
  final hlListScreen = readFile('../../app/lib/screens/highlights_screen.dart');
  final parse = readFile('../../app/lib/services/translate_parse.dart');

  // ── ① 拼接口径**只有一处**（真调用，不是 grep）──
  check('① `translationTextOf` 是公开顶层函数（两条路径共用它）',
      parse.contains('String? translationTextOf(List<TransSegment> segments)'));
  final tEmpty = tp.translationTextOf(const []);
  check(
      '🔴 ② 全空 ⇒ **null**（不是空串 —— 空串会被「有值者胜」当成有值 ⇒ 抹掉别端译文）',
      tEmpty == null,
      '实得 ${tEmpty == null ? 'null' : '"$tEmpty"'}');
  final tBlank =
      tp.translationTextOf(const [tp.TransSegment(src: 'a', dst: '   ')]);
  check('③ 只有空白段 ⇒ null', tBlank == null, '实得 $tBlank');
  final tMulti = tp.translationTextOf(const [
    tp.TransSegment(src: 'a', dst: '第一句'),
    tp.TransSegment(src: 'b', dst: '  '),
    tp.TransSegment(src: 'c', dst: ' 第二句 '),
  ]);
  check('④ 多段：丢空段 + 逐段 trim + 换行连接', tMulti == '第一句\n第二句',
      '实得 ${jsonEncode(tMulti)}');

  // ── ② 两条路径都复用它（各写一份 ⇒ 口径分叉）──
  check('🔴 ⑤ 翻译浮层调用 `translationTextOf(segments)`（不是自己拼）',
      ts.contains('translationTextOf(segments)'));
  check('🔴 ⑥ 批量补译调用 `translationTextOf(segments)`（不是自己拼）',
      backfill.contains('translationTextOf(segments)'));
  // ⚠️ 计数前**必须剥掉整行注释** —— 否则注释里提到 `.map((s) => s.dst` 就会**假红**
  //    （本人第一版正是如此）。剥法**只按整行**（判据：「剥注释只能按整行」；
  //    行内 `//` 与字符串里的 `//` 本项目不需要处理）。
  String codeOnly(String src) => src
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');
  final parseCode = codeOnly(parse);
  final tsCode = codeOnly(ts);
  final backfillCode = codeOnly(backfill);
  check(
      '⑦ `translationTextOf` 只有一处定义，且三条路径都不再自己拼 `dst`（计数已剥注释）',
      countOf(parseCode, 'String? translationTextOf') == 1 &&
          countOf(tsCode, '.map((s) => s.dst') == 0 &&
          countOf(backfillCode, '.map((s) => s.dst') == 0,
      '实得 def=${countOf(parseCode, 'String? translationTextOf')} '
          'ts=${countOf(tsCode, '.map((s) => s.dst')} '
          'backfill=${countOf(backfillCode, '.map((s) => s.dst')}');

  // ── ③ UI 链：浮层传出译文 ⇒ 入队接住 ⇒ 透传到仓储 ──
  check(
      '🔴 ⑧ `onRemember` 能带出译文（`ValueChanged<String?>` —— 原为无参 `VoidCallback`，'
          '译文正是在这一步被丢掉的）',
      RegExp(r'ValueChanged<String\?>\? onRemember').hasMatch(ts));
  final readyBtn = between(ts, "label: '划线记住这段'", 'widget.onRemember!(');
  check('⑨ 点按钮时**真的算了译文**（切片为 0 ⇒ 锚点失配）',
      readyBtn.contains('translationTextOf(segments)'),
      '切片长 ${readyBtn.length}');
  // ⚠️ 光「算了」不够 —— 还得**传出去**：写成 `onRemember!(null)` 时上面那条**照样绿**
  //    （判据：只断言到「有那个调用」= **假绿**）。这里锁**实参**。
  check('🔴 ⑨b 且**传出去的就是那个译文**（不是 `null`、不是别的变量）',
      ts.contains('widget.onRemember!(translation)'));
  check('⑩ 调用方把译文交给入队',
      sel.contains('_enqueueHighlight(text, translation: translation)'));
  check('⑪ `_enqueueHighlight` 签名收得下它',
      RegExp(r'_enqueueHighlight\(String text, \{String\? translation\}\)')
          .hasMatch(sel));
  check('⑫ `enqueueHighlight` 收得下并透传给 `repo.add`',
      RegExp(r'\s+String\? translation,').hasMatch(enq) &&
          enq.contains('translation: translation,'));

  // ── ④ 笔记页展示位（写了值却看不到 = 会让用户误判「没生效」）──
  check('🔴 ⑬ 笔记页**展开了才显示译文**（`expanded && hasTranslation`，收起态不塞）',
      hlListScreen.contains('if (expanded && hasTranslation)'));
  check('⑭ 且渲染的就是 `translation`',
      RegExp(r'Text\(\s*translation,').hasMatch(hlListScreen));

  // ══════════════════════════════════════════════════════════════
  print('');
  print('【8】仓储 `add()` 的译文语义 —— **真库真调用**');
  // ══════════════════════════════════════════════════════════════
  // ⚠️ end 锚点**不能**用 `\n  }` —— 方法头的 `  }) async {` 里就含 `\n  }`
  //    ⇒ 切片会在**参数表结束处**截断、压根不含方法体（本人第一版就是这么错的 ⇒ 假红）。
  //    🔑 改用「下一个方法的签名」当 end 锚点，并**显式断言切片有效**（含 `rawInsert`）：
  //       否则锚点一失配，后面的断言会静默变成「永远为假」，而报告上看不出是锚点问题。
  final addFn = between(repo, 'Future<void> add({',
      '  Future<List<Highlight>> listForSource({');
  check('① 切片有效（含方法体 `rawInsert`）', addFn.contains('rawInsert'),
      '切片长 ${addFn.length}');
  check('② `add()` 的 INSERT 列表含 translation（漏了 ⇒ 传进去也白传）',
      addFn.contains('text, note, translation, created_at'));
  check(
      '③ Dart 侧归一化空白（`translation.trim().isEmpty` ⇒ null）'
          '—— 归一化只能在这一侧做：SQLite 的 `TRIM` 只认 ASCII 空格',
      addFn.contains('translation.trim().isEmpty'));
  check(
      '🔴 ④ `ON CONFLICT` 用 `COALESCE(excluded.translation, highlight.translation)`'
          '（**只在有值时覆盖**）',
      addFn.contains('COALESCE(excluded.translation, highlight.translation)'));

  final dir = await Directory.systemTemp.createTemp('coevo_hl_add');
  final db = await databaseFactoryFfi.openDatabase(
    '${dir.path}/user.db',
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (d, _) => executeSqlScript(d, schemaSql),
    ),
  );
  final r = HighlightRepository(db);

  Future<void> addH(String id, {String? translation, String text = 'hello'}) =>
      r.add(
        id: id,
        sourceType: HighlightSourceType.article,
        sourceId: '1',
        startOffset: 0,
        endOffset: 5,
        text: text,
        translation: translation,
      );

  await addH('h-a', translation: '你好');
  final a = await r.byId('h-a');
  check('⑤ 带译文入库 ⇒ 读回来就是它', a?.translation == '你好',
      '实得 ${jsonEncode(a?.translation)}');

  await addH('h-b');
  final b = await r.byId('h-b');
  check('⑥ 不带译文 ⇒ **NULL**（不是空串）', b?.translation == null,
      '实得 ${jsonEncode(b?.translation)}');

  await addH('h-c', translation: '\u00a0  ');
  final c = await r.byId('h-c');
  check(
      '🔴 ⑦ 空白（含 NBSP `\\u00a0`）⇒ NULL —— 这条正是「归一化必须在 Dart 侧」的反例：'
          'SQLite 的 `TRIM()` 只剥 ASCII 空格 ⇒ 交给它就会把该值当有效译文存下来',
      c?.translation == null,
      '实得 ${jsonEncode(c?.translation)}');

  // 🔴🔴 本组最关键的一项
  await addH('h-d', translation: '你好');
  await r.remove('h-d'); // 软删（模拟「先取消、后重划」）
  await addH('h-d'); // ⚠️ 这次**没带译文**
  final d = await r.byId('h-d');
  check(
      '🔴🔴 ⑧ 重划同一条（`ON CONFLICT` 恢复路径）不带译文 ⇒ 原有译文必须保住'
          '（无条件取 `excluded.translation` 会把它清空，且**不报错**）',
      d?.translation == '你好' && d?.deleted == false,
      '实得 translation=${jsonEncode(d?.translation)} deleted=${d?.deleted}');

  await addH('h-d', translation: '哈喽');
  final d2 = await r.byId('h-d');
  check('⑨ 重划时带了新译文 ⇒ 正常覆盖旧值', d2?.translation == '哈喽',
      '实得 ${jsonEncode(d2?.translation)}');

  await db.close();
  await dir.delete(recursive: true);

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

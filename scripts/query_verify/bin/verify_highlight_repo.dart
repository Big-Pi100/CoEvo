// CoEvo · 划线仓储验收（**真库** · `sqflite_common_ffi`）
//
// 跑：cd scripts/query_verify && dart run bin/verify_highlight_repo.dart
// 🔴 退出码：0 = 全过，1 = 有失败（用 `; echo $?` 直读）。
//
// # 为什么必须用**真库**（而不是文本断言）
//
// 🔴 仓储里的 SQL 列名是**字符串字面量** —— 拼错一个字母，**Dart 编译器一声不吭**，
//    只有那条语句真跑时才炸（`no such column`）。
//    本脚本用**真 schema 建表 + 真跑每条语句** ⇒ 列名/表名/约束一次性全部验到。
//
// # 它专补「纯函数层验不到」的三样
// ① **软删与 upsert 的交互**（`INSERT OR IGNORE` 会让「取消过的划线」再也加不回来 —— 静默）
// ② **CHECK 约束真的生效**（`source_type` 只允许 article / book）
// ③ **时间列带 `Z`**（`parseUserDbUtc` 缺 `Z` 会抛 —— 静默时区错位比报错更难查）

import 'dart:io';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/highlight_enqueue.dart';
import '../../../app/lib/services/highlight_id.dart';
import '../../../app/lib/services/highlight_repository.dart';
import '../../../app/lib/services/review_list_query.dart';
import '../../../app/lib/services/user_db.dart';

var _pass = 0;
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

void section(String t) {
  print('');
  print('─' * 74);
  print(t);
  print('─' * 74);
}

/// 远古时刻 —— 用来**确定性地**验「某操作刷新了 `updated_at`」。
///
/// 🔴 为什么不直接比较「操作前后」：两次操作可能落在**同一毫秒**内
/// （`%f` 是毫秒精度）⇒ 结果相等 ⇒ **间歇性假红**。
/// ⇒ 把时间戳先改成远古值，再看它有没有被抬起来 —— 与执行速度**无关**。
final _kAncient = DateTime.utc(2020, 1, 1);

Future<void> _ageUpdatedAt(Database db, String id) async {
  await db.rawUpdate(
    "UPDATE highlight SET updated_at = '2020-01-01T00:00:00.000Z' WHERE id = ?",
    [id],
  );
}

/// **物理行数**（含已软删的）。
///
/// 🔴 与 `repo.count()` **不是一回事** —— 后者只数 `deleted = 0`。
/// 两者混用会得出反向结论：软删后「恢复」会让**未删计数 +1**（这是对的），
/// 而**物理行数不变**才是「没有多出第二行」的判据。
Future<int> _totalRows(Database db) async {
  final r = await db.rawQuery('SELECT COUNT(*) AS n FROM highlight');
  return (r.first['n'] as num).toInt();
}

Future<void> main() async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  final dir = await Directory.systemTemp.createTemp('coevo_hl_');
  final schemaSql =
      File('../../app/assets/sql/user_db_schema.sql').readAsStringSync();

  final db = await openUserDb(
    factory: factory,
    path: '${dir.path}/user.db',
    schemaSql: schemaSql,
  );
  final repo = HighlightRepository(db);

  try {
    // ══════════════════════════════════════════════════════════
    section('【1】空库');
    // ══════════════════════════════════════════════════════════
    check('新库计数为 0', await repo.count() == 0);
    check('新库清单为空', (await repo.listAll()).isEmpty);
    check('新库 pending 为空', (await repo.pending()).isEmpty);
    check('取不存在的 id ⇒ null', await repo.byId('nope') == null);

    // ══════════════════════════════════════════════════════════
    section('【2】新增（文章）—— 字段逐一回合');
    // ══════════════════════════════════════════════════════════
    await repo.add(
      id: 'a-1',
      sourceType: HighlightSourceType.article,
      sourceId: '123',
      startOffset: 40,
      endOffset: 78,
      text: 'attention. None of this is new, but the scale is.',
    );
    final a1 = await repo.byId('a-1');
    check('能取回', a1 != null);
    check('来源类型 = article', a1!.sourceType == HighlightSourceType.article);
    check('来源 id = "123"', a1.sourceId == '123');
    check('文章无章节 ⇒ chapterIdx 为 null', a1.chapterIdx == null);
    check('区间 [40,78)', a1.startOffset == 40 && a1.endOffset == 78);
    check('正文原样存回', a1.text == 'attention. None of this is new, but the scale is.');
    check('初始无笔记', a1.note == null);
    check('未删除', !a1.deleted);
    check('待同步 = 1', a1.pendingPush);
    check('🔴 时间列能过 `parseUserDbUtc`（即**带 Z**）', a1.createdAt.isUtc && a1.updatedAt.isUtc);
    check('计数 = 1', await repo.count() == 1);

    // ══════════════════════════════════════════════════════════
    section('【3】来源过滤 + 位置升序（正文渲染要按位置画）');
    // ══════════════════════════════════════════════════════════
    await repo.add(
      id: 'a-2',
      sourceType: HighlightSourceType.article,
      sourceId: '123',
      startOffset: 10,
      endOffset: 30,
      text: 'The habit of reading closely',
    );
    await repo.add(
      id: 'a-3',
      sourceType: HighlightSourceType.article,
      sourceId: '999',
      startOffset: 5,
      endOffset: 9,
      text: 'other article',
    );
    final forSrc = await repo.listForSource(
        sourceType: HighlightSourceType.article, sourceId: '123');
    check('只取该来源（2 条，不含 999 那条）', forSrc.length == 2, '实际 ${forSrc.length}');
    check('🔴 按 start_offset **升序**（渲染按位置画，不该再排一次）',
        forSrc.length == 2 && forSrc[0].startOffset == 10 && forSrc[1].startOffset == 40,
        forSrc.map((h) => h.startOffset).join(','));

    // ══════════════════════════════════════════════════════════
    section('【4】书：带章节，且**章节参与过滤**');
    // ══════════════════════════════════════════════════════════
    await repo.add(
      id: 'b-1',
      sourceType: HighlightSourceType.book,
      sourceId: 'book-uuid',
      chapterIdx: 3,
      startOffset: 7,
      endOffset: 20,
      text: 'It was the best of times',
    );
    await repo.add(
      id: 'b-2',
      sourceType: HighlightSourceType.book,
      sourceId: 'book-uuid',
      chapterIdx: 3,
      startOffset: 100,
      endOffset: 111,
      text: 'second highlight',
    );
    await repo.add(
      id: 'b-3',
      sourceType: HighlightSourceType.book,
      sourceId: 'book-uuid',
      chapterIdx: 7,
      startOffset: 1,
      endOffset: 9,
      text: 'another chapter',
    );
    final ch3 = await repo.listForSource(
        sourceType: HighlightSourceType.book, sourceId: 'book-uuid', chapterIdx: 3);
    check('按章过滤 ⇒ 只取第 3 章（2 条）', ch3.length == 2, '实际 ${ch3.length}');
    check('章的字段存得回', ch3.every((h) => h.chapterIdx == 3));
    final noChapter = await repo.listForSource(
        sourceType: HighlightSourceType.book, sourceId: 'book-uuid');
    check('不传章节 ⇒ 取全书（3 条）', noChapter.length == 3, '实际 ${noChapter.length}');
    check('书的来源类型 = book',
        (await repo.byId('b-1'))!.sourceType == HighlightSourceType.book);

    // ══════════════════════════════════════════════════════════
    section('【5】笔记（🔴 复习判定前不得显示 —— 那是数据消费方的责任，这里只验存取）');
    // ══════════════════════════════════════════════════════════
    await _ageUpdatedAt(db, 'a-1');
    await repo.setNote('a-1', '  这句是全文的主旨  ');
    final noted = (await repo.byId('a-1'))!;
    check('写笔记成功（且去掉首尾空白）', noted.note == '这句是全文的主旨', '实际 ${noted.note}');
    check('🔴 改笔记会刷新 updated_at（同步按时间戳判胜负）',
        noted.updatedAt.isAfter(_kAncient), noted.updatedAt.toIso8601String());
    await repo.setNote('a-1', '   ');
    check('只有空白 ⇒ 清除笔记（不是存一个空串）', (await repo.byId('a-1'))!.note == null);

    // ══════════════════════════════════════════════════════════
    section('【6】取消（软删）');
    // ══════════════════════════════════════════════════════════
    final beforeRemove = await repo.count();
    await _ageUpdatedAt(db, 'a-2');
    await repo.remove('a-2');
    check('🔴 计数恰好减 1', await repo.count() == beforeRemove - 1,
        '前 $beforeRemove → 后 ${await repo.count()}');
    check('清单不含已取消的', (await repo.listAll()).every((h) => h.id != 'a-2'));
    check('来源查询不含已取消的',
        (await repo.listForSource(sourceType: HighlightSourceType.article, sourceId: '123'))
            .every((h) => h.id != 'a-2'));
    final removed = await repo.byId('a-2');
    check('🔴 行**仍在**（软删，不是删行）且标记为已删',
        removed != null && removed.deleted);
    check('🔴 取消**也**刷新 updated_at（否则同步会丢弃这次取消）',
        removed!.updatedAt.isAfter(_kAncient), removed.updatedAt.toIso8601String());

    // ══════════════════════════════════════════════════════════
    section('【7】🔴🔴 软删之后**再划同一段**必须能恢复（upsert 陷阱）');
    // ══════════════════════════════════════════════════════════
    //
    // 若 `add` 用 `INSERT OR IGNORE`：PK 冲突 ⇒ 插入被忽略 ⇒ 那行仍是 `deleted = 1`
    // ⇒ **划线不生效**，而界面看着「点了没反应」（静默 —— 本项目最怕的一类）。
    final beforeRevive = await repo.count();
    final rowsBefore = await _totalRows(db);
    await repo.add(
      id: 'a-2',
      sourceType: HighlightSourceType.article,
      sourceId: '123',
      startOffset: 10,
      endOffset: 30,
      text: 'The habit of reading closely',
    );
    final revived = await repo.byId('a-2');
    check('🔴 曾被软删的 id 重新 add ⇒ **恢复**（deleted 归 0）',
        revived != null && !revived.deleted);
    check('恢复后重新出现在清单里',
        (await repo.listAll()).any((h) => h.id == 'a-2'));
    // 🔴 **物理行数**不变才是「没多出第二行」的判据（不是未删计数 —— 那个**应该** +1）
    check('🔴 恢复**不新增第二行**（物理行数不变）',
        await _totalRows(db) == rowsBefore,
        '恢复前 $rowsBefore → 后 ${await _totalRows(db)}');
    check('🔴 恢复后「未删」计数 +1（它真的回到清单里了）',
        await repo.count() == beforeRevive + 1,
        '前 $beforeRevive → 后 ${await repo.count()}');

    // ══════════════════════════════════════════════════════════
    section('【8】待同步 + 标记已同步');
    // ══════════════════════════════════════════════════════════
    final total = await repo.count();
    final pend = await repo.pending();
    check('🔴 pending 覆盖**全部**划线（含已软删的 —— 「删除」也要推出去）',
        pend.length == total, 'pending ${pend.length} / 未删 $total');
    await repo.markSynced(['a-1', 'a-2']);
    final after = await repo.pending();
    check('标记后恰好少 2 条', after.length == pend.length - 2,
        '前 ${pend.length} → 后 ${after.length}');
    check('标记是**定向**的（a-3 仍在）', after.any((h) => h.id == 'a-3'));
    await repo.markSynced([]);
    check('空列表不报错（边界）', (await repo.pending()).length == after.length);

    // ══════════════════════════════════════════════════════════
    section('【9】约束真的生效（不是只写在 DDL 里没人管）');
    // ══════════════════════════════════════════════════════════
    var rejected = false;
    try {
      await db.insert('highlight', {
        'id': 'bad-1',
        'source_type': 'video', // ← DDL 的 CHECK 只允许 article / book
        'source_id': 'x',
        'start_offset': 0,
        'end_offset': 1,
        'text': 'x',
      });
    } on DatabaseException {
      rejected = true;
    }
    check('🔴 CHECK 约束拒绝非法 source_type', rejected);

    // ══════════════════════════════════════════════════════════
    section('【11】入队 —— 一条划线同时进**两张表**');
    // ══════════════════════════════════════════════════════════
    final r1 = await enqueueHighlight(
      db: db,
      uuid: 'uuid-enq-1',
      sourceType: HighlightSourceType.article,
      sourceId: '777',
      startOffset: 5,
      endOffset: 25,
      text: 'a sentence worth remembering',
    );
    check('返回 ok', r1 == HighlightEnqueueResult.ok);
    check('① 划线本身写进去了', (await repo.byId('uuid-enq-1')) != null);
    check('① 位置原样存回',
        (await repo.byId('uuid-enq-1'))!.startOffset == 5 &&
            (await repo.byId('uuid-enq-1'))!.endOffset == 25);

    // ② 队列 —— 🔑 这是「划线能复习」的**唯一开关**
    final st = await ReviewListQuery(db).stateOf(highlightWordId('uuid-enq-1'));
    check('🔴 ② 队列里出现 `hl:<uuid>`（复习列表才认得它）', st != null);
    check('spelling 冗余列 = 正文摘录（复习列表那一行要能认出是哪条）',
        st != null && st.spelling.startsWith('a sentence worth'), '${st?.spelling}');
    check('state = 0（未学 —— 与查词入生词本同一档）', st?.state == 0);

    // 🔴 反向：**词库 id 与划线 id 不混淆**（`hl:` 前缀一旦写错，队列就永远取不到卡）
    check('🔴 队列键是 `hl:` 前缀（不是裸 uuid、也不是 `w`/`ext:`）',
        st != null && st.wordId == 'hl:uuid-enq-1', '${st?.wordId}');

    // ══════════════════════════════════════════════════════════
    section('【11b】🆕 暂停（2026-10-08）—— 🔴 暂停**不影响**正文与笔记页');
    // ══════════════════════════════════════════════════════════
    //
    // 🔴 这一节直接回答一个**很容易被误解**的问题：
    //    「暂停一条划线之后，原文里的下划线还在吗？」
    //
    //    · 生词的「暂停」= 离开复习视野，但**词还在生词本里**
    //    · 划线的「暂停」= 离开复习视野，但**原文的下划线必须还在**
    //      （`paused` 与 `deleted` 是两个语义 —— 后者才是「这条不要了」）
    //    ⇒ 所以 `listForSource`（正文渲染用）与 `listAll`（笔记页用）
    //      **都不过滤 `paused`**；只有**复习列表**过滤它。
    //
    // ⚠️ 若将来有人给这两处也加上 `paused = 0`，正文的下划线会**静默消失**
    //    （用户刚划过、又没删，却看不到线）—— 那正是本条要防的形态。

    final pId = 'uuid-pause-1';
    await repo.add(
      id: pId,
      sourceType: HighlightSourceType.article,
      sourceId: '888',
      startOffset: 0,
      endOffset: 10,
      text: 'pause me',
    );
    check('新插入的划线默认**未暂停**（`paused` 默认 0）',
        (await repo.byId(pId))!.paused == false);

    final pausedOk = await repo.pause(highlightWordId(pId));
    check('🔴 `pause(hl:<id>)` 返回 true（本次真的改了状态）', pausedOk);
    check('库里 `paused` 已置 1', (await repo.byId(pId))!.paused == true);

    // 🔴🔴 **核心两条**：暂停后，正文与笔记页**都必须还能看到它**
    final stillInSource = await repo.listForSource(
        sourceType: HighlightSourceType.article, sourceId: '888');
    check('🔴🔴 正文的来源查询**仍然返回**它（暂停 ≠ 删线）',
        stillInSource.any((h) => h.id == pId),
        '若红 ⇒ 暂停会让原文的下划线消失（用户会以为「划的线没了」）');
    check('🔴🔴 笔记页的全量查询**仍然返回**它（要能看见「已暂停」并恢复）',
        (await repo.listAll()).any((h) => h.id == pId));

    // 幂等 + 只管自己那类 id
    check('幂等：重复 `pause` 第二次返回 false（本来就已经暂停）',
        (await repo.pause(highlightWordId(pId))) == false);
    check('🔴 传生词 id（`w1`）返回 false —— **不归划线仓储管**',
        (await repo.pause('w1')) == false);

    final resumedOk = await repo.resume(highlightWordId(pId));
    check('`resume(hl:<id>)` 返回 true', resumedOk);
    check('库里 `paused` 已回 0', (await repo.byId(pId))!.paused == false);
    check('幂等：重复 `resume` 第二次返回 false',
        (await repo.resume(highlightWordId(pId))) == false);

    // 已取消的划线不该被暂停 / 恢复
    await repo.remove(pId);
    check('🔴 已取消（软删）的划线：`pause` 返回 false（它已经不在视野里）',
        (await repo.pause(highlightWordId(pId))) == false);
    check('取消后：正文来源查询**不再返回**它（这才是「线没了」的正确路径）',
        !(await repo.listForSource(
                sourceType: HighlightSourceType.article, sourceId: '888'))
            .any((h) => h.id == pId));

    // ══════════════════════════════════════════════════════════
    section('【12】其它');
    // ══════════════════════════════════════════════════════════
    check('未知来源类型解析 ⇒ 抛错（不静默回落）', () {
      try {
        HighlightSourceType.parse('video');
        return false;
      } catch (_) {
        return true;
      }
    }());
    final long = (await repo.byId('a-1'))!;
    check('excerpt 单行化 + 截断', !long.excerpt.contains('\n'));

    // 🔴 列名一致性：本脚本全程用真库跑 ⇒ 仓储里任何 SQL 列名写错都会在上面某一步
    //    直接抛 `no such column`。这里再显式确认一遍「查全部列不报错」。
    var allColsOk = true;
    try {
      await db.query('highlight', limit: 1);
    } catch (_) {
      allColsOk = false;
    }
    check('🔴 全列查询不报错（SQL 列名与 schema 一致）', allColsOk);
  } finally {
    await db.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  print('');
  print('=' * 68);
  print('通过 $_pass 项，失败 ${_failures.length} 项');
  if (_failures.isNotEmpty) {
    print('\n失败项：');
    for (final f in _failures) {
      print('  🔴 $f');
    }
    exit(1);
  }
  print('✅ 划线仓储全部通过');
  exit(0);
}

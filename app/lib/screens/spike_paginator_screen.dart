import 'package:flutter/material.dart';

import '../widgets/foliate_reader_view.dart';

/// 🔬 翻页阅读器 **spike 页面**（2026-10-22）。
///
/// # 目的
/// 在真机上验证三件事，**验完再决定要不要全量替换现有阅读器**：
/// 1. 翻页手感（foliate 的 CSS 多栏分页在 iOS WebView 里顺不顺）
/// 2. 主题注入（三档颜色能不能干净切换，不闪白）
/// 3. 选词回传（长按选中 → Flutter 能不能拿到文本）
///
/// # 为什么是独立页面
/// 主流程一行没动 —— 它就是「先有可看的目标」：手感不行就撤，损失控制在这个文件里。
///
/// ⚠️ 内置文本是**手写的英文长文**（与真书同样是 `<p>` 段落结构），
///    目的是能把页数撑到 6 页以上，好看清分页是否连续。
class SpikePaginatorScreen extends StatefulWidget {
  const SpikePaginatorScreen({super.key});

  @override
  State<SpikePaginatorScreen> createState() => _SpikePaginatorScreenState();
}

class _SpikePaginatorScreenState extends State<SpikePaginatorScreen> {
  final _c = FoliateReaderController();
  int _themeIdx = 0;
  String? _error;

  static const _themes = <({String name, String bg, String fg})>[
    (name: '墨', bg: '#F5F0E8', fg: '#3A332C'),
    (name: '格', bg: '#FBFAF6', fg: '#2E2C28'),
    (name: '夜', bg: '#1C1B19', fg: '#D9D3C7'),
  ];

  @override
  void initState() {
    super.initState();
    // 等 WebView 的 ready 消息到达后再喂内容（controller 内部会缓存）。
    _c.setChapters(_demoChapters);
    _c.lastError.addListener(_onErr);
    _c.selectedText.addListener(_onSel);
  }

  void _onErr() {
    final e = _c.lastError.value;
    if (e != null && mounted) setState(() => _error = e);
  }

  void _onSel() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c.lastError.removeListener(_onErr);
    _c.selectedText.removeListener(_onSel);
    super.dispose();
  }

  Future<void> _cycleTheme() async {
    setState(() => _themeIdx = (_themeIdx + 1) % _themes.length);
    final t = _themes[_themeIdx];
    await _c.setTheme(background: t.bg, foreground: t.fg);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F0E8),
      body: SafeArea(
        child: Column(
          children: [
            _bar(),
            Expanded(
              child: FoliateReaderView(
                controller: _c,
                onError: (m) => setState(() => _error = m),
              ),
            ),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _bar() => Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        color: const Color(0xFFFBF7F1),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => Navigator.of(context).pop(),
            ),
            const Expanded(
              child: Text('翻页 spike',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            TextButton(
              onPressed: _cycleTheme,
              child: Text('主题：${_themes[_themeIdx].name}'),
            ),
          ],
        ),
      );

  Widget _footer() => Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        color: const Color(0xFFFBF7F1),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('⚠️ $_error',
                    style: const TextStyle(fontSize: 11, color: Color(0xFFB4432C))),
              ),
            ValueListenableBuilder<FoliatePosition>(
              valueListenable: _c.position,
              builder: (_, p, __) => Text(
                '第 ${p.sectionIndex + 1} 节 · 节内第 ${p.pageInSection} 页 · ${(p.fraction * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 11, color: Color(0xFF6B6154)),
              ),
            ),
            const SizedBox(height: 6),
            ValueListenableBuilder<String?>(
              valueListenable: _c.selectedText,
              builder: (_, s, __) => Text(
                s == null || s.isEmpty ? '长按正文选一个词试试' : '选中的词：$s',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: s == null || s.isEmpty
                      ? const Color(0xFF8A7F70)
                      : const Color(0xFFB4432C),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _c.previousPage,
                    child: const Text('上一页'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _c.nextPage,
                    child: const Text('下一页'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  /// 演示文本（真实段落结构；足够撑 6+ 页）。
  static const _demoChapters = <String>[
    '<h2>Chapter I. Down the Rabbit-Hole</h2>'
        '<p>Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do: once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it, "and what is the use of a book," thought Alice, "without pictures or conversations?"</p>'
        '<p>So she was considering in her own mind (as well as she could, for the hot day made her feel very sleepy and stupid), whether the pleasure of making a daisy-chain would be worth the trouble of getting up and picking the daisies, when suddenly a White Rabbit with pink eyes ran close by her.</p>'
        '<p>There was nothing so very remarkable in that; nor did Alice think it so very much out of the way to hear the Rabbit say to itself, "Oh dear! Oh dear! I shall be late!" But when the Rabbit actually took a watch out of its waistcoat-pocket, and looked at it, and then hurried on, Alice started to her feet, for it flashed across her mind that she had never before seen a rabbit with either a waistcoat-pocket, or a watch to take out of it.</p>'
        '<p>Burning with curiosity, she ran across the field after it, and fortunately was just in time to see it pop down a large rabbit-hole under the hedge. In another moment down went Alice after it, never once considering how in the world she was to get out again.</p>'
        '<p>The rabbit-hole went straight on like a tunnel for some way, and then dipped suddenly down, so suddenly that Alice had not a moment to think about stopping herself before she found herself falling down a very deep well.</p>'
        '<p>Either the well was very deep, or she fell very slowly, for she had plenty of time as she went down to look about her and to wonder what was going to happen next. First, she tried to look down and make out what she was coming to, but it was too dark to see anything; then she looked at the sides of the well, and noticed that they were filled with cupboards and book-shelves; here and there she saw maps and pictures hung upon pegs.</p>'
        '<p>She took down a jar from one of the shelves as she passed; it was labelled "ORANGE MARMALADE", but to her great disappointment it was empty: she did not like to drop the jar for fear of killing somebody underneath, so managed to put it into one of the cupboards as she fell past it.</p>'
        '<p>"Well!" thought Alice to herself, "after such a fall as this, I shall think nothing of tumbling down stairs! How brave they will all think me at home! Why, I would not say anything about it, even if I fell off the top of the house!" (Which was very likely true.)</p>'
        '<p>Down, down, down. Would the fall never come to an end? "I wonder how many miles I have fallen by this time?" she said aloud. "I must be getting somewhere near the centre of the earth. Let me see: that would be four thousand miles down, I think—"</p>'
        '<p>Presently she began again. "I wonder if I shall fall right through the earth! How funny it will seem to come out among the people that walk with their heads downward! The Antipathies, I think—but I shall have to ask them what the name of the country is, you know."</p>'
        '<p>Down, down, down. There was nothing else to do, so Alice soon began talking again. "Dinah will miss me very much to-night, I should think!" (Dinah was the cat.) "I hope they will remember her saucer of milk at tea-time. Dinah, my dear! I wish you were down here with me!"</p>'
        '<p>Suddenly, thump! thump! down she came upon a heap of sticks and dry leaves, and the fall was over. Alice was not a bit hurt, and she jumped up on to her feet in a moment: she looked up, but it was all dark overhead; before her was another long passage.</p>',
  ];
}

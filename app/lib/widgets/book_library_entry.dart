// CoEvo · 信息流页的「我的书库」入口
//
// 🔴 **位置（白哥 2026-10-04 定）**：信息流页 `今日精选` 标题栏**下方**、
//    信息流列表**上方**。点击 → `/books`（书库页）。
//    （原设计把入口放「我的」页，见 `ebook-import-implementation` §六 —— 已改。）
//
// # 🔴 它与「兴趣筛选」不是一类东西（否则会撞上同一条判据）
//
// `home_screen.dart` 里留了一段注释：兴趣筛选栏**曾**放在同一位置，
// 白哥真机反馈「阅读界面太拥挤」⇒ 已移回「我的」页，并留下判据
// 「信息流页的垂直空间是稀缺资源，留给内容」+「⚠️ 别再放回来」。
//
// | | 兴趣筛选（已移走） | 我的书库（本组件） |
// |---|---|---|
// | 性质 | **前置控制**（筛选信息流本身） | **内容导航**（去读另一类内容） |
// | 频率 | 低频（设一次长期不动） | 中频（想读书时就用） |
// | 判定 | ❌ 不该常驻占行 | ✅ **它本身就是内容入口** |
//
// 🔑 所以本组件**不违反**那条判据 —— 判据针对的是「为设置占行」，
//    而这是「为内容占行」。⚠️ 但**占一行是有意的代价**，不是疏忽：
//    白哥的真问题是「**没看到导入入口**」⇒ 入口的首要指标是**被发现**。
//
// # 为什么是「淡色底的条」而不是纯文字行
//
// 纯文字行（像「关于」页的 `_LinkRow`）在信息流这个**满是卡片**的页面里
// 会被当成装饰而忽略；做成卡片又太占空间。⇒ 取中间：**淡色底 + 圆角**，
// 比裸文字醒目，又不像信息流卡片那么重。
//
// # 🔴 为什么在本文件里 import 了 `go_router`
//
// 直接 `context.push('/books')` 而不是把回调传进来 —— 入口只有这一个去处，
// 多一层回调只是把「去哪里」这件事**藏到一个构造参数里**（读代码时更难发现）。

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

/// 书库入口路由 —— 与 `app.dart` 的路由表**必须一致**。
const String kBookLibraryRoute = '/books';

class BookLibraryEntry extends StatelessWidget {
  const BookLibraryEntry({super.key});

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final accent = Color(t.accent.argb32);

    return InkWell(
      // 🔑 本组件**纯 UI、不查库** —— 书库打不开也照常显示、照常能点。
      //    判据同产品原则：「库可用性」不该成为「入口可见性」的开关。
      onTap: () => context.push(kBookLibraryRoute),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.menu_book_outlined, size: 17, color: accent),
            const SizedBox(width: 9),
            Text(
              '我的书库',
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Color(t.ink.argb32),
              ),
            ),
            const Spacer(),
            Icon(Icons.chevron_right, size: 20, color: accent),
          ],
        ),
      ),
    );
  }
}

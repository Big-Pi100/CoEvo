// CoEvo · 分享图（学习记录）的**纯逻辑层** —— 零 import，本机可断言。
//
// # 依据
// `docs/design/english-app-implementation-plan-v2-2026-09-25.md` **§5.7.3 学习成果分享**：
//
// | 规格原文 | 落地 |
// |---|---|
// | 「竖版 **3:4**（适配小红书/朋友圈）」 | 尺寸常量 [`kShareCardAspectW`] / [`kShareCardAspectH`] |
// | 「**深色/浅色双版本**」 | 跟随三档主题 token（见 `widgets/share_card.dart`）|
// | 「**不加二维码**」（社交平台判站外引流会限流）| 🔴 [`shareText`] **不得含任何 URL** —— 有断言守 |
// | 「**只放品牌名**，让用户主动搜索」 | 品牌名 [`kShareCardBrand`] |
// | 「只展示**用户自己的数据**，不含他人内容」 | [`ShareCardData`] 只有三个自测数字 |
// | 「连续学习 7 / 30 / 100 / 365 天」 | [`kMilestoneDays`] + [`milestoneReached`] |
//
// # 🔴 设计稿
// `docs/design/share-card-2026-10-06.html`（含 4 个预览：深/浅/夜/里程碑）
//
// # 🔑 为什么先要这个「零 import」文件
// 本项目**本机跑不了 flutter**（实测 `CreateFile failed 231`），
// 而分享图的**判定逻辑**（何时算里程碑、文案里有什么）**不该依赖渲染**——
// 抽成纯函数后可用 `dart run` 直接断言（同 `reading_settings.dart` / `sync_merge.dart` 的做法）。

// ══════════════════════════════════════════════════════════════
// 常量
// ══════════════════════════════════════════════════════════════

/// 分享图宽高比 **3:4**（规格 §5.7.3「竖版 3:4」）。
///
/// 渲染时逻辑尺寸用 `360 × 480`，再以 `pixelRatio: 3.0` 导出 ⇒ **1080 × 1440**。
const int kShareCardAspectW = 3;
const int kShareCardAspectH = 4;

/// 分享图逻辑宽度（导出宽 = 此值 × pixelRatio）。
const double kShareCardWidth = 360;
const double kShareCardHeight = 480;

/// 导出倍率 ⇒ 1080 × 1440（小红书/朋友圈的常见竖版尺寸）。
const double kShareCardPixelRatio = 3.0;

/// 品牌名 —— 规格「只放品牌名，让用户主动搜索」（分享图 / 分享文案用）。
///
/// 🔴 2026-10-12：随产品名改为「**记忆笔记**」（**ICP 备案要求** —— 「书」字触发
///    出版类前置审批字眼，详见 `app_info.dart` 的说明）。
///    沿革：`CoEvo` → `记忆之书`（10-11）→ `记忆笔记`（10-12）。
/// ⚠️ `share_card.dart` 里对它调了 `.toUpperCase()` —— 中文**不受影响**（原样返回），
///    但**排版宽度会变**（4 个汉字 ≫ 5 个拉丁字母的字宽）⇒ 分享图上线前请目视一眼。
///    （本次改名**不改变字数**：「记忆之书」与「记忆笔记」都是 4 字 ⇒ 宽度不变。）
const String kShareCardBrand = '记忆笔记';

/// 品牌副标（放右下角）。
///
/// # 文案（白哥 2026-10-06 定）
/// > 「读原文、学英语，自然记住单词」
///
/// 🔑 **原文是一句话**；这里按**逗号**断成两行 ——
/// 右下角是**窄区域**（与品牌名 `CoEvo` 并排）⇒ 短行更好读，也让整块构图更平衡。
/// ⚠️ 若要改回一行，只改这一个字符串（`\n` 去掉即可）。
///
/// 📌 文案的**合规注意**：这是**学习方式的主张**（在语境/原文中自然习得），
///    不是"保证效果" ⇒ 别在别处升级成「保证记住」「X 天记住 N 词」这类**效果承诺**。
const String kShareCardTagline = '读原文、学英语，\n自然记住单词';

/// 里程碑档位（规格 §5.7.3 表的「连续学习」行：**7 / 30 / 100 / 365 天**）。
///
/// 🔑 **升序**：`milestoneReached` 依赖它来找「恰好等于」的那档。
const List<int> kMilestoneDays = <int>[7, 30, 100, 365];

// ══════════════════════════════════════════════════════════════
// 数据模型
// ══════════════════════════════════════════════════════════════

/// 分享图**形态**。
enum ShareCardKind {
  /// 常驻版：主视觉 = 连续天数。
  regular,

  /// 里程碑版：主视觉 = 「达成 N 天」。
  milestone,
}

/// 一张分享图要展示的**全部数据**（值对象 · 不可变）。
///
/// 🔑 只有**三个用户自测数字** —— 规格「只展示用户自己的数据，不含他人内容」。
///    ⚠️ 刻意**不含**用户 id / 邮箱 / 推荐码：那三样一旦上图就是**对外泄露**。
class ShareCardData {
  /// 连续学习天数。
  final int streakDays;

  /// 已掌握词数。
  final int matureCards;

  /// 已读完文章数。
  final int articlesRead;

  /// 形态（常规 / 里程碑）。
  final ShareCardKind kind;

  /// 里程碑天数（`kind == milestone` 时非空）。
  final int? milestoneDay;

  const ShareCardData({
    required this.streakDays,
    required this.matureCards,
    required this.articlesRead,
    this.kind = ShareCardKind.regular,
    this.milestoneDay,
  });

  /// 由三个数字构造；**自动判定**是否该用里程碑版（恰好达到档位时）。
  ///
  /// 🔑 为什么自动判定（而不是让调用方传 kind）：
  ///    里程碑版的触发条件（「恰好等于 7/30/100/365」）是**规则**，不是调用方的选择。
  ///    放在这里 ⇒ 只有一个权威，且可被纯逻辑断言覆盖。
  factory ShareCardData.fromMetrics({
    required int streakDays,
    required int matureCards,
    required int articlesRead,
  }) {
    final hit = milestoneReached(streakDays);
    return ShareCardData(
      streakDays: streakDays,
      matureCards: matureCards,
      articlesRead: articlesRead,
      kind: hit != null ? ShareCardKind.milestone : ShareCardKind.regular,
      milestoneDay: hit,
    );
  }

  /// 「1234」→「1,234」（千分位）。
  ///
  /// 🔑 中文排版里四位以上数字加千分位可读性明显更好（微信读书/Spotify Wrapped 都这么做）。
  static String group(int n) {
    final s = n.abs().toString();
    if (s.length <= 3) return n < 0 ? '-$s' : s;
    final buf = StringBuffer(n < 0 ? '-' : '');
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

// ══════════════════════════════════════════════════════════════
// 纯函数
// ══════════════════════════════════════════════════════════════

/// 连续 [streakDays] 天时，是否**恰好**踩中里程碑档位？是则返回该档位，否则 `null`。
///
/// 🔴 「**恰好**」是刻意的（`==` 而非 `>=`）：
///    里程碑是「**达成那一刻**」的庆祝，若用 `>=`，则 101 天也会显示「达成 100 天」⇒
///    次日再打开还是同一张图 ⇒ **里程碑失去稀缺感**（且天天弹会烦）。
///    过期后回到常驻版，由用户主动分享。
int? milestoneReached(int streakDays) {
  for (final d in kMilestoneDays) {
    if (streakDays == d) return d;
  }
  return null;
}

/// 分享时附带的文案。
///
/// # 🔴🔴 它**不得包含任何 URL**
/// 规格 §5.7.3 原文：「小红书/微信对图片中的二维码会判定为**站外引流**，限流甚至封号。
/// 用户为了不被限流反而不会发 → 不如只放品牌名，让用户主动搜索」。
/// ⇒ **图里不放二维码，文案里也不放链接**（同一理由：带链接会被判营销）。
///
/// ⚠️ 这条有**断言守**（`verify_share_card.dart`）——
///    因为 2026-10-06 之前这里带着 `?ref=<推荐码>`（K12 分销残留），
///    是**从旧实现改回来的**，很容易被无意改回去。
String shareText(ShareCardData d) {
  if (d.kind == ShareCardKind.milestone && d.milestoneDay != null) {
    return '我在 $kShareCardBrand 连续学英语 ${d.milestoneDay} 天 🔥';
  }
  return '我在 $kShareCardBrand 连续学英语 ${d.streakDays} 天 🔥';
}

/// 分享图的落盘文件名（传给 `exportPngBytes(fileName:)`）。
///
/// 🔑 **必须带日期**：分享图会写进系统临时目录，同名会被覆盖 ——
///    带日期后「今天发过的图」与「昨天的」在文件管理器里能分辨。
String shareFileName(DateTime now) {
  final y = now.year.toString().padLeft(4, '0');
  final m = now.month.toString().padLeft(2, '0');
  final d = now.day.toString().padLeft(2, '0');
  return 'coevo_stats_$y$m$d.png';
}

/// 预览弹层里把分享图**缩放**到能放进当前屏幕的比例。
///
/// # 🔴 为什么用「缩放显示」而不是「缩小渲染」
/// 分享图必须**导出固定尺寸**（[kShareCardWidth] × [kShareCardPixelRatio] ⇒ 1080 宽）。
/// 若为了适配小屏而**改小卡片的逻辑尺寸**，那不同手机导出的图**尺寸就不同**
/// （同一份数据在小屏上出的图更小）—— 不可接受。
/// ⇒ 卡片**始终按 [kShareCardWidth] 渲染**，只在**预览时**缩放显示。
///
/// ⚠️ 缩放那个 widget **必须是 `FittedBox`，不能是 `Transform.scale`**：
///    `Transform` 不改布局约束 ⇒ 父 `SizedBox(360*scale)` 会把卡片**压小** ⇒
///    `RepaintBoundary.size` 跟着变小 ⇒ **导出尺寸随屏幕变化**（正好废掉上面的保证）。
///    `FittedBox` 给 child 无界约束 ⇒ child 按 360×480 布局，再缩放显示 ✓
///    （见 `widgets/share_card_preview.dart` 的同款说明。）
///
/// 【参数】[screenW] / [screenH] = `MediaQuery.of(context).size`
///
/// 【返回】缩放系数，夹在 `0.4`–`1.0`：
/// · 上限 1.0 —— 屏幕够大就**不放大**（放大只会变模糊）
/// · 下限 0.4 —— 极端小屏也保证看得出内容（更小等于没显示）
double shareCardPreviewScale({
  required double screenW,
  required double screenH,
}) {
  const double hPad = 64; // Dialog 左右留白
  const double vPad = 250; // 标题 + 切换 + 按钮 + 错误行
  final byW = (screenW - hPad) / kShareCardWidth;
  final byH = (screenH - vPad) / kShareCardHeight;
  final s = byW < byH ? byW : byH;
  if (s > 1.0) return 1.0;
  if (s < 0.4) return 0.4;
  return s;
}

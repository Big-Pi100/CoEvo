// CoEvo · 关于页
//
// 从「我的」页进入（`/about`）—— 依据 `ui-ux-refactor-assessment-2026-09-25` §6.1
// 定稿的「我的」子树最后一项：「关于」。
//
// # 🔴 本页**只有真实存在的内容**（不放假链接）
//
// | 想放的 | 为什么现在没放 |
// |---|---|
// | **隐私政策** | 🔴 URL 尚未确定。它是 **Apple 上架的硬要求**（App Store Connect 必填 + App 内应有入口）→ **待白哥提供正式 URL 后补**。**不编造链接**（判据同 `stats_card` 的分享注释：「若不编造 URL」）。 |
// | **用户协议** | 同上 |
// | **ICP 备案号** | ✅ 已备案（粤ICP备2026061557号-1）→ **可以放**，中国区 App 常规要求 |
// | 开源许可 | Flutter / 字体的许可都是真实的 → 可放；本版先不铺开（一张长列表会把「关于」变成一堵墙） |
// → 🔑 判据：**页面上的每个链接都必须能打开**。放一个死链比不放进糟糕 ——
//    用户点了没反应，会以为是 App 坏了（同「静默失败 + 无出口」）。
//
// # 🆕 「联系工作人员」2026-09-29 由「我的」页**移入本页**（白哥定）
//
// 🔑 为什么移到这里（不是冗余搬运）：它属**「关于本 App」这一族** ——
//    与「隐私政策 / 用户协议 / 版本 / 备案号」同类（都是「产品层面的信息」），
//    而不是「高频操作」（主题 / 朗读设置 / 成就）。
//    放在「我的」页的「其他」分组中段，会把「偶尔点」和「经常点」混在一起。
//
// # 🔴 视觉：本页**全平面**，所以新入口**不用**「我的」页那种粘土行
//
// 「我的」页的 `_navTile` 是 `bare: true` —— 它的设计前提是
// **外层已有 `Clay` 分组容器**（一整块凸起的卡，行与行之间用分隔线切）。
// 本页没有那个容器（内容直接铺在页面上）→ 直接搬过来会出现
// **一个孤立的凸起小块**，与周围全平面的文字不同源（判据：spec §〇 规则 1
// 「有体积的只可能是**可点**的东西」—— 可点 ≠ 必须有体积，形状要与所在页面成套）。
// ✅ 改用与 `_InfoRow` 同族的 [_LinkRow]：同一条基线、同样的行距，
//    只是右侧换成**强调色 + 箭头**来表达「这里能点进去」。

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/api_config.dart';
import '../constants/app_info.dart';
import '../theme/co_spacing.dart';
import '../theme/tokens_ext.dart';
import '../theme/coevo_tokens.dart';
import '../widgets/clay_button.dart';
import '../widgets/co_dialog.dart';
import '../widgets/twemoji.dart';

/// 关于页（版本 · 备案号 · 待补项）。
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    return Scaffold(
      // 🔑 与全站一致：**自绘顶栏**（不用 Material `AppBar`）
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 顶栏：「返回」在右（照 `bookmark_list_screen` 的范式：
            //    设计稿 `.bm-hd .back` 是**右对齐的文字链接**，不是左箭头）──
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 14, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '关于',
                      style: TextStyle(
                        fontFamily: CoFonts.uiSans,
                        fontSize: 23,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 23 * -0.015,
                        color: Color(t.ink.argb32),
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () => context.pop(),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Text(
                        '返回',
                        style: TextStyle(
                          fontFamily: CoFonts.uiSans,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(t.accent.argb32),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                    CoSpacing.xxl, 0, CoSpacing.xxl, CoSpacing.tabBarClearance),
                children: [
                  const SizedBox(height: CoSpacing.xl),
                  // ── App 名 + 版本 ──
                  Center(
                    child: Column(
                      children: [
                        Text(
                          kCoEvoName,
                          style: TextStyle(
                            fontFamily: CoFonts.uiSans,
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                            color: Color(t.ink.argb32),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '版本 $kCoEvoVersion',
                          style: TextStyle(
                            fontFamily: CoFonts.uiSans,
                            fontSize: 12.5,
                            color: Color(t.ink3.argb32),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: CoSpacing.xl),

                  _InfoRow(label: '应用名称', value: kCoEvoName),
                  _InfoRow(label: '版本', value: kCoEvoVersion),
                  // 🔑 备案号是**中国区上架的常规要求**，且已真实持有 → 直接放（不是占位）
                  _InfoRow(label: '备案号', value: '粤ICP备2026061557号-1'),

                  const SizedBox(height: CoSpacing.xl),
                  Divider(height: 1, color: Color(t.line.argb32)),
                  const SizedBox(height: CoSpacing.lg),

                  // ── 说明 ──
                  Text(
                    'CoEvo 是一款英语学习应用：读英文新闻、划词查词、'
                    '把生词收进生词本，再按记忆曲线复习。',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 12.5,
                      height: 1.8,
                      color: Color(t.ink2.argb32),
                    ),
                  ),
                  const SizedBox(height: CoSpacing.lg),

                  // ── 🔴 待补项（**可见地标注，而不是留死链**）──
                  //    Apple 上架需要「隐私政策」入口；URL 未定 → 先如实说明，
                  //    而不是放一个点了没反应的链接。
                  Text(
                    '隐私政策与用户协议即将上线。',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 12,
                      color: Color(t.ink3.argb32),
                    ),
                  ),

                  const SizedBox(height: CoSpacing.xl),
                  Divider(height: 1, color: Color(t.line.argb32)),
                  const SizedBox(height: CoSpacing.sm),

                  // ── 🆕 联系工作人员（2026-09-29 由「我的」页移入）──
                  _LinkRow(
                    label: '联系工作人员',
                    onTap: () => _showContactDialog(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  /// 「联系工作人员」弹窗（二维码）。
  ///
  /// 🔴 2026-09-29 由 `profile_screen` 整体移入 —— 逻辑与原实现一致，
  ///    只是**弹窗外壳换成公共 `CoDialog`**（本页此前无弹窗，现在起有了一处）。
  ///
  /// 🔑 二维码是**联网图片**（`/api/public/qrcode`）→ 必须有 `errorBuilder`：
  ///    没网/接口挂了时显示一个「图片不可用」图标，而不是留一块空白
  ///    （判据同本页文件头：「静默失败 + 无出口」比报错更糟）。
  void _showContactDialog(BuildContext context) {
    CoDialog.show<void>(
      context,
      builder: (ctx) {
        // ⚠️ 用 builder 的 `ctx` 取 token（而不是外层 context）——
        //    弹窗是**路由级 overlay**，它的 context 才是它真正所在的树。
        final t = CoEvoTokensExt.of(ctx);
        return CoDialog(
          title: '联系工作人员',
          actions: [
            ClayButton(
              label: '关闭',
              variant: ClayButtonVariant.secondary,
              expanded: true,
              onTap: () => Navigator.of(ctx).pop(),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tw(
                '扫码添加工作人员微信',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 13,
                  color: Color(t.ink2.argb32),
                ),
              ),
              const SizedBox(height: CoSpacing.lg),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image(
                  image: NetworkImage('${ApiConfig.baseUrl}/api/public/qrcode'),
                  width: 200,
                  height: 200,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Icon(
                    Icons.image_not_supported,
                    size: 64,
                    color: Color(t.ink3.argb32),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// **可点**一行（左标签 + 右箭头）—— [_InfoRow] 的「入口」版本。
///
/// # 与 [_InfoRow] 的关系
///
/// 两者**同族**（同一条左右基线、同样的 `vertical: 9` 行距），差别只有一处：
///
/// | | 读法 | 右侧 |
/// |---|---|---|
/// | `_InfoRow` | 「这个字段的**值**是…」（只读信息） | `ink` 文字（如「0.1.0」） |
/// | `_LinkRow` | 「点这里**进去**」（入口） | 强调色 + **箭头** |
///
/// 🔑 为什么用一个新类而不是给 `_InfoRow` 加 `onTap` 参数：
///    两者的**视觉契约不同**（值 vs 入口），混在一个类里要靠
///    `onTap == null` 分支去切两套观感 —— 那正是「同一组件两副面孔」的开始。
///    分成两个小类，各自的意图是**单一**的。
///
/// 🔑 右侧用**箭头图标**而不是文字「查看」：箭头是「可进入」的通用符号，
///    且不占横向空间（本页的字号都偏小，多一个词会把行挤得紧）。
class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final accent = Color(t.accent.argb32);

    return InkWell(
      // 顶栏「返回」用的也是 `InkWell` —— 本页既有的可点元素就这一种做法
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 13,
                color: Color(t.ink.argb32),
              ),
            ),
            const Spacer(),
            // 箭头也用强调色 —— 「能点」这件事由**颜色 + 符号**同时表达
            Icon(Icons.chevron_right, size: 20, color: accent),
          ],
        ),
      ),
    );
  }
}

/// 「标签 — 值」一行（只读信息）。
///
/// ⚠️ 与 [_LinkRow] 是**两个类**，别合并 —— 理由见 [_LinkRow] 的文档。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 13,
              color: Color(t.ink3.argb32),
            ),
          ),
          const Spacer(),
          Flexible(
            child: Tw(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 13,
                color: Color(t.ink.argb32),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

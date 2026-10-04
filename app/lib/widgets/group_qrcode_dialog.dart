/// 群二维码弹层 —— 全应用**唯一**一处定义「共读群二维码长什么样」。
///
/// # 消费者（2026-10-04 起两处）
/// | 位置 | 触发 |
/// |---|---|
/// | 「关于」页 · 「加入英文原著共读群」 | 用户想看群 |
/// | **书库空态** · 淡色引导卡 | 用户**想知道去哪找电子书**（空态的常见根因）|
/// | **导入失败（DRM）** · 弹层里的次要动作 | 提示里已提「改用 Project Gutenberg 的公版书」，但原来**没给出口** |
///
/// # 🔴 为什么必须抽成公共组件（而不是各处再写一遍）
///
/// 它原本是 `about_screen.dart` 里的**私有方法** `_showGroupQrcodeDialog`。
/// 书库空态要复用它时，有两条路：复制一份（两处实现），或抽出来（一处定义）。
///
/// 🔑 **「外观一致」最可靠的实现方式 = 只有一处定义。**
///    两处各写一份，即使今天参数完全相同，也会在下次改一处时**静默走偏**
///    —— 比如换二维码地址、改标题文案、调图片尺寸。这类漂移编译器看不出来，
///    往往到用户看到两个不一样的弹窗时才被发现。
///    这与项目既有判据一致（同 `HeaderChip` / `CoDialog` / `_ClayTabBar` 被抽出来的理由）。
///
/// # 二维码是**联网图片**
///
/// 走 `${ApiConfig.baseUrl}/api/public/qrcode`（后端托管），
/// 因为微信群的二维码**只有 7 天有效期**（见 `docs/operations/wechat-study-group-plan-*` §2.1）
/// —— 换码不能依赖发版。
///
/// 🔴 **必须有 `errorBuilder`**：没网 / 接口挂了 / 图还没传时，
///    显示一个「图片不可用」图标，而不是留一块空白
///    （判据：「**静默失败 + 无出口**」比报错更糟）。
///
/// ✅ **线上实测（2026-10-04 23:0x 复核）**：
///    `GET https://api.keyievolution.fun/api/public/qrcode` → `200` · `image/jpeg` · **134551 B**。
///    ⚠️ 早前（同日早些时候）该接口返回的是 `text/plain` + 一句「二维码图片未配置」——
///       **那个状态已过去**：图已传上去，现在显示的是真图。
///       （`about_screen.dart` 里那条「线上该图当前不存在」的注释已随之更正。）
///    📌 判据：**「还没配好」是状态、不是结论** —— 写进注释时要标明**观测时间**，
///       否则它会变成一条永远读不到头的假事实。
library;

import 'package:flutter/material.dart';

import '../api/api_config.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import 'clay_button.dart';
import 'co_dialog.dart';
import 'twemoji.dart';

class GroupQrcodeDialog {
  const GroupQrcodeDialog._();

  /// 弹窗标题 —— 与「关于」页的入口文案**同名**
  /// （`docs/operations/wechat-study-group-plan-*` §3.1：两端看到同一个名字，
  /// 用户才不会以为是两件事）。
  static const String kTitle = '加入英文原著共读群';

  /// 图片下方的说明 —— 只说「怎么用」，**不做任何承诺**。
  ///
  /// 🔴 **不能写成「扫码领书 / 免费下载 / 拿资源」**：
  ///    群定位是「**教方法 + 陪读 + 答疑**」，且**群规明令禁传电子书文件**
  ///    （见群方案 §3.1 / §3.2）—— 写成资源群既吸引错的人，又与群规自相矛盾。
  static const String kHint = '微信扫码加入共读群';

  /// 二维码边长（原 `about_screen` 的值，抽出来时**原样保留**）。
  static const double kQrSize = 200;

  /// 弹出群二维码。
  static Future<void> show(BuildContext context) {
    return CoDialog.show<void>(
      context,
      builder: (ctx) {
        // ⚠️ 用 builder 的 `ctx` 取 token（而不是外层 context）——
        //    弹窗是**路由级 overlay**，它的 context 才是它真正所在的树。
        final t = CoEvoTokensExt.of(ctx);
        return CoDialog(
          title: kTitle,
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
                kHint,
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
                  width: kQrSize,
                  height: kQrSize,
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

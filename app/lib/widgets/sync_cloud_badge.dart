/// 云端同步的**状态标** —— 两种形态，共一套逻辑。
///
/// # 两种形态（谁用哪个）
///
/// | 形态 | 用在哪 | 为什么 |
/// |---|---|---|
/// | [SyncCloudBadge]（**一枚图标**）| 订阅页「已订阅」状态卡 | 卡片的主题就是订阅，一枚紧凑图标**恰好**；文字会挤掉「订阅中 · 到期日」|
/// | [SyncCloudChip]（**独立胶囊**：图标 + 文案）| 「我的」页「订阅」组 | 白哥 2026-10-09：「**还是在我的里弄个独立的胶囊吧**」—— 贴在那行订阅卡上会被读成状态的一部分，独立成胶囊才是它自己的东西 |
///
/// 🔑 **形态不同、口径相同**：状态 →（图标, 颜色）走 [syncCloudVisual]，
///    点击行为走 [syncCloudOnTap]，**都只有一处**。
///    （本项目判据：**同一件事的口径只能一处权威** —— 两处各写一套 `switch`，
///      改一处漏一处，而且失败态往往只在一边被处理。）
///
/// # 五个状态（形态区分优于参数 —— 同 `trace_markdown` 的判据）
///
/// | 状态 | 图标 | 颜色 |
/// |---|---|---|
/// | 🔒 **未订阅**（能力未开）| `cloud_queue` | `ink3` **灰** —— 不是错误，只是没开 |
/// | 同步中 | `cloud_sync` | `accent`（朱砂 · 表示「正在动」）|
/// | **已同步** | `cloud_done` | **`success` 绿**（🆕 2026-10-09：由 `ink3` 改绿）|
/// | 失败 | `cloud_off` | `colorScheme.error` |
/// | 已订阅但从未同步过 | `cloud_queue` | `ink3` 灰 |
///
/// 🔑 **绿 / 灰的对比本身承担信息**（白哥 2026-10-09 指令）：
///    「同步了就显示绿色，未同步显示灰色，这样**没有订阅的用户才知道要订阅**」
///    ⇒ 这是**有意推翻**原先「正常态低调、只有异常才显眼」的取舍 ——
///      那条取舍的前提是「只给已订阅用户看自己的同步状况」，
///      而现在这条胶囊要给**所有人**广播「通了 / 没通」。
///    ⚠️ 唯一还保留的克制：**未订阅用灰不用红**（红 = 「我出问题了」的错觉）。
///
/// # 点击 = 一句话（徽标本身**放不下**「上次同步 10:32」）
///
/// · 有状态可说 ⇒ `SnackBar` 一句话；**失败时带「重试」**
/// · 从未同步过 ⇒ 点它就是「现在同步一次」（否则用户没有任何办法手动触发）
///
/// ⚠️ 已知取舍（图标形态）：点击区做成 **30×30**（icon 18 + padding），
///    **小于 iOS 的 44pt**。理由：它是**次要**入口（点开只是看一句话），
///    而 44pt 会把这行撑高、与「我的」页其它行的节奏不一致。
///    胶囊形态没有这个问题（有文字、横向够宽）。**不假装没有这个妥协** ——
///    若真机上抱怨难点，把它抬到 44 即可（改一处）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/iap_provider.dart';
import '../providers/sync_status_provider.dart';
import '../services/sync_status.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import 'sync_progress_dialog.dart';

/// 状态 →（图标, 颜色）—— **两种形态共用的唯一一处**。
///
/// 颜色由调用方传入（而不是在这里读 `Theme`），是为了让这个函数
/// **不依赖 `BuildContext`** ⇒ 将来要断言它也不必起一整个 widget 树。
///
/// # 🆕 2026-10-09：分**两层**判断（订阅能力 × 同步进展）
///
/// | 层 | 输入 | 结果 |
/// |---|---|---|
/// | ① **能力**（订阅）| [subscribed] = `false` | 灰 · `cloud_queue` —— **不是错误，只是能力没开** |
/// | ② **进展** | `syncing` / `ok` / `failed` / `idle` | 朱砂 / **绿** / 红 / 灰 |
///
/// 🔴 白哥 2026-10-09：「同步了就显示**绿色**，未同步显示**灰色**，
///    这样没有订阅的用户**才知道要订阅**」—— 两处都是**有意的**改动：
///    · `ok` 由「低调 `ink3`」改成 **`success` 绿**（原来正常态刻意不抢视线；
///      现在它的职责变成「对所有人广播"通了/没通"」，必须看得见）
///    · 未订阅由「不显示」改成 **灰色常显**（原来藏起来 ⇒ 未订阅用户
///      **根本不知道有同步这回事**，也就无从产生订阅动机）
///
/// ⚠️ 未订阅用**灰**而不是红：它不是一个失败（用户没做错任何事），
///    染红会制造「我出问题了」的错觉（同 `SyncPhase.skipped` 不置失败态的取向）。
({IconData icon, Color color}) syncCloudVisual({
  required SyncStatus status,
  required bool subscribed,
  required Color accent,
  required Color ink3,
  required Color error,
  required Color success,
}) {
  if (!subscribed) {
    return (icon: Icons.cloud_queue, color: ink3);
  }
  switch (status.phase) {
    case SyncPhase.syncing:
      return (icon: Icons.cloud_sync, color: accent);
    case SyncPhase.failed:
      return (icon: Icons.cloud_off, color: error);
    case SyncPhase.ok:
      return (icon: Icons.cloud_done, color: success);
    case SyncPhase.idle:
    case SyncPhase.skipped:
      return (icon: Icons.cloud_queue, color: ink3);
  }
}

/// 点击处理 —— **两种形态共用的唯一一处**。
///
/// 🆕 2026-10-09：未订阅时**跳订阅页**（不再静默）——
///    白哥要这个胶囊的意义正是「让未订阅的人知道要订阅」⇒ 点了必须有**出口**。
///    只弹一句「订阅后可同步」会把用户丢在原地（本项目判据：
///    **「有动作、无出口」**与静默失败同族）。
void syncCloudOnTap(
  BuildContext context,
  WidgetRef ref,
  SyncStatus s, {
  required bool subscribed,
}) {
  if (!subscribed) {
    // 🔑 用 `context.push`（本组件只在**页面内**使用 ⇒ 上下文在 Navigator 之下）。
    //    ⚠️ 若将来把它放进 `MaterialApp.builder` 之类 **Navigator 之上**的位置，
    //       这里必须改成 `goRouter.push(...)` —— 同 `app.dart` 那条记录
    //       （builder 上下文里 `context.push` 会因 `maybeOf` 为空而崩）。
    context.push('/subscribe');
    return;
  }
  // 🔴 正在同步 ⇒ 忽略本次点击（不叠加第二个请求）——
  //    弹窗本身已经在说「正在同步…」，再点一次不该再发一遍。
  if (s.phase == SyncPhase.syncing) return;

  // 🆕 2026-10-10（白哥）：「同步在 UI 上没有显示」⇒ **点击 = 立即同步一次**，
  //    并以**转圈弹窗**呈现进行中状态（[syncWithProgressDialog]）。
  //
  // 🔴 改掉旧行为的理由：旧版点击先弹一句「上次同步是几点」的 SnackBar，
  //    用户想真的同步还得再点一下「重试」—— 这是「有动作、多一跳」。
  //    ⇒ 反馈必须发生在**动作那一刻**。
  //    ⚠️ 「上次同步时间」并没有丢：它仍在胶囊的常驻文案里（`syncChipLabel`）
  //       与「我的」页的订阅组里。
  syncWithProgressDialog(context, ref);
}

/// 云端同步的**图标**形态（订阅页「已订阅」卡上的一枚）。
///
/// 🆕 2026-10-09：**不再「未订阅即零高」** —— 与胶囊形态统一成同一条规则
///    「**状态标一直显示**」（白哥指令）。判据走全库唯一那处 `subscriptionActiveNow`
///    （端侧 OR 服务端）——不要在这里自己写 `iapSnapshotOf(ref).isActive`
///    （安卓上永远是 false，那会让这个图标在能测的平台上**永远不出现**）。
///
/// ⚠️ 实际调用点仍在「已订阅」卡上（那张卡只在订阅时渲染）⇒ 未订阅态在这里
///    平时走不到；保留它是为了让**两种形态的规则完全一致**（一处特例会渗回来）。
class SyncCloudBadge extends ConsumerWidget {
  const SyncCloudBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subscribed = subscriptionActiveNow(ref);
    final s = ref.watch(syncStatusProvider);
    final t = CoEvoTokensExt.of(context);
    final v = syncCloudVisual(
      status: s,
      subscribed: subscribed,
      accent: Color(t.accent.argb32),
      ink3: Color(t.ink3.argb32),
      error: Theme.of(context).colorScheme.error,
      success: Color(t.success.argb32),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => syncCloudOnTap(context, ref, s, subscribed: subscribed),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
        child: Icon(v.icon, size: 18, color: v.color),
      ),
    );
  }
}

/// 云端同步的**独立胶囊**形态（「我的」页「订阅」组里的一枚）。
///
/// 🔑 与图标形态的区别**只在形态**：多一行文案（[syncChipLabel]），
///    自带**左侧对齐**与**上方间距** ⇒ 调用方一行就能放进任意 `Column`。
///
/// # 🆕 2026-10-09：**一直显示**（这是白哥要的那条）
///
/// 原先未订阅 ⇒ 零高（藏起来）⇒ 未订阅用户**根本不知道有同步这回事**。
/// 现在：**未订阅 = 灰云 + 「未订阅 · 订阅后可同步」，点击进订阅页**。
/// 于是这条胶囊自己承担了「订阅的入口」职责 —— 调用方仍然只需要写一行。
class SyncCloudChip extends ConsumerWidget {
  const SyncCloudChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subscribed = subscriptionActiveNow(ref);
    final s = ref.watch(syncStatusProvider);
    final t = CoEvoTokensExt.of(context);
    final v = syncCloudVisual(
      status: s,
      subscribed: subscribed,
      accent: Color(t.accent.argb32),
      ink3: Color(t.ink3.argb32),
      error: Theme.of(context).colorScheme.error,
      success: Color(t.success.argb32),
    );
    // 🔑 文案的换算在**纯逻辑层**（[syncChipLabel] / [syncUnsubscribedLabel]）——
    //    它们可以被离线穷举，而「上次同步是几点」这类换算错了
    //    **不报错、只会显示一句假的时间**。
    // ⚠️ 未订阅时**不调** `syncChipLabel`：它会读到「上次同步时间」并显示成
    //    「已同步 · 昨天 10:32」，而那个账号**根本没有能力同步**（两回事）。
    final label =
        subscribed ? syncChipLabel(s, DateTime.now()) : syncUnsubscribedLabel();
    // 🆕 文字与图标**共用同一个状态色**（原来是「只有失败才染红」）——
    //    白哥要的是「绿 / 灰」这个**对比本身**承担信息，只染 14px 图标太弱。
    //    一处口径：颜色只来自 [syncCloudVisual]（删掉了这里的第二处条件）。
    final textColor = v.color;

    return Padding(
      padding: const EdgeInsets.only(top: CoSpacing.sm),
      child: Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => syncCloudOnTap(context, ref, s, subscribed: subscribed),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              // `sunken` = 凹陷底：胶囊是**信息**而不是可点的按钮 ⇒
              // 用它而不是 `Clay`（粘土 = 可抬起的动作元素）。
              color: Color(t.sunken.argb32),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(v.icon, size: 14, color: v.color),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 11.5,
                    color: textColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

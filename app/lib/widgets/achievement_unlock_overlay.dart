/// 全局成就**解锁弹窗**（挂在 `MaterialApp.builder` 的最上层 Stack 里）。
///
/// # 依据
/// `docs/architecture/achievement-system-redesign.md` §4.1「**双层展示模型**」的
/// 「特效卡（卡片详情）」那一层 —— 出现场景「**任何页面**解锁成就时弹出」。
///
/// # 🔑 与旧实现（2026-06 删）的两点差异（如实标注）
/// | | 旧实现 | 本实现 |
/// |---|---|---|
/// | 数据源 | **后端** `new_achievements` 字段（WebSocket / REST 返回） | **端侧** `checkAndRefreshAchievements()`（后端成就引擎已退役） |
/// | 粒子撒花 | ✅ `_ConfettiPainter`（40 粒子 · 1.5s） | ❌ **未做** —— 见下 |
///
/// ⚠️ **粒子特效第一版不做**：它是独立的 `CustomPainter` + 粒子模型（旧实现 ~60 行），
///    属于**装饰**而非「解锁是否成立」的核心。先让解锁**可见**，
///    粒子可在后续版本补（设计稿 §4.2 的完整动画时序是 300 / 800 / 2500 / 3000ms）。
///    🔑 取舍理由：本项目判据「**先有可看的目标再干活**」——
///    解锁的**信息传达**（哪个成就 / 什么档位 / 达成了什么）必须先成立。
///
/// # 交互
/// 入场（缩放弹跳）→ 停留 2.6s → 自动淡出 → 出队 → 下一个（若有）
/// · **点击任意处可立即关闭**（不等自动消失）—— 不打断用户当前操作
/// · 多个成就排队时**逐个展示**，一个都不丢（见 `achievement_notifier.dart`）

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/achievement_notifier.dart';
import '../services/achievement_rules.dart';
import '../shared/achievement_icons.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

/// 入场时长 / 停留时长 / 出场时长（与旧设计稿的 3000ms 总量接近）。
const Duration _kEnterDuration = Duration(milliseconds: 320);
const Duration _kStayDuration = Duration(milliseconds: 2600);
const Duration _kExitDuration = Duration(milliseconds: 220);

class AchievementUnlockOverlay extends ConsumerStatefulWidget {
  const AchievementUnlockOverlay({super.key});

  @override
  ConsumerState<AchievementUnlockOverlay> createState() =>
      _AchievementUnlockOverlayState();
}

class _AchievementUnlockOverlayState
    extends ConsumerState<AchievementUnlockOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: _kEnterDuration,
    reverseDuration: _kExitDuration,
  );

  Timer? _timer;

  /// 当前正在展示的成就（`null` = 无）。
  AchievementDef? _showing;

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  /// 开始展示 [def]。
  void _show(AchievementDef def) {
    _timer?.cancel();
    setState(() => _showing = def);
    _ctrl.forward(from: 0);
    _timer = Timer(_kStayDuration, _hide);
  }

  /// 收起当前（**幂等** —— 自动超时与手动点击都会走到这里）。
  void _hide() {
    _timer?.cancel();
    _timer = null;
    // ⚠️ 动画未完成时不再重入（否则 dismissHead 会被调两次 → 队列少一个）
    if (_showing == null) return;
    _ctrl.reverse().whenComplete(() {
      if (!mounted) return;
      setState(() => _showing = null);
      // 出队 → 若还有下一个，`ref.listen` 会再次触发 `_show`
      ref.read(achievementUnlockProvider.notifier).dismissHead();
    });
  }

  @override
  Widget build(BuildContext context) {
    // 🔑 队列变化 → 若当前没在展示，取队首展示
    ref.listen<List<AchievementDef>>(achievementUnlockProvider, (prev, next) {
      if (next.isNotEmpty && _showing == null) {
        _show(next.first);
      }
    });

    final showing = _showing;
    if (showing == null) return const SizedBox.shrink();

    final t = CoEvoTokensExt.of(context);

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        // 点击任意处立即关闭（不打断用户）
        child: GestureDetector(
          onTap: _hide,
          behavior: HitTestBehavior.translucent,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Center(
              child: AnimatedBuilder(
                animation: _ctrl,
                builder: (context, child) {
                  final v = Curves.easeOutBack.transform(
                    _ctrl.value.clamp(0.0, 1.0),
                  );
                  return Opacity(
                    opacity: _ctrl.value.clamp(0.0, 1.0),
                    child: Transform.scale(scale: 0.86 + 0.14 * v, child: child),
                  );
                },
                child: _UnlockCard(def: showing, token: t),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 解锁卡片（图标 + 名称 + 档位 + 描述）。
class _UnlockCard extends StatelessWidget {
  final AchievementDef def;
  final CoEvoTokens token;

  const _UnlockCard({required this.def, required this.token});

  @override
  Widget build(BuildContext context) {
    final accent = tierColor(def.tier);
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: Color(token.card.argb32),
          borderRadius: BorderRadius.circular(16),
          // 档位色描边 + 外发光 —— 用**颜色 + 明度**同时表意（不靠单一色差）
          border: Border.all(color: accent, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.35),
              blurRadius: 18,
              spreadRadius: 1,
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
              child: Icon(achievementIcon(def.icon),
                  size: 21, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text('解锁成就',
                        style: TextStyle(
                          fontFamily: CoFonts.uiSans,
                          fontSize: 10,
                          letterSpacing: 0.6,
                          color: Color(token.ink3.argb32),
                        )),
                    const SizedBox(width: 6),
                    Text(tierLabel(def.tier),
                        style: TextStyle(
                          fontFamily: CoFonts.uiSans,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: accent,
                        )),
                  ],
                ),
                const SizedBox(height: 2),
                Text(def.name,
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                      color: Color(token.ink.argb32),
                    )),
                const SizedBox(height: 2),
                Text(def.description,
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 12,
                      color: Color(token.ink2.argb32),
                    )),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

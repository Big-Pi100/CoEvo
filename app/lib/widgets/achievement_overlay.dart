// 全局成就通知 Overlay
//
// 挂载在 MaterialApp.builder 中，监听 achievementNotifierProvider 队列，
// 逐个展示成就特效卡（入场弹跳动效 + 分级光效 + 粒子撒花 + 3s 自动消失）。

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/achievement_notifier.dart';
import '../shared/achievement_icons.dart';

// ── Confetti 粒子 ──

class _Particle {
  _Particle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.color,
    required this.size,
    required this.rotation,
    required this.rotationSpeed,
    this.shape, // 0=rect, 1=circle, 2=star-like
  });

  double x, y;
  double vx, vy;
  Color color;
  double size;
  double rotation;
  double rotationSpeed;
  int? shape;
  double opacity = 1.0;
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.particles);

  final List<_Particle> particles;

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      final paint = Paint()
        ..color = p.color.withValues(alpha: p.opacity)
        ..style = PaintingStyle.fill;

      canvas.save();
      canvas.translate(p.x, p.y);
      canvas.rotate(p.rotation);

      final shape = p.shape ?? 0;
      if (shape == 0) {
        // 矩形
        canvas.drawRect(
          Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 0.6),
          paint,
        );
      } else if (shape == 1) {
        // 圆形
        canvas.drawCircle(Offset.zero, p.size * 0.4, paint);
      } else {
        // 星形近似（小菱形）
        final path = Path()
          ..moveTo(0, -p.size * 0.5)
          ..lineTo(p.size * 0.3, 0)
          ..lineTo(0, p.size * 0.5)
          ..lineTo(-p.size * 0.3, 0)
          ..close();
        canvas.drawPath(path, paint);
      }

      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter oldDelegate) => true;
}

/// 挂载在 MaterialApp.builder 中的全局 Overlay 入口
class AchievementOverlay extends ConsumerStatefulWidget {
  const AchievementOverlay({super.key});

  @override
  ConsumerState<AchievementOverlay> createState() => _AchievementOverlayState();
}

class _AchievementOverlayState extends ConsumerState<AchievementOverlay>
    with TickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  late Animation<double> _opacity;
  Timer? _autoDismiss;
  String? _displayedKey;

  ColorScheme get _cs => Theme.of(context).colorScheme;

  // ── Confetti 粒子系统 ──
  final List<_Particle> _particles = [];
  late AnimationController _confettiCtrl;
  double _screenWidth = 390; // 默认值，build 时更新
  static const _confettiColors = [
    Color(0xFFFFD700), // gold
    Color(0xFFC0C0C0), // silver
    Color(0xFFCD7F32), // bronze
    Color(0xFFFF6B6B), // coral
    Color(0xFF4ECDC4), // teal
    Color(0xFF9B59B6), // purple
    Color(0xFFFF8C00), // orange
    Color(0xFF3498DB), // blue
  ];

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _scale = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut),
    );
    _opacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.0, 0.4, curve: Curves.easeOut),
      ),
    );

    // Confetti 动画控制器（1.5s 粒子生命周期）
    _confettiCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _confettiCtrl.addListener(_updateParticles);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    ref.listenManual(achievementNotifierProvider, (prev, next) {
      final current = next.isNotEmpty ? next.first : null;
      if (current != null && current.key != _displayedKey) {
        _showCurrent(current);
      }
      if (next.isEmpty) {
        _hide();
      }
    });
  }

  void _showCurrent(AchievementNotification a) {
    _autoDismiss?.cancel();
    _displayedKey = a.key;
    _ctrl.reset();
    _ctrl.forward();
    _spawnConfetti(a.tier);
    _autoDismiss = Timer(const Duration(seconds: 3), () {
      _dismissCurrent();
    });
  }

  void _hide() {
    _autoDismiss?.cancel();
    _ctrl.reset();
    _displayedKey = null;
    if (mounted) setState(() {});
  }

  void _dismissCurrent() {
    _autoDismiss?.cancel();
    _ctrl.reverse().then((_) {
      if (mounted) {
        ref.read(achievementNotifierProvider.notifier).dismiss();
        _displayedKey = null;
      }
    });
  }

  // ── Confetti 粒子逻辑 ──

  void _spawnConfetti(String tier) {
    _particles.clear();
    final rng = math.Random();
    final midX = _screenWidth / 2;

    // 根据分级选择粒子颜色偏向
    final tierBase = tierColor(tier);

    // 生成 40 个粒子，分布在卡片上方区域
    for (int i = 0; i < 40; i++) {
      final isAccent = rng.nextDouble() < 0.3;
      final color = isAccent
          ? _confettiColors[rng.nextInt(_confettiColors.length)]
          : tierBase.withValues(
              red: (tierBase.r + rng.nextDouble() * 0.2).clamp(0, 1),
              green: (tierBase.g + rng.nextDouble() * 0.2).clamp(0, 1),
              blue: (tierBase.b + rng.nextDouble() * 0.2).clamp(0, 1),
            );

      _particles.add(_Particle(
        x: midX + rng.nextDouble() * 300 - 150, // 左右 150px
        y: -20 - rng.nextDouble() * 100, // 屏幕上方
        vx: rng.nextDouble() * 200 - 100, // 水平速度
        vy: rng.nextDouble() * 150 + 50, // 下落速度
        color: color,
        size: rng.nextDouble() * 8 + 4, // 4-12px
        rotation: rng.nextDouble() * math.pi * 2,
        rotationSpeed: (rng.nextDouble() - 0.5) * 8,
        shape: rng.nextInt(3),
      ));
    }

    _confettiCtrl.reset();
    _confettiCtrl.forward();
  }

  void _updateParticles() {
    setState(() {
      final progress = _confettiCtrl.value;
      for (final p in _particles) {
        // 应用重力和阻力
        p.x += p.vx * 0.016;
        p.y += p.vy * 0.016;
        p.vy += 300 * 0.016; // 重力加速
        p.vx *= 0.98; // 水平阻力
        p.rotation += p.rotationSpeed * 0.016;

        // 后半段开始淡出
        if (progress > 0.6) {
          p.opacity = 1.0 - (progress - 0.6) / 0.4;
        }
      }
    });
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    _ctrl.dispose();
    _confettiCtrl.dispose();
    super.dispose();
  }

  Color _tierGlowColor(String tier) {
    final c = tierColor(tier);
    return c.withValues(alpha: 0.6);
  }

  IconData _resolveIcon(AchievementNotification a) {
    return achievementIcon(a.key);
  }

  Color _resolveColor(AchievementNotification a) {
    if (a.color != null && a.color!.isNotEmpty) {
      final hex = a.color!.replaceAll('#', '');
      final parsed = int.tryParse(hex, radix: 16);
      if (parsed != null) {
        return Color(parsed).withValues(alpha: 1.0);
      }
    }
    return achievementColor(a.key);
  }

  @override
  Widget build(BuildContext context) {
    _screenWidth = MediaQuery.of(context).size.width;
    final queue = ref.watch(achievementNotifierProvider);
    final current = queue.isNotEmpty ? queue.first : null;

    if (current == null || _displayedKey == null) {
      return const SizedBox.shrink();
    }

    final a = current;
    final glow = _tierGlowColor(a.tier);
    final iconColor = _resolveColor(a);
    final iconData = _resolveIcon(a);

    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: Material(
          color: _cs.scrim,
          child: GestureDetector(
            onTap: _dismissCurrent,
            child: Stack(
              children: [
                // 粒子撒花层（在卡片上方）
                if (_particles.isNotEmpty)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _ConfettiPainter(_particles),
                      ),
                    ),
                  ),
                // 成就卡片
                Center(
                  child: AnimatedBuilder(
                    animation: _ctrl,
                    builder: (context, child) => Opacity(
                      opacity: _opacity.value,
                      child: Transform.scale(
                        scale: _scale.value,
                        child: child,
                      ),
                    ),
                    child: _buildCard(a, glow, iconColor, iconData),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCard(
    AchievementNotification a,
    Color glowColor,
    Color iconColor,
    IconData iconData,
  ) {
    final tLabel = tierLabel(a.tier);
    return Container(
      width: 280,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: _cs.surface,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: glowColor,
            blurRadius: 24,
            spreadRadius: 4,
          ),
          BoxShadow(
            color: _cs.shadow,
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 分级缎带标签
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: glowColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: glowColor.withValues(alpha: 0.4)),
            ),
            child: Text(
              tLabel,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: glowColor,
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 图标（带光晕背景）
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.1),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: iconColor.withValues(alpha: 0.3),
                  blurRadius: 16,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(iconData, size: 36, color: iconColor),
          ),
          const SizedBox(height: 16),
          // 成就名称
          Text(
            a.name,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          if (a.description != null && a.description!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              a.description!,
              style: TextStyle(fontSize: 13, color: _cs.onSurfaceVariant),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 16),
          // 解锁提示
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.emoji_events, size: 16, color: glowColor),
              const SizedBox(width: 6),
              const Text(
                '成就解锁！',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

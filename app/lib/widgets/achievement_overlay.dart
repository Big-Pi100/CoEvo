// 全局成就通知 Overlay
//
// 挂载在 MaterialApp.builder 中，监听 achievementNotifierProvider 队列，
// 逐个展示成就特效卡（入场弹跳动效 + 分级光效 + 粒子撒花）。
// 分享海报也在同一 Stack 中渲染，不用 OverlayEntry。

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../api/api_config.dart';
import '../providers/achievement_notifier.dart';
import '../providers/auth_provider.dart';
import '../shared/achievement_icons.dart';
import 'achievement_share_card.dart';

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
    this.shape,
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
        canvas.drawRect(
          Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 0.6),
          paint,
        );
      } else if (shape == 1) {
        canvas.drawCircle(Offset.zero, p.size * 0.4, paint);
      } else {
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

/// 分享海报所需数据，加载后缓存避免重复请求
class _ShareData {
  _ShareData({
    required this.achievementKey,
    required this.achievementName,
    this.achievementDesc,
    required this.tier,
    required this.iconColor,
    required this.userName,
    this.referralCode,
  });

  final String achievementKey;
  final String achievementName;
  final String? achievementDesc;
  final String tier;
  final Color iconColor;
  final String userName;
  final String? referralCode;
}

class _AchievementOverlayState extends ConsumerState<AchievementOverlay>
    with TickerProviderStateMixin {
  String? _displayedKey;
  _ShareData? _shareData;

  ColorScheme get _cs => Theme.of(context).colorScheme;

  // ── Confetti 粒子系统 ──
  final List<_Particle> _particles = [];
  late AnimationController _confettiCtrl;
  double _screenWidth = 390;
  static const _confettiColors = [
    Color(0xFFFFD700),
    Color(0xFFC0C0C0),
    Color(0xFFCD7F32),
    Color(0xFFFF6B6B),
    Color(0xFF4ECDC4),
    Color(0xFF9B59B6),
    Color(0xFFFF8C00),
    Color(0xFF3498DB),
  ];

  @override
  void initState() {
    super.initState();
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
    _displayedKey = a.key;
    _spawnConfetti(a.tier);
    // 直接触发加载用户数据 → 显示全屏海报，无中间小弹窗
    _loadAndShowPoster(a);
  }

  void _hide() {
    _displayedKey = null;
    _shareData = null;
    if (mounted) setState(() {});
  }

  void _dismissCurrent() {
    ref.read(achievementNotifierProvider.notifier).dismiss();
    _displayedKey = null;
    _shareData = null;
    if (mounted) setState(() {});
  }

  /// 异步加载用户数据，完成后直接设置 _shareData 渲染全屏海报
  Future<void> _loadAndShowPoster(AchievementNotification a) async {
    String userName = '';
    String? referralCode;

    try {
      final auth = ref.read(authProvider);
      final uid = auth.userId;
      final token = auth.token;
      if (uid != null && token != null) {
        final headers = ApiConfig.headers(token: token);

        final codeResp = await http.get(
          Uri.parse('${ApiConfig.baseUrl}/api/referral/my-code?user_id=$uid'),
          headers: headers,
        );
        if (codeResp.statusCode == 200) {
          final data = jsonDecode(codeResp.body);
          referralCode = data['code'] as String? ?? data['referral_code'] as String?;
        }

        final profileResp = await http.get(
          Uri.parse('${ApiConfig.baseUrl}/api/user/$uid/profile'),
          headers: headers,
        );
        if (profileResp.statusCode == 200) {
          final data = jsonDecode(profileResp.body);
          userName = data['real_name'] as String? ??
              data['display_name'] as String? ??
              data['username'] as String? ??
              '';
        }
      }
    } catch (_) {}

    if (!mounted || _displayedKey != a.key) return;

    setState(() {
      _shareData = _ShareData(
        achievementKey: a.key,
        achievementName: a.name,
        achievementDesc: a.description,
        tier: a.tier,
        iconColor: _resolveColor(a),
        userName: userName,
        referralCode: referralCode,
      );
    });
  }

  void _closeShare() {
    setState(() => _shareData = null);
  }

  // ── Confetti 粒子逻辑 ──

  void _spawnConfetti(String tier) {
    _particles.clear();
    final rng = math.Random();
    final midX = _screenWidth / 2;
    final tierBase = tierColor(tier);

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
        x: midX + rng.nextDouble() * 300 - 150,
        y: -20 - rng.nextDouble() * 100,
        vx: rng.nextDouble() * 200 - 100,
        vy: rng.nextDouble() * 150 + 50,
        color: color,
        size: rng.nextDouble() * 8 + 4,
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
        p.x += p.vx * 0.016;
        p.y += p.vy * 0.016;
        p.vy += 300 * 0.016;
        p.vx *= 0.98;
        p.rotation += p.rotationSpeed * 0.016;

        if (progress > 0.6) {
          p.opacity = 1.0 - (progress - 0.6) / 0.4;
        }
      }
    });
  }

  @override
  void dispose() {
    _confettiCtrl.dispose();
    super.dispose();
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
      // 没有成就通知但有分享海报残留（极少情况）
      if (_shareData != null) {
        return Positioned.fill(
          child: AchievementShareCard(
            achievementKey: _shareData!.achievementKey,
            achievementName: _shareData!.achievementName,
            achievementDesc: _shareData!.achievementDesc,
            tier: _shareData!.tier,
            iconColor: _shareData!.iconColor,
            userName: _shareData!.userName,
            referralCode: _shareData!.referralCode,
            onClose: _closeShare,
          ),
        );
      }
      return const SizedBox.shrink();
    }

    // 有成就 → 全屏海报（数据就绪时）或只显示粒子（数据加载中）
    return Positioned.fill(
      child: Material(
        color: _shareData != null ? Colors.transparent : _cs.scrim,
        child: Stack(
          children: [
            // 粒子撒花层
            if (_particles.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _ConfettiPainter(_particles),
                  ),
                ),
              ),
            // 全屏海报（数据就绪后显示）
            if (_shareData != null)
              AchievementShareCard(
                achievementKey: _shareData!.achievementKey,
                achievementName: _shareData!.achievementName,
                achievementDesc: _shareData!.achievementDesc,
                tier: _shareData!.tier,
                iconColor: _shareData!.iconColor,
                userName: _shareData!.userName,
                referralCode: _shareData!.referralCode,
                onClose: _dismissCurrent,
              ),
          ],
        ),
      ),
    );
  }
}

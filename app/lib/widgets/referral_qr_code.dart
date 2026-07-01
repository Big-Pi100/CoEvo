/// 统一推广二维码组件
///
/// 所有展示推广二维码的地方都用此组件，保证：
/// - URL 格式一致：`{publicBaseUrl}/home?ref={code}&camp={context}`
/// - 样式统一：方形码眼 + 方形模块 + 深蓝色主题
///
/// 通过 `--dart-define=PUBLIC_BASE_URL=...` 配置域名。
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../api/api_config.dart';

class ReferralQrCode extends StatelessWidget {
  final String referralCode;
  final String camp;
  final double size;
  final Color? eyeColor;
  final Color? moduleColor;
  final Color? backgroundColor;

  const ReferralQrCode({
    super.key,
    required this.referralCode,
    this.camp = 'share',
    this.size = 104,
    this.eyeColor,
    this.moduleColor,
    this.backgroundColor,
  });

  String get _url =>
      '${ApiConfig.publicBaseUrl}/home?ref=$referralCode&camp=$camp';

  @override
  Widget build(BuildContext context) {
    final fg = eyeColor ?? moduleColor ?? const Color(0xFF1A237E);
    return QrImageView(
      data: _url,
      version: QrVersions.auto,
      size: size,
      backgroundColor: backgroundColor ?? Colors.transparent,
      eyeStyle: QrEyeStyle(
        eyeShape: QrEyeShape.square,
        color: fg,
      ),
      dataModuleStyle: QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square,
        color: moduleColor ?? fg,
      ),
    );
  }
}

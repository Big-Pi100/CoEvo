import 'package:flutter/material.dart';
import 'package:flutter_twemoji/flutter_twemoji.dart';

/// 带 Twemoji SVG 渲染的 Text 组件，emoji 自动替换为 Twitter 彩色 SVG
/// 用于替代常规 Text，消除 Flutter Web 对 fonts.gstatic.com 的 fallback 下载
class Tw extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;
  final double textScaleFactor;

  const Tw(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.softWrap,
    this.textScaleFactor = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    if (!_hasEmoji(data)) {
      return Text(
        data,
        style: style,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
        softWrap: softWrap,
      );
    }
    return TwemojiText(
      text: data,
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      softWrap: softWrap,
      textScaleFactor: textScaleFactor,
      twemojiFormat: TwemojiFormat.svg,
    );
  }
}

/// 快速判断字符串是否包含 emoji（避免不必要的 TwemojiText 开销）
bool _hasEmoji(String text) {
  // 常见 emoji 范围：U+1F300–U+1FAF6, U+2600–U+26FF, U+2700–U+27BF
  for (final rune in text.runes) {
    if (rune >= 0x1F300 && rune <= 0x1FAF6) return true;
    if (rune >= 0x2600 && rune <= 0x27BF) return true;
    if (rune >= 0x200D) return true; // ZWJ sequences
  }
  return false;
}

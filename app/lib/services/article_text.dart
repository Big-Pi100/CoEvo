// 文章正文的**文本处理**（纯函数 · 零 Flutter 依赖）
//
// # 🔴 为什么单独一层
// 「把一坨纯文本切成段落」看着简单，但它**决定了阅读界面能不能读**：
// 切错 → 要么整篇挤成一堵字墙，要么每句话都成了独立段落（段落间距满屏）。
// 两者都是**不报错的错**（页面照样渲染），只能靠断言锁住。
// → 抽成纯函数，由 `scripts/query_verify/bin/verify_article_text.dart` 独立断言。
//
// # 数据来源的口径（与后端的分工）
// 后端 `content_pool.body` 已按段落用 **`\n\n`** 分隔（`content_rss::strip_html_block`）。
// 🔑 所以本层只做「按 `\n\n` 切 + 逐段清理」，**不猜**段落边界
//    （不按句号、不按字数硬切 —— 那会把作者的段落结构毁掉）。
//
// 📌 同族判据：**上游已经算好的东西，下游不要重算** ——
//    若这里也去做「智能分段」，就出现了两处段落口径，必然不一致。

/// 把正文纯文本切成**可渲染的段落列表**。
///
/// 规则：
/// 1. 按**空行**（连续换行）分段 —— 与后端 `strip_html_block` 的输出口径一致
/// 2. 段内**单换行**视为软折行 → 合并成一个空格（源里的排版换行不是段落）
/// 3. 每段 trim；**丢掉空段**（否则渲染出多余间距）
///
/// ⚠️ 返回空列表 = 没有任何可读内容。调用方据此显示「正文未就绪」，
///    **不要**把「空列表」当成「加载失败」（那是两回事）。
List<String> splitParagraphs(String? text) {
  if (text == null) return const [];
  final raw = text.trim();
  if (raw.isEmpty) return const [];

  // 先按「一个或多个空行」切段。
  // 🔑 用 `\n\s*\n` 而不是字面 `\n\n`：源里常出现 `<p>a</p>\n \n<p>b</p>`
  //    （行尾有空格），只匹配 `\n\n` 会漏掉那种段落边界。
  final parts = raw.split(RegExp(r'\n\s*\n'));

  final out = <String>[];
  for (final p in parts) {
    // 段内的单换行 → 空格（源里的软折行）。
    // 注意这里**只在段内**做，段边界已经在上一步切掉了。
    final joined = p
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join(' ')
        .trim();
    if (joined.isNotEmpty) out.add(joined);
  }
  return out;
}

/// 正文是否**不足以阅读**（用于判断要不要给「正文未就绪」的提示）。
///
/// # 🔑 判据：段落数 == 0
/// 只要有一段就当有正文 —— **不设「至少 N 段」这类门槛**：
/// 一篇一句话的短讯也是**合法内容**（HN 的 Ask HN 常常就一段）。
/// 设门槛会让「内容存在但被判为未就绪」这种**用户无法理解**的状态出现。
bool hasReadableBody(List<String> paragraphs) => paragraphs.isNotEmpty;

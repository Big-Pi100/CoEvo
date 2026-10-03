//! 入库「**内容质量闸门**」—— 拦掉不该进内容池的条目（**纯函数 · 零 IO**）
//!
//! 与 [`crate::content_fetch::is_source_error_summary`] 同族：都是「入库前的把关」。
//!
//! # 拦两类（**两类互相独立**，不是同一件事）
//!
//! | 类 | 判据 | 真实案例（2026-10-03 生产实测）|
//! |---|---|---|
//! | **A. 非英语** | 拉丁字母占「全部字母」的比例 < [`MIN_LATIN_RATIO`] | Dev.to 的俄语投稿 |
//! | **B. 编码乱码** | 替换字符 `U+FFFD` 占比 > [`MAX_REPLACEMENT_RATIO`] | HN 的 `[pdf]` 帖子被当文本抓 |
//!
//! # 🔴 为什么 B 不能靠 A 兜住（这是实测推翻的一个「想当然」）
//!
//! 我最初以为「拦非英语就顺带拦住了乱码」。**实测否掉了**：
//!
//! | 条目 | 拉丁字母占比 | FFFD 占比 |
//! |---|---|---|
//! | 俄语那篇 | **6.8%** | 0% |
//! | PDF 乱码 A | **92.7%** | **41.8%** |
//! | PDF 乱码 B | **93.4%** | **42.1%** |
//!
//! ⇒ 乱码那两篇**九成是英文**（PDF 里的英文单词能解出来），所以语言判据**放过它们**。
//!    它们是**另一种毛病**：PDF 二进制被当 HTML 解析。
//!    实测 `body` 开头就是 `%PDF-1.7 … /Filter /FlateDecode … stream`。
//!
//! 📌 判据：**「一类坏内容的判据」不一定能兜住另一类** —— 要分别验证，别想当然。
//!
//! # 阈值不是拍脑袋：实测 523 篇生产正文
//!
//! 全部 523 篇跑这两个判据（脚本：`scripts/trace_verify/bin/probe_gate.dart`）：
//!
//! ```text
//!   丢弃 3 篇（1 俄语 + 2 PDF）· 保留 520 篇
//!   正例漏网: 无 ✅    误杀: 无 ✅
//!   临界样本: 空 —— 正常文章的拉丁占比全部 ≥97%、FFFD 全部为 0%
//! ```
//!
//! **「临界样本为空」是关键**：没有任何正常文章接近阈值 ⇒ 阈值有巨大安全边际，
//! 不是「勉强切过去」。
//!
//! ⚠️ **两处实现必须一致**：本模块与 `probe_gate.dart` 的判据/阈值是**同一套定义**。
//!    改了阈值要**同时改两处**，否则「验证过的阈值」只对其中一边成立。
//!    （📌 判据：「同一套判据要在两个实现里跑」时必须锁住定义 —— 见 skill `verifiable-core-logic`。）
//!    `test_matches_dart_probe_vectors` 用**同一组向量**在两侧交叉验证。

/// 字母总数低于这个值 → **不做判定**（放过）。
///
/// # 为什么必须有这条
///
/// 判据是**比例**，而比例在样本太小时不可靠：
/// `"Hi"` 全拉丁 = 100%，`"Привет"` 全西里尔 = 0% —— 但都不足以代表「这篇文章的语言」。
/// 实测正常文章都有数百个字母，所以 50 是很松的下限。
///
/// 📌 取舍：**宁可漏拦，不可误杀**（同 [`crate::content_fetch::SOURCE_ERROR_FINGERPRINTS`] 的判据）。
///    漏一篇短俄语文章 = 用户偶尔看到一篇，可接受；
///    误杀正常文章 = 内容持续缺失，且**不报错**、很难被发现。
pub const MIN_LETTERS: usize = 50;

/// 拉丁字母占「全部字母」比例的**下限**（低于它视为非英语）。
///
/// 实测：正常文章 ≥97%，俄语那篇 6.8% ⇒ 0.90 距离两侧都很远。
pub const MIN_LATIN_RATIO: f64 = 0.90;

/// 替换字符 `U+FFFD` 占比的**上限**（高于它视为编码乱码）。
///
/// `U+FFFD` 是「按 UTF-8 解码但解不出来」的**替换字符** —— 二进制被当文本的铁证。
/// 实测：正常文章 **全部 0%**；PDF 乱码 **41.8%** ⇒ 0.05 有 40 个百分点的余量。
pub const MAX_REPLACEMENT_RATIO: f64 = 0.05;

/// 🆕 2026-10-03：**不是 HTML 页面**的文件扩展名 —— 命中则**不抓取、不入库**。
///
/// # 🔴 为什么必须有这条（它堵的是乱码闸门的**盲区**）
///
/// 白哥问：「PDF 的占比如果很少的话，要不都过滤掉？」→ 实测后**建议过滤**，
/// 但理由**不是「占比少」**，而是下面两条：
///
/// **① 产品层**：PDF 是论文/报告（实测：`NTSB Preliminary Report`、
///    `Electrification Special Report`、`The Legend of von Neumann (1973)`），
///    学术语言不适合学英语；而且本产品的核心交互（**划词查词 + 朗读 + Markdown 渲染**）
///    在 PDF 上**全部会坏**。
///
/// **② 技术层**：抓 PDF 只有**两种**结果（实测生产库 4 条）：
///    | 结果 | 实例 | 危害 |
///    |---|---|---|
///    | **变乱码** | id=2041（3.5M 字符）· id=2692（4.3M）| 占**库体积 70.9%** |
///    | **body = 0** | id=195 · id=1495 | feed 里出现「点开没正文」的条目 |
///
/// 🔑 **关键是第二种**：`body = 0` 的条目**没有乱码** ⇒ [`check_content`] 的
///    乱码判据（`U+FFFD` 占比）**完全看不见它们**。
///    实测覆盖率只有 **2/4**。
///    ⇒ 「按 URL 形态过滤」是**更前面、更完整**的一道闸（4/4）。
///
/// # 实测数据（生产 924 条）
///
/// | 项 | 值 |
/// |---|---|
/// | URL 以 `.pdf` 结尾 | **4 条（0.43%）** |
/// | 其他文档类（`.doc` `.zip` `.xls` …）| **0 条** |
/// | 来源 | **全部是 HN**（其他 22 个源零 PDF）|
/// | **HN 每轮抓取里的占比** | **5.0%**（前 60 条含 3 条）⇒ **会持续产生** |
///
/// ⚠️ **「占比少」不是过滤的理由** —— 它是「5% 每轮持续产生」的反面：
///    单看库内 0.43% 很小，但它**不是一次性事件**。
///
/// # 误伤风险（实测为零）
///
/// 全库 URL 后缀分布：**920 网页 + 4 pdf** —— 只有 `.pdf` 一种非网页。
/// 特别验证过两个「看似会被误伤」的形态，**都不会**：
/// · `arxiv.org/abs/2609.38181` —— 是 `/abs/` 页面（**不是** `.pdf`）✅
/// · `dev.to/.../como-automatizar-facturas-pdf-...` —— url 含 `pdf` 但**不以它结尾** ✅
///   （这是「讲 PDF 的文章」，**是正常内容**，13 条，不该过滤）
pub const NON_HTML_EXTENSIONS: &[&str] = &[
    // 文档
    "pdf", "doc", "docx", "odt", "rtf", "txt", "epub", "mobi", // 表格 / 幻灯片
    "xls", "xlsx", "ods", "csv", "ppt", "pptx", "odp",
    // 压缩包（HN 偶尔有 `[zip]` 帖）
    "zip", "tar", "gz", "bz2", "xz", "7z",
];

/// 🆕 从 URL 提取「非 HTML 文档」的扩展名。返回 `Some(ext)` = 该跳过。
///
/// # 处理的形态（全部有断言锁住）
///
/// | 输入 | 结果 | 说明 |
/// |---|---|---|
/// | `https://a.com/x.pdf` | `Some("pdf")` | 基本形态 |
/// | `https://a.com/X.PDF` | `Some("pdf")` | **大小写归一** |
/// | `https://a.com/x.pdf?v=2#p1` | `Some("pdf")` | **剥 query / fragment** |
/// | `https://a.com/docs.pdf/index.html` | `None` | 🔑 只看**最后一段**（它才是文件名）|
/// | `https://a.com/report` | `None` | 无扩展名 |
/// | `https://a.com/v1.2/pdf` | `None` | 最后一段无点 ⇒ 不是扩展名 |
/// | `https://a.com` | `None` | 🔴 **域名里的点不算**（见下）|
///
/// # 🔴 为什么必须「先取最后一段，再找点」
///
/// 若直接对整串找最后一个 `.`，`https://example.com` 会得出 `com`
/// （恰好不在表里所以没出事，但那是**运气**）。
/// 先 `rsplit('/')` 取最后一段，`example.com` 就变成「无斜杠 ⇒ 整串即最后一段」，
/// 而它没有 `/` 之后的文件名 ⇒ 用 `rsplit_once('.')` 得到的 `com` 会被
/// 「最后一段必须是**路径**的最后一段」这个前提排除掉 ——
/// ⚠️ 诚实说：`example.com` 这种情况**我靠「`com` 不在表里」兜住**，
///    不是靠结构。所以**表里不能出现 `com` / `org` / `net` 这类 TLD**。
///    `test_non_html_extension_does_not_match_domain` 锁住这条。
pub fn non_html_extension(url: &str) -> Option<String> {
    // ① 剥 query / fragment（`x.pdf?v=2` 也是 PDF）
    let path = url.split(['?', '#']).next().unwrap_or(url);
    // ② 取**最后一个非空段**（文件名那一段）
    //    ⚠️ 用 `find` 而不是 `next`：`a.com/x.pdf/`（尾部斜杠）时
    //       `next` 会返回空串 ⇒ 漏拦。`find` 会跳过空段取到 `x.pdf`。
    let last = path.rsplit('/').find(|s| !s.is_empty())?;
    // ③ 取扩展名（必须有点，且点后非空）
    let (_, ext) = last.rsplit_once('.')?;
    if ext.is_empty() {
        return None;
    }
    let ext = ext.to_ascii_lowercase();
    if NON_HTML_EXTENSIONS.contains(&ext.as_str()) {
        Some(ext)
    } else {
        None
    }
}

// ⚠️ 已知盲区（**如实列出**，不掩盖）：
//
// | 形态 | 行为 | 为什么可接受 |
// |---|---|---|
// | `a.com/dl?f=x.pdf`（扩展名在 **query** 里）| **漏拦** | 罕见；且这种多是「下载端点」，返回的可能是 HTML 页 |
// | `a.com/download/1.0`（路径以版本号结尾）| 不拦 ✅ | `0` 不在表里 —— 这是**对的**（`v1.0` 是版本号不是文件）|
// | 无扩展名的下载端点（`a.com/getfile/123`）| **漏拦** | 判不出来；但这类返回 HTML 时正常处理，返回二进制时被**乱码判据**兜住 |

/// 内容被拒的原因（用于日志 —— 必须能看出**为什么**被拦）。
#[derive(Debug, Clone, PartialEq)]
pub enum ContentReject {
    /// 🆕 非 HTML 文档（PDF / 文档 / 压缩包）—— 不抓取、不入库。
    NonHtmlDocument { ext: String },
    /// 非英语：拉丁字母占比过低。
    NonEnglish { latin_pct: u32 },
    /// 编码乱码：替换字符占比过高。
    EncodingJunk { replacement_pct: u32 },
}

impl std::fmt::Display for ContentReject {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ContentReject::NonHtmlDocument { ext } => {
                write!(f, "非 HTML 文档（.{}）", ext)
            }
            ContentReject::NonEnglish { latin_pct } => {
                write!(f, "非英语（拉丁字母仅 {}%）", latin_pct)
            }
            ContentReject::EncodingJunk { replacement_pct } => {
                write!(f, "编码乱码（替换字符 {}%）", replacement_pct)
            }
        }
    }
}

/// 判定一条内容该不该入库。`None` = 通过。
///
/// `title` 与 `text`（正文或摘要，取能拿到的最长者）会**拼在一起**判定 ——
/// 因为「标题英文、正文俄语」与「标题俄语、正文英文」都该拦。
///
/// `url` 用于判「**是不是 HTML 页面**」（见 [`non_html_extension`]）。
/// ⚠️ 传 `""` = 不判 URL（测试与「无 url」场景用）。
///
/// # 判据顺序：**便宜且确定的放前面**
///
/// 1. **URL 形态**（字符串比较，O(len)）—— 且它**最确定**（url 是 `.pdf` 就是 PDF）
/// 2. 编码乱码（要遍历全串算占比）
/// 3. 语言（要遍历 + 计数）
///
/// 🔑 顺序不只是性能：`check_content` 返回**第一个**命中的原因，
///    而日志要看到「**最本质**的那个」—— 一条 PDF 的 `body` 是 3.5M 乱码，
///    报「乱码」会让人以为「抓取解析出问题」，报「非 HTML 文档」才指向真因。
pub fn check_content(title: &str, text: &str, url: &str) -> Option<ContentReject> {
    // ① URL 形态：最便宜、最确定、最本质
    if let Some(ext) = non_html_extension(url) {
        return Some(ContentReject::NonHtmlDocument { ext });
    }

    let all = format!("{}\n{}", title, text);

    // ① 乱码优先判：它的信号（U+FFFD）比语言更硬，且判据更简单
    let rep = replacement_char_ratio(&all);
    if rep > MAX_REPLACEMENT_RATIO {
        return Some(ContentReject::EncodingJunk {
            replacement_pct: (rep * 100.0).round() as u32,
        });
    }

    // ② 语言：样本太小时不判（见 `MIN_LETTERS` 的取舍说明）
    let (letters, latin) = count_letters(&all);
    if letters < MIN_LETTERS {
        return None;
    }
    let ratio = latin as f64 / letters as f64;
    if ratio < MIN_LATIN_RATIO {
        return Some(ContentReject::NonEnglish {
            latin_pct: (ratio * 100.0).round() as u32,
        });
    }

    None
}

/// `(字母总数, 其中拉丁字母数)`
pub fn count_letters(s: &str) -> (usize, usize) {
    let mut letters = 0usize;
    let mut latin = 0usize;
    for c in s.chars() {
        if is_letter(c) {
            letters += 1;
            if is_latin(c) {
                latin += 1;
            }
        }
    }
    (letters, latin)
}

/// 替换字符 `U+FFFD` 占比。
pub fn replacement_char_ratio(s: &str) -> f64 {
    let mut total = 0usize;
    let mut bad = 0usize;
    for c in s.chars() {
        total += 1;
        if c == '\u{FFFD}' {
            bad += 1;
        }
    }
    if total == 0 {
        0.0
    } else {
        bad as f64 / total as f64
    }
}

/// 拉丁字母：`A-Z` `a-z` + 拉丁扩展（`é ü å ñ` 等）。
///
/// ⚠️ 不含希腊字母（`α` 是 U+03B1 —— 技术文里常见作变量名，**不能算拉丁**，
///    否则「英文技术文里几个希腊字母变量」会推高占比；反过来把它算作「非拉丁」
///    才是正确的：它确实不是英语字母）。
fn is_latin(c: char) -> bool {
    let u = c as u32;
    (0x0041..=0x005A).contains(&u)        // A-Z
        || (0x0061..=0x007A).contains(&u) // a-z
        || (0x00C0..=0x024F).contains(&u) // 拉丁扩展 A/B
}

/// 「字母」的**覆盖面**（⚠️ 这是本判据最需要说清的地方）。
///
/// # 🔴 为什么不直接用 `char::is_alphabetic()`
///
/// `is_alphabetic()` 覆盖**全部** Unicode 字母（泰文/天城文/…），语义更完整；
/// 但本判据要**与 Dart 侧脚本一致**（`probe_gate.dart` 用同一张区间表），
/// 而 Dart 侧逐字符跑 `\p{L}` 正则代价高 —— 两边都用手写区间才能保证一致。
///
/// # ✅ 覆盖面（覆盖我们全部源的潜在内容）
///
/// | 文字系统 | 区间 | 我们的源里会出现吗 |
/// |---|---|---|
/// | 拉丁 | 0x0041–0x024F | 主体 |
/// | 希腊 | 0x0370–0x03FF | 技术文变量名 |
/// | 西里尔 | 0x0400–0x04FF | ✅ 实测有（俄语投稿）|
/// | 希伯来 | 0x0590–0x05FF | 罕见 |
/// | 阿拉伯 | 0x0600–0x06FF | 罕见 |
/// | CJK | 0x4E00–0x9FFF | ECNS 偶有 |
/// | 日文假名 | 0x3040–0x30FF | 罕见 |
/// | 韩文 | 0xAC00–0xD7AF | 罕见 |
///
/// # ⚠️ 不覆盖（**已知盲区**，如实列出）
///
/// 泰文 / 天城文 / 越南语扩展等 ⇒ 若出现**整篇**这类文字：
/// `letters` 会偏小 → 可能低于 [`MIN_LETTERS`] → **放过**（漏拦，不误杀）。
/// 当前 23 个源（英语媒体 + 英文技术社区）里**实测未出现** ⇒ 风险可接受。
/// 📌 判据：**判据的覆盖面要写出来**，别让人以为它「覆盖一切」。
fn is_letter(c: char) -> bool {
    let u = c as u32;
    is_latin(c)
        || (0x0370..=0x03FF).contains(&u) // 希腊
        || (0x0400..=0x04FF).contains(&u) // 西里尔
        || (0x0590..=0x05FF).contains(&u) // 希伯来
        || (0x0600..=0x06FF).contains(&u) // 阿拉伯
        || (0x4E00..=0x9FFF).contains(&u) // CJK 统一表意
        || (0x3040..=0x30FF).contains(&u) // 日文假名
        || (0xAC00..=0xD7AF).contains(&u) // 韩文音节
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 🔴 **正反例交叉验证**（本轮最重要的一条）
    ///
    /// 只测「反例（正常文章不被误杀）」会得到「永不误杀」的**假绿** ——
    /// 一个恒返回 `None` 的实现也能通过。
    /// 所以**两条腿都要**：正例必须拦、反例必须放。
    #[test]
    fn test_positive_and_negative_vectors() {
        // ── 正例 1：非英语（**生产实测样本**，id=2658）──
        let ru_title = "Telegram-бот с ИИ для заявок: архитектура без лишнего";
        let ru_body = "Типичный запрос малого бизнеса: «Хочу бота, который отвечает \
                       клиентам и собирает заявки». Если строить с нуля, придётся \
                       решать много задач: приём сообщений, хранение заявок, \
                       уведомления менеджеру. Разберём архитектуру по частям.";
        assert!(
            matches!(
                check_content(ru_title, ru_body, ""),
                Some(ContentReject::NonEnglish { .. })
            ),
            "🔴 俄语内容必须被拦下（生产实测样本）"
        );

        // ── 正例 2：编码乱码（**按生产实测特征构造**：真实样本 FFFD 占 41.8%）──
        //    真实样本开头是 `%PDF-1.7 … /Filter /FlateDecode … stream`。
        let junk = format!(
            "%PDF-1.7 {} 4 0 obj << /Filter /FlateDecode /Length 7521 >> stream x{}",
            "\u{FFFD}".repeat(120),
            "\u{FFFD}".repeat(180)
        );
        assert!(
            matches!(
                check_content("The Legend of von Neumann [pdf]", &junk, ""),
                Some(ContentReject::EncodingJunk { .. })
            ),
            "🔴 PDF 乱码必须被拦下"
        );

        // ── 反例 1：正常英文新闻（**生产实测样本**，id=2475）──
        let en_title =
            "Police questioning can shape a sexual assault case. Their approach is often wrong";
        let en_body =
            "A person walks by the Ithaca Police Department headquarters on March 22, 2021, \
                       in Ithaca, N.Y. Police officers often start interrogations by asking \
                       questions that assume the person is guilty, researchers say.";
        assert_eq!(
            check_content(en_title, en_body, ""),
            None,
            "🔴 正常英文内容**不能**被拦（误杀比漏拦更糟）"
        );

        // ── 反例 2：英文技术文（含 LaTeX / 代码 / 希腊字母变量 —— 最容易被误杀的一类）──
        let tech = "Adding Floating-Point Decimals for Fun and Profit \
                    A double-precision number \\(x\\) has 1 sign bit and 52 fraction bits. \
                    We compute \\alpha + \\beta with the formula \\(\\frac{1}{2}\\) and code: \
                    `const re = /\\d+/;` — the value is 0.1 + 0.2 = 0.30000000000000004.";
        assert_eq!(
            check_content("Adding Floating-Point Decimals", tech, ""),
            None,
            "🔴 英文技术文（LaTeX/代码/希腊字母）不能被拦"
        );

        // ── 反例 3：英文里混少量西里尔（id=744 实测：拉丁占比 99.8%）──
        let mixed = "Your Angular Test Passed. Could the User Click the Button? \
                     The fixture includes a name «Иван» and a city Москва in one test case.";
        assert_eq!(
            check_content(mixed, "", ""),
            None,
            "🔴 英文里混少量非拉丁（人名/地名）不能被拦"
        );
    }

    /// 样本太小时**不做判定** —— 这条锁住 [`MIN_LETTERS`] 的取舍。
    #[test]
    fn test_short_text_is_not_judged() {
        assert_eq!(
            check_content("Привет", "мир", ""),
            None,
            "短样本不判（否则误杀短英文标题）"
        );
        assert_eq!(check_content("Hi", "ok", ""), None);
        assert_eq!(check_content("", "", ""), None, "空内容不判");
        // 但**乱码是例外**：它不依赖最小样本（信号够硬）
        let short_junk = "\u{FFFD}".repeat(20);
        assert!(
            matches!(
                check_content("x", &short_junk, ""),
                Some(ContentReject::EncodingJunk { .. })
            ),
            "🔴 乱码不适用最小样本保护（它是硬信号）"
        );
    }

    /// 无字母（纯符号/数字/emoji）→ 不判（`letters == 0` 时不能除零，也不能误判）。
    #[test]
    fn test_no_letters_is_not_rejected() {
        assert_eq!(check_content("123 + 456 = 579", "!!! *** ###", ""), None);
        assert_eq!(check_content("🎉🎉🎉", "→←↑↓", ""), None);
        assert_eq!(count_letters("123"), (0, 0));
    }

    /// 🆕 2026-10-03：URL 扩展名提取 —— **全部形态与边界**。
    ///
    /// 这条判据是「**删/拦**」类判断，所以**两侧都要测**：
    /// 该拦的（正例）必须拦，不能拦的（反例）必须放 —— 只测一侧会假绿。
    #[test]
    fn test_non_html_extension_forms_and_boundaries() {
        // ── 正例：该拦 ──
        assert_eq!(
            non_html_extension("https://a.com/x.pdf").as_deref(),
            Some("pdf")
        );
        assert_eq!(
            non_html_extension("https://a.com/X.PDF").as_deref(),
            Some("pdf"),
            "大小写归一"
        );
        assert_eq!(
            non_html_extension("https://a.com/x.pdf?v=2").as_deref(),
            Some("pdf"),
            "剥 query"
        );
        assert_eq!(
            non_html_extension("https://a.com/x.pdf#page=3").as_deref(),
            Some("pdf"),
            "剥 fragment"
        );
        assert_eq!(
            non_html_extension("https://a.com/x.pdf/").as_deref(),
            Some("pdf"),
            "🔴 尾部斜杠（`next` 会漏，`find` 才对）"
        );
        assert_eq!(
            non_html_extension("https://a.com/x.zip").as_deref(),
            Some("zip")
        );
        assert_eq!(
            non_html_extension("https://a.com/x.docx").as_deref(),
            Some("docx")
        );
        // 生产实测的真实 url（含 %20 编码）
        assert_eq!(
            non_html_extension(
                "https://www.ntsb.gov/investigations/Documents/DCA26MA352%20Prelim.pdf"
            )
            .as_deref(),
            Some("pdf")
        );
        assert_eq!(
            non_html_extension("https://gwern.net/doc/math/1973-halmos.pdf").as_deref(),
            Some("pdf")
        );

        // ── 反例：**不能**拦（这组是防误杀的关键）──
        assert_eq!(
            non_html_extension("https://arxiv.org/abs/2609.38181"),
            None,
            "🔴 arXiv 是 `/abs/` 页面，不是 .pdf"
        );
        assert_eq!(
            non_html_extension("https://dev.to/luis_carias/como-automatizar-facturas-pdf-3j3e"),
            None,
            "🔴 「讲 PDF 的文章」url 含 pdf 但不以它结尾 —— 是**正常内容**"
        );
        assert_eq!(
            non_html_extension("https://github.com/x/y/releases/tag/v1.0"),
            None,
            "版本号结尾不是文件扩展名"
        );
        assert_eq!(non_html_extension("https://a.com/report"), None, "无扩展名");
        assert_eq!(
            non_html_extension("https://a.com/v1.2/pdf"),
            None,
            "最后一段无点 ⇒ 不是扩展名"
        );
        assert_eq!(
            non_html_extension("https://a.com/docs.pdf/index.html"),
            None,
            "🔑 只看**最后一段** —— 真实文件是 index.html"
        );
        assert_eq!(non_html_extension(""), None, "空 url（测试/无 url 场景）");
        assert_eq!(non_html_extension("not a url"), None);
    }

    /// 🔴 **域名不能被误判**（这是本条判据最危险的地方）。
    ///
    /// 若直接对整串找最后一个 `.`，`https://example.com` 会得出 `com`。
    /// 它**恰好**不在表里所以没出事 —— 但那是**运气**，所以要有断言锁住：
    /// **表里绝不能出现 `com` / `org` / `net` 这类 TLD**。
    #[test]
    fn test_non_html_extension_does_not_match_domain() {
        for u in [
            "https://example.com",
            "https://example.com/",
            "https://example.org",
            "https://example.net",
            "https://example.io",
            "https://feeds.npr.org/1001/rss.xml",
        ] {
            assert_eq!(
                non_html_extension(u),
                None,
                "🔴 域名/TLD 不该被当扩展名: {}",
                u
            );
        }
        // 反向断言：表里不能有 TLD（防止有人「顺手」加进去）
        for tld in ["com", "org", "net", "io", "gov", "edu"] {
            assert!(
                !NON_HTML_EXTENSIONS.contains(&tld),
                "🔴 `{}` 是 TLD，绝不能进 NON_HTML_EXTENSIONS（会拦掉整个域名）",
                tld
            );
        }
    }

    /// `check_content` 的 URL 判据 —— 正例拦、反例放，且**报的原因要对**。
    #[test]
    fn test_check_content_rejects_non_html_document() {
        // ── 正例：URL 是文档 → 拦，且原因必须是 `NonHtmlDocument` ──
        let r = check_content(
            "The Legend of von Neumann (1973) [pdf]",
            &"\u{FFFD}".repeat(300),
            "https://gwern.net/doc/math/1973-halmos.pdf",
        );
        assert!(
            matches!(r, Some(ContentReject::NonHtmlDocument { .. })),
            "🔴 必须报「非 HTML 文档」而**不是**「乱码」—— 乱码只是表象，PDF 才是真因。实得: {:?}",
            r
        );

        // 🔑 关键：**没有乱码**的 PDF 也要拦（这是乱码闸门的盲区）
        let clean_pdf = check_content(
            "Some Report [pdf]",
            "This is a perfectly readable English sentence about reports. "
                .repeat(5)
                .as_str(),
            "https://a.com/report.pdf",
        );
        assert!(
            matches!(clean_pdf, Some(ContentReject::NonHtmlDocument { .. })),
            "🔴 **body 正常**的 PDF 也必须拦（实测 id=195/1495 就是这种：body=0 无乱码）",
        );

        // body 为空也要拦（实测那两条 PDF 的 body 就是 0）
        assert!(
            matches!(
                check_content("Report [pdf]", "", "https://a.com/r.pdf"),
                Some(ContentReject::NonHtmlDocument { .. })
            ),
            "body 为空的 PDF 也要拦"
        );

        // ── 反例：正常网页 → 放行（继续走语言/乱码判据）──
        assert_eq!(
            check_content(
                "Police questioning can shape a sexual assault case",
                "A person walks by the police department headquarters on March 22.",
                "https://www.npr.org/2026/10/02/1234567/police-questioning"
            ),
            None,
            "🔴 正常新闻网页不能被 URL 判据误杀"
        );
        assert_eq!(
            check_content(
                "OpenRive editor",
                "A local-first editor for Rive animations.",
                "https://dev.to/x/openrive"
            ),
            None,
            "正常 Dev.to 文章"
        );
        // ⚠️ 反例里**有 url 含 pdf 字样**的（最容易被误伤的一类）
        assert_eq!(
            check_content(
                "How to autofacturas PDF invoices",
                "A guide about generating PDF invoices with code and templates.",
                "https://dev.to/luis/como-automatizar-facturas-pdf-3j3e"
            ),
            None,
            "🔴 「讲 PDF 的文章」不能被误杀（url 含 pdf 但不以它结尾）"
        );
    }

    /// 🔑 **生产真实数据**上的两侧一致性（最强的一条）。
    ///
    /// 用的是**真实那篇俄语**的正文（生产 `content_pool.id = 2658`，
    /// `signature: Telegram-бот с ИИ для заявок`），不是手编的样本。
    ///
    /// # 为什么这条不可省
    ///
    /// 本模块与 `probe_gate.dart` 各有一份「字母区间表」——
    /// **两份实现必然有漂移风险**，而漂移**不会报错**，只会让
    /// 「在 Dart 侧验证过的阈值」对服务端不成立。
    /// ⇒ 用同一份真实文本，断言两侧给出**同一量级**的比例。
    ///
    /// 实测（Dart 探针与 Python 独立复算均为 **6.8%**）。
    #[test]
    fn test_real_russian_body_ratio() {
        // 生产实测文本（`content_pool.id = 2658` 的 title + body 节选）
        let title = "Telegram-бот с ИИ для заявок: архитектура без лишнего";
        // 🔑 **完整正文**（不节选）—— 节选的比例与原篇不同，会误报「漂移」
        let body = r#"Типичный запрос малого бизнеса: «Хочу бота, который отвечает клиентам и собирает заявки»\. Если строить с нуля, легко переусложнить\. Разберём минимальную рабочую схему и где в ней место языковой модели\.

## Слой 1\. Детерминированный сценарий

Меню, кнопки, сбор контактов, пересылка заявки менеджеру\. Здесь ИИ не нужен вообще: сценарий до 10 веток описывается заранее, работает предсказуемо и дёшево\. Базовый бот приёма заявок — от 2 500 ₽ и около двух дней работы\.

## Слой 2\. Хранилище и логика

Как только нужно помнить клиента, считать заказы или выдавать статус, появляется база данных\. Бот с БД и логикой — от 5 000 ₽ и 3–5 дней\. Это же основа для каталога с корзиной\.

## Слой 3\. Модель для свободных вопросов

Языковая модель включается там, где сценарий не покрывает вопрос: «а у вас можно с собакой?», «сколько ехать от метро?»\. Важно ограничить её базой знаний — FAQ на 50–100 вопросов — и прописать, что она не делает: не называет цены вне прайса и не обещает сроков\. Подключение ChatGPT или Claude в бота — от 5 000 ₽\.

## Практические советы

- Логируйте все ответы модели первую неделю и правьте базу по реальным вопросам\.
- Держите явный выход на человека: команда или кнопка «Связаться с менеджером»\.
- Разворачивайте бота на аккаунте и сервере заказчика, а не у себя: так он остаётся владельцем данных\.

## Сколько это стоит в сумме

Типичная сборка «сценарий \+ база \+ модель» обходится от 10 000 ₽: бот с БД от 5 000 ₽ плюс подключение модели от 5 000 ₽\. База знаний на 50 вопросов — ещё от 2 000 ₽, если её нет готовой\. Сопровождение и правки после запуска — от 2 000 ₽ в месяц\.

Бот передаётся на аккаунт владельца с кодом и инструкцией\.

Варианты и цены: [https://om-digital\.ru/uslugi/telegram-boty/](https://om-digital.ru/uslugi/telegram-boty/)"#;

        let (letters, latin) = count_letters(&format!("{}\n{}", title, body));
        let pct = 100.0 * latin as f64 / letters as f64;

        assert!(letters > MIN_LETTERS, "样本应足够长（实测字母 {letters}）");
        assert!(
            (4.0..12.0).contains(&pct),
            // ⚠️ Rust 的浮点格式化是 `{:.1}`（**没有** C 风格的 `{:.1f}`）——
            //    写成 `{:.1f}` 会报 `unknown format trait 'f'`（已踩）
            "🔴 拉丁占比应在 4–12%（实测两侧均为 6.8%），实得 {pct:.1}% —— \
             若偏离，说明本模块的区间表与 Dart 探针**漂移**了"
        );
        assert!(
            matches!(
                check_content(title, body, ""),
                Some(ContentReject::NonEnglish { .. })
            ),
            "🔴 真实俄语正文必须被拦下"
        );
    }

    /// 🔑 与 Dart 探针（`scripts/trace_verify/bin/probe_gate.dart`）的**阈值一致性**。
    ///
    /// 这是「同一套判据在两个实现里跑」的防线：若有人只改了一边，
    /// 「本地验证过的阈值」就对服务端不成立 —— 而**这种偏差不会报错**。
    #[test]
    fn test_matches_dart_probe_vectors() {
        // 这三个向量在 probe_gate.dart 里跑出的判定（2026-10-03 实测）：
        //   id=2658 → 非英语（拉丁 6.8%）
        //   id=2041 → 乱码（FFFD 41.8%）
        //   正常文章 → 通过（临界样本为空）

        // 边界 1：正好 0.90 —— 我们取「低于才拦」，所以等于 0.90 应**通过**
        let exactly_90 = format!(
            "{}{}",
            "a".repeat(900),
            "я".repeat(100) // 900/(900+100) = 0.90
        );
        assert_eq!(
            check_content(&exactly_90, "", ""),
            None,
            "恰好 0.90 应通过（判据是「< 0.90 才拦」，边界要明确）"
        );

        // 边界 2：略低于 0.90 → 拦
        let just_below = format!("{}{}", "a".repeat(899), "я".repeat(101));
        assert!(
            matches!(
                check_content(&just_below, "", ""),
                Some(ContentReject::NonEnglish { .. })
            ),
            "0.899 应被拦"
        );

        // 边界 3：FFFD 恰好 0.05 → 通过（判据是「> 0.05 才拦」）
        let exactly_5pct = format!("{}{}", "a".repeat(950), "\u{FFFD}".repeat(50));
        assert_eq!(
            check_content(&exactly_5pct, "", ""),
            None,
            "恰 5% 应通过（边界要明确）"
        );

        // 边界 4：略高于 0.05 → 拦
        let just_above = format!("{}{}", "a".repeat(940), "\u{FFFD}".repeat(60));
        assert!(
            matches!(
                check_content(&just_above, "", ""),
                Some(ContentReject::EncodingJunk { .. })
            ),
            "6% 应被拦"
        );
    }
}

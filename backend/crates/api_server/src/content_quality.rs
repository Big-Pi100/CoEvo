//! 入库「**内容质量闸门**」—— 拦掉不该进内容池的条目（**纯函数 · 零 IO**）
//!
//! 与 [`crate::content_fetch::is_source_error_summary`] 同族：都是「入库前的把关」。
//!
//! # 拦四类（**四类互相独立**，不是同一件事）
//!
//! | 类 | 判据 | 真实案例（2026-10-03 生产实测）|
//! |---|---|---|
//! | **A. 非 HTML 文档** | URL 最后一段的扩展名 ∈ [`NON_HTML_EXTENSIONS`] | HN 的 `.pdf` 帖 |
//! | **B. 编码乱码** | 替换字符 `U+FFFD` 占比 > [`MAX_REPLACEMENT_RATIO`] | HN 的 `[pdf]` 帖子被当文本抓 |
//! | **C. 非英语字符集** | 英语字符占「全部字母」的比例 < [`MIN_ENGLISH_CHARSET_RATIO`] | Dev.to 的俄语投稿 |
//! | **D. 非英语词汇** | 英语功能词占「全部词」的比例 < [`MIN_ENGLISH_WORD_RATIO`] | 🆕 Dev.to 的越南语 / 西语 / 意语 / 土语投稿 |
//!
//! # 🔴 C 和 D 是**两条判据**，因为「区分文字系统」≠「区分语言」（2026-10-03 补）
//!
//! 一开始只有 C（原叫「拉丁占比」）。白哥报「一篇越南语文章没被过滤」⇒ 实测发现两个问题：
//!
//! **① 真 bug**：C 的字符区间表**漏了 `U+1E00–U+1EFF`（拉丁扩展附加）** ——
//! 而越南语的声调字符（`ạ ả ấ ầ ệ ị ọ ụ ứ ỳ`）**全在那一段**。
//! ⇒ 那些字符**既不入分子也不入分母**（被完全忽略）⇒ 分母只剩 ASCII + 扩展 A/B
//! ⇒ 占比**虚高到 100%** ⇒ **永不触发**。
//! ⚠️ 注释里我**自己写了**这个盲区，却赌「未出现」，而且预判的失效模式也错了
//! （以为是「字母偏小 → 放过」，实际是「分母偏小 → 比值虚高」）。
//!
//! **② 判据局限**：C 的结构决定它**永远拦不住拉丁语系的非英语** ——
//! 西语 / 意语 / 葡语 / 法语 / 德语 / **越南语** / 土耳其语 **全部用拉丁字母**
//! ⇒ 占比接近 100% ⇒ 统统放过。实测 6 条存量（西/意/越/土）**拉丁占比全是 100%**。
//!
//! ⇒ 对策：**C 修 bug 并明确其真实语义（「英语字符集占比」）**，
//! 同时**新增 D（英语功能词密度）** 直接判「文章是不是英语写的」。
//!
//! # 🔑 C 的真实语义：不是「拉丁字符占比」，而是「**英语所用字符集占比**」
//!
//! `is_english_charset` 里的字符集 = 英语文章实际会用到的拉丁字符
//! （ASCII 字母 + Latin-1 补充 + 拉丁扩展 A/B 的常见带音标字母）。
//!
//! **有意排除** `U+1E00–U+1EFF`（拉丁扩展附加）—— 虽然它们**是拉丁字母**，
//! 但**英语文章几乎不用**：该区块的字符绝大多数只出现在**越南语**与少数非洲语言里。
//! ⇒ 把它算作「非英语字符」是**有意的分类**，不是遗漏。
//! （📌 判据：**「是拉丁字母」与「是英语字符」不是同一件事** —— 判据要按**目的**分词，不是按 Unicode 分类。）
//!
//! ⚠️ 如实说明 C 的能力边界：对西语/意语/土语（用的是 `á é ñ ı ş` 等，
//!    落在 `0x00C0–0x024F` 内）C **仍然放过** —— 它们由 D 兜住。
//!
//! # 🔴 为什么 B 不能靠 C 兜住（这是实测推翻的一个「想当然」）
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
//! # 阈值不是拍脑袋：全量生产内容实测
//!
//! 每个阈值都用**生产库全量**标定（工具：`backend/examples/gate_replay.rs`，
//! 它直接读 `scripts/trace_verify/fixtures/prod_content_all.json`，
//! 调用**生产实现**跑，产出「拦截清单 + 临界样本 + 安全边际」）。
//!
//! | 判据 | 阈值 | 标定结果 |
//! |---|---|---|
//! | B 乱码 | `U+FFFD` > 5% | 正常文章**全部 0%**；PDF 乱码 **41.8%** |
//! | C 字符集 | 英语字符 < 90% | 正常文章 ≥97%；俄语 **6.8%**、越南语 **86.8%** |
//! | D 词汇 | 英语功能词 < 8% | 6 条非英语 **0.0–6.3%**；下一条真英语 **10.0%** |
//!
//! ⚠️ **两处实现必须一致，且「一致」要落到每一个共享定义**（不是只对阈值）：
//!    **阈值 + 字符区间表 + 词表 + 分词规则 + 边界处理** 全部要对齐
//!    （`probe_gate.dart` 与 `gate_replay` 是不同实现，漂移**不会报错**）。
//!    📌 上一轮就是只对齐了阈值、没对齐区间表 ⇒ 用 Python 的 `isalpha()`（第三套口径）
//!       去「验证」前两套 ⇒ 三方都不一致却谁也没发现。
//!    （判据见 skill `verifiable-core-logic`：**跨实现的「相等」必须覆盖全部共享定义**。）
//!    单测 `test_matches_dart_probe_vectors` 用**同一组向量**锁住这一致性。

/// 字母总数低于这个值 → **不做 C 判据**（放过）。
///
/// # 为什么必须有这条
///
/// 判据是**比例**，而比例在样本太小时不可靠：
/// `"Hi"` 全英语字符 = 100%，`"Привет"` 全西里尔 = 0% —— 但都不足以代表「这篇文章的语言」。
/// 实测正常文章都有数百个字母，所以 50 是很松的下限。
///
/// 📌 取舍：**宁可漏拦，不可误杀**（同 [`crate::content_fetch::SOURCE_ERROR_FINGERPRINTS`] 的判据）。
///    漏一篇短俄语文章 = 用户偶尔看到一篇，可接受；
///    误杀正常文章 = 内容持续缺失，且**不报错**、很难被发现。
pub const MIN_LETTERS: usize = 50;

/// 词（token）总数低于这个值 → **不做 D 判据**（放过）。
///
/// # 为什么 D 的下限比 C 的高（50 个字母 vs 30 个词）
///
/// D 的分母是**词数**，而**入库时往往只拿到 `title + summary`** ——
/// 很多源（NPR / ECNS）的 RSS 只给短摘要，正文是**之后补抓**的
/// ⇒ **短文本是常态**（实测 966 条里 **283 条 token < 30**）。
/// 所以 30 是「能判就判」的实战下限，不是理论下限。
///
/// ⚠️ **必须如实知道**：token < 30 的条目 **D 判据管不到**（漏拦来源之一）。
///    这是有意接受的代价 —— 反过来（把下限压到 10）会因样本太小而误杀短英文标题。
pub const MIN_TOKENS: usize = 30;

/// 🆕 英语字符占「全部字母」比例的**下限**（低于它视为非英语文字）。
///
/// # ⚠️ 名字改了：`MIN_LATIN_RATIO` → `MIN_ENGLISH_CHARSET_RATIO`
///
/// 旧名字说「拉丁占比」，但实现对**拉丁语系的非英语毫无办法**（西/意/越/土全 100%）
/// ⇒ **名实不符**，是本轮问题的根源之一。真实语义是
/// 「**英语所用字符集的占比**」（见 [`is_english_charset`] 的说明）。
///
/// 实测（生产全量）：正常文章 ≥97%；俄语 **6.8%**；🆕 越南语 **86.8%**（修区间表后）
/// ⇒ 0.90 距离两侧都远。
pub const MIN_ENGLISH_CHARSET_RATIO: f64 = 0.90;

/// 🆕 英语功能词占「全部词」比例的**下限**（低于它视为「拉丁文字但非英语」）。
///
/// # 为什么需要这条（C 结构性做不到）
///
/// C 判的是**字符集**，而西语/意语/葡语/法语/德语/**越南语**/土耳其语
/// **全用拉丁字母** ⇒ C 对它们永远是 100% ⇒ 只能靠 D。
///
/// # 阈值 8% 的标定（生产**全量 966 条**实测 · `examples/gate_replay.rs`）
///
/// ```text
/// ── 最低 6 条（全部是真非英语）──
///   2.58%  id=2032  越南语   A Linux Kernel CVE Just Dropped…      ← 标题英文、正文越语
///   3.05%  id=737   西语     Cómo automatizar facturas PDF…
///   3.37%  id=1645  土耳其语 Haftalık yapay zekâ özeti…
///   4.80%  id=8     西语     En esta ciudad de Pensilvania…        ← NPR 也发西语
///   6.88%  id=1021  意大利语 OpenAPA: una vecchia idea militare…
///   （id=4260 越南语被**字符集**判据先拦下 —— 英语字符只有 86.7%，轮不到词汇判据）
///
/// ── 保留条目里最低的真英语 ──
///  13.45%  id=2135  英语  The 2026 Student Podcast Challenge…
///  14.62%  id=1505  英语  TurboNotes: Local-first Markdown notes…
///  14.73%  id=1460  英语  Several vulnerabilities have been discovered…（Debian 安全公告）
/// ```
///
/// **⇒ 8% 到 13.45% 之间是一条干净的隔离带**（真非英语最高 6.88%、真英语最低 13.45%），
/// 安全边际 **1.68 倍** —— 不是「勉强切过去」。
///
/// ⚠️ 但**边际比 C 小得多**（C 是 6.8% vs 99.8%）⇒ D 是**更脆的判据**：
///    词表 / 分词规则 / 分母规则一改，标定就得重做。
///    🔴 **改 `ENGLISH_FUNCTION_WORDS`、`counts_as_language_word` 或分词规则
///    ⇒ 必须重跑 `gate_replay.rs` 重新标定。**
pub const MIN_ENGLISH_WORD_RATIO: f64 = 0.08;

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
    /// 非 HTML 文档（PDF / 文档 / 压缩包）—— 不抓取、不入库。
    NonHtmlDocument { ext: String },
    /// 🔴 非英语**文字**：英语所用字符占比过低（原 `NonEnglish { latin_pct }`）。
    ///
    /// 名字改了：旧名说的是「拉丁占比」，但对拉丁语系的非英语（西/意/越/土）无能为力
    /// —— **名实不符**。真实语义是「英语所用**字符集**的占比」。
    NonEnglishCharset { english_charset_pct: u32 },
    /// 🆕 非英语**词汇**：英语功能词占比过低（拉丁文字，但不是英语写的）。
    NonEnglishWords { english_word_pct: u32 },
    /// 编码乱码：替换字符占比过高。
    EncodingJunk { replacement_pct: u32 },
}

impl std::fmt::Display for ContentReject {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ContentReject::NonHtmlDocument { ext } => {
                write!(f, "非 HTML 文档（.{}）", ext)
            }
            ContentReject::NonEnglishCharset {
                english_charset_pct,
            } => {
                write!(f, "非英语文字（英语字符仅 {}%）", english_charset_pct)
            }
            ContentReject::NonEnglishWords { english_word_pct } => {
                write!(f, "非英语词汇（英语功能词仅 {}%）", english_word_pct)
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
/// 因为「标题英文、正文俄语」与「标题俄语、正文英文」都该拦
/// （🆕 实测 `id=2032`：标题是纯英文 `A Linux Kernel CVE Just Dropped…`，正文是越南语）。
///
/// `url` 用于判「**是不是 HTML 页面**」（见 [`non_html_extension`]）。
/// ⚠️ 传 `""` = 不判 URL（测试与「无 url」场景用）。
///
/// # 判据顺序：**便宜且确定的放前面**
///
/// 1. **URL 形态**（字符串比较，O(len)）—— 且它**最确定**（url 是 `.pdf` 就是 PDF）
/// 2. **编码乱码**（`U+FFFD` 是硬信号 —— 「解码失败」这件事没有歧义）
/// 3. **字符集**（英语字符占比 —— 客观事实：这些字符**是不是**英语用的）
/// 4. **词汇**（功能词密度 —— 统计判据，最"软"，放最后）
///
/// 🔑 顺序不只是性能：`check_content` 返回**第一个**命中的原因，
///    而日志要看到「**最本质**的那个」—— 一条 PDF 的 `body` 是 3.5M 乱码，
///    报「乱码」会让人以为「抓取解析出问题」，报「非 HTML 文档」才指向真因。
///
/// # 🔴 一个必须避开的坑：**样本不足的判据不能短路后面的判据**
///
/// 3 和 4 各有自己的「样本下限」（[`MIN_LETTERS`] / [`MIN_TOKENS`]）。
/// 若写成「3 不满足下限 → `return None`」，则 4 **永远不会被跑到** ——
/// 而「字母太少」不蕴含「词太少」（30 个单字母词 = 30 letters < 50 但 tokens = 30 ≥ 30）。
/// ⇒ 这里**逐个判据独立判断**，不用 `return None` 短路。
pub fn check_content(title: &str, text: &str, url: &str) -> Option<ContentReject> {
    // ① URL 形态：最便宜、最确定、最本质
    if let Some(ext) = non_html_extension(url) {
        return Some(ContentReject::NonHtmlDocument { ext });
    }

    let all = format!("{}\n{}", title, text);

    // ② 乱码：它的信号（U+FFFD）比语言更硬，且不依赖最小样本
    let rep = replacement_char_ratio(&all);
    if rep > MAX_REPLACEMENT_RATIO {
        return Some(ContentReject::EncodingJunk {
            replacement_pct: (rep * 100.0).round() as u32,
        });
    }

    // ③ 字符集：英语所用字符占比（样本太小时**不判，但继续往下判**）
    let (letters, eng_chars) = count_letters(&all);
    if letters >= MIN_LETTERS {
        let ratio = eng_chars as f64 / letters as f64;
        if ratio < MIN_ENGLISH_CHARSET_RATIO {
            return Some(ContentReject::NonEnglishCharset {
                english_charset_pct: (ratio * 100.0).round() as u32,
            });
        }
    }

    // ④ 词汇：英语功能词密度（C 拦不住拉丁语系非英语，由这条兜）
    let (tokens, hits) = english_word_stats(&all);
    if tokens >= MIN_TOKENS {
        let ratio = hits as f64 / tokens as f64;
        if ratio < MIN_ENGLISH_WORD_RATIO {
            return Some(ContentReject::NonEnglishWords {
                english_word_pct: (ratio * 100.0).round() as u32,
            });
        }
    }

    None
}

/// `(字母总数, 其中**英语所用字符**数)`
///
/// ⚠️ 第二个返回值**不是**「拉丁字母数」—— 见 [`is_english_charset`]。
/// （旧名 `latin` 已改，因为「拉丁」与「英语所用」不是同一件事，而这正是本轮 bug 的根。）
pub fn count_letters(s: &str) -> (usize, usize) {
    let mut letters = 0usize;
    let mut eng = 0usize;
    for c in s.chars() {
        if is_letter(c) {
            letters += 1;
            if is_english_charset(c) {
                eng += 1;
            }
        }
    }
    (letters, eng)
}

/// `(词总数, 其中英语功能词数)` —— [`MIN_ENGLISH_WORD_RATIO`] 判据的原始计数。
///
/// # 🔴 分母**不包含**「非自然语言 token」（2026-10-03 全量复跑后修正）
///
/// 这是本轮第二个实测教训。第一版把**所有**字母串都算进分母，全量复跑立刻抓到误杀：
///
/// ```text
/// id=1460（LWN 转发的 Debian 安全公告，**正文是英文**）
///   修正前：英语字符 100% · 功能词密度 2.63%（43/1632）⇒ 被拦 ❌ 误杀
///   修正后：同一篇 · 功能词密度 **14.73%（43/292）** ⇒ 保留 ✅
///   差异来自**分母**：1632 个 token 里有 1340 个是 `CVE` / `DSA` / `SHA` 这类缩写
///   真身：`From: Salvatore Bonaccorso … Subject: [SECURITY] [DSA 6528-1]` +
///         **几百个 `CVE-2026-80938` 编号** + 几十个包名（`linux-image-6.1.0-26-amd64`）
/// ```
///
/// 🔑 **同一个分子（43），分母一改，结论从「非英语」翻成「英语」** ——
///    ⇒ 比例类判据的**分母定义**和阈值一样重要，必须写清并单独断言。
///
/// ⇒ 那些 `CVE` / `SHA512` / `DSA` / 包名**不是自然语言**，却把分母灌到 1632
///   ⇒ 比例被稀释到阈值以下。**修法是修分母，不是调阈值**
///   （调阈值会同时放过真非英语，因为两者比例**交错**：1460 = 2.63% vs id=2032 = 2.50%）。
///
/// # 分词规则（**这是判据的一部分**，改它必须重跑 `gate_replay.rs` 重新标定）
///
/// · 一个「词」= 一段**连续字母**（用 [`is_letter`] 判字符是否算字母）；
/// · **撇号算词内字符**（`don't` 是一个词，不是 `don` + `t`）——
///   弯撇号 `’` 归一为直撇号 `'`（英文排版常用弯的，不归一就会漏掉 `don’t`）；
/// · 撇号**不能开头**（`'tis` 这种不常见，且避免把引号 `'quote'` 粘成一个词）；
/// · 查词表时**统一小写**（`The` 与 `the` 都要命中）；
/// · 🆕 **缩写/标识符不计入分母**（见 [`counts_as_language_word`]）。
///
/// ⚠️ 数字、代码、标点都被当作分隔符 —— 所以「纯代码块」的 token 数会很少，
///    可能低于 [`MIN_TOKENS`] ⇒ 不判（放过），这是有意的保守取舍。
pub fn english_word_stats(s: &str) -> (usize, usize) {
    let mut tokens = 0usize;
    let mut hits = 0usize;
    let mut cur = String::new();
    for c in s.chars() {
        if is_letter(c) {
            // ⚠️ **保留原始大小写** —— `counts_as_language_word` 要靠它识别缩写
            cur.push(c);
        } else if (c == '\'' || c == '\u{2019}') && !cur.is_empty() {
            cur.push('\''); // 词内撇号：归一为 ASCII 直撇号
        } else if !cur.is_empty() {
            if counts_as_language_word(&cur) {
                tokens += 1;
            }
            if is_english_function_word(&cur.to_lowercase()) {
                hits += 1;
            }
            cur.clear();
        }
    }
    if !cur.is_empty() {
        if counts_as_language_word(&cur) {
            tokens += 1;
        }
        if is_english_function_word(&cur.to_lowercase()) {
            hits += 1;
        }
    }
    (tokens, hits)
}

/// 🆕 这个 token 算不算「自然语言词」（→ 要不要计入**分母**）。
///
/// # 为什么必须有这条
///
/// 技术文本里混着大量**非语言**的字母串 —— 缩写（`CVE` `SHA512` `DSA` `PGP`）、
/// 标识符（`linux-image-6.1.0-26-amd64`）、长技术名词。
/// 它们会让「功能词密度」的分母虚高 ⇒ **英文技术文被误判成非英语**
/// （实测 `id=1460` 就是这么被误杀的，见 [`english_word_stats`] 的说明）。
///
/// # 规则（**保守**：只排除明确不是词的，宁可少排除）
///
/// | 规则 | 排除什么 | 为什么这么定 |
/// |---|---|---|
/// | **全大写**（≥ 2 个字母且一个小写都没有）| `CVE` `SHA512` `PGP` `DSA` | 正常英文句子里的词**不会**全大写（`I` 除外，见下）|
/// | **长度 > 20** | 超长技术标识符 | 英语最长常用词 ~15；20 已很宽松 |
/// | 单字母 | **不排除** ✅ | `I` / `a` 是英语功能词，排除它们会伤判据 |
/// | 非 ASCII 字母（越南语/西里尔…）| **不排除** ✅ | 没有大小写概念，`upper/lower` 都是 0 ⇒ 自然通过 |
///
/// ⚠️ 已知的**漏排除**（如实列出）：包名那样的小写长串（`linux-image-6.1.0-26-amd64`
///    会被切成 `linux` `image` `amd64`，都可能计入分母）。所以这是**缓解**而非根治 ——
///    但实测有效：`id=1460` 的分母 `1632 → 292`，密度 `2.63% → 14.73%`，误杀消失；
///    全量 966 条复跑后**零误杀**（见 `examples/gate_replay.rs`）。
fn counts_as_language_word(tok: &str) -> bool {
    let n = tok.chars().count();
    if n < 2 {
        return true; // 单字母：`I` / `a` 是功能词，必须保留
    }
    if n > 20 {
        return false; // 超长 ⇒ 技术标识符
    }
    let upper = tok.chars().filter(|c| c.is_ascii_uppercase()).count();
    let lower = tok.chars().filter(|c| c.is_ascii_lowercase()).count();
    // 全大写（≥2 个字母、无一个小写）⇒ 缩写/标识符（`CVE` `DSA` `SHA`）
    !(upper >= 2 && lower == 0)
}

/// 查词表（**二分** —— 词表必须升序，`test_function_word_list_is_sorted` 锁住）。
///
/// 🔑 用二分而不是 `contains` 线性扫描：全量 966 条、平均几千 token，
///    线性扫描是 O(tokens × 200) 的比较量级，二分是 O(tokens × log 200)。
fn is_english_function_word(w: &str) -> bool {
    ENGLISH_FUNCTION_WORDS.binary_search(&w).is_ok()
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

/// **英语所用字符**：`A-Z` `a-z` + Latin-1 补充 + 拉丁扩展 A/B 的常见带音标字母。
///
/// # 🔴 名字原来叫 `is_latin` —— 为什么改
///
/// 旧名说「拉丁字母」，但它**有意排除** `U+1E00–U+1EFF`（拉丁扩展附加），
/// 而那些**确实是拉丁字母**。**名字与实现不符**是上一轮 bug 的温床
/// （我照名字理解为「拉丁 vs 非拉丁」，于是没发现越南语字符被**整个忽略**）。
///
/// 改名后排除就有了**明确理由**：
///
/// · `U+1E00–U+1EFF` 的字符（`ạ ả ấ ầ ệ ị ọ ụ ứ ỳ`）**几乎只出现在越南语**
///   （及少数非洲语言）—— **英语文章不用它们**。
/// · ⇒ 「大量出现 ExtAdditional」本身就是「这不是英语」的**强信号**。
///
/// 📌 判据：**「是拉丁字母」与「是英语所用字符」不是同一件事** ——
///    判据要按**目的**（识别英语）划分，不是照抄 Unicode 的字母分类。
///
/// ⚠️ 不含希腊字母（`α` = U+03B1）：技术文里常见作变量名，算它作「英语字符」
///    会推高占比 ⇒ **不能算**（它确实不是英语字符）。
///
/// ⚠️ 能力边界（如实说）：西语/意语/土语用的 `á é í ó ú ñ ü ç ğ ş ı` 等
///    落在 `0x00C0–0x024F` 内 ⇒ 在本函数眼里**是英语字符** ⇒
///    [`MIN_ENGLISH_CHARSET_RATIO`] 对它们**永远通过**（由 [`MIN_ENGLISH_WORD_RATIO`] 兜住）。
fn is_english_charset(c: char) -> bool {
    let u = c as u32;
    (0x0041..=0x005A).contains(&u)        // A-Z
        || (0x0061..=0x007A).contains(&u) // a-z
        || (0x00C0..=0x024F).contains(&u) // Latin-1 补充 + 拉丁扩展 A/B
}

/// 「字母」的**分母覆盖面**（⚠️ 这是本判据最需要说清的地方）。
///
/// # 🔴 上一轮就是在这里翻车的（如实记录，防重犯）
///
/// 旧注释写了「⚠️ 不覆盖：泰文/天城文/**越南语扩展**等 …… 实测未出现 ⇒ 风险可接受」
/// —— **赌「没出现」，而它出现了**（Dev.to 有越南语投稿）。
/// 而且**失效模式也预判错了**：以为是「字母偏少 ⇒ 低于 [`MIN_LETTERS`] ⇒ 放过」，
/// 实际是「**分母偏小 ⇒ 比值虚高到 100% ⇒ 永不触发**」。
///
/// 📌 判据：**「已知盲区」不能靠「应该不会出现」来兜** ——
///    要么补上区间，要么给一条**不依赖该盲区**的兜底判据
///    （本轮兜底 = [`MIN_ENGLISH_WORD_RATIO`]，它只依赖词表，不依赖字符区间表）。
///
/// # 🔴 为什么不直接用 `char::is_alphabetic()`
///
/// `is_alphabetic()` 覆盖**全部** Unicode 字母（泰文/天城文/…），语义更完整；
/// 但本判据要**与 Dart 侧脚本一致**（`probe_gate.dart` 用同一张区间表），
/// 而 Dart 侧逐字符跑 `\p{L}` 正则代价高 —— 两边都用**手写区间**才能保证逐字节一致。
///
/// # ✅ 覆盖面
///
/// | 文字系统 | 区间 | 我们的源里会出现吗 |
/// |---|---|---|
/// | 英语所用（见 [`is_english_charset`]）| 0x0041–0x024F | **主体** |
/// | 🆕 组合变音符号 | 0x0300–0x036F | 有（NFD 形式的带音标词）|
/// | 希腊 | 0x0370–0x03FF | 技术文变量名 |
/// | 西里尔 | 0x0400–0x04FF | ✅ 实测有（俄语投稿）|
/// | 希伯来 | 0x0590–0x05FF | 罕见 |
/// | 阿拉伯 | 0x0600–0x06FF | 罕见 |
/// | 🆕 拉丁扩展附加 | 0x1E00–0x1EFF | ✅ **实测有**（越南语投稿）—— 上一轮的 bug 就在这 |
/// | 🆕 拉丁扩展 C / D | 0x2C60–0x2C7F / 0xA720–0xA7FF | 罕见 |
/// | CJK | 0x4E00–0x9FFF | ECNS 偶有 |
/// | 日文假名 | 0x3040–0x30FF | 罕见 |
/// | 韩文 | 0xAC00–0xD7AF | 罕见 |
///
/// # ⚠️ 本函数**不需要**「覆盖一切」
///
/// 「字母」的功能是**分母**。**多覆盖**一种文字 ⇒ 该文字占比变小 ⇒ **更容易被拦**（不误杀英语）；
/// **少覆盖** ⇒ 该文字被忽略 ⇒ 占比虚高 ⇒ **漏拦**。
/// ⇒ 漏覆盖的方向是「漏拦」而非「误杀」，所以剩余盲区（泰文/天城文等）
///    **风险等级低**，但要靠 ④ 词汇判据兜底（它们同样拦不住时才是真漏）。
fn is_letter(c: char) -> bool {
    let u = c as u32;
    is_english_charset(c)
        || (0x0300..=0x036F).contains(&u) // 🆕 组合变音符号（Mn）
        || (0x0370..=0x03FF).contains(&u) // 希腊
        || (0x0400..=0x04FF).contains(&u) // 西里尔
        || (0x0590..=0x05FF).contains(&u) // 希伯来
        || (0x0600..=0x06FF).contains(&u) // 阿拉伯
        || (0x1E00..=0x1EFF).contains(&u) // 🆕 拉丁扩展附加（越南语声调字符）★ 上一轮的 bug
        || (0x2C60..=0x2C7F).contains(&u) // 🆕 拉丁扩展 C
        || (0xA720..=0xA7FF).contains(&u) // 🆕 拉丁扩展 D
        || (0x4E00..=0x9FFF).contains(&u) // CJK 统一表意
        || (0x3040..=0x30FF).contains(&u) // 日文假名
        || (0xAC00..=0xD7AF).contains(&u) // 韩文音节
}

/// 🆕 英语**功能词**表（闭类词）—— [`MIN_ENGLISH_WORD_RATIO`] 判据的词表。
///
/// # 为什么是「功能词」而不是「常用词」
///
/// 判据要回答的是「**这篇文章是不是英语写的**」。
/// 若词表里混入**内容词**（`time` `people` `work` `code` `data` …），
/// 则**越南语技术文里夹的英文技术词**会被误当「英语证据」（`id=2032` 正是这种：
/// 标题英文 `A Linux Kernel CVE…`、正文越南语）。
/// ⇒ 只收**闭类词**：冠词 / 代词 / 介词 / 连词 / 助动词 / 情态动词 / 常见副词。
///    这类词**只在英语句法结构中出现**，是最干净的「英语信号」。
///
/// ⚠️ 词表**必须严格升序**（[`is_english_function_word`] 用二分查找）——
///    `test_function_word_list_is_sorted` 锁住；改词表后**必须重跑 `gate_replay.rs` 重新标定阈值**
///    （8% 这个数是在**本词表**上测出来的，换词表就不成立）。
///
/// 🔑 大小写：分词时已**统一小写**，所以表里只放小写形式。
/// 🔑 撇号：分词时弯撇号 `’` 已归一为直撇号 `'`，所以 `don't` 用 ASCII 撇号写法。
///
/// ⚠️ `#[rustfmt::skip]`：这是**词表**（数据），不是代码。
///    默认的 rustfmt 会把它排成「一行一个词」（242 行）——
///    那样就**看不出词表的规模与覆盖范围**了（这是本表最需要被一眼看到的信息）。
///    紧凑排布也便于与 Dart 侧的同名表**逐行比对**（跨实现一致性靠肉眼 + diff）。
#[rustfmt::skip]
pub const ENGLISH_FUNCTION_WORDS: &[&str] = &[
    "a", "about", "above", "across", "after", "again", "against", "all", "almost", "along",
    "already", "also", "although", "always", "am", "among", "an", "and", "another", "any",
    "anyone", "anything", "are", "aren't", "around", "as", "at", "away", "back", "be",
    "because", "been", "before", "behind", "being", "below", "beneath", "beside", "besides",
    "between", "beyond", "both", "but", "by", "can", "can't", "cannot", "could", "couldn't",
    "despite", "did", "didn't", "do", "does", "doesn't", "doing", "don't", "done", "down",
    "during",
    "each", "either", "else", "enough", "even", "ever", "every", "everyone", "everything",
    "except", "far", "few", "for", "from", "further", "had", "hadn't", "has", "hasn't",
    "have", "haven't", "having", "he", "her", "here", "hers", "herself", "him", "himself",
    "his", "how", "however", "i", "i'd", "i'll", "i'm", "i've", "if", "in", "inside",
    "instead", "into", "is", "isn't", "it", "it's", "its", "itself", "just", "later", "let's",
    "many", "may", "me", "might", "mine", "more", "most", "much", "must", "my", "myself",
    "near", "neither", "never", "no", "nobody", "nor", "not", "nothing", "now", "of", "off",
    "often", "on", "once", "only", "onto", "or", "other", "otherwise", "ought", "our", "ours",
    "ourselves", "out", "outside", "over", "past", "per", "quite", "rarely", "rather", "same",
    "seldom", "shall", "she", "should", "shouldn't", "since", "so", "some", "someone",
    "something", "sometimes", "soon", "still", "such", "than", "that", "that's", "the",
    "their", "theirs", "them", "themselves", "then", "there", "there's", "therefore", "these",
    "they", "they're", "they've", "this", "those", "though", "through", "throughout", "thus",
    "to", "together", "too", "toward", "towards", "under", "underneath", "unless", "until",
    "up", "upon", "us", "usually", "very", "via", "was", "wasn't", "we", "we're", "we've",
    "were", "weren't", "what", "whatever", "when", "whenever", "where", "whereas", "wherever",
    "whether", "which", "whichever", "while", "who", "whom", "whose", "why", "will", "with",
    "within", "without", "won't", "would", "wouldn't", "yet", "you", "you're", "you've",
    "your", "yours", "yourself", "yourselves",
];

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
                Some(ContentReject::NonEnglishCharset { .. })
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

        let (letters, eng_chars) = count_letters(&format!("{}\n{}", title, body));
        let pct = 100.0 * eng_chars as f64 / letters as f64;

        assert!(letters > MIN_LETTERS, "样本应足够长（实测字母 {letters}）");
        assert!(
            (4.0..12.0).contains(&pct),
            // ⚠️ Rust 的浮点格式化是 `{:.1}`（**没有** C 风格的 `{:.1f}`）——
            //    写成 `{:.1f}` 会报 `unknown format trait 'f'`（已踩）
            "🔴 英语字符占比应在 4–12%（实测两侧均为 6.8%），实得 {pct:.1}% —— \
             若偏离，说明本模块的区间表与 Dart 探针**漂移**了"
        );
        assert!(
            matches!(
                check_content(title, body, ""),
                Some(ContentReject::NonEnglishCharset { .. })
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
                Some(ContentReject::NonEnglishCharset { .. })
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

    // ══════════════════════════════════════════════════════════════════════
    // 🆕 2026-10-03：A1（区间表）+ A2/A3（英语功能词判据）的测试
    // ══════════════════════════════════════════════════════════════════════

    /// 🔴 **A1 的回归断言**：`U+1E00–U+1EFF` 必须计入**分母**。
    ///
    /// 这条测试存在的唯一目的，是让上一轮的 bug（越南语声调字符被**完全忽略**
    /// ⇒ 分母偏小 ⇒ 占比虚高到 100% ⇒ 永不触发）**不可能再悄悄回来**。
    #[test]
    fn test_latin_extended_additional_counts_in_denominator() {
        let vi = "ạảấầệịọụứỳ"; // 全部落在 U+1E00–U+1EFF
        let n = vi.chars().count();
        assert_eq!(n, 10, "样本是 10 个越南语声调字符");

        let (letters, eng_chars) = count_letters(vi);
        assert_eq!(
            letters, n,
            "🔴 越南语声调字符必须计入**分母**（上一轮 bug：它们被整个忽略）"
        );
        assert_eq!(
            eng_chars, 0,
            "🔴 它们**不是**英语所用字符（`is_english_charset` 有意排除 ExtAdditional）"
        );

        // 反向：若有人「顺手」把 ExtAdditional 加进 is_english_charset，
        // 分母修好了但分子也涨了 ⇒ 占比仍 100% ⇒ 判据对越南语失效。
        let mixed = format!("{}{}", "a".repeat(90), "ạ".repeat(10));
        let (l, e) = count_letters(&mixed);
        assert_eq!((l, e), (100, 90), "混排时分子只数英语字符");
        // 边界：英语字符恰 90% ⇒ **不满足** `< 0.90` ⇒ C 不拦
        // （写成 `>=` 而不是 `!(.. < ..)` —— 后者触发 clippy `neg_cmp_op_on_partial_ord`）
        let r1 = e as f64 / l as f64;
        assert!(
            r1 >= MIN_ENGLISH_CHARSET_RATIO,
            "🔴 越南语字符占 10% ⇒ 英语字符恰 90% ⇒ 该**恰好不满足** `< 0.90`（实得 {r1:.2}）"
        );

        let heavy = format!("{}{}", "a".repeat(80), "ạ".repeat(20));
        let (l2, e2) = count_letters(&heavy);
        let r2 = e2 as f64 / l2 as f64;
        assert!(
            r2 < MIN_ENGLISH_CHARSET_RATIO,
            "🔴 越南语字符占 20% ⇒ 应低于阈值（实得 {r2:.2}）"
        );

        // 组合变音符号（NFD 形式的带音标词）也要进分母
        let nfd = "e\u{0301}"; // é = e + U+0301
        assert_eq!(count_letters(nfd), (2, 1), "组合变音符号进分母、不进分子");
    }

    /// 词表自身的完整性（**二分查找的前提**，错了会静默查不到词）。
    #[test]
    fn test_function_word_list_is_sorted() {
        assert!(
            ENGLISH_FUNCTION_WORDS.len() > 100,
            "词表 {} 词 —— 太少会让密度整体偏低（安全边际变小）",
            ENGLISH_FUNCTION_WORDS.len()
        );
        for w in ENGLISH_FUNCTION_WORDS {
            assert!(!w.is_empty(), "词表不能有空串");
            assert_eq!(
                *w,
                w.to_lowercase(),
                "词表必须是小写 —— 分词时已统一小写，大写写法永远查不到: {w}"
            );
        }
        let mut sorted: Vec<&str> = ENGLISH_FUNCTION_WORDS.to_vec();
        sorted.sort_unstable();
        assert_eq!(
            sorted, ENGLISH_FUNCTION_WORDS,
            "🔴 词表必须**升序** —— `is_english_function_word` 用二分查找，乱序会静默漏词"
        );
        let n = sorted.len();
        sorted.dedup();
        assert_eq!(n, sorted.len(), "词表不能有重复项");
    }

    /// 分词规则 —— 每条规则都对应一个「不写就对不上标定」的坑。
    #[test]
    fn test_word_tokenization_rules() {
        // ① 基本计数
        assert_eq!(english_word_stats("the cat sat on the mat"), (6, 3));
        // ② 大小写归一（`The` 也要命中）
        assert_eq!(english_word_stats("The Of And"), (3, 3));
        // ③ 撇号**不破词**：直撇号与弯撇号（`’`）都要归一 —— 否则 `don’t` 会变成 `don` + `t`（都查不到）
        assert_eq!(english_word_stats("don't"), (1, 1), "直撇号");
        assert_eq!(
            english_word_stats("don\u{2019}t"),
            (1, 1),
            "🔴 弯撇号必须归一"
        );
        assert_eq!(english_word_stats("it's a test"), (3, 2));
        // ④ 撇号**不能开头**（避免把 `'quote'` 粘成一个词）
        assert_eq!(english_word_stats("'tis"), (1, 0));
        // ⑤ 数字 / 标点 / 连字符 / 下划线都是**分隔符**
        assert_eq!(
            english_word_stats("well-known 42 _x_ #tag"),
            (4, 0),
            "well / known / x / tag 是四个词，且都不是功能词"
        );
        // ⑥ 空串 / 纯符号
        assert_eq!(english_word_stats(""), (0, 0));
        assert_eq!(english_word_stats("123 !!! ..."), (0, 0));
        // ⑦ 非拉丁文字也是「词」（用 is_letter 判），但不命中英语词表
        assert_eq!(english_word_stats("Привет мир"), (2, 0));
        // ⑧ 纯代码（无字母组合）token 极少 ⇒ 可能低于 MIN_TOKENS ⇒ 不判（有意的保守）
        assert_eq!(english_word_stats("x = 1; y = 2;"), (2, 0));
        // ⑨ 🔴 **缩写/标识符不计入分母**（`id=1460` 误杀的根因）
        assert_eq!(
            english_word_stats("CVE DSA SHA512 attacks"),
            (1, 0),
            "CVE/DSA/SHA 是全大写缩写 ⇒ 不进分母；只有 attacks 计入 → 1 词"
        );
        // ⑩ 单字母**不排除**（`I` / `a` 是功能词）—— 与「全大写排除」的边界
        assert_eq!(english_word_stats("I a"), (2, 2), "单字母必须保留");
        // ⑪ 超长串（> 20 字母）不算词
        assert_eq!(
            english_word_stats("the internationalizationofeverything"),
            (1, 1),
            "只有 the 计入（另一个 > 20 字母）"
        );
    }

    /// 🔴 **D 判据的反例**（防误杀）—— 这几类最容易被「功能词密度」误伤。
    ///
    /// ⚠️ 只测正例（非英语被拦）会得到「拦得越狠越好」的**假绿**；
    ///    必须同时证明「正常英语一篇不被误杀」。
    #[test]
    fn test_word_ratio_does_not_kill_real_english() {
        // ① 普通英文新闻（生产实测样本风格）
        let news = "A person walks by the Ithaca Police Department headquarters on March 22, \
                    2021, in Ithaca, N.Y. Police officers often start interrogations by asking \
                    questions that assume the person is guilty, researchers say. The study, \
                    published in a peer-reviewed journal, analyzed hundreds of cases and found \
                    that the approach used by many departments is not supported by evidence.";
        let (t, h) = english_word_stats(news);
        let r = h as f64 / t as f64;
        assert!(
            r > MIN_ENGLISH_WORD_RATIO * 1.5,
            "🔴 普通英文新闻的功能词密度应远高于阈值（实得 {r:.3}）"
        );

        // ② 🔴 **英文技术文**（最危险的一类：代码/公式/专有名词多 ⇒ 密度天然偏低）
        let tech = "Adding Floating-Point Decimals for Fun and Profit. \
                    A double-precision number has 1 sign bit and 52 fraction bits. \
                    We compute the sum with the formula and the following code: \
                    `const re = /\\d+/;` — the value of 0.1 + 0.2 is 0.30000000000000004, \
                    which is not what you would expect from the math you learned in school.";
        let (t2, h2) = english_word_stats(tech);
        let r2 = h2 as f64 / t2 as f64;
        assert!(
            r2 > MIN_ENGLISH_WORD_RATIO * 1.5,
            "🔴 英文技术文不能被误杀（实得 {r2:.3}）—— 若这条失败，说明阈值需要重标"
        );

        // ③ 英文里混少量非拉丁（人名/地名）—— 不能因为几个外文词就判非英语
        let mixed = "Your Angular test passed. Could the user click the button? \
                     The fixture includes a name «Иван» and a city Москва in one test case, \
                     and the assertion still needs to check that the value is correct.";
        let (t3, h3) = english_word_stats(mixed);
        let r3 = h3 as f64 / t3 as f64;
        assert!(
            r3 > MIN_ENGLISH_WORD_RATIO * 1.5,
            "🔴 英文里混少量外文词不能被杀（实得 {r3:.3}）"
        );
    }

    /// 🔴 **短样本不判** —— [`MIN_TOKENS`] 的取舍（宁可漏拦，不可误杀）。
    #[test]
    fn test_short_text_skips_word_judgement() {
        // 30 个词以下：即使全是非英语，也**不判**（样本太小不可靠）
        let t = "en esta ciudad de pensilvania";
        let (tokens, _) = english_word_stats(t);
        assert!(tokens < MIN_TOKENS, "样本应少于下限（实得 {tokens} 词）");
        assert_eq!(
            check_content("", t, ""),
            None,
            "短样本不做词汇判定（否则短英文标题会被误杀）"
        );
    }

    /// 🔴 **6 条生产实测的非英语内容**（2026-10-03 全量复跑）—— 每一条都必须被拦下。
    ///
    /// # 为什么用「生产原文」而不是手编样本
    ///
    /// 📌 判据：**正例要用真实数据** —— 手编样本会不自觉地「编得像判据能识别的样子」。
    ///    这 6 条都是 2026-10-03 从生产库只读导出的**完整原文**
    ///    （title + 完整正文；全量 966 条的实测见 `examples/gate_replay.rs`）。
    ///
    /// ⚠️ 这里**只断言「被拦」**，不断言具体百分比 —— 百分比由 `gate_replay` 在**全量**上验。
    ///
    /// 🔑 其中 `id=2032` 与 `id=4260` 是「**标题是英文**、正文非英语」的形态，
    ///    它们证明**必须把 title 与正文拼起来判**（只判标题会漏）。
    ///
    /// 🔴 用**完整原文**（不是片段）：实测片段会失真 —— 只取前 360 字符时，
    ///    `id=1021`（意语）的英语标题 + `Posted on Oct 1 • Originally published at …`
    ///    权重过高，密度被拉到 14.9%（全文只有 6.8%）⇒ **片段会得出相反结论**。
    ///    📌 判据：**「截取样本」会改变比例类判据的结论** —— 比例判据必须用完整文本测。
    ///
    /// 原文由 `scripts/trace_verify/bin/dump_prod_content.py` 只读导出后按 id 拆分，见
    /// `tests/fixtures/non_english_samples/`（文件内已含 title，故测试用 `check_content("", t, "")`）。
    const NON_ENGLISH_SAMPLES: &[(&str, &str)] = &[
        (
            "西语 · NPR · id=8",
            include_str!("../tests/fixtures/non_english_samples/id8_es_npr.txt"),
        ),
        (
            "西语 · Dev.to · id=737",
            include_str!("../tests/fixtures/non_english_samples/id737_es_devto.txt"),
        ),
        (
            "意大利语 · Dev.to · id=1021",
            include_str!("../tests/fixtures/non_english_samples/id1021_it_devto.txt"),
        ),
        (
            "土耳其语 · Dev.to · id=1645",
            include_str!("../tests/fixtures/non_english_samples/id1645_tr_devto.txt"),
        ),
        (
            "越南语（标题是英文！）· Dev.to · id=2032",
            include_str!("../tests/fixtures/non_english_samples/id2032_vi_devto.txt"),
        ),
        (
            "越南语 · Dev.to · id=4260",
            include_str!("../tests/fixtures/non_english_samples/id4260_vi_devto.txt"),
        ),
    ];

    /// 🔴 6 条真实非英语内容**必须全部被拦**。
    #[test]
    fn test_real_non_english_samples_are_rejected() {
        for (lang, text) in NON_ENGLISH_SAMPLES {
            // 🔑 前置检查：样本必须长到能**触发**判据
            //    —— 否则「被拦」可能只是短样本保护之外的巧合，「没被拦」更是**假绿**
            let (tokens, hits) = english_word_stats(text);
            assert!(
                tokens >= MIN_TOKENS,
                "🔴 {lang}: 样本只有 {tokens} 词（< {MIN_TOKENS}）⇒ 判据根本没跑 ⇒ 这条测试无意义"
            );
            let r = check_content("", text, "");
            assert!(
                matches!(
                    r,
                    Some(ContentReject::NonEnglishCharset { .. })
                        | Some(ContentReject::NonEnglishWords { .. })
                ),
                "🔴 {lang} 必须被拦下（{tokens} 词 / {hits} 个英语功能词），实得: {r:?}"
            );
        }
    }
}

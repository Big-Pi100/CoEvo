//! 内容源解析：RSS 2.0 → **统一内部结构**（纯函数 · 零 IO）
//!
//! # 🔴 为什么把解析单独成一层（照 `achievement_rules` / `compliance` 的先例）
//!
//! 本模块**不碰网络、不碰 DB** —— 输入是 XML 字符串，输出是 `Vec<ParsedItem>`。
//! 这样它能用**真实抓下来的样本**（`tests/fixtures/*.xml`）做断言，
//! 而不必依赖「抓取时网络恰好可用」。
//! 🔑 源的差异（CDATA / 命名空间 / 缺字段 / 时间格式）**全部收敛在这一层**，
//!    上层（抓取器）只面对一个统一结构。
//!
//! # 实测的各源差异（2026-09-29 · 本机 + VPS 双实测可达的那 4 个 RSS 源）
//!
//! | 源 | 格式 | 特征 |
//! |---|---|---|
//! | NPR | RSS 2.0 | `content:encoded` 含 HTML + CDATA · 有 `dc:creator` · 命名空间多达 6 个 |
//! | ECNS 中国新闻网英文 | RSS 2.0 | 大量 CDATA · **无** `dc:creator` · 有自定义 `<column>` |
//! | Ars Technica | RSS 2.0 | 多个 `<category>` · 有 `slash:comments` · `media:credit` |
//! | Dev.to | RSS 2.0 | 有 `category` · `dc:creator` |
//!
//! → 共同点：**都是 RSS 2.0**（root 都是 `<rss>`，**无 Atom**）→ 不必引 `feed-rs`。
//! → 差异点：**命名空间前缀**（`dc:` / `content:` / `slash:`）→ 按**本地名**匹配
//!   （`tag_name().name()` 不含前缀），不要按带前缀的字符串匹配。
//!
//! # 🔑 输出**统一为纯文本**（不是 HTML）
//! 源给的 `content:encoded` / `description` 是 HTML 片段。本层**剥成纯文本**：
//! ① App 只需展示文字，存 HTML 会让端侧要带一个渲染器与清洗器；
//! ② 少一个注入口（HTML 里可以藏 `<script>` / 外链图片追踪像素 —— NPR 的
//!   样本里**真的**有 `<img src=...npr-rss-pixel.png?story=...>` 追踪像素）。
//!
//! # 🔴 时间一律归一为 **UTC ISO8601 带 `Z`**
//! 源给的是 RFC 822/2822（如 `Tue, 29 Sep 2026 07:36:24 -0400`）。
//! 若不归一就下发，App 侧 `DateTime.parse` 对「有时区偏移」的串能正确解析，
//! 但对「无偏移」的串会**静默按本地时区解释** —— 归一成显式 `Z` 才与端侧硬约束一致。

use std::sync::OnceLock;

use regex::Regex;

/// 一条内容（**源的差异已被抹平**）。
///
/// ⚠️ **不含 `category`**：源给的 `<category>` 是自由文本（Ars 用 "Security" / "Gadgets"），
///    与我们自己的分类体系（news / tech / science…）**不是一套**。
///    我们的分类来自 `content_source.category`（运营配置）——
///    🔑 把自由标签塞进受控分类列，会让那一列**两种语义混在一起**。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedItem {
    pub title: String,
    /// 摘要（纯文本）。源没给摘要时为 `None`。
    pub summary: Option<String>,
    /// 正文（纯文本）。
    ///
    /// 🔴 **只在「源确实给了比摘要更长的正文」时才有值** —— 见 [`extract_body`]。
    ///    典型情况：NPR 的 `content:encoded` 与 `description` **内容相同**，
    ///    此时 `body = None`（body 若照抄 summary，调用方会误以为拿到了全文）。
    pub body: Option<String>,
    /// 原文链接。**幂等键**（`content_pool` 的 `UNIQUE(url)`）→ 无链接的条目会被跳过。
    pub url: String,
    /// 作者（`dc:creator`），源没给则 `None`。
    pub author: Option<String>,
    /// 发布于 **UTC ISO8601 带 `Z`**。
    pub published_at: Option<String>,
    /// 热帖分数 —— **只有 HN 会给**（RSS 源恒为 `None`）。
    /// 用于「热帖」形态的排序（`content_pool.score DESC`）。
    pub score: Option<i64>,
    /// 评论数 —— **只有 HN 会给**（RSS 源的 `slash:comments` 暂未取）。
    pub comments: Option<i64>,
}

/// 解析 RSS 2.0 文档 → 条目列表。
///
/// # 参数 `tz_offset_min`
/// 源的时间戳**不带时区**时按此偏移解释（分钟；东八区 = 480）。
/// 由**源配置**（`content_source.tz_offset_min`）传入 —— 见 [`parse_pub_date`] 的说明，
/// 以及 `CONTENT_SCHEMA_SQL` 里那一列为什么存在。
///
/// 跳过规则（都是**无法处理**而非「处理失败」）：
/// · **无 `<url>`/`<link>`** → 跳过（没有幂等键，入库会重复）
/// · **无 `<title>`** → 跳过（信息流必须有标题可展示）
pub fn parse_rss(xml: &str, tz_offset_min: i32) -> Result<Vec<ParsedItem>, String> {
    let doc = roxmltree::Document::parse(xml).map_err(|e| format!("XML 解析失败: {}", e))?;

    let root = doc.root_element();
    if root.tag_name().name() != "rss" {
        return Err(format!(
            "不是 RSS 2.0 文档（根元素是 `{}`）—— Atom 需另写适配器",
            root.tag_name().name()
        ));
    }

    let mut out = Vec::new();
    for item in doc.descendants().filter(|n| n.is_element() && n.tag_name().name() == "item") {
        let Some(title) = child_text(item, "title").filter(|t| !t.is_empty()) else {
            continue;
        };
        let Some(url) = extract_link(item) else { continue };

        let summary = child_text(item, "description")
            .map(|s| strip_html(&s))
            .filter(|s| !s.is_empty());

        let body = extract_body(item, summary.as_deref());
        out.push(ParsedItem {
            title: strip_html(&title),
            summary,
            body,
            url,
            author: child_text(item, "creator").filter(|s| !s.is_empty()),
            published_at: child_text(item, "pubDate")
                .as_deref()
                .and_then(|s| parse_pub_date(s, tz_offset_min)),
            // RSS 没有「分数/评论数」的概念 → 恒为 None（热帖字段只由 HN 适配器填）
            score: None,
            comments: None,
        });
    }
    Ok(out)
}

/// 取子元素文本（按**本地名**匹配 —— 见模块头「命名空间」）。
///
/// 命名空间前缀不进 `tag_name().name()`：`<dc:creator>` 的 name 是 `creator`。
fn child_text(node: roxmltree::Node, local_name: &str) -> Option<String> {
    node.children()
        .find(|c| c.is_element() && c.tag_name().name() == local_name)
        .and_then(|c| c.text())
        .map(|t| t.to_string())
}

/// 取链接。
///
/// ① 优先 `<link>` 的**文本**（RSS 2.0 形态）
/// ② 退回 `<link href="...">` 的**属性**（部分源用 Atom 风格，实测虽都是 2.0，
///    但这是零成本的兼容 —— 只多一次属性读取）
/// ③ 再退回 `<guid isPermaLink="true">` 的文本
fn extract_link(item: roxmltree::Node) -> Option<String> {
    if let Some(link) = item
        .children()
        .find(|c| c.is_element() && c.tag_name().name() == "link")
    {
        if let Some(t) = link.text() {
            let t = t.trim();
            if !t.is_empty() {
                return Some(t.to_string());
            }
        }
        if let Some(href) = link.attribute("href") {
            let href = href.trim();
            if !href.is_empty() {
                return Some(href.to_string());
            }
        }
    }
    let guid = item
        .children()
        .find(|c| c.is_element() && c.tag_name().name() == "guid")?;
    let is_link = guid.attribute("isPermaLink").map(|v| v.eq_ignore_ascii_case("true")).unwrap_or(true);
    if !is_link {
        return None;
    }
    let t = guid.text()?.trim();
    if t.is_empty() || !t.starts_with("http") {
        return None;
    }
    Some(t.to_string())
}

/// 「`content:encoded` 确实比摘要长」的判据阈值（**字符**）。
///
/// # 🔑 为什么是 100
/// `content:encoded` 与 `description` **同源**时（NPR 就是），多出来的部分基本是
/// **样板**：图片的 `alt` 说明、`(Image credit: …)` 署名、排版标签。
/// 实测 NPR 那条只多 **~32 字符**。而**真全文**会多出几百到几千字符。
/// → 取 100 把「样板级差异」与「量级差异」分开。
///
/// ⚠️ 代价（**已知且接受**）：一篇很短的报道（全文只比摘要多几十字符）会被判成
///    「没拿到全文」→ `body = None` → 上层退回用摘要展示。
///    那种情况下两者本来就差不多，**不影响可读性**；
///    而反过来（把摘要当全文存进 `body`）会**污染语义** —— 之后无法区分
///    「我们没抓到全文」与「全文就这么长」。
const BODY_LONGER_THRESHOLD: usize = 100;

/// 取正文（`content:encoded`），**仅当它确实比摘要更长**时返回。
///
/// 🔑 为什么要比长度：实测 NPR 的 `content:encoded` 与 `description` **内容相同**
///    （都是那段两句话的摘要，只是前者带 `<img>`/署名标签）。
///    若无条件取 `content:encoded` 当正文，上层会把「摘要」当「全文」存进 `body`
///    → 之后就无法区分「我们没抓到全文」和「全文就这么长」。
///    → 用「明显更长」作判据，**拿不到全文时老实给 `None`**。
fn extract_body(item: roxmltree::Node, summary: Option<&str>) -> Option<String> {
    let raw = child_text(item, "encoded")?;
    // 🔑 **正文用「保留段落」的版本** —— 否则整篇挤成一整行（见 `strip_html_block`）
    let text = strip_html_block(&raw);
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    let longer = match summary {
        Some(s) => text.chars().count() > s.chars().count() + BODY_LONGER_THRESHOLD,
        None => true,
    };
    if longer {
        Some(text.to_string())
    } else {
        None
    }
}

/// RFC 822/2822 → **UTC ISO8601 带 `Z`**。
///
/// `chrono` 的 `parse_from_rfc2822` 能处理 `Tue, 29 Sep 2026 07:36:24 -0400`
/// （RFC 2822 取代了 822，格式兼容）。解析失败返回 `None`（不猜）。
fn rfc822_to_utc_iso(s: &str) -> Option<String> {
    chrono::DateTime::parse_from_rfc2822(s.trim())
        .ok()
        .map(|dt| dt.with_timezone(&chrono::Utc).format("%Y-%m-%dT%H:%M:%SZ").to_string())
}

/// 解析 `<pubDate>` → **UTC ISO8601 带 `Z`**（两种格式都要支持）。
///
/// # 🔴 实测：源之间**时间格式不统一**（2026-09-29 冒烟发现的真问题）
///
/// | 源 | 格式 | 自带时区？ |
/// |---|---|---|
/// | NPR / Ars Technica / Dev.to | `Tue, 29 Sep 2026 07:36:24 -0400` | ✅ RFC 2822 带偏移 |
/// | **ECNS 中国新闻网英文** | **`2026-09-29 21:34:24`** | ❌ **不带** |
///
/// ## 🔴 「不带时区」时**不能猜 UTC**
/// ECNS 那条若按 UTC 解释 → `21:34:24Z`，而抓取时刻是 `15:58Z`
/// → **时间比现在还晚**（未来时间）。它实际是**北京时间**。
/// → 用**源配置的 `tz_offset_min`**（ECNS = 480）解释。
///
/// 🔑 判据：**「缺失的元信息」不能靠默认值兜底** —— 默认值（0 = UTC）
///    在这里会产出一个**看起来正常、实际错了 8 小时**的时间，
///    而且**不会报错**（未来时间只有在排序时才显得怪）。
///    所以宁可让「这个源不带时区」变成一条**显式配置**。
///
/// 带时区的格式**不受 `tz_offset_min` 影响**（它自带偏移，以它为准）。
fn parse_pub_date(s: &str, tz_offset_min: i32) -> Option<String> {
    let t = s.trim();
    if let Some(iso) = rfc822_to_utc_iso(t) {
        return Some(iso);
    }
    // 非标准格式：`YYYY-MM-DD HH:MM:SS`（ECNS 用的）
    let naive = chrono::NaiveDateTime::parse_from_str(t, "%Y-%m-%d %H:%M:%S").ok()?;
    let offset = chrono::FixedOffset::east_opt(tz_offset_min * 60)?;
    let dt = naive.and_local_timezone(offset).single()?;
    Some(dt.with_timezone(&chrono::Utc).format("%Y-%m-%dT%H:%M:%SZ").to_string())
}

/// Unix 秒 → **UTC ISO8601 带 `Z`**（Hacker News 的 `time` 字段是这个格式）。
///
/// 同样归一成带 `Z` —— 理由与 [`rfc822_to_utc_iso`] 完全一致（端侧 `DateTime.parse`）。
pub fn unix_to_utc_iso(secs: i64) -> Option<String> {
    chrono::DateTime::from_timestamp(secs, 0)
        .map(|dt| dt.format("%Y-%m-%dT%H:%M:%SZ").to_string())
}

/// HTML → 纯文本（**行内语义：空白全折叠**）—— 用于 `title` / `summary` / `author`。
///
/// 🔑 这些字段是**单行展示**的（卡片标题、摘要一行），换行没有意义 →
///    全部折叠成空格。若要**保留段落**（正文），用 [`strip_html_block`]。
///
/// 步骤：去 `script`/`style` 整块 → 块级标签换行 → 去其余标签 → 解实体 → 折叠空白。
///
/// ⚠️ 用正则而非 HTML 解析器（本机 `scraper`/`html5ever` **不在 crate 缓存里**，
///    而拉新依赖会卡在索引更新 —— 见 `Cargo.toml` 的说明）。
///    对本用途（RSS 片段 → 纯文本）足够：输入是**受控**的、不要求容错 HTML 解析。
///    🔴 但**不要**把它当通用 HTML 清洗器用（正则解析 HTML 有已知边界）。
///
/// # 🔴 每个正则必须有自己的 `OnceLock`（我在这里踩过一次）
///
/// 曾写成一个 `fn re(cell, pattern)` —— 用**同一个** `static` cell 依次初始化两个不同模式。
/// `OnceLock::get_or_init` **只初始化一次**：第二次传进去的模式**被静默忽略**，
/// 返回的是**上一个**正则 → 表现为「某个标签没被剥掉」，而且**不报错**。
/// → 改为每个模式一个独立 `static`，让「一个 cell 一个模式」成为类型层面的事实。
/// 📌 同族判据：**共享的缓存槽位 = 第二件事静默失效的地方**。
pub fn strip_html(s: &str) -> String {
    collapse_ws(&decode_entities(&strip_tags(s)))
}

/// HTML → 纯文本（**块级语义：保留段落**）—— 用于文章 `body` 全文。
///
/// # 🔴 为什么正文不能用 [`strip_html`]
///
/// 实测：`strip_html` 把「块级标签」换成 `\n` 之后**又把 `\n` 折叠成空格**
/// （它的语义是「单行」）→ **整篇文章挤成一整行**。
/// 后果不是「不好看」而是**读不下去**：阅读界面的正文没有段落边界，
/// 用户面对一堵字墙。而这是本产品的**核心场景**。
///
/// → 本函数把块级边界保留为**空行**（`\n\n`），行内空白仍折叠成单空格。
///
/// 🔑 两个函数**并存**而不是加个 `bool` 参数：
///    它们服务两类**语义不同**的消费方（列表的单行摘要 vs 阅读器的多段正文）。
///    一个参数化的函数会让调用点写 `strip_html(s, true)` —— 读代码时
///    无法一眼看出那个 `true` 是什么意思。
pub fn strip_html_block(s: &str) -> String {
    // 先把块级边界变成换行（顺序与 `strip_tags` 一致），再按「段」归一化
    let with_breaks = strip_tags(s);
    let text = decode_entities(&with_breaks);
    normalize_paragraphs(&text)
}

/// 去标签并**把块级边界换成 `\n`**（不做空白折叠）—— [`strip_html`] 与
/// [`strip_html_block`] 共用的前半段。
fn strip_tags(s: &str) -> String {
    static SCRIPT: OnceLock<Regex> = OnceLock::new();
    static STYLE: OnceLock<Regex> = OnceLock::new();
    // 🔴 `BR` 与 `BLOCK` **必须各占一个 cell**。
    //
    // 2026-09-29 实测踩到：我写完本文件顶部那条「一个 cell 一个模式」的说明后，
    // **下一次重构就把这两个模式塞回了同一个 `BLOCK` cell** ——
    // `get_or_init` 只初始化一次 → 第二个模式（`</p>` 等块级闭合）被
    // **静默忽略**，实际又跑了一遍 `<br>` 模式（它匹配不到任何东西）。
    // 症状：段落边界全丢 → 正文变成一整行，而**测试立刻抓到**
    // （`test_strip_html_block_keeps_paragraphs`：期望 `第一段\n\n第二段`，实得 `第一段第二段`）。
    // 🔑 这就是那条判据说的：**共享的缓存槽位 = 第二件事静默失效的地方** ——
    //    它不报错，只让结果悄悄不对。
    static BR: OnceLock<Regex> = OnceLock::new();
    static BLOCK: OnceLock<Regex> = OnceLock::new();
    static TAG: OnceLock<Regex> = OnceLock::new();

    fn get(cell: &'static OnceLock<Regex>, pat: &str) -> &'static Regex {
        cell.get_or_init(|| Regex::new(pat).expect("正则字面量写错"))
    }

    // 整块删除：脚本/样式（保留内容会污染正文）
    let s = get(&SCRIPT, r"(?is)<script\b[^>]*>.*?</script>").replace_all(s, " ");
    let s = get(&STYLE, r"(?is)<style\b[^>]*>.*?</style>").replace_all(&s, " ");
    // `<br>` → 单个换行（段内软折行）
    let s = get(&BR, r"(?is)<br\s*/?>").replace_all(&s, "\n");
    // 块级闭合标签 → **两个**换行（= 段落边界）。
    // 🔑 用两个而不是一个：`<p>a</p><p>b</p>` 是**两段**，
    //    一个换行会被 `normalize_paragraphs` 当成「同一段里的折行」而合并。
    let s = get(
        &BLOCK,
        r"(?is)</(p|div|li|h[1-6]|blockquote|section|article|tr)\s*>",
    )
    .replace_all(&s, "\n\n");
    // 其余标签（含 `<img .../>` 自闭合）
    let s = get(&TAG, r"(?s)<[^>]*>").replace_all(&s, "");

    s.into_owned()
}

/// 段落归一化：**行内空白折叠成单空格**，**块间保留一个空行**。
///
/// 具体规则：
/// 1. 逐行处理：行首尾去空白，行内连续空白 → 单空格
/// 2. 连续空行 → 压缩成**一个空行**（`\n\n` = 一个段落分隔）
/// 3. 首尾空白去掉
///
/// 🔑 为什么要压缩空行：源里 `<p>a</p>\n\n\n<p>b</p>` 这种三连换行很常见
///    （排版缩进），不压缩会在正文里出现**成片空行**。
fn normalize_paragraphs(s: &str) -> String {
    let mut paras: Vec<String> = Vec::new();
    for line in s.split('\n') {
        let collapsed = collapse_ws(line);
        if collapsed.is_empty() {
            // 空行 = 段边界；用空串占位，最后再合并
            if !paras.is_empty() {
                paras.push(String::new());
            }
        } else {
            paras.push(collapsed);
        }
    }
    // 压缩连续空元素 → 单个空元素
    let mut out = String::with_capacity(s.len());
    let mut prev_blank = true; // 开头视为「已有空行」→ 避免前导换行
    for p in paras {
        if p.is_empty() {
            if prev_blank {
                continue;
            }
            prev_blank = true;
            out.push('\n');
            out.push('\n');
        } else {
            if !prev_blank {
                // 同一段里的折行（源里的软换行）→ 空格接上，不当作新段
                out.push(' ');
            }
            out.push_str(&p);
            prev_blank = false;
        }
    }
    out.trim().to_string()
}

/// 解常见 HTML 实体 + 数字实体。
///
/// ⚠️ 只覆盖**实际会遇到**的：RSS 是 UTF-8（中文/英文正文直接是字符），
///    实体主要出现在**属性被剥落后的残留**与 `&amp;` 这类转义。
///    未列出的实体保持原样（不猜）—— 宁可显示 `&foo;` 也不要显示错字符。
fn decode_entities(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'&' {
            let ch = s[i..].chars().next().unwrap();
            out.push(ch);
            i += ch.len_utf8();
            continue;
        }
        // 找最近的 `;`（限制在 12 字符内，避免把正文里的 `&` 当实体起点吞掉一大段）
        let rest = &s[i..];
        let semi = rest[1..].char_indices().take(12).find(|(_, c)| *c == ';').map(|(k, _)| k + 1);
        let Some(semi_pos) = semi else {
            out.push('&');
            i += 1;
            continue;
        };
        let entity = &rest[1..semi_pos];
        if let Some(decoded) = decode_one(entity) {
            out.push(decoded);
            i += semi_pos + 1;
        } else {
            out.push('&');
            i += 1;
        }
    }
    out
}

fn decode_one(entity: &str) -> Option<char> {
    if let Some(num) = entity.strip_prefix('#') {
        let code = if let Some(hex) = num.strip_prefix(['x', 'X']) {
            u32::from_str_radix(hex, 16).ok()?
        } else {
            num.parse::<u32>().ok()?
        };
        // 过滤非法码点（surrogate / 越界）→ 返回 None 表示「解不了」，保留原样
        return char::from_u32(code);
    }
    Some(match entity {
        "amp" => '&',
        "lt" => '<',
        "gt" => '>',
        "quot" => '"',
        "apos" => '\'',
        "nbsp" => ' ',
        "mdash" => '—',
        "ndash" => '–',
        "hellip" => '…',
        "lsquo" => '‘',
        "rsquo" => '’',
        "ldquo" => '“',
        "rdquo" => '”',
        "middot" => '·',
        _ => return None,
    })
}

/// 空白折叠：连续空白（含换行）→ 单个空格；首尾去空白。
fn collapse_ws(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut pending_space = false;
    for ch in s.chars() {
        if ch.is_whitespace() {
            pending_space = !out.is_empty();
        } else {
            if pending_space {
                out.push(' ');
                pending_space = false;
            }
            out.push(ch);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实样本（2026-09-29 实测可达的 4 个源各抓一份，**入库以便离线可测**）
    const NPR: &str = include_str!("../tests/fixtures/npr.xml");
    const ECNS: &str = include_str!("../tests/fixtures/ecns.xml");
    const ARS: &str = include_str!("../tests/fixtures/arstechnica.xml");
    const DEVTO: &str = include_str!("../tests/fixtures/devto.xml");

    #[test]
    fn test_all_four_real_sources_parse() {
        // ⚠️ ECNS 的时间**不带时区** → 必须给 +480（北京时间）。
        //    若给 0（UTC），它会被解释成「未来时间」—— 见 `parse_pub_date` 的说明。
        for (name, xml, tz) in [
            ("npr", NPR, 0),
            ("ecns", ECNS, 480),
            ("ars", ARS, 0),
            ("devto", DEVTO, 0),
        ] {
            let items = parse_rss(xml, tz).unwrap_or_else(|e| panic!("{} 解析失败: {}", name, e));
            assert!(!items.is_empty(), "{} 解析出 0 条", name);
            // 每条都必须有标题与链接（否则会被跳过 —— 这里断言「留下的都是完整的」）
            for it in &items {
                assert!(!it.title.is_empty(), "{} 有空标题", name);
                assert!(it.url.starts_with("http"), "{} 的 url 异常: {}", name, it.url);
                // 🔴 **回归断言**：4 个真实源的每条都该解析出时间。
                //    2026-09-29 冒烟时 ECNS 的时间**全为 NULL** —— 因为它用的是
                //    非标准格式 `2026-09-29 21:34:24`，而解析器只认 RFC 2822。
                //    → 这条断言就是那个 bug 的守门人（含 tz 配置错误也会在这里红）。
                assert!(
                    it.published_at.is_some(),
                    "{} 的条目 `{}` 没解析出时间（pubDate 格式变了？）",
                    name,
                    it.title
                );
            }
        }
    }

    #[test]
    fn test_ecns_non_standard_date_with_tz_offset() {
        // ECNS 样本第 1 条：`2026-09-29 21:34:24`（北京时间）→ 13:34:24Z
        // 🔑 期望值独立核算：21:34:24 - 8h = 13:34:24Z
        let items = parse_rss(ECNS, 480).unwrap();
        assert_eq!(items[0].published_at.as_deref(), Some("2026-09-29T13:34:24Z"));

        // 🔴 反向：**同一份数据**给 0（UTC）会得到 21:34:24Z —— 那是**错的**
        //    （它是源站本地时间，不是 UTC）。这条反向断言说明「时区配置不是装饰」。
        let wrong = parse_rss(ECNS, 0).unwrap();
        assert_eq!(wrong[0].published_at.as_deref(), Some("2026-09-29T21:34:24Z"));
        assert_ne!(
            items[0].published_at, wrong[0].published_at,
            "时区配置必须真的影响结果，否则那一列是摆设"
        );
    }

    #[test]
    fn test_published_at_normalized_to_utc_iso8601_z() {
        let items = parse_rss(NPR, 0).unwrap();
        let t = items[0].published_at.as_deref().expect("NPR 应有 pubDate");
        assert!(t.ends_with('Z'), "必须以 Z 结尾（否则 App 侧按本地时区解释）: {}", t);
        // NPR 样本第 1 条：Tue, 29 Sep 2026 07:36:24 -0400 → 11:36:24Z
        assert_eq!(t, "2026-09-29T11:36:24Z");
    }

    #[test]
    fn test_npr_body_none_because_same_as_summary() {
        // 实测：NPR 的 content:encoded 与 description **内容相同**（前者带 img 标签）
        // → 若照抄当正文，上层会把「摘要」当「全文」
        let items = parse_rss(NPR, 0).unwrap();
        assert_eq!(items[0].body, None, "NPR 的 content:encoded 不比摘要长 → body 应为 None");
        assert!(items[0].summary.is_some(), "摘要应有值");
    }

    #[test]
    fn test_summary_html_and_tracking_pixel_stripped() {
        let items = parse_rss(NPR, 0).unwrap();
        let s = items[0].summary.as_deref().unwrap();
        assert!(!s.contains('<'), "不该残留标签: {}", s);
        assert!(!s.contains("npr-rss-pixel"), "追踪像素不该进正文: {}", s);
        assert!(s.contains("Trump"), "正文内容应保留: {}", s);
    }

    #[test]
    fn test_dc_creator_matched_by_local_name() {
        let items = parse_rss(NPR, 0).unwrap();
        assert_eq!(items[0].author.as_deref(), Some("Brittney Melton"));
        // ECNS 没有 dc:creator → None（不报错）
        let ecns = parse_rss(ECNS, 480).unwrap();
        assert_eq!(ecns[0].author, None);
    }

    #[test]
    fn test_ecns_cdata_extracted() {
        let items = parse_rss(ECNS, 480).unwrap();
        // CDATA 在 roxmltree 里就是文本节点 → 应能取到，且不残留 <![CDATA[
        assert!(!items[0].title.is_empty());
        assert!(!items[0].title.contains("CDATA"), "不该残留 CDATA 标记: {}", items[0].title);
    }

    #[test]
    fn test_non_rss_document_errors_not_silent_empty() {
        let atom = r#"<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"></feed>"#;
        let e = parse_rss(atom, 0).unwrap_err();
        assert!(e.contains("不是 RSS 2.0"), "错误信息应说明原因: {}", e);
    }

    #[test]
    fn test_items_without_url_or_title_skipped() {
        let xml = r#"<?xml version="1.0"?><rss version="2.0"><channel>
            <item><title>有标题有链接</title><link>https://a.test/1</link></item>
            <item><title>缺链接</title></item>
            <item><link>https://a.test/3</link></item>
            <item><title></title><link>https://a.test/4</link></item>
        </channel></rss>"#;
        let items = parse_rss(xml, 0).unwrap();
        assert_eq!(items.len(), 1, "只应留下第 1 条，实际 {:?}", items);
        assert_eq!(items[0].url, "https://a.test/1");
    }

    #[test]
    fn test_entity_decode_and_whitespace_collapse() {
        assert_eq!(strip_html("a &amp; b"), "a & b");
        assert_eq!(strip_html("caf&#233;"), "café");
        assert_eq!(strip_html("&#x4E2D;文"), "中文");
        assert_eq!(strip_html("<p>a</p><p>b</p>"), "a b");
        assert_eq!(strip_html("  多   空白\n\n折叠  "), "多 空白 折叠");
        // 未知实体保持原样（不猜）
        assert_eq!(strip_html("&foo;"), "&foo;");
        // script/style 整块删除
        assert_eq!(strip_html("<script>bad()</script>ok"), "ok");
        assert_eq!(strip_html("<style>x{}</style>ok"), "ok");
    }

    #[test]
    fn test_strip_html_block_keeps_paragraphs() {
        // 🔴 这是「正文不挤成一整行」的守门断言
        assert_eq!(
            strip_html_block("<p>第一段</p><p>第二段</p>"),
            "第一段\n\n第二段"
        );
        // `<br>` → 单换行，但两段之间的软换行会被合并（同一段内的折行）
        assert_eq!(strip_html_block("a<br>b"), "a b");
        // 同一段内的多行 → 单空格（不是新段）
        assert_eq!(strip_html_block("<p>a\nb</p>"), "a b");
        // 🔑 连续空行压缩成一个空行（源里常见三连换行）
        assert_eq!(
            strip_html_block("<p>a</p>\n\n\n\n<p>b</p>"),
            "a\n\nb"
        );
        // 首尾不留空行
        assert_eq!(strip_html_block("\n\n<p>a</p>\n\n"), "a");
        // 标签仍要被剥（含 img 追踪像素）
        let s = strip_html_block("<img src='x.png'/><p>正文</p>");
        assert!(!s.contains('<'), "不该残留标签: {}", s);
    }

    #[test]
    fn test_two_strip_variants_differ_on_multiline() {
        // 🔑 固定住「两个函数的差异」本身 —— 若有人把它们合并（或把 block
        //    改成 inline），这条会红，提醒「正文会挤成一整行」这个回归。
        let html = "<p>第一段</p><p>第二段</p>";
        assert_eq!(strip_html(html), "第一段 第二段", "inline 版：单行");
        assert_eq!(strip_html_block(html), "第一段\n\n第二段", "block 版：保留段落");
        assert_ne!(strip_html(html), strip_html_block(html));
    }

    #[test]
    fn test_real_source_bodies_have_paragraphs() {
        // Ars Technica 的 feed 自带全文（实测 20/20）→ 正文应有段落边界
        let items = parse_rss(ARS, 0).unwrap();
        let with_body: Vec<_> = items.iter().filter(|i| i.body.is_some()).collect();
        assert!(!with_body.is_empty(), "Ars 应有带全文的条目（实测如此）");
        let body = with_body[0].body.as_deref().unwrap();
        assert!(
            body.contains('\n'),
            "真实全文应当有段落边界（否则阅读界面是一堵字墙）: {:?}",
            &body.chars().take(120).collect::<String>()
        );
    }

    #[test]
    fn test_invalid_date_returns_none() {
        let xml = r#"<?xml version="1.0"?><rss version="2.0"><channel>
            <item><title>t</title><link>https://a.test/1</link><pubDate>不是时间</pubDate></item>
        </channel></rss>"#;
        let items = parse_rss(xml, 0).unwrap();
        assert_eq!(items[0].published_at, None);
    }
}

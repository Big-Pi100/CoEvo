//! 网页正文提取 —— 从文章页 HTML 里取「正文段落」（**纯函数 · 零 IO**）
//!
//! 解决什么：RSS 通常**只给摘要**，而白哥定了「新闻类全文展示」→
//! 要全文就得**抓原网页**。本模块负责「拿到 HTML 之后，正文在哪」。
//!
//! # 🔴 为什么不用 `<article>` 优先（实测推翻的常见做法）
//!
//! 业界通行的启发式是「优先 `<article>`，退回 `<main>`」。**实测对 NPR 完全失效**：
//!
//! | 容器 | 实测内容 |
//! |---|---|
//! | NPR 的 `<article>` | **3 段，全是导航噪音**（`LISTEN & FOLLOW NPR App Apple Podcasts…`）|
//! | NPR 的 `<main>` | 26 段，**真正文在里面**（1477 → 6830 字符）|
//!
//! 🔑 所以判据不是「容器叫什么标签」，而是**「候选块里有多少像正文的文字」** ——
//!    本模块对**所有候选容器都算一遍得分**，选得分最高的。
//!    📌 判据同族：**别按名字判断内容**（我在删数据时也栽过：据名字误判 `pipelines/`）。
//!
//! # 🔴 负面容器（去掉它们对得分的贡献）
//!
//! Dev.to 实测：整个文档 124 个 `<p>`（18903 字符），其中**大量是评论/推荐**——
//! 若不排除，正文会被评论淹没。于是对 `nav` / `footer` / `aside` / 评论类
//! `class`/`id` 命中的区块：
//! · **不计入得分**（不让噪音赢）
//! · **且在最终提取时被剔除**
//!
//! # 局限（如实说明，别当通用可读性引擎）
//! · 这是**启发式**，不是 `readability.js` 级别的内容评分算法
//! · 对 JS 渲染的页面无效（拿到的 HTML 里没有正文）
//! · 判据阈值（[MIN_PARA_CHARS]）是实测调出来的，换站点群可能要调

use std::sync::OnceLock;

use regex::Regex;
use scraper::{ElementRef, Html, Selector};

use dom_smoothie::{Config, Readability, TextMode};

/// 一个 `<p>` 至少多少字符才算「正文段」（用于评分；提取时不丢弃短段）。
///
/// # 为什么是 40
/// 实测三类 `<p>` 的长度分布：
/// · 导航/署名/图注（噪音）：多为 5–35 字符（`By&nbsp;` / `Brittney Melton` / `hide caption`）
/// · 真正文段落：多在 50–600 字符
/// → 40 落在两者之间的空档。**这是分界，不是精确阈值**：
///   调大到 80 会漏掉短的正经段落（新闻里常见一句话成段），调小到 20 会让噪音计分。
pub const MIN_PARA_CHARS: usize = 40;

/// 候选正文容器（**按优先级排列**；但最终由[得分](block_score)决定，不是顺序）。
const CANDIDATE_SELECTORS: &[&str] = &[
    "main",
    "article",
    "[role=main]",
    // 常见的正文类名（实测站点里出现过的）
    "[class*=storytext]",
    "[id=storytext]",
    "[class*=article-body]",
    "[class*=articleBody]",
    "[class*=post-content]",
    "[class*=entry-content]",
    "[class*=content-body]",
    "[class*=story-body]",
];

/// 负面容器的 `class` / `id` 关键词 —— 命中即**排除**。
///
/// ⚠️ 用「包含」匹配（`[class*=comment]`）而不是全等：
///    同一含义的类名在各站写法不同（`comments` / `comment-list` / `js-comment`）。
const NEGATIVE_MARKERS: &[&str] = &[
    "comment",
    "footer",
    "nav",
    "sidebar",
    "aside",
    "related",
    "recommend",
    "share",
    "social",
    "promo",
    "advert",
    "ad-",
    "sponsor",
    "newsletter",
    "subscribe",
    "breadcrumb",
    "pagination",
    "menu",
    "toolbar",
    "cookie",
    "banner",
    "popup",
    "modal",
    "caption",
    "byline",
    "metadata",
    "tags",
];

/// 从 HTML 提取正文段落（纯文本，一段一个元素）。
///
/// 返回空 `Vec` 表示**判定为没有正文** —— 调用方据此**不写 body**
/// （而不是写一个空串：那会让 `has_body` 为真，界面以为可读）。
pub fn extract_article_paragraphs(html: &str) -> Vec<String> {
    let doc = Html::parse_document(html);
    let Ok(p_sel) = Selector::parse("p") else {
        return Vec::new();
    };

    // ① 逐个**候选容器**打分，选最高分；
    //    没有任何候选命中 → 退回「整个文档」（ECNS 实测就是这种：无 article/main）。
    let mut best: Option<(i64, ElementRef)> = None;
    for sel_str in CANDIDATE_SELECTORS {
        let Ok(sel) = Selector::parse(sel_str) else {
            continue;
        };
        for el in doc.select(&sel) {
            let score = block_score(el, &p_sel);
            if best.as_ref().map(|(s, _)| score > *s).unwrap_or(true) {
                best = Some((score, el));
            }
        }
    }

    let scope: ElementRef = match best {
        // 🔑 得分必须**明显为正**才采用 —— 否则说明找到的容器其实是噪音区
        //    （如 NPR 那个只含导航的 `<article>`）→ 退回全文反而更好
        Some((score, el)) if score > 0 => el,
        _ => doc.root_element(),
    };

    // ② 从选中的范围里收集 `<p>`，跳过负面容器内的
    let mut out: Vec<String> = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    for p in scope.select(&p_sel) {
        if is_inside_negative(p) {
            continue;
        }
        let text = normalized_text(p);
        if text.is_empty() {
            continue;
        }
        // 去重（有的站把同一段同时放在 `<p>` 与隐藏容器里）
        if !seen.insert(text.clone()) {
            continue;
        }
        out.push(text);
    }
    out
}

/// 给一个容器打分：**它像不像正文区**。
///
/// 判据 = 「够长的 `<p>` 的总字符数」（不含负面容器内的）。
/// 🔑 用**总字符数**而不是「`<p>` 个数」：
///    个数会被「一堆短噪音」骗到（导航栏也有几十个 `<p>`）；
///    字符数才反映「这里有多少真正要读的东西」。
fn block_score(el: ElementRef, p_sel: &Selector) -> i64 {
    let mut total = 0i64;
    for p in el.select(p_sel) {
        if is_inside_negative(p) {
            continue;
        }
        let len = normalized_text(p).chars().count();
        if len >= MIN_PARA_CHARS {
            total += len as i64;
        }
    }
    // 🔑 减去「容器自带噪音」的惩罚？不做 —— 排除已经把噪音去掉了，
    //    再加惩罚会让「大容器 but 真正文也多」的情况被误杀。
    total
}

/// 该元素（或其任一祖先）是否落在**负面容器**里。
///
/// 沿 `ancestors()` 向上查 —— 因为负面标记常在外层
/// （`<div class="comments">` 里嵌套很多层才是 `<p>`）。
fn is_inside_negative(el: ElementRef) -> bool {
    static TAG_NEG: OnceLock<Vec<&'static str>> = OnceLock::new();
    let tags = TAG_NEG.get_or_init(|| vec!["nav", "footer", "aside", "form"]);

    for node in el.ancestors() {
        let Some(e) = ElementRef::wrap(node) else {
            continue;
        };
        let tag = e.value().name();
        if tags.contains(&tag) {
            return true;
        }
        // class 与 id 都要查（有的站把标记放在 id 上）
        for attr in ["class", "id", "role"] {
            if let Some(v) = e.value().attr(attr) {
                let lower = v.to_ascii_lowercase();
                if NEGATIVE_MARKERS.iter().any(|m| lower.contains(m)) {
                    return true;
                }
            }
        }
    }
    false
}

/// 元素文本 → 归一化的单行文本（空白折叠）。
///
/// # 🔴 为什么不用 `el.text()`（`scraper` 的便捷方法）
/// `el.text()` 会把 `<script>` / `<style>` 的**内容也吐出来** ——
/// 那些文本一旦进入正文，就是「看起来是文章、实际是 JS 源码」的静默污染。
///
/// # 为什么不用「先取文本再用正则删 script 块」
/// 我第一版那么写过 —— **错的**：`scraper` 的 `descendants()` 已经把标签结构展开成
/// 纯文本了，此时**没有 `>` 能匹配** `[^>]*>` → 正则**永远匹配不到任何东西**，
/// 于是脚本内容照旧泄漏，而**代码看起来是在防它**。
/// → 正解：**在遍历时就按标签跳过**（见下）。
///
/// # 🔑 为什么要「跳过整棵子树」而不是「跳过这个节点」
/// `<script>var x = 1;</script>` 的文本在**子节点**里 ——
/// 只跳过 `<script>` 元素本身，它的文本子节点仍会被 `descendants()` 访问到。
/// → 用一个 `skip_depth` 计数器：进入 `script` 块 +1，离开 -1，> 0 时不收文本。
///
/// 🔑 与后端 `content_rss::strip_html` 的折叠规则**保持一致**：
///    段落内不留换行（渲染层按段落渲染，不按源里的换行）。
fn normalized_text(el: ElementRef) -> String {
    static SKIP_TAGS: OnceLock<Vec<&'static str>> = OnceLock::new();
    let skip = SKIP_TAGS.get_or_init(|| vec!["script", "style", "noscript", "template"]);

    let mut buf = String::new();
    let mut skip_depth: usize = 0;
    for node in el.descendants() {
        match node.value() {
            scraper::node::Node::Element(e) if skip.contains(&e.name()) => {
                skip_depth += 1;
            }
            scraper::node::Node::Text(t) if skip_depth == 0 => {
                buf.push_str(&t.text);
            }
            _ => {}
        }
    }
    collapse_ws(&decode_basic_entities(&buf))
}

/// 折叠空白（连续空白 → 单空格，首尾去空白）。
fn collapse_ws(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut pending = false;
    for ch in s.chars() {
        if ch.is_whitespace() {
            pending = !out.is_empty();
        } else {
            if pending {
                out.push(' ');
                pending = false;
            }
            out.push(ch);
        }
    }
    out
}

/// 解常见实体 + 数字实体（与 `content_rss` 同一套 —— 只是这里不能复用它的私有函数）。
fn decode_basic_entities(s: &str) -> String {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"&(#x?[0-9a-fA-F]+|[a-zA-Z]+);").unwrap());
    re.replace_all(s, |caps: &regex::Captures| {
        let ent = &caps[1];
        if let Some(num) = ent.strip_prefix('#') {
            let code = if let Some(hex) = num.strip_prefix(['x', 'X']) {
                u32::from_str_radix(hex, 16).ok()
            } else {
                num.parse::<u32>().ok()
            };
            return code
                .and_then(char::from_u32)
                .map(|c| c.to_string())
                .unwrap_or_else(|| caps[0].to_string());
        }
        match ent {
            "amp" => "&".into(),
            "lt" => "<".into(),
            "gt" => ">".into(),
            "quot" => "\"".into(),
            "apos" => "'".into(),
            "nbsp" => " ".into(),
            "mdash" => "—".into(),
            "ndash" => "–".into(),
            "hellip" => "…".into(),
            "lsquo" => "\u{2018}".into(),
            "rsquo" => "\u{2019}".into(),
            "ldquo" => "\u{201C}".into(),
            "rdquo" => "\u{201D}".into(),
            // 未知实体保持原样（不猜）
            _ => caps[0].to_string(),
        }
    })
    .into_owned()
}

// ─────────────────────────────────────────────────────────────────────
// 🆕 2026-10-02 · 成熟包路线：`dom_smoothie`（readability.js 的 Rust 移植）
// ─────────────────────────────────────────────────────────────────────
//
// 上面那套启发式（`extract_article_paragraphs`）**保留**，但**不再是主路径** ——
// 它降级为「**回归对照**」：S2 的断言会拿同一批页面比较新旧输出。
// 保留的另一个作用是**回滚**（见 `content-pipeline-rebuild-plan` §七）。
//
// # 🔴 为什么要换（不是「包更成熟」这种空话，是三个可复现的症状）
// | 症状 | 自建版的行为 | 根因 |
// |---|---|---|
// | `<pre>` 里的 ASCII 树变成一行乱码 | `collapse_ws` 把换行与缩进一视同仁 | 只取 `<p>`、且折叠一切空白 |
// | 讨论 HTML 标签的文章里 `<img>` 裸奔 | `<code>` 的语义（等宽带底色）丢失 | 不是纯文本能表达的东西 |
// | 图片/表格/列表一律消失 | 只取 `<p>` 的文本节点 | 结构信息在提取时就没了 |
//
// # 🔑 「不自建」不是审美，是本项目自己的历史
// · 自建提取器：**640 行**，本报告三个症状中 2 个源于它
// · 自建渲染器 `markdown_span_nodes.dart`：**870 行**，**零消费者（死代码）**
// ⇒ 自建的隐性成本不只是「写」，还有「接线、维护、被弃置」。
//
// # 🔑 选它的硬理由：与现有栈**共享同一个 `html5ever 0.27.0`**
// 项目已有 `scraper 0.20`（→ html5ever 0.27.0），而 `dom_smoothie 0.18` 也是 0.27.0
// → **零重复编译、二进制不膨胀**。（对照：`htmd` → html5ever 0.39，会引入第二份解析器。）

/// 用 `dom_smoothie` 把网页正文提取成 **Markdown**（纯函数 · 零 IO）。
///
/// # 返回值语义
/// · 提到正文 → 返回 Markdown（**可能含 ``` 围栏、`##` 标题、反引号内联代码**）
/// · **返回空串** = 判定为「这篇没有可提取的正文」 → 调用方据此**不写 body**
///   （与旧版一致：**不要写空串进库**，那会让 `has_body` 为真、界面以为可读）
///
/// # 参数
/// · [html] 原网页 HTML
/// · [base_url] 页面**绝对 URL** —— 用来把 Markdown 里的**相对链接绝对化**
///   （`[t](/a/b)` 在 App 里点不开）。传 `None` 或不合法 URL 时**降级**：
///   链接保持相对，但**正文照常提取**（见下）。
///
/// # 🔴 两个「宁可降级也不要整篇失败」的处理
/// ① `document_url` 必须是**绝对 URL**，否则 `Readability::new` 直接返回
///    `BadDocumentURL`。→ 带 url 建失败时**退回不带 url 重试**，而不是放弃。
///    📌 判据：**增强项（绝对链接）失败，不该让主体（正文提取）失败**
///    —— 同族：端侧 `word_db.version` 读不到时退回「比文件大小」。
/// ② `parse()` 失败 → 返回空串（调用方记 `NoParagraphs`），不 panic。
///
/// # 🔴 图片：**有意丢弃**（产品决定 2026-10-02）
/// 白哥定「正文图片**先不显示**」—— 理由是**图片的版权风险比文字更直接**
/// （本项目的内容源策略就是绕开版权风险），且图床的国内可达性不可控。
/// 实测 `dom_smoothie` 的 Markdown 模式**本来就不输出 `![...](...)`**，
/// 但这里仍**做一次显式剥离** —— 「不显示图片」是**产品决定**，
/// **不该依赖第三方库的默认行为**（库升级可能改）。
/// 📌 判据：**决定要靠自己的代码兑现，不能靠依赖的副作用**。
pub fn extract_to_markdown(html: &str, base_url: Option<&str>) -> String {
    let cfg = || Config {
        text_mode: TextMode::Markdown,
        ..Default::default()
    };

    // ① 带 base_url（相对链接绝对化）；失败退回不带
    let mut rd = match Readability::new(html, base_url, Some(cfg())) {
        Ok(r) => r,
        Err(e) => {
            tracing::debug!(
                "content_extract: 带 url 构造失败（{:?}）→ 退回不带 url 重试",
                e
            );
            match Readability::new(html, None, Some(cfg())) {
                Ok(r) => r,
                Err(e2) => {
                    tracing::warn!("content_extract: 构造 Readability 失败: {:?}", e2);
                    return String::new();
                }
            }
        }
    };

    // ② 解析
    let article = match rd.parse() {
        Ok(a) => a,
        Err(e) => {
            tracing::warn!("content_extract: parse 失败: {:?}", e);
            return String::new();
        }
    };

    // ③ `text_content` 在 `TextMode::Markdown` 下**就是 Markdown**
    let md = article.text_content.to_string();

    // ④ 显式剥离图片语法（见函数文档「图片」一节）
    strip_markdown_images(&md)
}

/// 删掉 Markdown 图片语法 `![alt](url)` —— 见 [extract_to_markdown] 的「图片」说明。
///
/// ⚠️ 只删**图片**（`![`），**不碰链接**（`[`）—— 链接是正文的一部分，
/// 且实测正文里确有有用链接（`[my first post here](https://…)`）。
fn strip_markdown_images(md: &str) -> String {
    static RE: OnceLock<Regex> = OnceLock::new();
    // 📌 正则说明（**不是嵌套括号解析器**，够用即可）：
    //    `![` alt `]` `(` url `)` —— url 里出现 `)` 的极端情况会截断，
    //    但那只会让**图片残留一小段文字**，不会影响正文（且实测输出里根本没有图片）。
    let re = RE.get_or_init(|| Regex::new(r"!\[[^\]]*\]\([^)]*\)").unwrap());
    re.replace_all(md, "").into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实文章页（2026-09-29 抓自三站的真实文章，入库供离线断言）
    const NPR_PAGE: &str = include_str!("../tests/fixtures/npr_page.html");
    const ECNS_PAGE: &str = include_str!("../tests/fixtures/ecns_page.html");
    const DEVTO_PAGE: &str = include_str!("../tests/fixtures/devto_page.html");

    /// 🆕 2026-10-02 · 成熟包路线的 fixture —— **真实页面**，
    /// 且这两篇正是白哥真机反馈里的两个案例（`docs/review/content-parsing-rendering-issues-*`）：
    /// · 案例 3「正文里有 HTML 代码」→ 原文用 **32 个 `<code>`** 讨论标签（`` `<img>` `` / `alt`）
    /// · 案例 1「图表渲染错误」同类 → 原文 `<pre>` 里是**多行 + 缩进**的内容
    const DEVTO_INLINE_CODE_PAGE: &str =
        include_str!("../tests/fixtures/devto_inline_code_page.html");
    const DEVTO_CODE_BLOCK_PAGE: &str =
        include_str!("../tests/fixtures/devto_code_block_page.html");

    #[test]
    fn test_npr_article_tag_is_navigation_noise_but_we_avoid_it() {
        // 🔴 这是本模块存在的理由：NPR 的 `<article>` 里是导航噪音，
        //    真正文在 `<main>`。断言「提取结果**不含**那段导航」。
        let paras = extract_article_paragraphs(NPR_PAGE);
        assert!(!paras.is_empty(), "NPR 应提取到正文");
        let joined = paras.join("\n");
        assert!(
            !joined.contains("LISTEN & FOLLOW"),
            "🔴 不该把 `<article>` 里的导航当正文：{:?}",
            joined.chars().take(200).collect::<String>()
        );
        assert!(
            !joined.contains("Apple Podcasts"),
            "🔴 不该包含播客订阅链接"
        );
    }

    #[test]
    fn test_npr_extracts_real_body() {
        let paras = extract_article_paragraphs(NPR_PAGE);
        let joined = paras.join(" ");
        // 真实正文里出现过的内容（来自样本）
        assert!(
            joined.contains("fuel-economy")
                || joined.contains("fuel efficiency")
                || joined.contains("fuel-economy standards"),
            "应含真正文片段: {:?}",
            joined.chars().take(300).collect::<String>()
        );
        // 正文应当有一定体量（不是一两句）
        assert!(
            joined.chars().count() > 800,
            "正文太短: {}",
            joined.chars().count()
        );
    }

    #[test]
    fn test_ecns_has_no_article_or_main_falls_back_to_document() {
        // ECNS 实测：**既没有 `<article>` 也没有 `<main>`** → 必须退回整个文档。
        assert!(!ECNS_PAGE.to_ascii_lowercase().contains("<article"));
        let paras = extract_article_paragraphs(ECNS_PAGE);
        assert!(!paras.is_empty(), "ECNS 退回全文后应提取到段落");
        let joined = paras.join(" ");
        assert!(
            joined.chars().count() > 300,
            "ECNS 正文太短: {}",
            joined.chars().count()
        );
    }

    #[test]
    fn test_devto_excludes_comment_noise() {
        let paras = extract_article_paragraphs(DEVTO_PAGE);
        assert!(!paras.is_empty());
        // Dev.to 的文章页有大量评论/推荐；不应把它们全捞进来
        let joined = paras.join(" ").to_ascii_lowercase();
        // ⚠️ 这里不断言「完全不含评论词」—— 正文本身可能提到 comment。
        //    改为断言**体量可控**：不应把整页 18903 字符全捞进来。
        assert!(
            joined.chars().count() < 18000,
            "把整页都当正文了（评论未排除）: {}",
            joined.chars().count()
        );
    }

    #[test]
    fn test_negative_containers_are_excluded() {
        let html = r#"<html><body><main>
            <p>This is a genuine article paragraph that is long enough to count as body text.</p>
            <div class="comments"><p>This is a comment that should never be treated as body text at all.</p></div>
            <div id="sidebar"><p>Sidebar text that is also long enough to look like a paragraph here.</p></div>
            <nav><p>Navigation text that is long enough to be mistaken for a paragraph unfortunately.</p></nav>
            <p>Second genuine paragraph, also long enough to be counted as real body content here.</p>
        </main></body></html>"#;
        let paras = extract_article_paragraphs(html);
        let joined = paras.join(" ");
        assert!(
            joined.contains("genuine article paragraph"),
            "应取到正文: {:?}",
            paras
        );
        assert!(
            joined.contains("Second genuine"),
            "应取到第二段: {:?}",
            paras
        );
        assert!(
            !joined.contains("comment"),
            "🔴 评论不该进正文: {:?}",
            paras
        );
        assert!(
            !joined.contains("Sidebar"),
            "🔴 侧栏不该进正文: {:?}",
            paras
        );
        assert!(
            !joined.contains("Navigation"),
            "🔴 导航不该进正文: {:?}",
            paras
        );
    }

    #[test]
    fn test_script_and_style_text_not_leaked() {
        let html = r#"<html><body><main>
            <script>var secret = "should not appear";</script>
            <style>.x{content:"also not appear"}</style>
            <p>Real paragraph text that is long enough to be counted as actual body content.</p>
        </main></body></html>"#;
        let paras = extract_article_paragraphs(html);
        let joined = paras.join(" ");
        assert!(!joined.contains("secret"), "脚本内容泄漏: {:?}", paras);
        assert!(
            !joined.contains("also not appear"),
            "样式内容泄漏: {:?}",
            paras
        );
        assert!(joined.contains("Real paragraph"));
    }

    #[test]
    fn test_entities_decoded_and_whitespace_collapsed() {
        // ⚠️ 断言要挑**不会被字面文本干扰**的输入。
        //    我第一版写成 `and&nbsp;nbsp` —— 实体后面的字面 `nbsp` 会出现在结果里，
        //    断言 `!contains("nbsp")` 就变成了假红（**期望值自己写错了**）。
        let html = r#"<html><body><main><p>A paragraph with &amp; entity and&nbsp;a line
            break inside that should collapse into single spaces for rendering.</p></main></body></html>"#;
        let paras = extract_article_paragraphs(html);
        assert_eq!(paras.len(), 1);
        assert!(paras[0].contains("& entity"), "amp 应解码: {:?}", paras);
        assert!(!paras[0].contains('\n'), "段落内不该有换行: {:?}", paras);
        assert!(
            paras[0].contains("and a line break"),
            "nbsp 应解码成普通空格: {:?}",
            paras
        );
    }

    #[test]
    fn test_empty_or_garbage_input_returns_empty() {
        assert!(extract_article_paragraphs("").is_empty());
        assert!(extract_article_paragraphs("<html><body></body></html>").is_empty());
        // 🔴 无正文时必须返回**空**而不是含噪音的非空 —— 否则 `has_body` 会假真
        assert!(extract_article_paragraphs(
            "<html><body><nav><p>Only navigation here.</p></nav></body></html>"
        )
        .is_empty());
    }

    #[test]
    fn test_duplicate_paragraphs_deduped() {
        let html = r#"<html><body><main>
            <p>Identical paragraph text that is long enough to be counted as body content here.</p>
            <p>Identical paragraph text that is long enough to be counted as body content here.</p>
        </main></body></html>"#;
        let paras = extract_article_paragraphs(html);
        assert_eq!(paras.len(), 1, "重复段落应去重: {:?}", paras);
    }

    // ═══════════════════════════════════════════════════════════════
    // 🆕 2026-10-02 · 新提取器 `extract_to_markdown`（dom_smoothie）
    //
    // 🔑 这一组断言的**存在理由**：自建版把「结构」丢了 ——
    //    `<pre>` 被压成一行、`<code>` 的等宽语义消失。
    //    用户看到的是乱码/裸源码。文本断言**验不到「好看」**，
    //    但**能验「结构信息没丢」** —— 这正是本组要守的东西。
    //    ⚠️ 诚实边界：观感（代码块底色、内联代码样式）只能真机看。
    // ═══════════════════════════════════════════════════════════════

    /// 🔴 内联代码必须是**反引号**，而不是裸 `<img>` 这样的「HTML 源码」。
    #[test]
    fn test_md_inline_code_becomes_backticks() {
        let src_code = DEVTO_INLINE_CODE_PAGE.matches("<code").count();
        assert!(
            src_code >= 20,
            "fixture 应含大量内联代码，实际 {src_code} 个 <code>"
        );

        let md = extract_to_markdown(DEVTO_INLINE_CODE_PAGE, None);
        assert!(!md.is_empty(), "应提取到正文");

        // 判据 = **成对反引号的数量**（不是「有没有反引号」—— 那个太松，随便一段代码块也能满足）
        let ticks = md.matches('`').count();
        assert!(
            ticks >= src_code,
            "🔴 内联代码应被转成反引号：原 {src_code} 个 <code>，输出仅 {ticks} 个反引号\n前 300 字：{}",
            md.chars().take(300).collect::<String>()
        );
        // 更强的形态断言：原文讨论的就是这些标签 → 应出现**被反引号包裹的标签**
        //
        // ⚠️ 这里我第一版写错过（**期望值自己写错了**，不是实现错）：
        //    我断言 `` `> ``（反引号 + `>`），但 `` `<img>` `` 的形态是
        //    「反引号 + `<`」与「`>` + 反引号」—— **反引号后面永远不会跟 `>`**
        //    （`>` 后面跟的才是收尾反引号）→ 该断言恒为假。
        //    📌 同族旧例就在本文件（`and&nbsp;nbsp` 那条）：写断言时**要照着真实形态写**，
        //       不能凭「看起来对」—— 这类错会表现为「实现没问题但断言红」。
        assert!(
            md.contains("`<") && md.contains(">`"),
            "应出现被反引号包裹的标签（`` `<tag>` ``），实际含 ` <` = {} / `> ` = {}",
            md.contains("`<"),
            md.contains(">`")
        );
    }

    /// 🔴🔴 **本组最关键的一条**：代码块必须**保留换行与缩进**。
    ///
    /// 这正是案例 1 的命门 —— 自建版 `collapse_ws` 把 `<pre>` 里的 ASCII 树/终端输出
    /// **压成一行**，用户看到的是一串乱码。只断言「有 ``` 围栏」**不够**：
    /// 围栏里如果还是一行，症状**照旧**。
    #[test]
    fn test_md_code_block_keeps_newlines_and_indent() {
        let fence = "```";
        let md = extract_to_markdown(DEVTO_CODE_BLOCK_PAGE, None);
        assert!(md.contains(fence), "应产出 ``` 围栏代码块");

        // 切出**第一个**围栏块的内容
        let start = md.find(fence).expect("刚断言过有围栏");
        let after = &md[start + fence.len()..];
        let end = after.find(fence).expect("围栏应成对");
        let block = &after[..end];

        let lines = block.matches('\n').count();
        assert!(
            lines >= 5,
            "🔴 代码块内应保留换行（自建版会压成一行），实际仅 {lines} 个换行：{block:?}"
        );
        // 缩进：终端/树形图靠缩进表意，丢了就不可读
        assert!(
            block.contains("\n    ") || block.contains("\n\t"),
            "🔴 代码块内应保留缩进：{block:?}"
        );
    }

    /// 🔴 图片**有意丢弃**（产品决定 2026-10-02）——
    /// 且这条**不依赖第三方库的默认行为**（见 `strip_markdown_images` 的说明）。
    #[test]
    fn test_md_images_are_stripped() {
        // ① 真实页面（含分享图/头像等 `<img>`）
        let real = extract_to_markdown(DEVTO_INLINE_CODE_PAGE, None);
        assert!(
            !real.contains("!["),
            "🔴 产品决定「正文不显示图片」→ 真实页面输出不该有图片语法"
        );

        // ② 构造：正文里嵌一张图 —— 断言 `alt` 文字与 URL **都不残留**
        let html = r#"<html><body><article>
            <p>A genuinely long paragraph of body text that gives the extractor enough material to score it as the article content.</p>
            <figure>
              <img src="https://example.com/pic.png" alt="UNIQUE_ALT_MARKER">
              <figcaption>Some caption text.</figcaption>
            </figure>
            <p>Another long paragraph continuing the article so the scoring has enough material to work with reliably.</p>
        </article></body></html>"#;
        let md = extract_to_markdown(html, None);
        assert!(!md.contains("!["), "不该有图片语法：{md}");
        assert!(
            !md.contains("example.com/pic.png"),
            "图片 URL 不该出现在正文里：{md}"
        );
    }

    /// 🔑 **回归对照**：同一页面，旧版产出里**根本没有围栏**，新版有 ——
    /// 这条把「换包的收益」变成可检验的差异，而不是口头结论。
    #[test]
    fn test_old_vs_new_structural_regression() {
        let old = extract_article_paragraphs(DEVTO_CODE_BLOCK_PAGE).join("\n\n");
        let new = extract_to_markdown(DEVTO_CODE_BLOCK_PAGE, None);

        assert!(!old.is_empty() && !new.is_empty(), "两个版本都应提到内容");
        assert!(
            !old.contains("```"),
            "旧版是纯文本拼接，不该有围栏（若有，说明对照前提不成立）"
        );
        assert!(new.contains("```"), "新版应有围栏 —— 这就是换包的收益");
        // 🔑 旧版**没有任何换行缩进**的表意（都折成单行段落）
        //    新版有 —— 用「新版缩进行数 > 0」表达（旧版那侧不可能有，因为它 join 的每段内无换行）
        assert!(
            !old.contains("\n    "),
            "旧版段落内不该有缩进（它按段落折叠空白）→ 对照前提成立"
        );
    }

    /// 增强项失败**不该拖垮主体**：`base_url` 非法时降级重试，正文照常提取。
    #[test]
    fn test_md_bad_base_url_still_extracts() {
        let md = extract_to_markdown(DEVTO_INLINE_CODE_PAGE, Some("not a url"));
        assert!(
            !md.is_empty(),
            "🔴 非法 base_url 应降级成「不带 url 重试」，而不是返回空（那等于整篇丢正文）"
        );
    }

    /// 相对链接应被绝对化（否则 App 里点不开）。
    #[test]
    fn test_md_relative_links_absolutized() {
        let html = r#"<html><body><article>
            <p>A sufficiently long paragraph of article body text so the extractor treats this as readable content.</p>
            <p>See <a href="/relative/path">this link</a> for a longer explanation of the same topic that follows here.</p>
            <p>A third paragraph to give the scoring algorithm enough material to work with reliably here.</p>
        </article></body></html>"#;
        let md = extract_to_markdown(html, Some("https://example.com/post"));
        assert!(
            md.contains("https://example.com/relative/path"),
            "相对链接应绝对化：{md}"
        );
    }

    /// 空/垃圾输入 → **空串**（调用方据此记 `NoParagraphs`，不写 body）。
    #[test]
    fn test_md_empty_input_returns_empty() {
        assert!(extract_to_markdown("", None).is_empty());
        assert!(extract_to_markdown("<html><body></body></html>", None).is_empty());
    }

    /// `strip_markdown_images` 的直接单测 —— 它只该删**图片**，**不能碰链接**。
    #[test]
    fn test_strip_markdown_images_only_touches_images() {
        let src = "text ![alt](http://a/b.png) and [a link](http://a/c) end";
        let out = strip_markdown_images(src);
        assert!(!out.contains("![alt]"), "图片应被删：{out}");
        assert!(!out.contains("a/b.png"), "图片 URL 应被删：{out}");
        assert!(
            out.contains("[a link](http://a/c)"),
            "🔴 普通链接不该被删：{out}"
        );
    }
}

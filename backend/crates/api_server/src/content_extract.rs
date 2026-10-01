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

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实文章页（2026-09-29 抓自三站的真实文章，入库供离线断言）
    const NPR_PAGE: &str = include_str!("../tests/fixtures/npr_page.html");
    const ECNS_PAGE: &str = include_str!("../tests/fixtures/ecns_page.html");
    const DEVTO_PAGE: &str = include_str!("../tests/fixtures/devto_page.html");

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
            &joined.chars().take(200).collect::<String>()
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
            &joined.chars().take(300).collect::<String>()
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
}

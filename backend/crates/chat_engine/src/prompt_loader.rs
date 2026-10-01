//! Prompt Loader — 按类别 × 科目加载 prompt 模板
//!
//! 目录结构:
//!   prompts/{category}/{subject}/{type}.md                          ← 旧式单文件（保留后向兼容）
//!   prompts/{category}/{subject}/signal/{type}.md                   ← 新式：指令（判断逻辑）
//!   prompts/{category}/{subject}/format/{type}.md                   ← 新式：输出格式（可引用 format/ 共享池）
//!   prompts/format/{subcategory}/{type}.md                          ← 共享格式模板池
//!
//! 加载优先级:
//!   1. signal/{type}.md + format/{type}.md（合并）→ resolve {include:...}
//!   2. {type}.md（旧式单文件，后向兼容）
//!   3. fallback 到对应 general
//!
//! 类别:
//!   chat     - 教师对话（free/structured/reading...）
//!   concept  - CP1 概念提取（extract/direct）
//!   plan     - CP2 计划管理（creation/analysis/signal）
//!   quiz     - 考核（generate/judge/grill）
//!   verify   - 复习验证（spelling/dialogue/translation）
//!   routing  - 学科路由（subject）

use std::collections::HashMap;
use std::sync::OnceLock;

// ── 各类别 prompt 结构体 ──

#[derive(Clone, Debug, Default)]
pub struct ChatTemplates {
    pub free: String,
    pub structured: String,
    pub reading: String,
    pub reading_nursery: String,
    pub reading_primary: String,
    pub reading_secondary: String,
}

#[derive(Clone, Debug, Default)]
pub struct ConceptTemplates {
    pub extract: String,
    pub direct: String,
}

#[derive(Clone, Debug, Default)]
pub struct PlanTemplates {
    pub creation: String,
    pub analysis: String,
    pub signal: String,
}

#[derive(Clone, Debug, Default)]
pub struct QuizTemplates {
    pub generate: String,
    pub judge: String,
    pub grill: String,
}

#[derive(Clone, Debug, Default)]
pub struct VerifyTemplates {
    pub spelling: String,
    pub dialogue: String,
    pub translation: String,
    pub usage: String,
}

#[derive(Clone, Debug, Default)]
pub struct RoutingTemplates {
    pub subject: String,
}

// ── 注册表 ──

pub struct PromptRegistry {
    /// 各类别 × 科目 map
    pub chat: HashMap<String, ChatTemplates>,
    pub concept: HashMap<String, ConceptTemplates>,
    pub plan: HashMap<String, PlanTemplates>,
    pub quiz: HashMap<String, QuizTemplates>,
    pub verify: HashMap<String, VerifyTemplates>,
    pub routing: HashMap<String, RoutingTemplates>,
    /// 各类别通用兜底
    pub chat_general: ChatTemplates,
    pub concept_general: ConceptTemplates,
    pub plan_general: PlanTemplates,
    pub quiz_general: QuizTemplates,
    pub verify_general: VerifyTemplates,
    pub routing_general: RoutingTemplates,
    /// 存储 base_dir，用于解析 {include:...} 引用
    #[allow(dead_code)]
    base_dir: String,
}

static REGISTRY: OnceLock<PromptRegistry> = OnceLock::new();

// ── 工具函数 ──

fn read_file(path: &str) -> String {
    std::fs::read_to_string(path).unwrap_or_default()
}

/// 递归解析 {include:path} 引用
/// path 基准格式: format/{subcategory}/{name}.md
/// 从 {base_dir}/format/{subcategory}/{name}.md 读取
fn resolve_includes(text: &str, base_dir: &str) -> String {
    /// `{include:...}` 匹配器。
    ///
    /// 🔑 **进程内只编译一次**（`OnceLock`），而不是每次进函数/每轮迭代都 `Regex::new`。
    ///     原实现在 **loop 内部**构造正则 —— 而 `resolve_includes` 对每个 prompt 文件
    ///     都要调用，且它自身还要**递归展开到稳定**（`loop`）→
    ///     编译次数 = O(文件数 × 迭代轮数)。正则编译要分配、是 O(模式) 成本，白白浪费。
    ///
    /// 🔴 注意：同一函数内若还要第二个模式，**必须另开一个 `OnceLock`** ——
    ///     共用一个 cell 会让第二个 `get_or_init` **静默失效**（返回上一个正则）。
    ///     同族判据：「共享的缓存槽位 = 第二件事静默失效的地方」。
    static RE: OnceLock<regex::Regex> = OnceLock::new();
    let re = RE.get_or_init(|| regex::Regex::new(r"\{include:([^}]+)\}").expect("正则字面量写错"));

    let mut result = text.to_string();
    loop {
        let before = result.clone();
        result = re
            .replace_all(&result, |caps: &regex::Captures| {
                let include_path = caps.get(1).unwrap().as_str();
                let full_path = std::path::Path::new(base_dir).join(include_path);
                let full_str = full_path.to_string_lossy().to_string();
                read_file(&full_str)
            })
            .to_string();
        if result == before {
            break;
        }
    }
    result
}

/// 读取三部分 prompt：主模板 + signal（正则信号）+ format（输出格式），按序合并
/// 此外还会自动追加类别级 {category}/signal.md 和 {category}/format.md（如存在）
/// 优先级: signal/{type}.md + format/{type}.md + {type}.md（三份合并）
/// → {type}.md（旧式单文件兜底）
/// → general fallback
fn read_signal_or_flat(dir: &str, type_name: &str, base_dir: &str, _fallback: &str) -> String {
    let dir_path = std::path::Path::new(dir);
    // category 从 dir 的父目录提取: prompts/{category}/{subject}
    let signal_path = dir_path.join("signal").join(format!("{}.md", type_name));
    let format_path = dir_path.join("format").join(format!("{}.md", type_name));
    let flat_path = dir_path.join(format!("{}.md", type_name));

    // 1. 主模板（{type}.md）— 需要解析 {include:...} 引用
    let main_raw = read_file(&flat_path.to_string_lossy());
    let main = if !main_raw.is_empty() {
        resolve_includes(&main_raw, base_dir)
    } else {
        String::new()
    };
    // 2. subject 级 signal
    let signal_raw = read_file(&signal_path.to_string_lossy());
    let subject_signal = if !signal_raw.is_empty() {
        resolve_includes(&signal_raw, base_dir)
    } else {
        String::new()
    };
    // 3. subject 级 format
    let format_raw = read_file(&format_path.to_string_lossy());
    let subject_format = if !format_raw.is_empty() {
        resolve_includes(&format_raw, base_dir)
    } else {
        String::new()
    };
    // 4. 类别级 signal.md（仅用于手动 {include:...} 引用，不自动追加）
    // 如需启用，取消下方注释并从对应主 prompt 移除 {include:...} 引用
    // let cat_signal = resolve_includes(&read_file(&cat_dir.join("signal.md").to_string_lossy()), base_dir);
    // let cat_format = resolve_includes(&read_file(&cat_dir.join("format.md").to_string_lossy()), base_dir);

    // 合并：主 + subject_signal + subject_format
    let mut parts: Vec<String> = Vec::new();
    if !main.is_empty() {
        parts.push(main);
    }
    if !subject_signal.is_empty() {
        parts.push(subject_signal);
    }
    if !subject_format.is_empty() {
        parts.push(subject_format);
    }

    if parts.is_empty() {
        return String::new();
    }
    parts.join("\n\n")
}

/// 读取 subject 目录下某个 type 的文件，fallback 到指定的兜底值
fn read_signal_or_flat_with_fallback(
    dir: &str,
    type_name: &str,
    base_dir: &str,
    fallback: &str,
) -> String {
    let val = read_signal_or_flat(dir, type_name, base_dir, fallback);
    if val.is_empty() {
        fallback.to_string()
    } else {
        val
    }
}

// ── 加载函数 ──

fn load_chat_dir(dir: &str, base_dir: &str) -> ChatTemplates {
    ChatTemplates {
        free: read_signal_or_flat(dir, "free", base_dir, ""),
        structured: read_signal_or_flat(dir, "structured", base_dir, ""),
        reading: read_signal_or_flat(dir, "reading", base_dir, ""),
        reading_nursery: read_signal_or_flat(dir, "reading-nursery", base_dir, ""),
        reading_primary: read_signal_or_flat(dir, "reading-primary", base_dir, ""),
        reading_secondary: read_signal_or_flat(dir, "reading-secondary", base_dir, ""),
    }
}

fn load_chat_dir_with_fallback(
    dir: &str,
    fallback: &ChatTemplates,
    base_dir: &str,
) -> ChatTemplates {
    ChatTemplates {
        free: read_signal_or_flat_with_fallback(dir, "free", base_dir, &fallback.free),
        structured: read_signal_or_flat_with_fallback(
            dir,
            "structured",
            base_dir,
            &fallback.structured,
        ),
        reading: read_signal_or_flat_with_fallback(dir, "reading", base_dir, &fallback.reading),
        reading_nursery: read_signal_or_flat_with_fallback(
            dir,
            "reading-nursery",
            base_dir,
            &fallback.reading_nursery,
        ),
        reading_primary: read_signal_or_flat_with_fallback(
            dir,
            "reading-primary",
            base_dir,
            &fallback.reading_primary,
        ),
        reading_secondary: read_signal_or_flat_with_fallback(
            dir,
            "reading-secondary",
            base_dir,
            &fallback.reading_secondary,
        ),
    }
}

fn load_concept_dir(dir: &str, base_dir: &str) -> ConceptTemplates {
    ConceptTemplates {
        extract: read_signal_or_flat(dir, "extract", base_dir, ""),
        direct: read_signal_or_flat(dir, "direct", base_dir, ""),
    }
}

fn load_concept_dir_with_fallback(
    dir: &str,
    fallback: &ConceptTemplates,
    base_dir: &str,
) -> ConceptTemplates {
    ConceptTemplates {
        extract: read_signal_or_flat_with_fallback(dir, "extract", base_dir, &fallback.extract),
        direct: read_signal_or_flat_with_fallback(dir, "direct", base_dir, &fallback.direct),
    }
}

fn load_plan_dir(dir: &str, base_dir: &str) -> PlanTemplates {
    PlanTemplates {
        creation: read_signal_or_flat(dir, "creation", base_dir, ""),
        analysis: read_signal_or_flat(dir, "analysis", base_dir, ""),
        signal: read_signal_or_flat(dir, "signal", base_dir, ""),
    }
}

fn load_plan_dir_with_fallback(
    dir: &str,
    fallback: &PlanTemplates,
    base_dir: &str,
) -> PlanTemplates {
    PlanTemplates {
        creation: read_signal_or_flat_with_fallback(dir, "creation", base_dir, &fallback.creation),
        analysis: read_signal_or_flat_with_fallback(dir, "analysis", base_dir, &fallback.analysis),
        signal: read_signal_or_flat_with_fallback(dir, "signal", base_dir, &fallback.signal),
    }
}

fn load_quiz_dir(dir: &str, base_dir: &str) -> QuizTemplates {
    QuizTemplates {
        generate: read_signal_or_flat(dir, "generate", base_dir, ""),
        judge: read_signal_or_flat(dir, "judge", base_dir, ""),
        grill: read_signal_or_flat(dir, "grill", base_dir, ""),
    }
}

fn load_quiz_dir_with_fallback(
    dir: &str,
    fallback: &QuizTemplates,
    base_dir: &str,
) -> QuizTemplates {
    QuizTemplates {
        generate: read_signal_or_flat_with_fallback(dir, "generate", base_dir, &fallback.generate),
        judge: read_signal_or_flat_with_fallback(dir, "judge", base_dir, &fallback.judge),
        grill: read_signal_or_flat_with_fallback(dir, "grill", base_dir, &fallback.grill),
    }
}

fn load_verify_dir(dir: &str, base_dir: &str) -> VerifyTemplates {
    VerifyTemplates {
        spelling: read_signal_or_flat(dir, "spelling", base_dir, ""),
        dialogue: read_signal_or_flat(dir, "dialogue", base_dir, ""),
        translation: read_signal_or_flat(dir, "translation", base_dir, ""),
        usage: read_signal_or_flat(dir, "usage", base_dir, ""),
    }
}

fn load_verify_dir_with_fallback(
    dir: &str,
    fallback: &VerifyTemplates,
    base_dir: &str,
) -> VerifyTemplates {
    VerifyTemplates {
        spelling: read_signal_or_flat_with_fallback(dir, "spelling", base_dir, &fallback.spelling),
        dialogue: read_signal_or_flat_with_fallback(dir, "dialogue", base_dir, &fallback.dialogue),
        translation: read_signal_or_flat_with_fallback(
            dir,
            "translation",
            base_dir,
            &fallback.translation,
        ),
        usage: read_signal_or_flat_with_fallback(dir, "usage", base_dir, &fallback.usage),
    }
}

fn load_routing_dir(dir: &str, base_dir: &str) -> RoutingTemplates {
    RoutingTemplates {
        subject: read_signal_or_flat(dir, "subject", base_dir, ""),
    }
}

fn load_routing_dir_with_fallback(
    dir: &str,
    fallback: &RoutingTemplates,
    base_dir: &str,
) -> RoutingTemplates {
    RoutingTemplates {
        subject: read_signal_or_flat_with_fallback(dir, "subject", base_dir, &fallback.subject),
    }
}

/// 扫描某类别下所有科目子目录并注册
fn scan_subject_dirs<T, F1, F2>(
    base_dir: &str,
    category: &str,
    load_dir: F1,
    load_with_fb: F2,
) -> (HashMap<String, T>, T)
where
    T: Clone + Default,
    F1: Fn(&str, &str) -> T,
    F2: Fn(&str, &T, &str) -> T,
{
    let base = std::path::Path::new(base_dir);
    let cat_dir = base.join(category);
    let general_dir = cat_dir.join("general");
    let general_path = general_dir.to_string_lossy().to_string();
    let general = if general_dir.exists() {
        load_dir(&general_path, base_dir)
    } else {
        T::default()
    };

    let mut map = HashMap::new();
    if let Ok(entries) = std::fs::read_dir(&cat_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let name = match path.file_name().and_then(|n| n.to_str()) {
                Some(n) if !n.is_empty() && n != "general" => n.to_string(),
                _ => continue,
            };
            let dir_str = path.to_string_lossy().to_string();
            let tpl = load_with_fb(&dir_str, &general, base_dir);
            map.insert(name, tpl);
        }
    }
    (map, general)
}

// ── 初始化 ──

/// 初始化: 扫描 prompts/{category}/{subject}/ 注册所有 prompt
pub fn init(base_dir: &str) {
    // 解析 base_dir 为绝对路径（不做 canonicalize，避免 Windows \/ 混用问题）
    let abs_base = std::path::Path::new(base_dir);
    let abs_base = if abs_base.is_absolute() {
        base_dir.to_string()
    } else {
        // 相对路径 → 获取当前目录
        std::env::current_dir()
            .unwrap_or_default()
            .join(base_dir)
            .to_string_lossy()
            .to_string()
    };

    let (chat, chat_general) = scan_subject_dirs(
        &abs_base,
        "chat",
        load_chat_dir,
        load_chat_dir_with_fallback,
    );
    let (concept, concept_general) = scan_subject_dirs(
        &abs_base,
        "concept",
        load_concept_dir,
        load_concept_dir_with_fallback,
    );
    let (plan, plan_general) = scan_subject_dirs(
        &abs_base,
        "plan",
        load_plan_dir,
        load_plan_dir_with_fallback,
    );
    let (quiz, quiz_general) = scan_subject_dirs(
        &abs_base,
        "quiz",
        load_quiz_dir,
        load_quiz_dir_with_fallback,
    );
    let (verify, verify_general) = scan_subject_dirs(
        &abs_base,
        "verify",
        load_verify_dir,
        load_verify_dir_with_fallback,
    );
    let (routing, routing_general) = scan_subject_dirs(
        &abs_base,
        "routing",
        load_routing_dir,
        load_routing_dir_with_fallback,
    );

    let registry = PromptRegistry {
        chat: chat.clone(),
        chat_general: chat_general.clone(),
        concept: concept.clone(),
        concept_general: concept_general.clone(),
        plan: plan.clone(),
        plan_general: plan_general.clone(),
        quiz: quiz.clone(),
        quiz_general: quiz_general.clone(),
        verify: verify.clone(),
        verify_general: verify_general.clone(),
        routing: routing.clone(),
        routing_general: routing_general.clone(),
        base_dir: abs_base,
    };
    let _ = REGISTRY.set(registry);

    tracing::info!(
        "Prompts loaded: chat({} subjects), concept({}), plan({}), quiz({}), verify({}), routing({})",
        chat.len(), concept.len(), plan.len(), quiz.len(), verify.len(), routing.len(),
    );
}

// ── 查询 API（完全后向兼容） ──

/// 获取教师对话 prompt，按科目 fallback
pub fn get_chat(subject: &str) -> &'static ChatTemplates {
    let r = REGISTRY.get().expect("Prompts not initialized");
    if subject.is_empty() || subject == "general" {
        return &r.chat_general;
    }
    r.chat.get(subject).unwrap_or(&r.chat_general)
}

/// 获取概念提取 prompt，按科目 fallback
pub fn get_concept(subject: &str) -> &'static ConceptTemplates {
    let r = REGISTRY.get().expect("Prompts not initialized");
    if subject.is_empty() || subject == "general" {
        return &r.concept_general;
    }
    r.concept.get(subject).unwrap_or(&r.concept_general)
}

/// 获取计划 prompt
pub fn get_plan(subject: &str) -> &'static PlanTemplates {
    let r = REGISTRY.get().expect("Prompts not initialized");
    if subject.is_empty() || subject == "general" {
        return &r.plan_general;
    }
    r.plan.get(subject).unwrap_or(&r.plan_general)
}

/// 获取考核 prompt，按科目 fallback
pub fn get_quiz(subject: &str) -> &'static QuizTemplates {
    let r = REGISTRY.get().expect("Prompts not initialized");
    if subject.is_empty() || subject == "general" {
        return &r.quiz_general;
    }
    r.quiz.get(subject).unwrap_or(&r.quiz_general)
}

/// 获取复习验证 prompt
pub fn get_verify(subject: &str) -> &'static VerifyTemplates {
    let r = REGISTRY.get().expect("Prompts not initialized");
    if subject.is_empty() || subject == "general" {
        return &r.verify_general;
    }
    r.verify.get(subject).unwrap_or(&r.verify_general)
}

/// 获取路由 prompt
pub fn get_routing() -> &'static RoutingTemplates {
    &REGISTRY
        .get()
        .expect("Prompts not initialized")
        .routing_general
}

// ── 辅助函数（供 concept_extractor 等调用） ──

/// 构建概念提取 prompt（通用管线，后向兼容）
pub fn build_concept_extract(
    text: &str,
    existing_concepts: &[String],
    context_turns: &[(String, String)],
) -> String {
    build_concept_extract_for_domain(text, existing_concepts, context_turns, "general")
}

/// 构建概念提取 prompt（带 domain 路由）
pub fn build_concept_extract_for_domain(
    text: &str,
    existing_concepts: &[String],
    context_turns: &[(String, String)],
    domain: &str,
) -> String {
    build_concept_extract_for_domain_with_plan(text, existing_concepts, context_turns, domain, "")
}

/// 构建概念提取 prompt（带 domain 路由 + plan 上下文）
pub fn build_concept_extract_for_domain_with_plan(
    text: &str,
    existing_concepts: &[String],
    context_turns: &[(String, String)],
    domain: &str,
    plan_context: &str,
) -> String {
    let tpl = get_concept(domain);

    let concepts_str = if existing_concepts.is_empty() {
        "（暂无）".to_string()
    } else {
        existing_concepts
            .iter()
            .map(|c| format!("- {}", c))
            .collect::<Vec<_>>()
            .join("\n")
    };

    let history_str = if context_turns.is_empty() {
        "（首轮对话）".to_string()
    } else {
        context_turns
            .iter()
            .map(|(role, content)| format!("{}: {}", role, content))
            .collect::<Vec<_>>()
            .join("\n")
    };

    if tpl.extract.is_empty() {
        // 降级为硬编码
        format!(
            "从以下文本中提取值得记住的知识点，最多5个。返回JSON数组。\n\n已有概念:\n{}\n\n{}",
            concepts_str, text
        )
    } else {
        tpl.extract
            .replace("{text}", text)
            .replace("{existing_concepts_list}", &concepts_str)
            .replace("{conversation_history}", &history_str)
            .replace("{plan_context}", plan_context)
    }
}

/// 构建直接制卡 prompt
pub fn build_card_direct(user_message: &str, ai_reply: &str) -> String {
    let tpl = get_concept("general");
    if tpl.direct.is_empty() {
        format!(
            "Generate a flashcard from this conversation.\nUser: {}\nAI: {}",
            user_message, ai_reply
        )
    } else {
        tpl.direct
            .replace("{user_message}", user_message)
            .replace("{ai_reply}", ai_reply)
    }
}

// ── 后向兼容（过渡期用，后续删除） ──
use crate::pipeline_router::Domain;

/// 后向兼容: 从 Domain 解析 subject，获取 chat prompt
pub fn get_chat_for_domain(domain: &Domain) -> &'static ChatTemplates {
    get_chat(&domain.to_string())
}

/// 后向兼容: 从 domain 字符串获取 concept prompt
pub fn get_concept_for_domain(domain: &str) -> &'static ConceptTemplates {
    get_concept(domain)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Once;

    static INIT: Once = Once::new();
    /// 🔑 用 `OnceLock` 而不是 `static mut` —— 后者在 Rust 2024 里
    ///    「对可变 static 取共享引用」是**未定义行为**（`static_mut_refs`）。
    ///    `call_once` 内的写入语义与 `OnceLock::set` 完全一致（只成功一次）。
    static TMP_DIR: OnceLock<String> = OnceLock::new();

    /// 获取测试用 tmp 路径
    fn test_tmp() -> String {
        TMP_DIR.get().cloned().unwrap_or_default()
    }

    fn test_init() -> String {
        INIT.call_once(|| {
            let tmp = std::env::temp_dir().join("coevo_prompt_test_three_part");
            let _ = std::fs::remove_dir_all(&tmp);
            // chat/general/ — 三份结构: main.md + signal + format
            std::fs::create_dir_all(tmp.join("chat/general/signal")).ok();
            std::fs::create_dir_all(tmp.join("chat/general/format")).ok();
            std::fs::write(tmp.join("chat/general/free.md"), "通用聊天指令").ok();
            std::fs::write(tmp.join("chat/general/signal/free.md"), "正则信号").ok();
            std::fs::write(
                tmp.join("chat/general/format/free.md"),
                "{include:format/shared/json-only.md}",
            )
            .ok();
            // chat/math/ — 三份
            std::fs::create_dir_all(tmp.join("chat/math/signal")).ok();
            std::fs::create_dir_all(tmp.join("chat/math/format")).ok();
            std::fs::write(tmp.join("chat/math/free.md"), "数学聊天指令").ok();
            std::fs::write(tmp.join("chat/math/signal/free.md"), "数学正则信号").ok();
            std::fs::write(
                tmp.join("chat/math/format/free.md"),
                "{include:format/shared/json-only.md}",
            )
            .ok();
            // shared format pool
            std::fs::create_dir_all(tmp.join("format/shared")).ok();
            std::fs::write(tmp.join("format/shared/json-only.md"), "只返回JSON").ok();
            // concept/ — 三份: main extract.md + signal + format
            std::fs::create_dir_all(tmp.join("concept/general/signal")).ok();
            std::fs::create_dir_all(tmp.join("concept/general/format")).ok();
            std::fs::write(tmp.join("concept/general/extract.md"), "通用提取指令").ok();
            std::fs::write(
                tmp.join("concept/general/format/extract.md"),
                "通用输出格式",
            )
            .ok();
            // quiz/ — 三份
            std::fs::create_dir_all(tmp.join("quiz/general/signal")).ok();
            std::fs::create_dir_all(tmp.join("quiz/general/format")).ok();
            std::fs::write(tmp.join("quiz/general/generate.md"), "通用出题指令").ok();
            std::fs::write(tmp.join("quiz/general/format/generate.md"), "出题JSON格式").ok();
            // plan/ — 三份
            std::fs::create_dir_all(tmp.join("plan/general/signal")).ok();
            std::fs::create_dir_all(tmp.join("plan/general/format")).ok();
            std::fs::write(tmp.join("plan/general/creation.md"), "通用创建指令").ok();
            std::fs::write(tmp.join("plan/general/format/creation.md"), "创建JSON格式").ok();
            // verify/ — 仅旧式 flat 文件
            std::fs::create_dir_all(tmp.join("verify/general")).ok();
            std::fs::write(tmp.join("verify/general/translation.md"), "旧式翻译模板").ok();
            // routing/ — 三份
            std::fs::create_dir_all(tmp.join("routing/general/signal")).ok();
            std::fs::create_dir_all(tmp.join("routing/general/format")).ok();
            std::fs::write(tmp.join("routing/general/subject.md"), "路由指令").ok();
            std::fs::write(tmp.join("routing/general/signal/subject.md"), "路由信号").ok();

            let path = tmp.to_str().unwrap().to_string();
            init(&path);
            let _ = TMP_DIR.set(path);
        });
        test_tmp()
    }

    #[test]
    fn test_get_chat_general_signal_format() {
        test_init();
        let tpl = get_chat("general");
        // main + signal + format 三份合并
        assert!(tpl.free.contains("通用聊天指令"), "应包含 main 内容");
        assert!(tpl.free.contains("正则信号"), "应包含 signal 内容");
        assert!(
            tpl.free.contains("只返回JSON"),
            "应包含解析后的 format include"
        );
        assert!(tpl.structured.is_empty());
    }

    #[test]
    fn test_get_chat_math_subject_specific() {
        test_init();
        let tpl = get_chat("math");
        assert!(tpl.free.contains("数学聊天指令"), "数学专用 main");
        assert!(tpl.free.contains("数学正则信号"), "数学专用 signal");
        assert!(tpl.free.contains("只返回JSON"), "共享 format (resolved)");
    }

    #[test]
    fn test_get_chat_unknown_fallback() {
        test_init();
        let tpl = get_chat("history");
        assert!(tpl.free.contains("通用聊天指令"), "fallback 到 general");
    }

    #[test]
    fn test_get_concept_general() {
        test_init();
        let tpl = get_concept("general");
        // main + format（无 signal）
        assert!(tpl.extract.starts_with("通用提取指令"), "应包含 main");
        assert!(tpl.extract.contains("通用输出格式"), "应包含 format");
    }

    #[test]
    fn test_get_quiz() {
        test_init();
        let tpl = get_quiz("general");
        assert!(tpl.generate.contains("通用出题指令"));
        assert!(tpl.generate.contains("出题JSON格式"));
    }

    #[test]
    fn test_get_plan() {
        test_init();
        let tpl = get_plan("general");
        assert!(tpl.creation.contains("通用创建指令"));
        assert!(tpl.creation.contains("创建JSON格式"));
    }

    #[test]
    fn test_get_verify_fallback_to_flat() {
        test_init();
        let tpl = get_verify("general");
        assert_eq!(tpl.translation, "旧式翻译模板");
    }

    #[test]
    fn test_get_routing() {
        test_init();
        let tpl = get_routing();
        assert!(tpl.subject.contains("路由指令"));
    }

    #[test]
    fn test_reading_not_present() {
        test_init();
        let tpl = get_chat("general");
        // reading 未设置，应为空
        assert!(tpl.reading.is_empty());
        assert!(tpl.reading_nursery.is_empty());
    }
}

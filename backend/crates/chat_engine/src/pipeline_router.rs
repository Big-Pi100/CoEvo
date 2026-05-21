//! Pipeline Router — 管线注册表与路由
//!
//! 根据 domain 返回管线的元数据配置。
//! 调用方使用配置确定加载哪组 prompt、使用哪种验证策略。

/// 管线配置
#[derive(Debug, Clone)]
pub struct PipelineConfig {
    /// domain 标识（与 learning_plans.domain 对齐）
    pub domain: &'static str,
    /// 可读名称
    pub display_name: &'static str,
    /// 可用的验证方式列表
    pub available_verifications: &'static [&'static str],
}

/// 通用管线
const GENERAL: PipelineConfig = PipelineConfig {
    domain: "general",
    display_name: "通用学习",
    available_verifications: &["ai_dialogue"],
};

/// 数学/物理管线
const MATH: PipelineConfig = PipelineConfig {
    domain: "math",
    display_name: "数学/物理学习",
    available_verifications: &["ai_dialogue"],
};

/// 语言学习管线
const LANGUAGE: PipelineConfig = PipelineConfig {
    domain: "language",
    display_name: "语言学习",
    available_verifications: &["spelling", "ai_dialogue"],
};

/// 解析 domain 到管线配置
///
/// - 已知 domain → 返回对应管线配置
/// - domain 为空或未知 → 返回通用管线
pub fn resolve(domain: &str) -> &'static PipelineConfig {
    match domain {
        "math" => &MATH,
        "language" => &LANGUAGE,
        _ => &GENERAL,
    }
}

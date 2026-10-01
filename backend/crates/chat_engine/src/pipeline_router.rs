//! Pipeline Router — 管线注册表与路由
//!
//! 根据 domain 返回管线的元数据配置。
//! 调用方使用配置确定加载哪组 prompt、使用哪种验证策略。

use std::fmt;
use std::str::FromStr;

/// 学科分类枚举 — K12 全科目，对应 DB CHECK 约束
///
/// Display → 小写字符串（"math"），用于写入 DB
/// FromStr → 接受英文名和中文名，未知值返回 General
/// 有专用管线的科目（math/language）走各自管线，其余全部走 General 兜底管线
#[derive(Debug, Clone, PartialEq)]
pub enum Domain {
    /// 通用 / 兜底（历史、地理、政治、科学、信息技术、体育、艺术、劳动等）
    General,
    /// 数学
    Math,
    /// 语言类（语文、英语、日语、俄语）
    Language,
    /// 化学
    Chemistry,
    /// 生物
    Biology,
    /// 物理
    Physics,
    /// 历史
    History,
    /// 地理
    Geography,
    /// 政治 / 道德与法治
    Politics,
    /// 科学（小学）
    Science,
    /// 信息技术
    It,
    /// 体育
    Pe,
    /// 艺术（美术 / 音乐）
    Art,
    /// 劳动
    Labor,
}

impl Domain {
    /// 所有有效值的静态列表，用于 SQL CHECK 约束和测试
    pub const ALL: &'static [&'static str] = &[
        "general",
        "math",
        "language",
        "chemistry",
        "biology",
        "physics",
        "history",
        "geography",
        "politics",
        "science",
        "it",
        "pe",
        "art",
        "labor",
    ];

    /// 从中文 subject 映射到 Domain 枚举
    /// 标记 deprecated：新代码应使用 Domain::from_str（同时支持中英文）
    #[deprecated(note = "use Domain::from_str instead (supports both Chinese and English)")]
    pub fn from_chinese(cn: &str) -> Self {
        match cn {
            "数学" => Domain::Math,
            "语文" | "英语" | "日语" | "俄语" => Domain::Language,
            "化学" => Domain::Chemistry,
            "生物" | "生物学" => Domain::Biology,
            "物理" => Domain::Physics,
            "历史" => Domain::History,
            "地理" => Domain::Geography,
            "政治" | "道德与法治" | "道法" => Domain::Politics,
            "科学" => Domain::Science,
            "信息技术" | "信息科技" | "it" | "IT" => Domain::It,
            "体育" | "体育与健康" => Domain::Pe,
            "美术" | "音乐" | "艺术" => Domain::Art,
            "劳动" => Domain::Labor,
            _ => Domain::General,
        }
    }

    /// SQL CHECK 表达式字符串，直接嵌入 DDL
    pub fn check_sql() -> &'static str {
        "CHECK(domain IN ('general','math','language','chemistry','biology','physics',\
                          'history','geography','politics','science','it','pe','art','labor'))"
    }
}

impl fmt::Display for Domain {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Domain::General => write!(f, "general"),
            Domain::Math => write!(f, "math"),
            Domain::Language => write!(f, "language"),
            Domain::Chemistry => write!(f, "chemistry"),
            Domain::Biology => write!(f, "biology"),
            Domain::Physics => write!(f, "physics"),
            Domain::History => write!(f, "history"),
            Domain::Geography => write!(f, "geography"),
            Domain::Politics => write!(f, "politics"),
            Domain::Science => write!(f, "science"),
            Domain::It => write!(f, "it"),
            Domain::Pe => write!(f, "pe"),
            Domain::Art => write!(f, "art"),
            Domain::Labor => write!(f, "labor"),
        }
    }
}

impl FromStr for Domain {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "general" | "" => Ok(Domain::General),
            "math" | "数学" => Ok(Domain::Math),
            "language" | "语文" | "英语" => Ok(Domain::Language),
            "chemistry" | "化学" => Ok(Domain::Chemistry),
            "biology" | "生物" => Ok(Domain::Biology),
            "physics" | "物理" => Ok(Domain::Physics),
            "history" | "历史" => Ok(Domain::History),
            "geography" | "地理" => Ok(Domain::Geography),
            "politics" | "政治" | "道法" => Ok(Domain::Politics),
            "science" | "科学" => Ok(Domain::Science),
            "it" | "信息技术" | "信息科技" => Ok(Domain::It),
            "pe" | "体育" => Ok(Domain::Pe),
            "art" | "艺术" | "美术" | "音乐" => Ok(Domain::Art),
            "labor" | "劳动" => Ok(Domain::Labor),
            _ => Ok(Domain::General), // 未知值兜底
        }
    }
}

/// 管线配置
#[derive(Debug, Clone)]
pub struct PipelineConfig {
    /// domain 标识（与 conversation_plans.domain 对齐）
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

/// 通过 Domain 枚举路由（类型安全版本）
pub fn resolve_domain(domain: &Domain) -> &'static PipelineConfig {
    match domain {
        Domain::Math => &MATH,
        Domain::Language => &LANGUAGE,
        _ => &GENERAL,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_domain_roundtrip() {
        let cases = [
            ("general", Domain::General, "general"),
            ("math", Domain::Math, "math"),
            ("language", Domain::Language, "language"),
            ("chemistry", Domain::Chemistry, "chemistry"),
            ("biology", Domain::Biology, "biology"),
            ("physics", Domain::Physics, "physics"),
            ("history", Domain::History, "history"),
            ("geography", Domain::Geography, "geography"),
            ("politics", Domain::Politics, "politics"),
            ("science", Domain::Science, "science"),
            ("it", Domain::It, "it"),
            ("pe", Domain::Pe, "pe"),
            ("art", Domain::Art, "art"),
            ("labor", Domain::Labor, "labor"),
            ("", Domain::General, "general"),
        ];
        for (input, expected, display) in &cases {
            let parsed: Domain = input.parse().unwrap();
            assert_eq!(parsed, *expected, "parse({:?})", input);
            assert_eq!(parsed.to_string(), *display, "display({:?})", expected);
        }
    }

    #[test]
    fn test_domain_from_chinese() {
        assert_eq!(Domain::from_chinese("数学"), Domain::Math);
        assert_eq!(Domain::from_chinese("语文"), Domain::Language);
        assert_eq!(Domain::from_chinese("英语"), Domain::Language);
        assert_eq!(Domain::from_chinese("化学"), Domain::Chemistry);
        assert_eq!(Domain::from_chinese("生物"), Domain::Biology);
        assert_eq!(Domain::from_chinese("物理"), Domain::Physics);
        assert_eq!(Domain::from_chinese("历史"), Domain::History);
        assert_eq!(Domain::from_chinese("地理"), Domain::Geography);
        assert_eq!(Domain::from_chinese("政治"), Domain::Politics);
        assert_eq!(Domain::from_chinese("道法"), Domain::Politics);
        assert_eq!(Domain::from_chinese("科学"), Domain::Science);
        assert_eq!(Domain::from_chinese("信息技术"), Domain::It);
        assert_eq!(Domain::from_chinese("体育"), Domain::Pe);
        assert_eq!(Domain::from_chinese("艺术"), Domain::Art);
        assert_eq!(Domain::from_chinese("音乐"), Domain::Art);
        assert_eq!(Domain::from_chinese("劳动"), Domain::Labor);
        // 无对应 → General
        assert_eq!(Domain::from_chinese("社会学"), Domain::General);
    }

    #[test]
    fn test_domain_all_valid() {
        for d in Domain::ALL {
            assert!(d.parse::<Domain>().is_ok(), "ALL contains invalid: {}", d);
        }
        assert_eq!(Domain::ALL.len(), 14);
    }

    #[test]
    fn test_resolve_domain() {
        assert_eq!(resolve_domain(&Domain::Math).domain, "math");
        assert_eq!(resolve_domain(&Domain::Language).domain, "language");
        assert_eq!(resolve_domain(&Domain::General).domain, "general");
        assert_eq!(resolve_domain(&Domain::Chemistry).domain, "general"); // 无专用管线
        assert_eq!(resolve_domain(&Domain::History).domain, "general"); // 无专用管线
        assert_eq!(resolve_domain(&Domain::Art).domain, "general"); // 无专用管线
    }
}

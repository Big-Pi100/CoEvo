//! K12 科目 × 学段矩阵定义
//!
//! 5 学段（g1-2, g3-4, g5-6, g7-9, g10-12）
//! 每个学段覆盖适用科目，配学生开场白

use serde::{Serialize, Deserialize};

/// 学段
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum GradeBand {
    #[serde(rename = "g1-2")]
    G1_2,   // 小学低年级
    #[serde(rename = "g3-4")]
    G3_4,   // 小学中年级
    #[serde(rename = "g5-6")]
    G5_6,   // 小学高年级
    #[serde(rename = "g7-9")]
    G7_9,   // 初中
    #[serde(rename = "g10-12")]
    G10_12, // 高中
}

impl GradeBand {
    /// 返回学段对应的中文描述（用于生成学生开场白）
    pub fn display_level(&self) -> &'static str {
        match self {
            GradeBand::G1_2 => "小学低年级",
            GradeBand::G3_4 => "小学三年级",
            GradeBand::G5_6 => "小学六年级",
            GradeBand::G7_9 => "初中",
            GradeBand::G10_12 => "高中",
        }
    }
}

impl TestCase {
    /// 自动生成统一格式的学生开场白
    pub fn default_opening(&self) -> String {
        format!("我想学习{}{}", self.grade_band.display_level(), self.subject)
    }
}

impl GradeBand {
    pub fn as_str(&self) -> &'static str {
        match self {
            GradeBand::G1_2 => "g1-2",
            GradeBand::G3_4 => "g3-4",
            GradeBand::G5_6 => "g5-6",
            GradeBand::G7_9 => "g7-9",
            GradeBand::G10_12 => "g10-12",
        }
    }
}

/// 单个测试用例定义
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestCase {
    pub subject: &'static str,
    pub grade_band: GradeBand,
    pub domain: &'static str,
    pub student_opening: String,
}

/// K12 测试矩阵
pub fn get_k12_matrix() -> Vec<TestCase> {
    // 开场白统一格式："我想学习{学段}{科目}"
    let mut cases = vec![
        // ════════════════════════════════════════════
        // g1-2: 小学低年级
        // ════════════════════════════════════════════
        TestCase { subject: "数学", grade_band: GradeBand::G1_2, domain: "math", student_opening: String::new() },
        TestCase { subject: "语文", grade_band: GradeBand::G1_2, domain: "", student_opening: String::new() },
        TestCase { subject: "英语", grade_band: GradeBand::G1_2, domain: "language", student_opening: String::new() },

        // g3-4: 小学中年级
        TestCase { subject: "数学", grade_band: GradeBand::G3_4, domain: "math", student_opening: String::new() },
        TestCase { subject: "语文", grade_band: GradeBand::G3_4, domain: "", student_opening: String::new() },
        TestCase { subject: "英语", grade_band: GradeBand::G3_4, domain: "language", student_opening: String::new() },
        TestCase { subject: "科学", grade_band: GradeBand::G3_4, domain: "math", student_opening: String::new() },

        // g5-6: 小学高年级
        TestCase { subject: "数学", grade_band: GradeBand::G5_6, domain: "math", student_opening: String::new() },
        TestCase { subject: "语文", grade_band: GradeBand::G5_6, domain: "", student_opening: String::new() },
        TestCase { subject: "英语", grade_band: GradeBand::G5_6, domain: "language", student_opening: String::new() },
        TestCase { subject: "科学", grade_band: GradeBand::G5_6, domain: "math", student_opening: String::new() },
        TestCase { subject: "历史", grade_band: GradeBand::G5_6, domain: "", student_opening: String::new() },

        // g7-9: 初中
        TestCase { subject: "数学", grade_band: GradeBand::G7_9, domain: "math", student_opening: String::new() },
        TestCase { subject: "语文", grade_band: GradeBand::G7_9, domain: "", student_opening: String::new() },
        TestCase { subject: "英语", grade_band: GradeBand::G7_9, domain: "language", student_opening: String::new() },
        TestCase { subject: "物理", grade_band: GradeBand::G7_9, domain: "math", student_opening: String::new() },
        TestCase { subject: "化学", grade_band: GradeBand::G7_9, domain: "chemistry", student_opening: String::new() },
        TestCase { subject: "生物", grade_band: GradeBand::G7_9, domain: "biology", student_opening: String::new() },
        TestCase { subject: "历史", grade_band: GradeBand::G7_9, domain: "", student_opening: String::new() },
        TestCase { subject: "地理", grade_band: GradeBand::G7_9, domain: "", student_opening: String::new() },
        TestCase { subject: "政治", grade_band: GradeBand::G7_9, domain: "", student_opening: String::new() },

        // g10-12: 高中
        TestCase { subject: "数学", grade_band: GradeBand::G10_12, domain: "math", student_opening: String::new() },
        TestCase { subject: "语文", grade_band: GradeBand::G10_12, domain: "", student_opening: String::new() },
        TestCase { subject: "英语", grade_band: GradeBand::G10_12, domain: "language", student_opening: String::new() },
        TestCase { subject: "物理", grade_band: GradeBand::G10_12, domain: "math", student_opening: String::new() },
        TestCase { subject: "化学", grade_band: GradeBand::G10_12, domain: "chemistry", student_opening: String::new() },
        TestCase { subject: "生物", grade_band: GradeBand::G10_12, domain: "biology", student_opening: String::new() },
        TestCase { subject: "历史", grade_band: GradeBand::G10_12, domain: "", student_opening: String::new() },
        TestCase { subject: "地理", grade_band: GradeBand::G10_12, domain: "", student_opening: String::new() },
        TestCase { subject: "政治", grade_band: GradeBand::G10_12, domain: "", student_opening: String::new() },
    ];

    // 自动填充开场白
    for c in &mut cases {
        c.student_opening = c.default_opening();
    }
    cases
}

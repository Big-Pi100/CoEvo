/// 复习评分
#[derive(Debug, Clone, Copy, serde::Serialize, serde::Deserialize)]
pub enum Rating {
    Again = 1,
    Hard = 2,
    Good = 3,
    Easy = 4,
}

impl Rating {
    pub fn from_i32(v: i32) -> Self {
        match v {
            1 => Rating::Again,
            2 => Rating::Hard,
            3 => Rating::Good,
            4 => Rating::Easy,
            _ => Rating::Good,
        }
    }

    pub fn to_i32(&self) -> i32 {
        *self as i32
    }

    pub fn from_pass_fail(passed: bool) -> Self {
        if passed { Rating::Good } else { Rating::Again }
    }
}

/// 验证方式
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub enum VerificationType {
    Spelling,        // 语言类打字验证
    AiDialogue,      // 通用类 AI 快问快答
}

impl VerificationType {
    pub fn as_str(&self) -> &'static str {
        match self {
            VerificationType::Spelling => "spelling",
            VerificationType::AiDialogue => "ai_dialogue",
        }
    }
}

/// 复习日志记录
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ReviewLog {
    pub id: String,
    pub card_id: String,
    pub rating: i32,
    pub verification_type: String,
    pub verification_result: String,  // "pass" | "fail"
    pub reviewed_at: i64,
}

/// 提交复习结果请求
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ReviewSubmitRequest {
    pub card_id: String,
    pub rating: i32,
    pub verification_type: String,
    pub verification_result: String,
}

/// AI 快问快答验证请求
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct VerifyRequest {
    pub card_id: String,
    pub front: String,
    pub back: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct VerifyQuestion {
    pub question: String,
    pub expected_answer: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct VerifyResponse {
    pub questions: Vec<VerifyQuestion>,
}

/// AI 批量判断请求
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct JudgeRequest {
    pub card_id: String,
    pub questions: Vec<JudgeQuestion>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct JudgeQuestion {
    pub question: String,
    pub expected_answer: String,
    pub user_answer: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct JudgeResult {
    pub correct: bool,
    pub feedback: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct JudgeResponse {
    pub results: Vec<JudgeResult>,
    pub total_correct: usize,
    pub total: usize,
}

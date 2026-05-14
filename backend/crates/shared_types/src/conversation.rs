//! N1: 对话相关类型

/// WebSocket 聊天请求
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ChatRequest {
    pub user_id: String,
    pub conversation_id: String,
    pub message: String,
    /// 可选 token — 首条 WS 消息通过 payload 传递鉴权
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
}

/// 对话回复 (REST end)
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ChatResponse {
    pub reply: String,
    pub candidates: Vec<String>,        // 候选概念 (ColdPath)
    pub new_achievements: Vec<String>,  // 新成就 key
}

/// 单轮对话记录
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ConversationTurn {
    pub id: String,
    pub conversation_id: String,
    pub role: String,          // "user" | "assistant"
    pub content: String,
    pub created_at: i64,
}

/// WebSocket 事件
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(tag = "type")]
pub enum WsEvent {
    #[serde(rename = "thinking")]
    Thinking,
    #[serde(rename = "token")]
    Token { content: String },
    #[serde(rename = "done")]
    Done {
        reply: String,
        candidates: Vec<String>,
        achievements: Vec<String>,
    },
    #[serde(rename = "error")]
    Error { content: String },
}

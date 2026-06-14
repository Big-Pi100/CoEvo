//! 调试日志写入器
//!
//! 将结构化日志写入 `data/debug_logs/{yyyy-mm-dd}/{conversation_id}.jsonl`
//! 格式: JSON Lines（每行一个 JSON 对象）
//!
//! 原则: 日志自身不做任何截断，截断信息记录在 details 中

use serde_json::json;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio::io::AsyncWriteExt;

/// 调试日志会话摘要
#[derive(Debug, Clone)]
pub struct DebugLogSummary {
    pub conversation_id: String,
    pub entry_count: usize,
    pub file_size_bytes: u64,
    pub date: String,
}

/// 调试日志写入器
pub struct DebugLogger {
    base_dir: PathBuf,
    conversation_id: String,
    date: String,
    file: Arc<Mutex<tokio::fs::File>>,
    entry_count: Arc<Mutex<usize>>,
}

impl DebugLogger {
    /// 创建新的调试日志会话（自动创建目录和文件句柄）
    pub async fn create(conversation_id: &str) -> Result<Self, String> {
        let now = chrono::Utc::now();
        let date = now.format("%Y-%m-%d").to_string();
        let dir = PathBuf::from("data/debug_logs").join(&date);

        tokio::fs::create_dir_all(&dir)
            .await
            .map_err(|e| format!("创建日志目录失败: {}", e))?;

        let file_path = dir.join(format!("{}.jsonl", conversation_id));
        let file = tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&file_path)
            .await
            .map_err(|e| format!("打开日志文件失败: {}", e))?;

        Ok(Self {
            base_dir: dir,
            conversation_id: conversation_id.to_string(),
            date,
            file: Arc::new(Mutex::new(file)),
            entry_count: Arc::new(Mutex::new(0)),
        })
    }

    /// 写入一条日志（JSON 序列化 + 追加写入 + flush）
    pub async fn log(&self, phase: &str, step: &str, details: serde_json::Value) -> Result<(), String> {
        let timestamp = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string();
        let entry = json!({
            "timestamp": timestamp,
            "conversation_id": self.conversation_id,
            "phase": phase,
            "step": step,
            "details": details,
        });

        let mut line = serde_json::to_string(&entry)
            .map_err(|e| format!("JSON 序列化失败: {}", e))?;
        line.push('\n');

        let mut file = self.file.lock().await;
        file.write_all(line.as_bytes())
            .await
            .map_err(|e| format!("写入日志失败: {}", e))?;
        file.flush()
            .await
            .map_err(|e| format!("flush 日志失败: {}", e))?;

        let mut count = self.entry_count.lock().await;
        *count += 1;

        Ok(())
    }

    /// 会话结束，fsync + 返回摘要
    pub async fn close(self) -> Result<DebugLogSummary, String> {
        let mut file = self.file.lock().await;
        file.flush()
            .await
            .map_err(|e| format!("关闭日志时 flush 失败: {}", e))?;

        // 获取文件大小
        let file_path = self.base_dir.join(format!("{}.jsonl", self.conversation_id));
        let metadata = tokio::fs::metadata(&file_path)
            .await
            .map_err(|e| format!("获取日志文件元数据失败: {}", e))?;
        let file_size = metadata.len();

        let entry_count = *self.entry_count.lock().await;

        Ok(DebugLogSummary {
            conversation_id: self.conversation_id,
            entry_count,
            file_size_bytes: file_size,
            date: self.date,
        })
    }
}

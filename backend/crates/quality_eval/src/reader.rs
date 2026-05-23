//! 读取 LifecycleLog JSON 文件

use std::path::Path;
use k12_tests::LifecycleLog;

/// 从文件读取 LifecycleLog
pub fn read_lifecycle_log(path: &str) -> Result<LifecycleLog, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("读取 {} 失败: {}", path, e))?;
    serde_json::from_str::<LifecycleLog>(&content)
        .map_err(|e| format!("解析 {} 失败: {}", path, e))
}

/// 从目录读取所有 LifecycleLog JSON 文件
pub fn read_dir(dir: &str) -> Result<Vec<(String, LifecycleLog)>, String> {
    let mut results = Vec::new();
    let dir_path = Path::new(dir);
    if !dir_path.is_dir() {
        return Err(format!("目录不存在: {}", dir));
    }

    for entry in std::fs::read_dir(dir_path).map_err(|e| format!("读取目录失败: {}", e))? {
        let entry = entry.map_err(|e| format!("读取条目失败: {}", e))?;
        let path = entry.path();
        if path.extension().map_or(false, |ext| ext == "json") {
            let path_str = path.to_string_lossy().to_string();
            match read_lifecycle_log(&path_str) {
                Ok(log) => results.push((path_str, log)),
                Err(e) => eprintln!("[warn] 跳过文件: {}", e),
            }
        }
    }

    if results.is_empty() {
        return Err(format!("目录 {} 中未找到有效的 JSON 文件", dir));
    }

    Ok(results)
}

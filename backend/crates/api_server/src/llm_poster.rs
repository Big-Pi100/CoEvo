//! LLM 海报 / H5 生成 + QR 码替换 — 占位实现
//!
//! 完整实现见 T07

/// 生成推广海报 SVG（通过 LLM）
pub async fn generate_poster_svg(
    _user_id: &str,
    _campaign_id: &str,
    _referral_code: &str,
) -> Result<String, String> {
    // TODO: 调用 LLM 生成海报
    Ok("<svg></svg>".to_string())
}

/// 生成推广 H5 页面
pub async fn generate_h5_page(
    _user_id: &str,
    _referral_code: &str,
) -> Result<String, String> {
    // TODO: 生成 H5 页面并保存到 /share/{code}/index.html
    Ok("/share/".to_string())
}

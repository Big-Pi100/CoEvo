# CoEvo 分享海报体系架构文档

## 概述

CoEvo 有两种分享海报，均用于用户推广引流：

| 类型 | 产出格式 | 前端载体 | API 端点 |
|:-----|:---------|:---------|:---------|
| **SVG/PNG 海报** | base64 PNG 图片 | `_PosterDialog` 弹窗 | `POST /api/referral/generate-poster` |
| **H5 海报** | HTML 字符串 + 分享 URL | 浏览器/WebView | `POST /api/referral/generate-h5` |

两种海报的数据来源和模板替换逻辑基本相同，但各自有独立的模板格式和渲染路径。

## 系统架构

```
┌─────────────────────────────────────────────────┐
│                   API 入口                        │
├─────────────────────┬───────────────────────────┤
│  generate-poster    │    generate-h5             │
│  (referral_handler) │    (referral_handler)      │
└──────────┬──────────┴──────────┬────────────────┘
           │                     │
           ▼                     ▼
┌──────────────────────┐ ┌──────────────────────┐
│ build_user_poster_data│ │ build_user_h5_data    │
│ (poster_template.rs)  │ │ (h5_template.rs)      │
├──────────────────────┤ ├──────────────────────┤
│ • display_name        │ │ • display_name        │
│ • real_name ←加密!!   │ │ • real_name ←加密!!   │
│ • streak_days         │ │ • streak_days         │
│ • total_cards         │ │ • total_cards         │
│ • today_reviews       │ │ • today_reviews       │
│ • referral_code       │ │ • referral_code       │
│ • qr_code_url ←缺cid  │ │ • register_url ←已修复│
│ • plan_stats ←已统一  │ │ • plan_stats ←已统一  │
└──────────────────────┘ └──────────────────────┘
           │                     │
           ▼                     ▼
┌──────────────────────┐ ┌──────────────────────┐
│ replace_template_    │ │ replace_h5_variables  │
│ variables()          │ │ ()                    │
│ (SVG 变量替换)        │ │ (HTML 变量替换)        │
├──────────────────────┤ ├──────────────────────┤
│ {display_name}        │ │ {display_name}        │
│ {real_name}           │ │ {real_name}           │
│ {streak_days}         │ │ {streak_days}         │
│ {total_cards}         │ │ {total_cards}         │
│ {today_reviews}       │ │ {today_reviews}       │
│ {referral_code}       │ │ {referral_code}       │
│ {active_plans_summary}│ │ {active_plans_summary}│
│ {current_focus}       │ │ {current_focus}       │
│ {plan_count}          │ │ {plan_count}          │
│ {completed_plans}     │ │ {completed_plans}     │
│ {achievement_count}   │ │ {achievement_count}   │
│ QR 码内嵌为 <image>   │ │ {register_url}        │
│ (无对应变量)           │ │                       │
└──────────────────────┘ └──────────────────────┘
```

## 数据层（共用逻辑）

### 已共享：计划统计

`build_user_plan_stats()` (`poster_template.rs`) 是唯一实现，两个模板构建函数都调用它。

```rust
pub struct UserPlanStats {
    pub plan_count: i64,
    pub active_plans_summary: String,
    pub current_focus: String,
    pub completed_plans: i64,
    pub achievement_count: i64,
}
```

查询逻辑：
1. 取所有 `status = 'active'` 的计划总数
2. 对有 `in_progress` task 的计划，取最新一条显示 "科目·任务名"
3. 无 `in_progress` 时显示纯科目名
4. 超过 1 个计划时追加 " 等 N 个科目"

### 未共享：用户基础数据

两处都会查询 `display_name`、`real_name`、`streak_days`、`total_cards`、`today_reviews`、`referral_code`、`qr_code_url`/`register_url`，但代码各有一份。

**潜在风险**：`real_name` 在 DB 中为 AES-256-GCM 加密存储，两处模板构建函数均未解密，会输出密文乱码。

```rust
// ❌ 错误：读到了加密值
"SELECT COALESCE(real_name, '') FROM users WHERE id = ?1"

// ✅ 正确：需解密
let real_name = real_name_raw.as_ref()
    .map(|v| if is_encrypted(v) { decrypt(v) } else { v.clone() })
    .unwrap_or_default();
```

参考正确做法：`routes.rs:1579-1581`（用户 profile 路由中的解密逻辑）。

### 命名建议统一

当前两个 struct 字段名不同，但语义相同：

| poster_template.rs | h5_template.rs | 建议统一名 |
|:-------------------|:---------------|:-----------|
| `qr_code_url`      | `register_url` | `register_url` |

本质都是"注册推广链接"，应统一命名。

## 营销链路参数

### 分享 URL 格式

```
{base}/share/{referral_code}?campaign_id={campaign_id}
```

### 注册按钮链接

```
{base}/app/auth?ref={referral_code}&campaign_id={campaign_id}
```

### 状态

| 场景 | 当前状态 |
|:-----|:---------|
| H5 注册按钮 | ✅ `register_url` 已带 `campaign_id` |
| SVG 海报 QR 码 | ❌ `qr_code_url` 未带 `campaign_id`，扫码无法关联活动 |
| Fallback H5 | ✅ `campaign_id` 已注入按钮链接 |
| LLM 生成 H5 | ✅ `{register_url}` 替换后自动包含 `campaign_id` |

### base URL 配置

```rust
fn coevo_base_url() -> String {
    std::env::var("COEVO_BASE_URL")
        .unwrap_or_else(|_| "http://localhost:8080".to_string())
}
```

**注意**：默认值 `http://localhost:8080` 指向后端端口，但 `/app/auth` 是 Flutter Web 路由。本地开发需设置：

```bash
COEVO_BASE_URL=http://localhost:3000 ./target/release/coevo_backend.exe
```

## 模板替换

### SVG/PNG 海报

```rust
// poster_template.rs
pub fn replace_template_variables(template: &str, data: &UserPosterData) -> String
```

替换逻辑：
1. 替换 `{变量}` 占位符
2. 生成 QR 码 PNG 图片（先 SVG→PNG 转换）
3. 将 QR PNG 以 `<image>` 元素嵌入 SVG
4. 用 `translate(-90,-90)` 包裹实现居中定位

模板来源：
- 活动有 `poster_template` → 用 LLM 生成的模板
- 无模板 → 用硬编码的 `fallback_poster_svg()`

### H5 海报

```rust
// h5_template.rs
pub fn replace_h5_variables(template: &str, data: &UserH5Data) -> String
```

替换逻辑：
1. 替换 `{变量}` 占位符
2. 自动注入 OG meta 标签（og:image 等）

模板来源：
- 活动有 `h5_template` → 用 LLM 生成的模板
- 无模板 → 用硬编码的 `fallback_h5_html()`

## 关键文件清单

| 文件 | 职责 | 行数（约） |
|:-----|:-----|:----------|
| `poster_template.rs` | SVG 海报模板 + 用户数据构建 + fallback SVG | ~240 |
| `h5_template.rs` | H5 模板 + 用户数据构建 + fallback HTML | ~250 |
| `referral_handler.rs` | API 入口：`generate_poster` + `generate_h5` + `share_landing` | ~160 |
| `llm_poster.rs` | LLM 调用生成海报模板 | ~20 |

## 待修复事项

1. **`real_name` 解密**：两个模板构建函数均直接读取加密值，需解密
2. **`qr_code_url` 缺 `campaign_id`**：SVG 海报的 QR 码链接未关联活动
3. **数据层统一**：建议抽 `build_user_share_data()`，避免两份重复代码
4. **`coevo_base_url()` 重复**：两模板文件各有一份，建议合并
5. **`display_name` 用作 QR 码文案**：未加密的明文可正常使用，但需确认 PII 合规

## 推荐重构方案

```
┌──────────────────────────────────────────┐
│          shared_share_data.rs            │
│  (新建模块，存放共用数据逻辑)              │
├──────────────────────────────────────────┤
│ pub struct UserShareData {               │
│     display_name, real_name,            │
│     streak_days, total_cards,            │
│     today_reviews, referral_code,        │
│     register_url,  // 统一命名           │
│     plan_stats: UserPlanStats,           │
│ }                                        │
│                                          │
│ pub fn build_user_share_data(conn,       │
│     user_id, campaign_id)                │
│     -> UserShareData                     │
│                                          │
│ pub fn coevo_base_url() -> String        │
│ pub struct UserPlanStats { ... }         │
│ pub fn build_user_plan_stats()           │
└──────────────────────────────────────────┘
           │              │
           ▼              ▼
┌──────────────────┐ ┌──────────────────┐
│ poster_template   │ │ h5_template       │
│ SVG 替换逻辑      │ │ HTML 替换逻辑     │
│ QR 码 PNG 生成    │ │ OG meta 注入      │
│ fallback SVG      │ │ fallback HTML     │
└──────────────────┘ └──────────────────┘
```

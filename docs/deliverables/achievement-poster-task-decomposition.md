# 成就页海报直接展示 — 任务分解方案

> **Architect**: 高见远  
> **Date**: 2026-06-19  
> **Status**: v1.0 设计稿  
> **Based on**: PRD 需求 + `distribution-marketing-design.md §9` + 现有代码审计

---

## 1. 文件清单

### 1.1 后端（Rust — 需创建）

| # | 文件路径 | 类型 | 用途 |
|---|---------|------|------|
| 1 | `backend/crates/api_server/src/poster_handler.rs` | **新建** | 海报 API 集合：列表查询、生成触发、保底模板 |
| 2 | `backend/crates/api_server/src/poster_scheduler.rs` | **新建** | 定时预生成（cron 每日 6:00）+ 复习完成触发检查 |
| 3 | `backend/crates/api_server/src/poster_storage.rs` | **新建** | 文件系统读写：`data/posters/{user_id}/` 目录管理、缓存检查 |

### 1.2 后端（Rust — 需修改）

| # | 文件路径 | 类型 | 用途 |
|---|---------|------|------|
| 4 | `backend/crates/api_server/src/routes.rs` | **修改** | 注册 3 条新路由 |
| 5 | `backend/crates/api_server/src/referral_handler.rs` | **修改** | 提取 `generate_poster` 中的 LLM 管线为可复用函数；增加 `daily` / `campaign` 两种生成模式 |
| 6 | `backend/crates/api_server/src/campaign_scheduler.rs` | **修改** | 启动时同时启动 poster scheduler；增加 `start_poster_scheduler()` 调用 |
| 7 | `backend/src/main.rs` | **修改** | 初始化和启动 poster scheduler |
| 8 | `backend/crates/api_server/src/lib.rs` | **修改** | 导出新模块 |

### 1.3 后端（Prompt 文件 — 需修改）

| # | 文件路径 | 类型 | 用途 |
|---|---------|------|------|
| 9 | `backend/prompts/share/signal/poster.md` | **修改** | 增加 `QR_PLACEHOLDER` 要求和尺寸规范 |
| 10 | `backend/prompts/share/format/poster.md` | **修改** | 增加 `id="QR_PLACEHOLDER"` 占位要求 |

### 1.4 前端（Flutter — 需创建/修改）

| # | 文件路径 | 类型 | 用途 |
|---|---------|------|------|
| 11 | `app/lib/widgets/poster_carousel.dart` | **新建** | 多海报轮播组件（PageView + 指示器），支持个人 & 活动海报切换 |
| 12 | `app/lib/widgets/poster_viewer.dart` | **新建** | 单张海报渲染组件（SVG 渲染 + 保存按钮 + 分享链接按钮）|
| 13 | `app/lib/providers/poster_provider.dart` | **新建** | Riverpod 状态管理：海报列表、加载状态、当前索引、刷新逻辑 |
| 14 | `app/lib/screens/achievements_screen.dart` | **修改** | 用 `PosterCarousel` 替换 `_buildReferralSection()` 中的二维码区域 |
| 15 | `app/lib/widgets/share_widget.dart` | **修改** | 将"保存海报"和"分享链接"功能迁移到 `PosterViewer`，本文件保留供其他入口使用 |
| 16 | `app/lib/api/chat_client.dart` | **修改** | 新增海报相关 API 调用方法 |

---

## 2. 数据流（完整链路）

```
┌────────────────────────────────────────────────────────────────────────┐
│                     海报生成→存储→展示 完整数据流                        │
└────────────────────────────────────────────────────────────────────────┘

【触发阶段】
┌────────────────────────────────────────────────────────────────┐
│ 触发源 A：每日 cron（poster_scheduler.rs → 6:00 AM）          │
│ 触发源 B：复习完成回调（review_submit → 检查数据变化→触发）   │
│ 触发源 C：管理员推送活动（campaign_handler → 生成活动海报）    │
└───────────────────────┬────────────────────────────────────────┘
                        │
                        ▼
【生成阶段 — poster_handler.rs / referral_handler.rs】
┌────────────────────────────────────────────────────────────────┐
│  1. 检查频率限制（每人每天最多 1 次 LLM 调用）                │
│     ├─ 已有缓存（daily.svg 存在且今日已生成）→ 直接返回       │
│     └─ 无缓存 → 继续                                         │
│                                                               │
│  2. 调用 get_user_portrait_data() 获取学习画像                │
│                                                               │
│  3. 调用 LLM（复用现有 chat_engine::llm_caller）             │
│     ├─ LLM 成功 → 得到 SVG（含 QR_PLACEHOLDER）              │
│     ├─ LLM 失败 → 走 fallback_poster_svg()                   │
│     └─ LLM 已达每日限额 → 走 fallback_poster_svg()           │
│                                                               │
│  4. 生成二维码 + 替换 QR_PLACEHOLDER                         │
│                                                               │
│  5. svg_to_png() 生成 PNG 版本                               │
│                                                               │
│  6. 保存到 data/posters/{user_id}/                            │
│     ├─ daily.svg + daily.png  (个人海报，每天覆盖)            │
│     └─ 或 camp_{id}.svg + camp_{id}.png  (活动海报)          │
└───────────────────────┬────────────────────────────────────────┘
                        │
                        ▼
【存储阶段 — poster_storage.rs】
┌────────────────────────────────────────────────────────────────┐
│  data/posters/                                                │
│  └── {user_id}/                                               │
│      ├── daily.svg          ← 今日个人海报（LLM/fallback）    │
│      ├── daily.png          ← PNG 副本                        │
│      ├── camp_{id1}.svg     ← 活动海报（活动期内）            │
│      ├── camp_{id1}.png     ← PNG 副本                        │
│      ├── camp_{id2}.svg     ← 活动海报                        │
│      └── camp_{id2}.png                                       │
│                                                               │
│  【清理规则】                                                 │
│  - daily.svg/png: 每天新生成覆盖旧文件                         │
│  - camp_{id}.svg/png: 活动结束（valid_until < now）后由       │
│    poster_scheduler 或活动结束回调清理                         │
└───────────────────────┬────────────────────────────────────────┘
                        │
                        ▼
【查询阶段 — 前端请求】
┌────────────────────────────────────────────────────────────────┐
│  GET /api/posters?user_id={id}                                │
│                                                               │
│  后端 poster_handler:                                         │
│  1. 扫描 data/posters/{user_id}/ 目录下的 *.svg 文件          │
│  2. 读取各文件元数据（文件名 → 类型推导）                     │
│  3. 返回海报列表：                                            │
│     [                                                         │
│       { id: "daily",    type: "daily",   svg: "..." },        │
│       { id: "camp_xxx", type: "campaign", svg: "..." },       │
│     ]                                                         │
│  4. 如果目录为空 → 调用 generate_daily_poster() 生成          │
└───────────────────────┬────────────────────────────────────────┘
                        │
                        ▼
【展示阶段 — 前端 Flutter】
┌────────────────────────────────────────────────────────────────┐
│  PosterProvider (Riverpod):                                   │
│  1. achievements_screen 加载时调用 fetchPosters()             │
│  2. 获取海报列表 → 存入 posterList 状态                       │
│  3. 提供 refresh() 方法                                       │
│                                                               │
│  PosterCarousel (PageView):                                   │
│  ┌──────────────────────────────────────────────────────┐     │
│  │  ← [个人学习海报]  [活动：邀新送7天]  [更多...] →    │     │
│  │  ┌──────────────────────────────────────────────────┐│     │
│  │  │                                                  ││     │
│  │  │          SVG 海报渲染区域                        ││     │
│  │  │    （flutter_svg 渲染 SVG / Image.memory PNG）    ││     │
│  │  │    二维码已嵌入海报中（QR_PLACEHOLDER替换）       ││     │
│  │  │                                                  ││     │
│  │  └──────────────────────────────────────────────────┘│     │
│  │                                                     │     │
│  │  ● ● ○ ○ （小圆点指示器：当前第1/4张）              │     │
│  │                                                     │     │
│  │  [💾 保存海报]  [🔗 分享链接]                      │     │
│  └──────────────────────────────────────────────────────┘     │
│                                                               │
│  PosterViewer:                                                 │
│  - Renders SVG using flutter_svg (or PNG fallback)             │
│  - "保存海报"按钮 → 截取 SVG 区域 → 保存为 PNG                │
│  - "分享链接"按钮 → 复制推广 H5 链接                           │
│  - 底部推广码文本（独立于海报，可复制）                       │
└────────────────────────────────────────────────────────────────┘
```

---

## 3. 多海报轮播方案

### 3.1 海报分类与排序

```
排序规则（前端排序，后端按类型返回）:
  1. type=daily 的个人学习海报 → 始终排第一
  2. type=campaign 的活动推送海报 → 按活动 valid_until ASC 排列
     （即将结束的排前面，制造紧迫感）
  3. fallback 保底海报 → 仅当前两者都为空时展示
```

### 3.2 轮播实现（PosterCarousel）

```dart
// PageView.builder + 底部圆点指示器
// 每页 = 一张海报
// 支持左右滑动切换

class PosterCarousel extends ConsumerWidget {
  // 使用 posterProvider 获取海报列表
  // PageView.builder + buildPosterPage()
  // 底部: Row of dots (page indicator)
  // 超出1张时显示左右箭头或滑动提示
}
```

### 3.3 个人 vs 活动海报的视觉区分

| 维度 | 个人学习海报 | 活动推送海报 |
|------|-------------|-------------|
| 内容来源 | LLM 基于用户数据生成 | LLM 基于活动信息 + llm_prompt_hint 生成 |
| 更新频率 | 每天最多 1 次 | 管理员推送时生成一次 |
| 生命周期 | 当天有效（次日覆盖） | 活动周期内（valid_from ~ valid_until） |
| 底部标签 | 🔥 今日学习报告 | 🎉 活动推广 |
| 删除条件 | 次日被新海报覆盖 | 活动结束后 scheduler 清理 |

### 3.4 空状态 / 无海报时

不使用灰色占位。规则：
1. 首次进入成就页 → 检查 `data/posters/{user_id}/` 目录
2. 目录为空 → 后端自动调用 `generate_daily_poster()` → LLM/fallback 生成
3. LLM 配额已用完 → 走 fallback 模板（`fallback_poster_svg()` 已有）
4. **保证用户永远看到一张有效海报，不是灰色占位**

---

## 4. 后端 API 设计

### 4.1 新增接口

| 方法 | 路径 | 说明 | 认证 |
|------|------|------|------|
| **GET** | `/api/posters` | 获取用户所有海报列表（SVG 内容） | ✅ Bearer Token |
| **POST** | `/api/posters/generate` | 强制重新生成今日个人海报（频率控制） | ✅ Bearer Token |
| **DELETE** | `/api/posters/campaign/{id}` | 删除指定活动海报 | ✅ Admin |

### 4.2 GET /api/posters — 响应格式

```
请求: GET /api/posters?user_id={userId}

响应 200:
{
  "posters": [
    {
      "id": "daily",
      "type": "daily",
      "label": "今日学习报告",
      "svg": "<svg>...</svg>",         // SVG 内容（含二维码）
      "png_data_url": "data:image/png;base64,...",  // PNG 版本
      "campaign_name": null,
      "created_at": "2026-06-19T06:00:00Z",
      "expires_at": null               // daily 无过期，次日覆盖
    },
    {
      "id": "camp_camp_001",
      "type": "campaign",
      "label": "邀新送 7 天",
      "svg": "<svg>...</svg>",
      "png_data_url": "data:image/png;base64,...",
      "campaign_name": "邀新送 7 天",
      "created_at": "2026-06-18T10:30:00Z",
      "expires_at": "2026-07-18T00:00:00Z"  // 活动结束时间
    }
  ],
  "has_daily": true,
  "campaign_count": 1
}
```

### 4.3 POST /api/posters/generate — 请求/响应

```
请求: POST /api/posters/generate
Body: { "user_id": "xxx", "type": "daily" }

响应 200:
{
  "poster": { ...同上 poster 结构... },
  "from_cache": false,       // true 表示今天已生成过，直接返回缓存
  "llm_used": true,          // 是否调用了 LLM
  "daily_quota_remaining": 0 // 今日剩余调用次数
}

频率控制:
- 后端检查 data/posters/{user_id}/daily.svg 的 mtime
- 如果 mtime 在今天范围内 → from_cache=true, 直接返回
- 如果 mtime 不在今天 → 允许重新生成（消耗 1 次配额）
- 每人每天最多 1 次 LLM 调用
```

### 4.4 现有接口的修改

| 方法 | 路径 | 变更 |
|------|------|------|
| **POST** | `/api/referral/generate-poster` | 保持兼容（仍可用），内部改为调用新的 `PosterGenerator::generate_daily()` |
| **POST** | `/api/referral/generate-h5` | 不变（仍用于"分享链接"按钮）|

### 4.5 内部接口（模块间）

```rust
// poster_storage.rs
pub struct PosterStorage;

impl PosterStorage {
    /// 列出用户的所有海报
    pub fn list_posters(user_id: &str) -> Result<Vec<PosterMeta>, String>;
    
    /// 保存海报（SVG + PNG）
    pub fn save_poster(user_id: &str, poster: &PosterData) -> Result<(), String>;
    
    /// 获取今日海报路径
    pub fn daily_path(user_id: &str) -> String;
    
    /// 获取活动海报路径
    pub fn campaign_path(user_id: &str, campaign_id: &str) -> String;
    
    /// 检查今日是否已生成
    pub fn has_today_daily(user_id: &str) -> bool;
    
    /// 清理过期活动海报
    pub fn clean_expired_campaigns() -> Result<usize, String>;
}

// poster_handler.rs
pub struct PosterGenerator;

impl PosterGenerator {
    /// 生成今日个人海报（LLM + QR + SVG→PNG）
    pub fn generate_daily(user_id: &str, conn: &Connection) -> Result<PosterData, String>;
    
    /// 生成活动海报
    pub fn generate_campaign(user_id: &str, campaign_id: &str, conn: &Connection) -> Result<PosterData, String>;
    
    /// 获取用户所有海报
    pub fn get_all_posters(user_id: &str) -> Result<Vec<PosterData>, String>;
}

// poster_scheduler.rs
/// 每日 cron 预生成（6:00 AM）
pub fn pregenerate_daily_posters() -> Result<usize, String>;

/// 清理过期活动海报
pub fn clean_expired_campaign_posters() -> Result<usize, String>;

/// 复习完成后的触发检查
pub fn check_and_generate_after_review(user_id: &str) -> Result<(), String>;
```

---

## 5. 任务分解

### 任务依赖图

```
T01: 基础设施
  │
  ├──→ T02: 后端存储 + 生成管线
  │       │
  │       ├──→ T03: 后端 API + 调度器
  │       │
  │       └──→ T04: 前端海报展示组件
  │               │
  │               └──→ T05: 前端集成与联调
  │
  T01 是所有任务的前置依赖
  T02 → T03 （存储管线 → API 层）
  T02 → T04 （存储管线 → 前端组件）
  T03 + T04 → T05 （API + 组件 → 集成）
```

### T01: 项目基础设施（P0）

| 字段 | 内容 |
|------|------|
| **Task ID** | T01 |
| **名称** | 项目基础设施 — 目录创建 + 模块声明 + 路由注册 |
| **源文件** | ① `backend/crates/api_server/src/lib.rs`（导出新模块）② `backend/crates/api_server/src/routes.rs`（注册路由）③ `backend/src/main.rs`（启动 scheduler）④ `backend/crates/api_server/src/campaign_scheduler.rs`（启动 poster scheduler） |
| **具体内容** | ① 在 `lib.rs` 中添加 `pub mod poster_handler;` `pub mod poster_scheduler;` `pub mod poster_storage;` ② 在 `routes.rs` 中添加 3 条新路由：`GET /api/posters` / `POST /api/posters/generate` / `DELETE /api/posters/campaign/{id}` ③ 在 `main.rs` 中 `db_pool::init()` 之后添加 `poster_scheduler::start_scheduler(&db_path);` ④ 在 `campaign_scheduler.rs` 的 `start_scheduler()` 中增加 `start_poster_scheduler()` 调用 |
| **依赖** | 无（基础设施） |
| **工时估计** | 小（~0.5h） |

### T02: 后端存储 + 生成管线（P0）

| 字段 | 内容 |
|------|------|
| **Task ID** | T02 |
| **名称** | 后端存储层 + 海报生成管线 |
| **源文件** | ① `backend/crates/api_server/src/poster_storage.rs`（新建）② `backend/crates/api_server/src/poster_handler.rs`（新建，含 PosterGenerator）③ `backend/crates/api_server/src/referral_handler.rs`（修改：提取公用函数）④ `backend/prompts/share/signal/poster.md`（修改）⑤ `backend/prompts/share/format/poster.md`（修改） |
| **具体内容** | **poster_storage.rs**: 实现 `PosterStorage` 结构体，包含 `list_posters()` / `save_poster()` / `has_today_daily()` / `clean_expired_campaigns()` 方法。文件目录为 `data/posters/{user_id}/`。**poster_handler.rs**: 实现 `PosterGenerator`，包含 `generate_daily()` / `generate_campaign()` / `get_all_posters()`。`generate_daily()` 逻辑：① 检查频率限制（今日 mtime）② 获取用户数据 ③ 调用 LLM（复用 `referral_handler.rs` 中的管线）④ 生成 QR 替换 `QR_PLACEHOLDER` ⑤ SVG→PNG 转换 ⑥ 保存到 PosterStorage。**referral_handler.rs**: 将 `generate_poster` 中的 LLM 调用 + QR 嵌入 + SVG→PNG 逻辑提取为公共函数 `fn generate_poster_inner(user_id, conn) -> Result<PosterData, String>`，供 `poster_handler.rs` 和旧的 `generate_poster` handler 共同使用。**prompt 文件**: 修改 signal 和 format prompt，确保输出中包含 `QR_PLACEHOLDER` 占位符。 |
| **依赖** | T01 |
| **工时估计** | 大（~4h） |

### T03: 后端 API + 调度器（P0）

| 字段 | 内容 |
|------|------|
| **Task ID** | T03 |
| **名称** | 后端 API handler + Poster Scheduler |
| **源文件** | ① `backend/crates/api_server/src/poster_handler.rs`（新建：HTTP handler 函数）② `backend/crates/api_server/src/poster_scheduler.rs`（新建）③ `backend/crates/api_server/src/referral_handler.rs`（修改：`generate_poster` handler 调用新函数）|
| **具体内容** | **poster_handler.rs HTTP handlers**: 实现 `get_posters()`（读取 PosterStorage.list_posters() + 返回 JSON）、`generate_poster_handler()`（调用 PosterGenerator.generate_daily() + 频率控制 + 返回）、`delete_campaign_poster()`（Admin 权限验证 + 删除文件）。**poster_scheduler.rs**: 实现 `start_scheduler()`（独立线程，每 5 分钟执行：清理过期活动海报 + 每 1 小时检查是否需要预生成）、`pregenerate_daily_posters()`（每日 6:00 遍历活跃用户，调用 generate_daily()）、`clean_expired_campaign_posters()`（扫描 data/posters/ 下所有 camp_*.svg，比对关联活动的 valid_until）。**referral_handler.rs**: 修改 `generate_poster` handler 为调用新的内部管线。 |
| **依赖** | T02 |
| **工时估计** | 大（~3h） |

### T04: 前端海报展示组件（P0）

| 字段 | 内容 |
|------|------|
| **Task ID** | T04 |
| **名称** | 前端海报轮播 + 展示组件 |
| **源文件** | ① `app/lib/widgets/poster_carousel.dart`（新建）② `app/lib/widgets/poster_viewer.dart`（新建）③ `app/lib/providers/poster_provider.dart`（新建）④ `app/lib/api/chat_client.dart`（修改）|
| **具体内容** | **poster_provider.dart**: 创建 `PosterState`（海报列表、当前索引、加载状态、错误信息）。实现 `fetchPosters()` / `generatePoster()` / `refresh()`。使用 Riverpod `StateNotifierProvider`。**poster_carousel.dart**: 基于 `PageView.builder` 实现左右滑动切换。底部圆点指示器。每页内容为 `PosterViewer`。**poster_viewer.dart**: 渲染 SVG（使用 `flutter_svg`）或 PNG（`Image.memory`）。"保存海报"按钮（截取 SVG → 保存为 PNG）。"分享链接"按钮（调用 `generate-h5` API → 复制链接）。底部显示推广码文本（独立于海报）。**chat_client.dart**: 新增 `fetchPosters()` / `generatePoster(String type)` 方法。 |
| **依赖** | T02（需要了解 PosterData 结构）|
| **工时估计** | 大（~4h） |

### T05: 前端集成 + 联调（P1）

| 字段 | 内容 |
|------|------|
| **Task ID** | T05 |
| **名称** | 成就页集成 + 复习触发 + 联调 |
| **源文件** | ① `app/lib/screens/achievements_screen.dart`（修改）② `app/lib/widgets/share_widget.dart`（修改）|
| **具体内容** | **achievements_screen.dart**: ① 导入 `PosterCarousel` 和 `posterProvider`。② 在 `build()` 中，将原有的 `_buildReferralSection()` 替换为新的海报区域。③ 海报区域布局：顶部 "分享推广" 标题 → PosterCarousel（滑动切换海报）→ 底部推广码文本（可复制）。④ 在 `_loadWithAuth()` 的 `Future.wait` 中增加 `fetchPosters()` 调用。⑤ 移除原有 QR 码控件和 ShareWidget 弹窗入口。⑥ 监听 `cardRefreshProvider` 变化时触发 `check_and_regenerate()`（检查数据变化，如有变化则调用 `generatePoster()`）。**share_widget.dart**: 保留现有文件供其他入口使用（如个人页），但移除成就页对该组件的依赖。**联调**: 确保 T02/T03/T04 所有接口对接正确。测试场景：① 首次进入 → 自动生成海报 ② 每日首次进入 → 展示缓存海报 ③ 复习完成后 → 自动触发再生 ④ 活动海报出现/消失 ⑤ LLM 失败 → fallback 展示 ⑥ 左右滑动切换。 |
| **依赖** | T03（后端 API 就绪）、T04（前端组件就绪）|
| **工时估计** | 中（~3h） |

---

## 6. 任务汇总表

| ID | 名称 | 文件数 | 依赖 | 优先级 | 估计工时 |
|----|------|--------|------|--------|----------|
| T01 | 项目基础设施 | 4 个（修改） | 无 | P0 | 0.5h |
| T02 | 后端存储 + 生成管线 | 5 个（3新建+2修改） | T01 | P0 | 4h |
| T03 | 后端 API + 调度器 | 3 个（2新建+1修改） | T02 | P0 | 3h |
| T04 | 前端海报展示组件 | 4 个（3新建+1修改） | T02 | P0 | 4h |
| T05 | 前端集成 + 联调 | 2 个（修改） | T03, T04 | P1 | 3h |
| **合计** | **5 个任务** | **18 个文件** | | | **~14.5h** |

---

## 7. 风险提示

### 7.1 技术风险

| # | 风险 | 影响 | 缓解措施 |
|---|------|------|----------|
| R1 | **LLM 生成失败率高** | 用户看到 fallback 海报，体验下降 | fallback 模板已有（`fallback_poster_svg()`），确保视觉上不是"灰色占位"，而是可用的推广海报 |
| R2 | **SVG→PNG 转换失败**（已存在）| 前端只有 SVG 无 PNG | 已有降级逻辑（`poster_json_response` 中 SVG 可用时返回 None PNG，前端 fallback 到 SVG 渲染）|
| R3 | **频繁触发生成导致性能问题** | 每张海报 SVG 可能很大（~50KB），大量用户同时预生成 → IO 压力 | cron 分批生成（每批 50 人，间隔 1s），复习触发检查数据变化（非每次），频率控制严格 |
| R4 | **多海报 loading 性能** | 同时加载多张 SVG/PNG 大图 → 前端渲染慢 | 懒加载（PageView 按需渲染），PNG 作为 SVG 渲染失败时的降级，优先使用 SVG |
| R5 | **Flutter Web SVG 兼容性** | flutter_svg 对复杂 SVG 支持有限 | 已有 `Image.memory(base64)` 兜底，确保 PNG 版本始终可用 |

### 7.2 业务风险

| # | 风险 | 影响 | 缓解措施 |
|---|------|------|----------|
| R6 | **LLM 生成内容不符合品牌调性** | 海报风格不可控 | LLM prompt 中约束设计规范（配色、字体、布局），并定期审查 LLM 输出质量 |
| R7 | **活动海报在活动结束后仍展示** | 用户点过期活动，产生困惑 | `clean_expired_campaign_posters()` 每 5 分钟清理一次；前端也检查 `expires_at` 字段 |
| R8 | **二维码内容变更（如链接改版）** | 已生成海报二维码失效 | 二维码内容模板放在常量中，集中管理；URL 结构保持稳定 |

### 7.3 已有代码复用分析

| 现有代码 | 复用方式 | 是否需要修改 |
|----------|---------|-------------|
| `referral_handler.rs` 中 `generate_poster()` 的 LLM 管线 | 提取为公共函数 `generate_poster_inner()` | ✅ 需要重构 |
| `referral_handler.rs` 中 `svg_to_png()` | 直接调用 | ✅ 不需要修改 |
| `referral_handler.rs` 中 `generate_qr_svg()` | 直接调用 | ✅ 不需要修改 |
| `referral_handler.rs` 中 `fallback_poster_svg()` | 作为 LLM 失败的保底 | ✅ 不需要修改 |
| `achievements_screen.dart` 中 `_buildReferralSection()` | 整体替换 | ✅ 需要重写 |
| `share_widget.dart` 中保存海报/分享链接逻辑 | 复制到新 PosterViewer 组件 | ✅ 需重构 |
| `campaign_scheduler.rs` 中 `start_scheduler()` 模式 | 复用相同模式启动 poster scheduler | ✅ 参考实现 |
| `achievements_screen.dart` 中 `cardRefreshProvider` | 监听复习完成信号 | ✅ 不需要修改 |

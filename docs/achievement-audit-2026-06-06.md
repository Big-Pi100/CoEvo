# 成就系统对照审计报告

> 日期: 2026-06-06 | 对照文档: achievement-system-redesign.md V2.0

## 审计方法

逐项对照 `achievement-system-redesign.md` 的 8 个现状问题、40 个成就列表、5 个触发点、进度 API、前端模块清单，与代码实际实现比对。

## 结论摘要

| 指标 | 原值 | 修复后 |
|------|-------|--------|
| 总成就数 (文档承诺) | 40 | ✅ 40 (`subjects_3` + `all_subjects` 已补) |
| TOML key 与文档不一致 | 5 | ✅ 已对齐 |
| 重复成就 | 1 (`polymath_5`) | ✅ 已删除 |
| API 路径文档不一致 | 1 | ✅ 文档已更新 |

---

## 🔴 P0 — 文档承诺但缺失的成就（2 个）✅ 已修复

| Key | 名称 | 条件 | 分级 | 状态 |
|-----|------|------|------|------|
| `subjects_3` | 三科通 | 覆盖 3 个 K12 学科 | Silver | ✅ 已补 |
| `all_subjects` | 全科状元 | 覆盖 10 个 K12 学科 | Diamond | ✅ 已补 |

**修复内容**:
- `achievements.toml`: 加 2 个 achievement 定义
- `shared_types/src/growth.rs`: `AchievementContext` 加 `subjects_count: u32` + Default
- `api_server/src/achievement_engine.rs`: `build_context()` 加 SQL 查询（提取 domain 中 `::` 之间的学科名去重）
- `growth_engine/src/achievements.rs`: `ComparisonEvaluator::evaluate()` 加 `"subjects_count"` arm
- `api_server/src/routes.rs`: `compute_progress()` 加 arm + metric_label

---

## 🟡 P1 — 文档 API 描述与实际不一致 ✅ 已修复

**文档** (四、4.3):
```
新增 GET /api/achievements/progress → { "unlocked": [...], "locked": [...] }
```

**实际** (`routes.rs:84`):
```
GET /api/user/{user_id}/achievements-all
  → { "categories": [{ "category", "label", "achievements": [{...progress_pct, progress_label}] }] }
```

✅ 已更新 `achievement-system-redesign.md`：
- 2.5 节：改为描述实际 API 返回格式
- Phase 3 注释：更新 API 路径
- 4.3 表格：更新 API client 描述

---

## 🟡 P2 — TOML key 与文档 key 不一致（5 个）✅ 已修复

| 文档 key | TOML 实际 key（修复后） | 所属分类 |
|----------|--------------|---------|
| `cards_50` | ✅ `cards_50` | seed |
| `cards_200` | ✅ `cards_200` | knowledge |
| `cards_500` | ✅ `cards_500` | knowledge |
| `reviews_100` | ✅ `reviews_100` | consistency |
| `reviews_1000` | ✅ `reviews_1000` | consistency |

✅ 已修复：`collector_50`→`cards_50`，`library_200`→`cards_200`，`scholar_500`→`cards_500`，`hundred_100`→`reviews_100`，`thousand_1000`→`reviews_1000`

## 🟡 P2 — TOML 含文档未定义的重复成就（1 个）✅ 已修复

| Key | 名称 | 分级 | 备注 |
|-----|------|------|------|
| ~~`polymath_5`~~ | ~~博学家~~ | Silver | ✅ 已删除（与 `domains_5` 完全重复） |

✅ 已删除：`polymath_5` TOML 段落 + `shared_types/growth.rs` 引用（`predefined()` + `match_tier` + 测试）

---

## 🟢 P3 — 可选未实现

- **confetti 粒子撒花**: 文档标记"可选"，未添加。可接受。
- **隐藏成就红点提示**: 当前有 lock icon + "隐藏" badge，无红点未读计数。功能上已可区分隐藏成就。

---

## ✅ 已完成的 6 个 Phase

| Phase | 内容 | 状态 |
|-------|------|------|
| 0 | 全局通知模块 + Overlay + 图标函数 | ✅ |
| 1 | TOML 加载 + AchievementEngine | ✅ |
| 2 | 事件总线 + 5 个触发点 | ✅ |
| 3 | 前端分类 Tab + 进度条 + 分级色彩 | ✅ |
| 4 | 40 成就 TOML 扩展 | ✅ 40/40（缺 2 个→已补） |
| 5 | DB 查询 17 个 metric | ✅ |
| 6 | WS 成就通知 + 前端清理 | ✅ |

## ✅ 8 个原问题全部解决

| # | 原问题 | 状态 |
|---|--------|------|
| 1 | 仅 11 个成就 | ✅ 38→40 |
| 2 | 硬编码 HashMap | ✅ 迁移到 TOML |
| 3 | 条件引擎只支持 >= | ✅ gte/lte/eq/gt/lt + AND/OR |
| 4 | 只在复习提交触发 | ✅ 5 触发点 + WS done |
| 5 | Context 只有 4 字段 | ✅ 23→24 字段 |
| 6 | 无分类/进度 | ✅ 6 Tab + 进度条 |
| 7 | emoji 图标 | ✅ Material Icons |
| 8 | tier/source 未使用 | ✅ tier 已用（source→category） |

---

## ✅ 前端模块全部到位

| 文档要求 | 状态 |
|---------|------|
| 双层展示模型（图标+特效卡） | ✅ |
| 全局 Overlay + notifier 队列 | ✅ |
| achievement_notifier.dart (Riverpod) | ✅ |
| achievement_overlay.dart | ✅ |
| app.dart 挂载 Overlay | ✅ |
| shared/achievement_icons.dart | ✅ |
| achievements_screen.dart 分类 Tab+进度条 | ✅ |
| review_screen.dart → notifier.push() | ✅ |
| chat_screen.dart → notifier.push() | ✅ Phase 6 |
| API client 接口 | ✅ getAchievementsAll() |

---

## 修复结果 ✅ 全部完成

| 顺序 | 优先级 | 事项 | 状态 |
|------|--------|------|------|
| 1 | P2 | TOML key 对齐 (5 个 rename) + 删除重复 | ✅ 完成 |
| 2 | P1 | 更新 redesign 文档 API 描述 | ✅ 完成 |
| 3 | P0 | 补全 subjects_3 + all_subjects (5 文件修改) | ✅ 完成 |

**修复后状态**:
- TOML 成就数: 40 (原 38 + 2 新增，删 1 重复 = 40)
- `cargo check`: ✅ 0 errors
- `cargo test -p growth_engine`: ✅ 9/9
- API 文档: ✅ 与实际对齐

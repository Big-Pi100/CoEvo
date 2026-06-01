# 科目标识全链路不一致审计报告

> 日期: 2026-06-01
> 审计范围: Flutter 前端 + Rust 后端 + JSON 数据文件 + SQLite 数据库 + 测试代码

---

## TL;DR

同一个"科目标识"在 API 接口、DB 存储、JSON 文件、代码逻辑中用了 **3 套不同的值**（中文汉字、英文代码、混合值），且维护着 **3 份手工映射表**，彼此不完全一致。这是严重的代码质量问题。

---

## 一、问题定义

### 核心矛盾

| 层 | 字段 | 示例值 | 状态 |
|---|---|---|---|
| JSON 预生成文件 (`plans/*.json`) | `subject` | `"math"`, `"chinese"` | ✅ 英文代码 |
| JSON 预生成文件 (`cards/*.json`) | `subject`, `domain` | `"math"`, `"biology"` | ✅ 英文代码 |
| DB `conversations` | `subject` | `"数学"`, `"语文"` | ❌ 中文汉字 |
| DB `learning_plans` | `domain` | `"math"`, `"language"` | ✅ 英文代码 (CHECK 约束) |
| DB `cards` | `subject` | `"数学"`, `"语文"` | ❌ 中文汉字 |
| DB `cards` | `domain` | `"数学"` + `"math"` + `"general"` | ❌❌ 中英混用 |
| DB `k12_progress` | `subject` | `"数学"` | ❌ 中文汉字 |
| DB `plan_templates` | `subject_key` | `"math"`, `"chinese"` | ✅ 英文代码 |
| 前端 `home_screen.dart` | API 参数 subject | `"数学"` | ❌ 中文汉字 |
| 前端 `k12_subject_screen.dart` | API 参数 subject | `"数学"` | ❌ 中文汉字 |
| 后端 `K12InitInput.subject` | API 入参 | `"数学"` | ❌ 中文汉字 |
| `routes.rs:2149` | `UPDATE cards SET domain = subject` | 写入中文 | ❌❌ 污染 domain 列 |
| 测试 `e2e_card_pipeline.rs` | DB 硬编码 | `"数学"`, `"语文"` | ❌ 中文汉字 |
| `subject_router.rs` test | 断言 | 3 处错误：`"物理" -> "math"`(应为 `"physics"`), `"语文" -> ""`(应为 `"language"`), `"历史" -> ""`(应为 `"history"`) | ❌❌ 断言全错 |

---

## 二、3 份手工映射表

### 2.1 `CHINESE_TO_ENGLISH` — curriculum_loader.rs:93

```rust
pub const CHINESE_TO_ENGLISH: &[(&str, &str)] = &[
    ("数学", "math"), ("语文", "chinese"), ("英语", "english"),
    ("物理", "physics"), ("化学", "chemistry"), ("生物", "biology"),
    ("历史", "history"), ("地理", "geography"), ("政治", "politics"),
    ("科学", "science"), ("信息技术", "it"), ("体育", "pe"),
    ("艺术", "art"), ("日语", "japanese"), ("俄语", "russian"),
];
```

用途: `get_plan()`, `get_cards()`, `reading_loader`, `plan_handler` 多处内部调用

### 2.2 `Domain::from_chinese()` — pipeline_router.rs:54

```rust
pub fn from_chinese(cn: &str) -> Self {
    match cn {
        "数学" => Domain::Math,
        "语文" | "英语" | "日语" | "俄语" => Domain::Language,
        "化学" => Domain::Chemistry,
        "生物" | "生物学" => Domain::Biology,
        // ...
    }
}
```

用途: `routes.rs:2106`, `routes.rs:2307` (k12_init / reading_init)

### 2.3 `subject_to_domain()` — subject_router.rs:24

```rust
fn subject_to_domain(subject: &str) -> &'static str {
    match subject {
        "数学" => "math",
        "物理" => "physics",
        // ...
    }
}
```

用途: LLM 学科路由 (用户自然语言 → 科目)

### 2.4 三份映射的差异

| 中文名 | CHINESE_TO_ENGLISH | Domain::from_chinese | subject_to_domain |
|--------|-------------------|---------------------|-------------------|
| 语文 | `"chinese"` | `-> Language` (`"language"`) | `"language"` |
| 艺术 | `"art"` | `-> Art` (`"art"`) | `"art"` |
| it/信息技术 | `"it"` | 接受 `"it"`/`"IT"`/`"信息技术"`/`"信息科技"` | 接受 `"信息技术"`/`"信息科技"` |
| 物理 | `"physics"` | `-> Physics` (`"physics"`) | `"physics"` |
| 生物 | `"biology"` | 接受 `"生物"`/`"生物学"` | 接受 `"生物"`/`"生物学"` |

**注意**：`subject_to_domain` 的测试断言有错误（写死了 `"物理" -> "math"`，实际应为 `"physics"`），说明该测试从未通过或被人忽视了。

---

## 三、API 接口清单

### 3.1 `POST /api/k12/init`

```json
// 当前：❌ subject 传中文
{"user_id":"xxx","subject":"数学","grade_band":"g7-9"}
// 目标：✅ subject 应传英文代码
{"user_id":"xxx","subject":"math","grade_band":"g7-9"}
```

### 3.2 `POST /api/k12/reading/init`

```json
// 当前：❌ subject 传中文
{"user_id":"xxx","subject":"语文","grade_band":"g7-9"}
// 目标：✅ subject 应传英文代码
{"user_id":"xxx","subject":"chinese","grade_band":"g7-9"}
```

### 3.3 `GET /api/cards/all`

```json
// 当前：❌ subject 是中文，domain 是英文，混搭
?user_id=xxx&subject=数学&domain=math
// 目标：✅ 统一使用英文代码
?user_id=xxx&subject=math&domain=math
```

### 3.4 `POST /api/plans`

`domain` 字段已经是英文代码，无需改动。

---

## 四、`cards.domain` 混写来源

### 重要：缺少 CHECK 约束

`learning_plans.domain` 列有 CHECK 约束（14 科枚举值，见 `Domain::check_sql`），但 `cards.domain` 列**没有任何 CHECK 约束**（`src/main.rs:53` 定义 `domain TEXT` 无 CHECK）。这意味着即使迁移清理后，新的中文值仍可能被写入——必须同步修复写入路径。

`cards.subject` 列同样无 CHECK 约束。

### 混写来源

`cards.domain` 列被多个写入路径污染：

| 路径 | 写法 | 值 |
|------|------|-----|
| `routes.rs:2164` (k12_init 卡片写入) | `domain = input.subject` | `"数学"` (中文) ❌ |
| `routes.rs:2149` (k12_init domain 修复) | `UPDATE cards SET domain = subject` | `"数学"` (中文) ❌ |
| `routes.rs:2364` (reading_init 卡片写入) | `domain = input.subject` | `"语文"` (中文) ❌ |
| `routes.rs:2385` (reading_init 词卡写入) | `domain = input.subject` | `"语文"` (中文) ❌ |
| `plan_handler.rs:1948` (sync 卡片写入) | `domain = subj` | `"chinese"` 或中文混搭 ❌ |
| `routes.rs:761` (`cards_skip_delete_handler`) | `domain = domain_str` | `""` 空字符串 ❌（前端 skipConcept 不传 domain，后端 unwrap_or_default 得空串；**改造后删除**） |
| `routes.rs:836` (`cards_batch_create_handler`) | `domain = "general"` | `"general"` 英文 ✅（**改造后改为 `PATCH status`**） |
| `card_repository.rs:91` | `domain = card.domain` | 英文代码 ✅ |

---

## 五、卡片状态重构（skip 机制改造）

### 5.1 现状问题

当前跳过操作走 `skipped_concepts` 独立表，带来连锁问题：

- 已制卡再跳过 = 删 `cards` 行 + 搬数据到 `skipped_concepts`，丢失 `back`, `card_type`, `subject`, `grade_band`, `conversation_id`
- 概念弹窗跳过（未入库） = 存在 `skipped_concepts`，但 `domain` 前端没传导致空字符串
- 去重扫不到 `skipped_concepts` 表，跳过后的概念还会再问用户
- 恢复 = 从 `skipped_concepts` 插回 `cards`，但字段残缺

### 5.2 改造方案

**核心原则**：所有概念统一入 `cards` 表，状态字段控制可见性。

```
概念提取 → INSERT INTO cards (status='pending')    ← 数据齐全入库
   ↓
用户确认 → UPDATE cards SET status='active'        ← 立即可复习
用户跳过 → UPDATE cards SET status='skipped'        ← 保留全部字段，但隐藏
   ↓
去重：扫整个 cards 表（含 skipped），不会重复问
```

### 5.3 `cards` 表变更

```sql
-- 新增 status 列（替代 origin 的部分语义）
ALTER TABLE cards ADD COLUMN status TEXT NOT NULL DEFAULT 'active'
    CHECK(status IN ('active', 'pending', 'skipped', 'archived'));

-- 删除/废弃 origin 列（extracted/prebuilt 语义被 status 覆盖）
-- origin 当前仅 K12 预生成卡片设为 'prebuilt'，这部分可迁移到 status='active' + 新标记

-- 废弃 skipped_concepts 表
DROP TABLE skipped_concepts;
```

### 5.4 涉及改动

#### 前端

| 文件 | 改动内容 |
|------|---------|
| `app/lib/screens/home_screen.dart` | 将 `_subjects` map 的 key 从中文改为英文 code，增加 display_name 字段；发送 `subject` 时传 code |
| `app/lib/screens/k12_subject_screen.dart` | 同上（该文件未在 GoRouter 注册但代码存在） |
| `app/lib/screens/reading_subject_screen.dart` | 同上 |
| `app/lib/screens/card_list_screen.dart` | subject 过滤改用英文 code；跳过改为标记跳过而非删除 |
| `app/lib/screens/achievements_screen.dart` | 从 API 读取 subject 时按英文 code 处理 |
| `app/lib/api/chat_client.dart` | 合并 batch_create 和 skip API 为 status 更新；`skipConcept` 不再独立 |
| `app/lib/screens/chat/chat_concept_dialog.dart` | 确认 / 跳过统一调用 `updateCardStatus` |
| `app/lib/screens/review_screen.dart` | 跳过用 `updateCardStatus` 而非删除 + re-skip |

#### 后端 — DB 层

| 文件 | 改动内容 |
|------|---------|
| `backend/src/main.rs` | 迁移脚本 Phase N：ALTER cards ADD status + 迁移存量 `origin='prebuilt'`、清 domain 中文值、DROP skipped_concepts |
| `backend/crates/card_engine/src/card_repository.rs` | `insert_card` 默认 `status='pending'`；新增 `update_card_status(card_id, status)`；删除 skip_concept 函数（不再需要） |

#### 后端 — API 层

| 文件 | 改动内容 |
|------|---------|
| `routes.rs:2014` | `K12InitInput` 的 `subject` 改为英文代码 |
| `routes.rs:2024` | `k12_init_handler`: 移除 `Domain::from_chinese`，直接用 `Domain::from_str` |
| `routes.rs:2149` | **修复 bug**: `UPDATE cards SET domain =?1` 改为用 domain_val.to_string() 而非 input.subject |
| `routes.rs:2164` | `cards.domain` 写入用 `domain_val.to_string()` 而非 `input.subject` |
| `routes.rs:2194` | `k12_reading_init_handler`: 同理处理 |
| `routes.rs:2364,2385` | `cards.domain` 写入用英文代码 |
| `routes.rs:937-941` | `cards_all_handler` 的 subject 过滤参数同步英文 |
| `routes.rs:656-688` | **重写 skip handler**：改为 `PATCH /api/cards/{id}/status` 更新 status |
| `routes.rs:722-790` | **删除 skip/restore 相关的完整 handler**（`cards_skip_delete_handler`, `cards_skipped_handler`, `cards_skipped_list_handler`） |
| `routes.rs:809-890` | **`batch_create` handler** 改为：批量更新 `candidates` 的 status（pending→active），配合 `update_card_status` |
| `routes.rs:658-664` | 删除 `SkipInput` struct，新增 `UpdateStatusInput`：`{user_id, card_id, status}` |

#### 后端 — 数据加载器（2 个文件）

| 文件 | 改动内容 |
|------|---------|
| `backend/.../curriculum_loader.rs` | 新增 `get_plan_by_key(subject_key, grade)` 绕过 CHINESE_TO_ENGLISH；保留旧 `get_plan` 兼容 |
| `backend/.../reading_loader.rs` | `get_plan_content` 去掉 CHINESE_TO_ENGLISH 依赖 |

#### 后端 — plan_handler（1 个文件）

| 文件 | 改动内容 |
|------|---------|
| `backend/.../plan_handler.rs` | 3 处 `CHINESE_TO_ENGLISH` 使用改为直取英文 code |
| `plan_handler.rs:1937` | `subj = subject.as_deref().unwrap_or("chinese")` 中的 `"chinese"` 硬编码需改为从 conversations.subject 取英文值 |

#### 后端 — 映射表清理（2 个文件）

| 文件 | 改动内容 |
|------|---------|
| `pipeline_router.rs` | `from_chinese` 保留但标记 deprecated，后续准备移除 |
| `subject_router.rs` | `subject_to_domain` 保留（用于 LLM 路由，接受中文输入），但修复测试断言 |

#### 查询适配

所有涉及 `cards` 表的查询需加 `WHERE status='active'` 过滤：
- `cards_all_handler`（行903-950）：加 `AND c.status = 'active'`
- review 查询（ws.rs）：`WHERE status='active'`
- 成就要检测：`WHERE status='active'`（不算 skipped）
- 卡片数量统计同理

#### 测试（4 个文件）

| 文件 | 改动内容 |
|------|---------|
| `backend/.../tests/e2e_card_pipeline.rs` | 所有硬编码中文 subject/domain 改为英文；适配 status 列；移除 skipped_concepts 相关断言 |
| `backend/.../tests/e2e_live_llm_plan_lifecycle.rs` | 所有硬编码中文 subject/domain 改为英文；适配 status 列 |
| `backend/.../tests/e2e_main_lifecycle.rs` | 移除 skipped_concepts 表创建 |
| `card_repository.rs` tests | 新增 `update_card_status` 测试；移除 `skip_concept` 测试 |
| `subject_router.rs` tests | 修复错误断言 |

### 测试（2 个文件）

| 文件 | 改动内容 |
|------|---------|
| `backend/.../tests/e2e_card_pipeline.rs` | 所有硬编码中文 subject/domain 改为英文 |
| `backend/.../tests/e2e_live_llm_plan_lifecycle.rs` | 所有硬编码中文 subject/domain 改为英文 |
| `subject_router.rs` tests | 修复错误断言 |

---

## 六、修复原则

1. **API 契约统一使用英文代码**（与 JSON 文件和 `Domain::Display` 对齐）
2. **DB 存储统一使用英文代码**（`conversations.subject` 从 `"数学"` 改为 `"math"`）
3. **保留 `Domain::from_chinese` 做存量兼容**，前端切到英文后逐步废弃
4. **`cards.domain` 列清理**：通过迁移脚本将中文值 UPDATE 为英文，消除混写
5. **三份映射表合并为一份**：`Domain::from_str` 已同时支持中/英文解析，建立 `FromStr + Display` 的权威映射（`pipeline_router.rs`），其他两个映射逐步废弃
6. **卡片全量入库，status 控制可见性**：概念提取结果直接 INSERT 到 `cards`（status='pending'），用户确认→`active`，跳过→`skipped`；废除 `skipped_concepts` 独立表
7. **增量修复**：分批实施，每批完成后验证测试通过

### ⚠️ 关键：迁移顺序敏感

`plan_handler.rs:1937` 中有 `subj = subject.as_deref().unwrap_or("chinese")`，该 `subject` 来自 `conversations.subject`。同时 `get_cards(subj, grade)`（行 1939）内部通过 `CHINESE_TO_ENGLISH` 查找。

**迁移顺序必须严格遵循**：
- **先**迁移 `conversations.subject` 为英文代码
- **再**修改 `get_cards` / `get_plan` 入参语义（取消 CHINESE_TO_ENGLISH 依赖）
- **最后**改 `plan_handler.rs:1937` 中 `subj` 的 `unwrap_or("chinese")` 默认值

如果顺序反了（先改 `get_cards` 取消中文支持，再改 conversations），`plan_handler` 在过渡期会传英文参数给 `get_cards`，但 `get_cards` 内部用 `CHINESE_TO_ENGLISH` 查找会找不到英文 key，导致卡片导入失败。

---

## 七、GitNexus 代码图交叉验证

> 验证工具: GitNexus 知识图谱 (indexed 2026-05-29, 21795 nodes, 29109 edges)

> 验证基准: GitNexus 索引已重建 (2026-06-01T11:36:57, HEAD 对齐, 9103 nodes / 16805 edges)

| 发现 | GitNexus 验证结果 | 可信度 |
|------|------------------|--------|
| `k12_init_handler` 调用 `get_plan` + `get_cards` + `from_chinese` | ✅ routes.rs → curriculum_loader + pipeline_router | 高 |
| `k12_reading_init_handler` 调用 `from_chinese` + `get_plan` + `get_card` | ✅ routes.rs → reading_loader + pipeline_router | 高 |
| `build_plan_context` → `get_plan_content` → `get_plan` | ✅ plan_handler.rs → reading_loader.rs 调用链完整 | 高 |
| `analyze_turn_progress` (CP2) 调用 `handle_plan_update` + `build_plan_creation_prompt` | ✅ CP2 核心流程 | 高 |
| `subject_to_domain` 仅被 `route` 调用 | ✅ subject_router.rs 内 | 高 |
| `Domain.from_chinese` 被 2 个 handler 调用 | ✅ 索引重建后正确追踪 | 高 |
| `CHINESE_TO_ENGLISH` 的调用关系 | ⚠️ const 常量引用不在图追踪范围 | 低 |
| `cards.domain` 列混写来源 | ⚠️ SQL 写入路径不在图追踪范围 | 低 |

**限界说明**: 图结构索引完整（9103 节点 / 16805 边），`context` 和 `impact` 工具可正常工作。本环境不支持 SQLite FTS5 扩展，因此关键词搜索 (`query`) 降级为向量近似扫描。常量引用 (`const`) 和 SQL 写入路径不在图追踪范围内，这些仍依赖手动代码审查。**过时的索引比没有索引更危险——已确认当前索引与 HEAD 对齐，无 staleness。**

---

## 八、影响范围评估

| 影响维度 | 评估 |
|---------|------|
| 前端改动 | 3-5 个 screen 文件 + 1 个 API client 参数名无需改 |
| 后端 API | 2 个 handler 入口参数 + 内部数据写入 |
| 后端业务逻辑 | curriculum_loader / plan_handler / reading_loader 共 5-7 处 CHINESE_TO_ENGLISH 引用 |
| DB 存量数据 | 需要迁移脚本 UPDATE 约 4 张表 |
| 测试 | 2 个测试文件 ~13 处硬编码值 |
| 提示词管线 | 不受影响（`get_for_domain` 已用英文代码） |
| 概念提取 | 不受影响（`extract_concepts` 已用英文代码） |
| CP2 进度管理 | 不受影响（`learning_plans.domain` 已是英文） |
| 用户可见变化 | 无（前端显示中文名不变，只是 API 底层改编码） |

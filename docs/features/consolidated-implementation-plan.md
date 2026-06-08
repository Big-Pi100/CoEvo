# 综合实施计划

> 来源: `subject-code-audit.md` + `prompt-architecture-audit.md` + `code-impact-status.md`
> 日期: 2026-06-01

---

## 依赖关系图

```
Phase 0 ──► Phase 1 ──► Phase 2 ──► Phase 3 ──► Phase 5
  (DB)       (API)        (查询)      (前端)      (测试)

                                   Phase 4 (Prompt)
                                  (完全独立，可并行)
```

- Phase 0-4 是强依赖链条，必须顺序执行
- Phase 5 与 Phase 0-4 **完全独立**，可在任何阶段穿插

---

## Phase 0 — DB 架构迁移（必须先做）

**依赖**: 无
**输出**: 可回滚的安全快照

### Steps

0.1 **备份数据库**（迁移前快照）
```bash
cp data/coevo.db data/coevo.db.bak.$(date +%Y%m%d)
```

0.2 **Add `status` column to `cards`**
```sql
ALTER TABLE cards ADD COLUMN status TEXT NOT NULL DEFAULT 'active'
    CHECK(status IN ('active', 'pending', 'skipped', 'archived'));
```

0.3 **迁移存量 `origin='prebuilt'` 为 status='active'**
```sql
UPDATE cards SET status = 'active' WHERE origin = 'prebuilt';
```
（`origin` 列保留暂不删除，后续再清理）

0.4 **清理 `cards.domain` 中文值 → 英文代码**
```sql
UPDATE cards SET domain = 'math'     WHERE domain = '数学';
UPDATE cards SET domain = 'chinese'  WHERE domain = '语文';
UPDATE cards SET domain = 'english'  WHERE domain = '英语';
UPDATE cards SET domain = 'physics'  WHERE domain = '物理';
UPDATE cards SET domain = 'chemistry'WHERE domain = '化学';
UPDATE cards SET domain = 'biology'  WHERE domain = '生物' OR domain = '生物学';
UPDATE cards SET domain = 'general'  WHERE domain = '';
-- 其他按对应关系补齐
```

0.5 **清理 `conversations.subject` 中文值 → 英文代码**
```sql
UPDATE conversations SET subject = 'math'     WHERE subject = '数学';
UPDATE conversations SET subject = 'chinese'  WHERE subject = '语文';
UPDATE conversations SET subject = 'english'  WHERE subject = '英语';
-- 同理补齐所有科目
```

0.6 **清理 `cards.subject` 中文值 → 英文代码**
```sql
UPDATE cards SET subject = 'math'    WHERE subject = '数学';
-- 同理补齐
```

0.7 **DROP `skipped_concepts` 表**
```sql
DROP TABLE IF EXISTS skipped_concepts;
```

0.8 **迁移脚本落 `backend/src/main.rs` 的 DDL/CREATE 段 + Phase N**

### ⚠️ 迁移前准备：概念提取流程需新增入库步骤

当前概念提取在 `ws.rs:538-541` 构建 candidates JSON 后直接发送给前端，**不进行任何数据库写入**。改为 status 模式后，需要在提取完成后、发送前端前，先将所有 candidates INSERT 到 `cards`（`status='pending'`），并返回 `card_id` 给前端供后续 PATCH status 定位。

**新增步骤（在 Phase 1 实施，但依赖 Phase 0 的 status 列）：**

在 `ws.rs` 提取流程中（`extraction.candidates.iter().map(...).collect()` 之后，`cold_tx.send()` 之前）：
```rust
// 新增：概念提取 → 批量入库（status='pending'），返回 card_id 供前端 PATCH
for c in &extraction.candidates {
    let card_id = uuid::Uuid::new_v4().to_string();
    card_engine::card_repository::insert_pending_card(
        &conn, &card_id, &user_id, &c.front, &c.back,
        &c.source_sentence, &c.domain,
    );
    ids.push(card_id);
}
// candidates 的 JSON 中增加 "id": card_id
```

- `insert_pending_card` 是新函数（或 `insert_card` 加 `status` 参数），写 `cards` 表 + `card_memory` 表，status='pending'
- candidates JSON 从 `{front, back, source_sentence, domain}` 改为 `{id, front, back, source_sentence, domain}`

### 验证
```bash
# domain 范围内不应有中文值
sqlite3 data/coevo.db "SELECT DISTINCT domain FROM cards WHERE domain IN ('数学','语文','英语','物理')"
# 应返回空

# skipped_concepts 应不存在
sqlite3 data/coevo.db ".tables" | grep skipped
# 应无输出

# status 列应存在
sqlite3 data/coevo.db "SELECT DISTINCT status FROM cards"
# 应输出 active, pending, skipped
```

**涉及文件**: `backend/src/main.rs`（DDL + Phase N 迁移代码）

---

## Phase 1 — 后端 API 层（必须 Phase 0 之后）

**依赖**: Phase 0 完成（DB schema 就绪、存量数据已清理）

### 1.1 `card_repository.rs` — 数据层

| 改动 | 详情 |
|------|------|
| `insert_card` 默认 status='active' | 保留现有行为（K12 预生成、直接制卡用）；新增 `insert_pending_card` 写 status='pending'（概念弹窗用） |
| 新增 `update_card_status(card_id, status)` | 单行 UPDATE cards SET status=?1 WHERE id=?2 |
| 删除 `skip_concept()` | 整函数删除 |
| **注意**：`insert_card` 内部去重扫描的范围**不**加 status 过滤（必须扫全表含 skipped） |
| **注意**：直接制卡（Path B1/B2, 用户说"记下这个"）→ `insert_card` status='active'，不需要 pending 过渡 |
| **注意**：概念弹窗 → `insert_pending_card` status='pending'，用户确认后才 active |

### 1.2 `routes.rs` — API handler 重写

| 改动 | 详情 |
|------|------|
| `SkipInput` struct 删除 | 行658-664 删除 |
| 新增 `UpdateStatusInput` | `{user_id, card_id, status}` |
| `cards_skip_handler` 删除 | 行666-688 |
| `cards_skipped_handler` 删除 | 行691-719 |
| `cards_skip_delete_handler` 删除 | 行722-790 |
| 新增 `cards_status_handler` | `PATCH /api/cards/status` — 调用 `update_card_status` |
| **路由注册** | `.route("/api/cards/skip", ...)` 三行改为 `.route("/api/cards/status", patch(cards_status_handler))` |

### 1.3 `routes.rs` — k12 初始化修复（科目标识统一 + domain 写入）

| 改动 | 行号 | 详情 |
|------|------|------|
| `K12InitInput` 注释更新 | 2014 | API 契约改为英文代码（前端同步改） |
| `k12_init_handler` | 2106 | `Domain::from_chinese` → `Domain::from_str` |
| UPDATE domain bug 修复 | 2149 | 改为 `domain = domain_val.to_string()` |
| INSERT cards domain 修复 | 2164 | 同上 |
| `k12_reading_init_handler` | 2194 | 同理 |
| INSERT cards domain (reading) | 2364,2385 | 同理 |
| `cards_all_handler` subject 过滤 | 937-941 | 参数名不变，值变成英文（前端同步） |

### 1.4 `routes.rs` — `batch_create` 改为 `PATCH status`

| 改动 | 详情 |
|------|------|
| `cards_batch_create_handler` 重写 | 行810-890 替换为：接收 `{user_id, card_ids, status}`，批量调用 `update_card_status` |
| `BatchCreateInput` struct 删除 | 行794-799 |
| 新增 `BatchStatusInput` | `{user_id, card_ids: Vec<String>, status: String}` |

### 1.5 数据加载器调整

| 文件 | 改动 |
|------|------|
| `curriculum_loader.rs` | 新增 `get_plan_by_key(subject_key, grade)` — 直接取 plan_index[subject_key]，绕过 `CHINESE_TO_ENGLISH` |
| `reading_loader.rs:185` | `get_plan_content` 中 `CHINESE_TO_ENGLISH.iter().find(...)` → 直接使用 subject（此时已为英文） |

### 1.6 plan_handler 修复

| 文件 | 改动 |
|------|------|
| `plan_handler.rs:391` | `CHINESE_TO_ENGLISH` 查找 → 直取 `subj`（此时已为英文代码） |
| `plan_handler.rs:994` | 同上 |
| `plan_handler.rs:1937` | `unwrap_or("chinese")` → `unwrap_or("chinese")` 保留（作为兜底，因为 K12 预生成文件 key 是 `"chinese"` 不是 `"language"`） |
| `plan_handler.rs:1948-2008` | `domain = subj` 此时 subj 是英文代码，domain 写入 ✅ |

### 1.7 `load_chat_context` + `ws.rs` — `skipped_fronts` 查询迁移

两处从 `skipped_concepts` 读取已跳过概念（用于概念提取时去重）：

| 位置 | 当前查询 | 改后 |
|------|---------|------|
| `routes.rs:258` (`load_chat_context`) | `SELECT LOWER(front) FROM skipped_concepts WHERE user_id = ?1` | **删除该查询**（`existing_fronts` 已从 `cards` 全量读取，含 skipped） |
| `ws.rs:495` | 同上 | **删除该查询**（同上） |

**理由**：`existing_fronts` 查询（`routes.rs:254`、`ws.rs:478`）已经从 `cards WHERE user_id=?1` 全量读取（含所有 status）。`skipped_fronts` 与 `existing_fronts` 是冗余的——概念提取器不应重复提取任何已有卡片，无论什么 status。删除 `skipped_fronts` 查询后，`load_chat_context` 返回值签名也可简化。

### 1.8 `skipped_fronts` 参数链删除

因 `skipped_concepts` 表删除，`skipped_fronts` 参数从调用链全线移除：

| 文件 | 行 | 改动 |
|------|-----|------|
| `concept_extractor.rs` | 25,36,54,60 | 删除 `skipped_fronts` 参数、doc 注释、行54 `.chain(skipped_fronts.iter())`、行60 `skipped_lower` |
| `routes.rs:248` | 250,283,385,425 | `load_chat_context` 返回类型从4元组改为3元组；`chat_handler` 调用处适配；`extract_concepts` 调用删掉 `skipped_fronts` 参数 |
| `ws.rs:526` | 526 | `extract_concepts` 调用删掉 `&skipped_fronts` 参数 |

### 1.9 映射表清理

| 文件 | 改动 |
|------|------|
| `pipeline_router.rs` | `from_chinese` 函数体加 `#[deprecated]` 注释 |
| `subject_router.rs` | 修复 `test_subject_mapping` 断言：`"物理" -> "physics"`、`"语文" -> "language"`、`"历史" -> "history"` |

**验证**: `cargo build --release` 通过

---

## Phase 2 — 后端查询适配（必须 Phase 0 之后）

**依赖**: Phase 0（status 列存在）

### WHERE status='active' 必须加的 16 处（面向用户）：

| 位置 | 行号 | 原查询 | 改后 |
|------|------|--------|------|
| `routes.rs` | 914-926 | `FROM cards c` | `FROM cards c WHERE c.status = 'active'` |
| `routes.rs` | 1005 | `SELECT DISTINCT domain FROM cards` | `WHERE status='active'` |
| `routes.rs` | 1012 | `SELECT DISTINCT subject FROM cards` | `WHERE status='active'` |
| `routes.rs` | 858 | `SELECT COUNT(*) FROM cards` | `WHERE status='active'` |
| `routes.rs` | 870 | `SELECT COUNT(DISTINCT domain) FROM cards` | `WHERE status='active'` |
| `routes.rs` | 1284 | `SELECT COUNT(*) FROM cards` | `WHERE status='active'` |
| `routes.rs` | 1296 | `SELECT COUNT(DISTINCT domain) FROM cards` | `WHERE status='active'` |
| `routes.rs` | 1710, 1714, 1817, 1858 | 4 处统计 | `WHERE status='active'` |
| `ws.rs` | 424 | `SELECT COUNT(*) FROM cards` | `WHERE status='active'` |
| `fsrs_scheduler.rs` | 36 | `FROM cards c`（复习到期） | `WHERE c.status = 'active'` |
| `fsrs_scheduler.rs` | 60, 163, 167 | 3 处统计 | `WHERE status='active'` |
| `admin_handlers.rs` | 151, 195, 590, 1052 | 4 处管理统计 | `WHERE status='active'`（管理端看活跃卡片） |

### WHERE 不加 status 过滤的（必须全量）：

| 位置 | 原因 |
|------|------|
| `routes.rs:254` | 去重建议需包含 skipped |
| `card_repository.rs:57` | `insert_card` 去重扫描必须全量 |

**验证**: `cargo build --release` 通过

---

## Phase 3 — 前端适配

**依赖**: Phase 1（新 API 合约）、Phase 0（DB 存量已清理）

### 3.1 API Client (`chat_client.dart`)

| 方法 | 改动 |
|------|------|
| `skipConcept(front, sourceText)` | **删除** |
| `getSkippedConcepts()` | **删除** |
| `deleteSkipped(skipId)` | **删除** |
| `batchCreateCards(candidates)` | 改为 `updateCardStatus(List<String> cardIds, String status)` |
| 新增 | `updateCardStatus(String cardId, String status)` → `PATCH /api/cards/status` |

### 3.2 `chat_concept_dialog.dart`

| 位置 | 改动 |
|------|------|
| 行71 `skipConcept(...)` | 改为 `client!.updateCardStatus(candidates[i].id, 'skipped')` |
| 行97 `batchCreateCards(toCreate)` | 改为 `client!.updateCardStatus(toCreate.map((c)=>c.id), 'active')` |
| 行100 `skipConcept(...)` | 同上 → `updateCardStatus(id, 'skipped')` |
| 需要新增：提取候选概念时先 `batchInsert cards` (status='pending')，再弹窗 |

> ⚠️ **注意**：当前概念弹窗不预先入库。改成 status 模式后，需要在展示弹窗前 INSERT cards (status='pending')，再根据用户操作 UPDATE status。这涉及 `routes.rs` 概念提取流程的调整（与 Phase 1 联动）。

### 3.3 `card_list_screen.dart`

| 位置 | 改动 |
|------|------|
| 行516 `client.skipConcept(card.front, ...)` | 改为 `client.updateCardStatus(card.id, 'skipped')` |
| 行769 `client.skipConcept(card.front, ...)` | 同上 |
| 卡片列表查询 | subject 过滤值从中文改为英文 code |
| subject 筛选面板 | `_subjects` map 的 key 改为英文 code，display 保留中文 |

### 3.4 `review_screen.dart`

| 位置 | 改动 |
|------|------|
| 行245 `client.skipConcept(card.front, ...)` | 改为 `client.updateCardStatus(card.id, 'skipped')` |
| 刷新列表 | 复习到期查询会自动过滤 `status='active'`，跳过操作后卡片消失 |

### 3.5 `home_screen.dart` / `k12_subject_screen.dart` / `reading_subject_screen.dart`

| 改动 |
|------|
| `_subjects` map key 从 `"数学"` 改为 `"math"`，增加 `display_name: "数学"` 字段 |
| `POST /api/k12/init` 时 subject 传英文码（如 `"math"`） |

### 3.6 `skipped_list_screen.dart`

**整个文件删除**：跳过的卡片现在仍在 `cards` 表中（status='skipped'），可在卡片列表页的筛选选项中增加"显示已跳过"切换。

### 3.7 `achievements_screen.dart`

API 返回的 subject/domain 现在统一是英文代码，前端按英文 code 处理（显示仍用 display_name 映射）。

---

## Phase 4 — Prompt 架构重整

**依赖**: **无**（完全独立，可随时进行）

### 4.1 创建目录 + 复制文件

```bash
mkdir -p backend/prompts/general backend/prompts/math backend/prompts/language

# general/ ← 从 prompts/ root 复制
cp backend/prompts/chat_system_free.md       backend/prompts/general/chat-free.md
cp backend/prompts/chat_system_structured.md backend/prompts/general/chat-structured.md
cp backend/prompts/chat_system_reading.md    backend/prompts/general/chat-reading.md
cp backend/prompts/chat_system_reading_nursery.md  backend/prompts/general/chat-reading-nursery.md
cp backend/prompts/chat_system_reading_primary.md  backend/prompts/general/chat-reading-primary.md
cp backend/prompts/chat_system_reading_secondary.md backend/prompts/general/chat-reading-secondary.md
cp backend/prompts/concept_extract.md        backend/prompts/general/concept-extract.md
cp backend/prompts/card_direct.md            backend/prompts/general/card-direct.md
cp backend/prompts/quiz_generate.md          backend/prompts/general/quiz-generate.md
cp backend/prompts/quiz_judge.md             backend/prompts/general/quiz-judge.md
cp backend/prompts/grill_assessment.md       backend/prompts/general/grill-assessment.md

# math/ ← 从 pipelines/math/prompts/ 复制
cp pipelines/math/prompts/*.md backend/prompts/math/

# language/ ← 从 pipelines/language/prompts/ 复制
cp pipelines/language/prompts/*.md backend/prompts/language/
```

### 4.2 修改 `prompt_loader.rs::init()`

```rust
// 改前: init(prompts_dir, pipelines_base) → 加载 prompts/ + pipelines/{4}/prompts/
// 改后: init(base) → 加载 prompts/{general,math,language}/
```

### 4.3 修改 `main.rs` 调用处

`prompt_loader::init("prompts")`（去掉 `pipelines_dir` 参数）

### 4.4 提取 CP2 plan-creation prompt

从 `plan_handler.rs:1452` 硬编码提取为 `backend/prompts/general/plan-creation.md`，模板变量 `{dialogue_text}`，`{domain_options}` 用 `Domain::ALL` 注入

### 4.5 删除旧目录

```bash
rm -f backend/prompts/chat_system_*.md
rm -f backend/prompts/concept_extract.md
rm -f backend/prompts/card_direct.md
rm -f backend/prompts/quiz_*.md
rm -f backend/prompts/grill_assessment.md
rm -rf backend/pipelines/
```

### 验证

```bash
cargo build --release
# 确保 prompt_loader 的测试通过
cargo test -p chat_engine -- prompt_loader
```

---

## Phase 5 — 测试修复

**依赖**: Phase 0-3（代码已改动才能跑测试）

### 5.1 修复 `subject_router.rs` 测试

| 断言 | 当前 | 改后 |
|------|------|------|
| `subject_to_domain("物理")` | `"math"` ❌ | `"physics"` ✅ |
| `subject_to_domain("语文")` | `""` ❌ | `"language"` ✅ |
| `subject_to_domain("历史")` | `""` ❌ | `"history"` ✅ |

### 5.2 修复 `card_repository.rs` 测试

| 测试 | 改动 |
|------|------|
| `test_insert_new_card` | 验证 status 默认 'pending' |
| `test_insert_duplicate_rejected` | 无需改（去重不看 status） |
| 删除 `test_skip_concept_writes` | `skip_concept` 已删除 |
| 新增 `test_update_card_status` | 写入 status='active' → 改为 'skipped' → 验证查询 |

### 5.3 修复 `e2e_card_pipeline.rs`

- 硬编码 `"数学"` → `"math"`（行97-100, 217）
- `"语文"` → `"chinese"`（行186）
- `cards_with_domain("数学")` → `cards_with_domain("math")`
- 移除 `skipped_concepts` 相关断言（行数量检查）

### 5.4 修复 `e2e_live_llm_plan_lifecycle.rs`

- `"语文"` → `"chinese"`（行1533, 2655）
- `"数学"` → `"math"`（行2800）
- 适配 status 列

### 5.5 修复 `e2e_main_lifecycle.rs`

- 移除 `CREATE TABLE skipped_concepts`（行130）
- `"skipped_concepts"` 从表名列表中移除（行158）

### 5.6 修复 `e2e_learning_plan_lifecycle.rs`
- 行125 `CREATE TABLE IF NOT EXISTS skipped_concepts` → 删除

### 5.7 修复 `e2e_pipeline_test.rs`

`backend/src/bin/e2e_pipeline_test.rs:517`：
```rust
// 改前
let stmt = conn.prepare("SELECT LOWER(front) FROM skipped_concepts WHERE user_id = ?1");
// 改后（skipped_concepts 表已删除）
let stmt = conn.prepare("SELECT LOWER(front) FROM cards WHERE user_id = ?1 AND status = 'skipped'");
```

### 5.8 修复 `fsrs_scheduler.rs` 测试段

`backend/crates/card_engine/src/fsrs_scheduler.rs:259`：
```rust
// 改前：测试 setup 中创建 skipped_concepts 表
CREATE TABLE IF NOT EXISTS skipped_concepts (...);
// 改后：删除这行（表已不存在）
```

### 5.9 全量运行

```bash
cargo test --all-features 2>&1 | tail -30
```

---

## 执行建议

| 阶段 | 估算改动文件数 | 建议并行 | 预计工时 |
|------|--------------|---------|---------|
| Phase 0 | 1 (main.rs) | 串行 | 1 轮 |
| Phase 1 | 6 (routes.rs, card_repository, curriculum_loader, reading_loader, plan_handler, pipeline_router) | 串行 | 2-3 轮 |
| Phase 2 | 4 (routes.rs, ws.rs, fsrs_scheduler.rs, admin_handlers.rs) | 与 Phase 1 可少量重叠 | 1 轮 |
| Phase 3 | 7 frontend files | Phase 1 完成后 | 2 轮 |
| Phase 4 | 4 (prompt_loader, main.rs, plan_handler + 目录操作) | **与任何阶段并行** | 1 轮 |
| Phase 5 | 9 个测试/测试文件 | 最后 | 1-2 轮 |

**总估计**：10-12 轮实施 + 测试验证

**建议起始顺序**：Phase 0 → Phase 1 → (Phase 4 并行)

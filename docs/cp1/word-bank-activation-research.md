# 词库匹配分支重构：从「制卡」到「激活」—— 调查与设计方案

> 调查日期：2026-06-10 | 作者：寇豆码（Kou）· 工程师

## 一、现状分析

### 1.1 词库匹配分支的代码位置

`backend/crates/chat_engine/src/concept_extractor.rs` 第 76-137 行，位于 `extract_candidates_from_llm()` 函数尾部。

### 1.2 当前流程

```
AI reply
    ↓
word_bank::match_text(ai_reply)
    → 将 AI 回复按非英文字符分割
    → 提取所有长度 ≥ 2 的英文单词
    → 与 cefr_catalog.json（41574 条）逐词精确匹配
    → 返回 Vec<WordMatch>（含 word、definition、ipa、cefr_level）
    ↓
去重：
    → 跳过 已有卡片的 front
    → 跳过 刚由概念 LLM 提取的候选
    ↓
调 LLM 生成释义（第 96-116 行）：
    → prompt: "为以下英语单词生成简洁的单词卡..."
    → LLM 返回 JSON → parse_candidates
    → domain 写死为 "vocabulary"（已修复为继承 plan.domain）
    ↓
LLM 不可用时降级（第 117-133 行）：
    → 直接用词库自带 definition + ipa 拼接 back
    ↓
合并回 candidates 列表 → ws.rs 插入子表
```

### 1.3 发现的问题

| 问题 | 表现 | 影响 |
|:-----|:-----|:-----|
| `domain="vocabulary"` 不存在于 V4 子表 | 子表写入失败，背面为空 | false/true 两张卡片背面空白 |
| LLM 调用浪费 | 词库已有完整数据（发音、释义、例句），LLM 重新生成 | 多一次 API 调用 + 500ms 延迟 |
| 非语言域误触 | 逻辑学对话中 "false" "true" 被提取 | 用户收到无关词汇卡 |
| 弹窗突兀 | 基础词汇也要用户确认制卡 | 用户体验差，干扰对话 |
| 变体匹配不彻底 | 目前仅精确匹配，不做词干还原 | 但 CEFR 词库已含 41574 条，覆盖 "running" "cats" 等变体，影响不大 |

## 二、词库数据源分析

### 2.1 原始方案：cefr_catalog.json

最初使用 `cefr_catalog.json`（41574 条 CEFR 词汇）进行匹配。启动时一次性加载到 `HashMap`，运行时 `match_text()` 按非英文字符分割 AI 回复后精确匹配。

### 2.2 最终方案：prebuilt_cards 数据库表

**不再使用 cefr_catalog.json。** 改为查询 `prebuilt_cards WHERE subject='english'/'chinese'`，从数据库中加载所有预置词汇的 `front` 到 `HashSet`，按非字母字符分割 AI 回复后匹配。

- 英语：`prebuilt_cards WHERE subject='english'`（含全部课标词汇）
- 汉语：`prebuilt_cards WHERE subject='chinese'`（含语文课标词汇）
- 两套数据均已通过 `curriculum_loader` 在服务器启动时写入数据库

**优点：** 数据源统一，无需额外文件加载；覆盖课标全部词汇；汉语也得到支持。

## 三、产品设计：从「制卡」到「激活」

### 3.1 核心理念
词库匹配的本质不是**创建新卡片**，而是**在对话中遇到已学词汇时，将其加入复习队列**。

### 3.2 使用场景限定
| 场景 | 是否激活 | 理由 |
|:-----|:---------|:-----|
| 任何域的对话中出现预置词库词汇（english/chinese subject） | ✅ 激活 | 遇到就该认识，FSRS 自然排期 |
| 用户已有该词（user_cards 中 front 匹配） | ❌ 跳过 | 已在复习队列中 |
| 预置词库中不存在的词 | → 不处理 | 走概念 LLM（现有 CP1 流程）作为知识点提取 |

### 3.3 激活 vs 制卡对比

| 维度 | 当前（制卡） | 目标（激活） |
|:-----|:------------|:------------|
| LLM 调用（激活时） | 1 次（生成释义） | 0 次（用户输入验证仍需要，但这是另一条路径） |
| 用户感知 | ✅ 弹窗确认 | 静默无感 |
| 数据来源 | LLM 生成 | 复用预置卡 |
| 写入表 | user_cards + 子表 | user_cards（带上 prebuilt_card_id）+ card_memory |
| domain/plan | 继承 plan.domain | plan_run_id=''，独立 language+level |
| 复习排期 | FSRS 正常 | FSRS 正常 |
| 弹窗显示 | 显示在 CP1 弹窗中 | 不显示 |

### 3.4 跨域激活

不再限制 domain。任何对话（science/literature/humanities/language）中出现预置词汇时，静默激活。因为「遇到了就要认识」——不认识就通过 FSRS 排期学会它。

## 四、技术实现方案

### 4.1 改动范围

| 文件 | 改动 |
|:-----|:-----|
| `concept_extractor.rs` | 删除第 76-137 行词库匹配分支（含 LLM 调用），`extract_candidates_from_llm` 只走 LLM |
| `ws.rs` | Cold path 中新增 `activate_from_ai_reply(ai_reply, subject)`（AI 回复激活）+ `verify_user_input(user_message, language)`（用户输入验证） |
| `word_bank.rs` | 激活路径不再使用（但保留供 admin 统计端点的 CEFR lookup 使用） |
| `prompts/concept/*/extract.md` | 不改，CP1 提示词不涉及单词提取 |

### 4.2 数据结构调整

无新增结构体。两条路径独立运行，无需共享数据通道：

- 路径 A（概念提取）：走现有 `ExtractionResult` 不变
- 路径 B（词库激活）：在 ws.rs 中直接写 DB，不经过 `ExtractionResult`

### 4.3 伪代码

两条路径完全独立，不在同一函数中：

```
// ===== 路径 A：概念提取（走 LLM，结果给 CP1 弹窗） =====
extract_candidates_from_llm(...):
    return call_concept_llm(...)
    // 不再内部调用 word_bank

// ===== 路径 B：词库激活（ws.rs cold path，独立于概念提取） =====

// B1: AI 回复 → 首次激活（查询 prebuilt_cards subject 匹配，纯规则，0 LLM）
activate_from_ai_reply(ai_reply, user_id, subject):
    vocab = SELECT front FROM prebuilt_cards WHERE subject = subject  // HashSet
    matched = split(ai_reply) ∩ vocab
    if matched.is_empty() { return }
    for each matched word:
        if user already has this card (by front): skip
        INSERT user_cards { plan_run_id: '', prebuilt_card_id, language, level }
        INSERT card_memory { status: 'pending' }

// B2: 用户输入 → 激活 + 验证（查询 prebuilt_cards subject 匹配 + LLM 判断）
verify_user_input(user_message, user_id, language):
    vocab = SELECT front FROM prebuilt_cards WHERE subject = language  // HashSet
    matched = split(user_message) ∩ vocab
    if matched.is_empty() { return }
    for each matched word:
        if NOT yet activated:
            INSERT user_cards + card_memory（同 B1，用户用出说明应认识）
        else:
            result = llm_verify_usage(word, user_message_context)  // LLM 验证用法
            if result.correct:
                if last_review < today_start:
                    UPDATE card_memory { reps+1, due=fsrs_next(...), last_review=now }
            else:
                inject_correction_context(result.reason, result.correction_hint)  // 教学 LLM 纠正
```

### 4.4 激活写的 SQL

```sql
-- 1. INSERT user_cards（不绑定 plan，关联预置卡，plan_run_id 填 ''）
INSERT INTO user_cards (id, user_id, plan_run_id, prebuilt_card_id, domain, front, status, language, level, created_at)
VALUES (?1, ?2, '', ?3, ?4, ?5, 'pending', ?6, ?7, ?8)
-- prebuilt_card_id → 预置卡（get_due_cards 通过 JOIN 自动拿到 front/back）
-- language → 'english' | 'chinese'
-- level → 'A1'-'C2'（从 prebuilt_language_cards.level 继承）

-- 2. INSERT card_memory（初始 FSRS 状态）
INSERT INTO card_memory (card_id, user_card_id, state, status, difficulty, stability, due, last_review, reps, lapses)
VALUES (?1, ?1, 0, 'pending', 0.3, 1.0, ?2, 0, 0, 0)
```

## 五、待确认事项

| # | 事项 | 结论/状态 |
|:--|:-----|:----------|
| 1 | prebuilt_cards 数据是否完备？ | ✅ 已通过 curriculum_loader 写入 DB，english 17438 张 + chinese 若干 |
| 2 | 激活的卡片归属于哪个 plan_run？ | ✅ plan_run_id=''，不绑定 plan |
| 3 | 激活卡片是否要显示在 CP1 弹窗？ | ❌ 不显示，静默激活 |
| 4 | 用户能否手动从复习队列中移除激活的卡片？ | 🔲 后续可做 skip 功能，同现有卡片机制 |
| 5 | 按 level 渐进解锁？ | ❌ 不做，遇到就激活，FSRS 自然排期 |
| 6 | 汉语常驻 tab？ | ✅ 已实现，同时启用英语+汉语 |

## 六、变更历史

| 日期 | 变更 |
|:-----|:-----|
| 2026-06-10 | 初始文档，记录词库匹配分支调查与重构方案 |
| 2026-06-10 | 新增「常驻语言 tab 跨域激活」详细设计（第七节） |
| 2026-06-11 | ✅ 全部实现：schema + concept_extractor + fsrs_scheduler + routes + ws.rs + review_screen + chat_client。测试通过。|
| 2026-06-11 | 文档修正：SQL 中旧 `plan_run_id=NULL` 改为 `''`；数据源改为 prebuilt_cards；B2 未接通标注 |

---

## 七、「常驻语言 tab + 跨域激活」详细设计

### 7.1 设计目标

摆脱「语言学习依赖 learning plan」的绑定，改为：
- **常驻卡池**：英语词汇、汉语词汇各自独立，不绑定任何 plan
- **跨域激活**：任何域（science/literature/humanities/language）的对话，AI 回复中的预置词汇（英文/中文）都静默激活
- **对话即复习**：用户输入中用到已激活词汇时，LLM 验证用法 → 正确则更新 FSRS，错误则注入纠正
- **独立复习**：复习页新增「英语」「汉语」tab，只看被激活的语言词汇

### 7.2 交互变化

```
复习页（当前）
  ┌─────────────────────────────────┐
  │ 全部计划  │  计划A  │  计划B  │   ← 每个 plan 一个 tab
  └─────────────────────────────────┘
```

```
复习页（目标）
  ┌─────────────────────────────────────┐
  │ 英语  │  汉语  │  数学  │  物理  │  ...  │  全部卡片  │   
  └─────────────────────────────────────┘
  │ ↑ 常驻最前    ↑ 非 language plan 不变    ↑ 最后
  │ 英语/语文 plan 被移除（归入英语/汉语常驻 tab）              ← 点击英语 tab → 只显示激活的英语词汇
  │                                                         ← 点击全部卡片 → 不变
```

### 7.3 激活流程（改后的词库匹配分支）

```
任何域的 AI reply（science/humanities/language/...）
    ↓
subject = "english" 或 "chinese"（由当前 conversation 的 domain 决定）
    ↓
SELECT front FROM prebuilt_cards WHERE subject = ?  → HashSet
    ↓
按非字母字符分割 AI reply，提取匹配项
    ↓
逐词检查去重：
    → user_cards 中已存在该词（front 匹配）→ 跳过
    → 新词 → 激活
    ↓
激活：
    INSERT user_cards { plan_run_id: '', prebuilt_card_id, language, level }
    INSERT card_memory { status: 'pending' }
    → 无弹窗，无用户感知
    ↓
复习页语言 tab 查询时：
    → SELECT ... FROM user_cards WHERE language='english' ORDER BY cm.due ASC
    → 走 FSRS 队列
```

### 7.4 用户输入验证回路（对话即复习）

用户在对话中主动用出已激活的词汇时，自动判断其用法是否正确，实现「在对话中完成复习」。

```
用户输入 → 匹配预置词库中已激活的词汇
    ↓
匹配到已激活词汇 → LLM 判断用法是否正确（一次 LLM 调用）
    ├─ 正确 → UPDATE card_memory { reps+1, due=fsrs_next(...) }
    │         → 复习页不再出现该词，FSRS 自动拉长间隔
    │         → 用户无感
    │
    └─ 不正确 → LLM 输出错误分析 JSON
                → 注入 `system_reminder` 到教学 LLM 的对话上下文
                → 教学 LLM 在下一轮回复中自然纠正用户
                → 不更新 card_memory
```

#### 频率控制：每天最多一次 FSRS 更新

一天内多次正确使用同一词，只更新一次 FSRS。检查 `card_memory.last_review`：

```
第 1 次正确使用（10:00）→ last_review 不在今天 → 正常更新 FSRS
第 2 次正确使用（10:05）→ last_review 在今天 → 跳过，不更新
第 3 次正确使用（14:00）→ last_review 在今天 → 跳过，不更新

第二天再次正确使用 → last_review 不在今天 → 正常更新 FSRS
```

伪代码：
```
if result.correct:
    if last_review < today_start:           // 今天还没更新过
        UPDATE card_memory { reps+1, due=fsrs_next(...), last_review=now }
    // else: 今天已更新过，跳过
```

#### 验证 LLM 输出格式

```json
{
    "word": "false",
    "correct": true,
    "reason": "用户正确使用了 false 表示真假值。",
    "correction_hint": ""
}
```

```json
{
    "word": "false",
    "correct": false,
    "reason": "用户把 false 当动词用了，false 是形容词/名词。",
    "correction_hint": "False 是形容词或名词，表示'错误的/假'。例如: That statement is false."
}
```

- `correct: true` → 只更新 FSRS，不干预对话
- `correct: false` → 不更新 FSRS，将 `correction_hint` + `reason` 注入对话上下文，由教学 LLM 在回复中自然纠正

#### 优点

- 对话本身就是最自然的复习场景（主动输出 > 被动答题）
- 用户用对了 → 自动拉长复习间隔，无需复习页验证
- 用户用错了 → 在对话语境中即时纠正，比复习页事后看结果更有效
- `prebuilt_cards` DB 查询是纯规则（免费），只有需要判断时才调一次 LLM（不会比复习页更多）

### 7.5 数据库设计

不在 `user_cards` 和 `card_memory` 之外新建冗余表，仅给现有表增加必要的字段。

#### user_cards 新增列

```sql
-- 标记语言常驻卡片（非 plan-based）
ALTER TABLE user_cards ADD COLUMN language TEXT;   -- 'english' | 'chinese' | NULL（plan-based 卡片为 NULL）
ALTER TABLE user_cards ADD COLUMN level TEXT;       -- 'A1' | 'A2' | 'B1' | 'B2' | 'C1' | NULL
```

激活卡片：
- `plan_run_id` = ''（不绑定任何 learning plan）
- `language` = 标记语言
- `level` = 从 `prebuilt_language_cards.level` 继承（仅统计展示，不参与过滤）
- `prebuilt_card_id` = 指向预置卡（确保 front/back 完整）
- `card_memory` 记录正常创建（FSRS 调度）

不建新表。卡片数据全部在 `user_cards` 和 `card_memory` 中。

#### get_due_cards 的扩展

查询时加 OR 条件支持语言卡片：

```sql
WHERE (
    -- 现有 plan-based 卡片
    (c.plan_run_id != '' AND cm.status = 'active')
    -- 常驻语言卡片（无 plan，但有 language 标记）
    OR (c.language = ?5 AND cm.status = 'active')
)
```

前端 tab 切换时传不同的查询参数：
- `language=english` → 追加 `c.language = 'english'` 条件
- `language=chinese` → 追加 `c.language = 'chinese'` 条件
- 无参数 → 只查 plan-based 卡片（现有逻辑）

### 7.6 前端 UI 变更

1. **复习页 tab 栏（核心变化）**：

   当前：
   ```
   [全部卡片] [语文] [英语] [数学] [地理] ...
   ```

   目标：
   ```
   [英语] [汉语] [数学] [地理] ... [全部卡片]   ← 英语/汉语 常驻最前 ;全部卡片在最后
                                                ← 英语/语文 plan 彻底移除，不再出现
                                                ← 非语言 plan 保持不变
   ```

   - 英语 tab 激活时 → 查 `c.language = 'english'`
   - `domain=language` 的 plan 不再出现在 tab 栏中，原有计划复习入口关闭
   - 语言类词汇走独立激活 + FSRS 排期，不再依赖 plan 机制
   - 其他 plan tab 不变

2. **语言 tab 内布局**：
   - 卡片列表：与现有 inline review 一致（front → 翻转 → back → 验证）
   - 只显示该语言的激活卡片，按 FSRS 排期

3. **弹窗提示**（可选增强）：
   - 对话中激活新词时，非弹窗，而是在对话页底部出现一个小提示条 "已收录 3 个新单词"，点击跳转到该语言 tab

### 7.7 后端 API 变更

仅 1 个 REST API 接口需要扩展：

| 端点 | 变更 |
|:-----|:------|
| `GET /api/review/due` | `DueQuery` 新增 `language: Option<String>` 参数。有值时追加 `c.language = ?` 查询条件，无值时保持现有 plan-based 逻辑不变 |
| `/api/plans` | **不改** — 前端直接过滤 `plan_subject == english/chinese` |
| `/api/cards/by-plan` | **不改** — 语言 tab 不走此接口 |

其余改动（`activate_from_ai_reply`、`verify_user_input`、`card_memory` 更新）均为 ws.rs 内部实现，不经过 HTTP API。

> **注意**：`verify_user_input()`（B2 用户输入验证）函数已实现但尚未接入 hot path。当前仅 B1（AI 回复激活）在 cold path 中生效。B2 的接通需要额外工作：在 `ws.rs` 的消息处理循环中调用该函数，并将 `correction_hint` 注入教学 LLM 的 system context。

### 7.8 代码影响范围（完整清单）

| 文件 | 改动 | 关键行 |
|:-----|:-----|:-------|
| `backend/schema.rs` | `user_cards` 表新增 `language TEXT`、`level TEXT` 列；`plan_run_id TEXT NOT NULL` 改为 `TEXT DEFAULT ''` | — |
| `backend/crates/chat_engine/src/concept_extractor.rs` | 删除词库匹配分支 | L76-137 |
| `backend/crates/api_server/src/ws.rs` | Cold path 中 `english/chinese` 跳过处新增 `activate_from_ai_reply(ai_reply, subject)`；新增 `verify_user_input(user_message, language)` 路径；词库匹配改用 `prebuilt_cards WHERE subject=?` DB 查询 | L528-534 |
| `backend/crates/card_engine/src/fsrs_scheduler.rs` | `get_due_cards` 签名加 `language: Option<&str>`；`JOIN plan_runs` → `LEFT JOIN`；WHERE 加 `c.language = ?` OR 分支 | L38, L70, L82 |
| `backend/crates/api_server/src/routes.rs` | `DueQuery` 加 `language: Option<String>`；透传到 `get_due_cards` | L240-245, L262-263 |
| `backend/prompts/verify_usage.md` | 新增：用户词汇用法验证 LLM 提示词 | 新文件 |
| `frontend/lib/screens/review_screen.dart` | `plans` 过滤 `subject==english/chinese`；tab 最前加 `[英语]` `[汉语]`；传 `language` 参数 | L607-671 |
| `frontend/lib/api/chat_client.dart` | `getDueCards` 调用增加 `language` 参数 | — |

**不改的文件：**
- `word_bank.rs` — `match_text` 接口不变
- `prompts/concept/*/extract.md` — CP1 提示词不动
- `cards_by_plan_handler` — 语言 plan 的卡片自然不被返回（用户不会点进去）
- 其他 pipeline — 都不受影响

### 7.9 与现有系统的关系

**不兼容，直接替换。** 语言类科目不再使用 plan tab 机制：

1. **删除英语/语文 plan tab**：`plan_runs` 中 `subject=english/chinese` 的 plan 不在复习页展示
2. **原有卡片不删除**：已有 `user_cards` 记录保留，但不再通过 plan tab 访问。旧计划卡片没有 `language` 标记，不会出现在英语 tab 中。后续可通过迁移脚本将 `plan_run_id != ''` 的语言卡片加上 `language = 'english'` 标记。
3. **非语言 plan 不变**：数学、物理、科学等 plan tab 照常工作

#### SQL 关键变更

`get_due_cards` 中 `JOIN plan_runs` 必须改为 `LEFT JOIN`，否则空 plan_run_id 的语言卡片会被 INNER JOIN 排除：

```sql
-- 当前（language 卡片被 INNER JOIN 排除）
JOIN plan_runs pr ON c.plan_run_id = pr.id

-- 目标
LEFT JOIN plan_runs pr ON c.plan_run_id = pr.id AND c.plan_run_id != ''
-- plan_based: c.user_id = ?1 AND c.plan_run_id != '' AND cm.status = 'active' AND cm.due <= ?2
-- language:   c.user_id = ?1 AND c.language = 'english' AND cm.status = 'active' AND cm.due <= ?2
```

### 7.10 已决策事项

| # | 事项 | 结论 |
|:--|:-----|:-----|
| 1 | 汉语常驻 tab？ | ✅ 已实现，同时启用英语+汉语 |
| 2 | 按 level 渐进解锁？ | 不做，遇到就激活 |
| 3 | 激活时弹窗？ | 不弹窗，静默激活 |
| 4 | 已存在于课标 plan 的词是否重复激活？ | 去重（front 匹配），不重复 |
| 5 | 激活卡片计入每日复习限制？ | 与现有卡片共享 FSRS 配额 |
| 6 | B2 用户输入验证 (`verify_user_input`) 何时接入 hot path？ | 🔲 函数已实现，未接通。待产品确认后接入 ws.rs 消息循环 |
| 7 | 旧英语/语文 plan 的已有卡片是否迁移 `language` 标记？ | 🔲 不自动迁移。后续可写迁移脚本 backfill `UPDATE user_cards SET language='english' WHERE plan_run_id IN (SELECT id FROM plan_runs WHERE subject='english')` |

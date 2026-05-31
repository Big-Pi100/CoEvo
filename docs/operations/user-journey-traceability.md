# 用户旅程追踪与架构对比分析

> 版本: v1.0 · 2026-05-31
> 方法: 从用户意图出发，逐层追溯全链路，与架构文档交叉对比找盲区。
> 格式: 
>   用户想要 → 点击/操作 → 前端 → 网络请求 → 后端 → DB → 响应 → 用户看到
>   对比: 架构文档中的"预期" vs 用户旅程中的"实际"

---

## 目录

1. [旅程 1: K12 结构化入学（数学）](#1-k12-结构化入学数学)
2. [旅程 2: 语文阅读入学](#2-语文阅读入学)
3. [旅程 3a: 自由对话（无 plan 起步）](#3a-自由对话无-plan-起步)
4. [旅程 3b: 结构化对话（有 plan 教学）](#3b-结构化对话有-plan-教学)
5. [旅程 3c: 历史对话续接](#3c-历史对话续接)
6. [旅程 4: 概念确认制卡（CP1）](#4-概念确认制卡cp1)
7. [旅程 5: 学习计划自动推进（CP2）](#5-学习计划自动推进cp2)
8. [旅程 6: 到期复习](#6-到期复习)
9. [旅程 7: 查看成就与进度](#7-查看成就与进度)
10. [旅程 8: 个人设置](#8-个人设置)
11. [对比分析: 架构意图 vs 用户旅程](#9-对比分析-架构意图-vs-用户旅程)

---

## 1. K12 结构化入学（数学）

### 旅程

```
用户想要: "开始学初中数学"
  ↓ 点击底部导航"学习" → K12 入口 → 选择"数学"+"初中(g7-9)"
  ↓
前端: POST /api/k12/init
  Body: {user_id, subject:"数学", grade_band:"g7-9", preferred_stage:0, goals:"初中数学基础"}
  ↓
后端: k12_init_handler (routes.rs)
  1. 查已有 conversation: user_id + subject + grade_band
  2. 有 → resumed=true, 返回已有 conv_id
  3. 无 → 创建新 conversation
  4. DELETE learning_plans WHERE domain="数学_g7-9" (清理旧plan, 2026-05-30修复)
  5. 从预置 plan 文件读取 plan_content (math.json 中 subject="数学", grade="g7-9")
  6. INSERT learning_plans (plan_content + 初始 plan_json + domain="数学_g7-9")
  7. unlock_next_cards: 首 task 的 gold_cr_ids/vocab_card_ids 导入 cards 表
  ↓
DB: 
  conversations 表: INSERT id=uuid, subject="数学", grade_band="g7-9", turn_count=0
  learning_plans 表: INSERT domain="数学_g7-9", plan_content="{\"stages\":[...]}", plan_json="{\"task_status\":{...}}"
  cards 表: INSERT ... (预置卡)
  card_memory 表: INSERT ... (初始状态 New)
  ↓
响应: {conversation_id, plan: {goal, stages, tasks}, resumed: bool}
  ↓
前端: 跳转到 chat_screen
  → 显示 plan 面板（阶段名 + 首任务 + 状态）
  → 输入框可用 → 用户可以发第一条消息
```

### 预期 vs 实际

| 检查点 | 架构预期 | 实际表现 | 状态 |
|:-------|:---------|:---------|:-----|
| 同一科目+学段续接 | 返回已有会话 | `resumed=true` + 旧 conv_id | ✅ |
| 不同学段不互相覆盖 | domain 含 grade_band | domain="数学_g7-9" vs "数学_g10-12" | ✅ 2026-05-30 修复 |
| plan 首任务激活 | 首 task 为 in_progress | plan_json 中首 task 标记为 in_progress | ✅ |
| 预置卡已导入 | unlock_next_cards 执行 | cards 表中有对应预置卡 | ✅ |
| 前端进入对话页 | chat_screen 显示 plan 面板 | `_loadPlan()` 在 initState 触发 | ✅ |

---

## 2. 语文阅读入学

### 旅程

```
用户想要: "开始学语文课文"
  ↓ 点击"学习" → K12 → "语文" → "1-2年级"
  ↓
前端: POST /api/k12/reading/init
  Body: {user_id, subject:"语文", grade_band:"g1-2"}
  ↓
后端: k12_reading_init_handler (routes.rs)
  1. 查已有 conversation: user_id + "语文" + "g1-2"
  2. 有 → resumed=true, 返回 conv_id
  3. 无 → 创建新 conversation
  4. 从 reading_plans 目录读取 plan_content (含课文列表)
  5. 创建 plan: mode="reading", domain="语文_g1-2"
  6. 导入所有课文卡和词卡到 cards 表
  ↓
DB:
  conversations: INSERT subject="语文", grade_band="g1-2"
  learning_plans: INSERT domain="语文_g1-2", mode="reading", plan_content=(146课文)
  cards: INSERT ... (775 张课文卡 + 词卡)
  ↓
响应: {conversation_id, plan: {stages, tasks}, card_count: 775}
  ↓
前端: 跳转 chat_screen
  → PlanPanel 显示: "课文一: 我是中国人" (in_progress)
  → 用户输入区带预设问候
```

### 与数学的差异

| 维度 | 数学 (structured) | 语文 (reading) |
|:-----|:------------------|:---------------|
| plan mode | `structured` | `reading` |
| plan 来源 | 预置 plans/math.json | 预置 reading_plans/ 目录 |
| 卡片导入 | 按 task 的 gold_cr_ids 逐步导入 | 初始化时全部导入 (775张) |
| Teacher prompt | `chat_system_structured.md` | `chat_system_reading_primary.md` |
| 任务粒度 | 概念级 (集合/函数) | 课文级 (我是中国人/我爱祖国) |
| 领域名称 | "数学_g7-9" | "语文_g1-2" |
| CP2 推进单位 | task 完成 | 课文完成 |

---

## 3a. 自由对话（无 plan 起步）

### 旅程

```
用户想要: "跟AI随意聊聊，让AI教我东西"
  ↓ 场景: 用户从会话列表点"新建对话" → 进入空白 chat_screen
  ↓ 此时无 conversation_id（或使用临时 uuid）
  ↓
前端: 生成新的 conversation_id（临时 uuid）
  → WS send （无 mode/subject/grade_band 字段）
  {
    "user_id": "user_xxx",
    "conversation_id": "new_uuid",   ← 前端生成的 uuid
    "token": "auth_token",
    "message": "老师好，我想学Python编程！"
  }
  ↓
后端 ws.rs handle_ws:
  1. 校验 token
  2. 校验 subscription
  3. conversation_id 不存在 → 自动 INSERT INTO conversations (id=uuid, user_id, turn_count=0)
     ⚠️ 注意: 此时 conversations 表的 subject/grade_band/mode 均为 null
  4. build_plan_context() → domain="" (无 plan，返回 free 模式)
  5. 读取最近10轮 → 空（新对话）
  6. 选择 prompt → `chat_system.md` (free 兜底)
  7. 调用 LLM API
  ↓
  LLM 回复 → WS token → done
  ↓
  对话结束后台:
    INSERT conversation_turn
    CP1: extract_domain="" → ❌ 跳过（2026-05-31 起无 plan 不运行）
    CP2: 检测教学内容 → 如果 LLM 输出了教学信号:
          → build_plan_creation_prompt() → LLM 生成 plan JSON
          → upsert_learning_plan() → INSERT learning_plans
          → cp2_tx.send(true) → WS plan_updated
  ↓
用户第一次看到: Teacher 的回复（无 plan 面板，无 candidates）
  ↓
用户发送第二条消息:
  WS send (此时仍无 plan)
  →
  CP2 在第 2 轮可能: 如果第 1 轮已创建 plan，则已绑定
    build_plan_context() 返回 domain="general" + plan ctx
    → 第 2 轮开始 Teacher 看到 plan 上下文
    → 第 2 轮开始 CP1 可以运行
```

### 与结构化对话的关键差异

| 维度 | 自由对话 | 结构化对话 |
|:-----|:---------|:-----------|
| 初始 plan | ❌ 无 | ✅ K12/reading init 时创建 |
| Plan 创建时机 | 第 1 轮 CP2 检测到教学后 | 对话开始前已存在 |
| Plan 何时可见 | 第 1 轮 done 后，通过 plan_updated，但用户刷新才稳定 | initState 的 _loadPlan() 立即可见 |
| CP1 何时运行 | 第 2 轮及以后 | 每轮都运行 |
| mode | `free` | `structured` / `reading` |
| prompt | `chat_system.md` (通用) | 按 subject 路由的有结构 prompt |

### 已知问题

| 问题 | 描述 | 状态 |
|:-----|:------|:-----|
| 第 1 轮无 CP1 | extract_domain 为空，跳过 | ✅ 设计如此——无 plan 提取也无意义，第 2 轮起 plan 创建后 CP1 即可运行 |
| 第 1 轮无 plan 面板 | CP2 需先检测到教学意图才创建 plan，在此之前 plan 面板不显示 | ✅ 设计如此——用户在自由对话，系统不确定是否要创建计划，等确认后再创建 |

---

## 3b. 结构化对话（有 plan 教学）

### 旅程

```
用户想要: "AI老师教我集合的概念"
  ↓ 前置条件: 已通过 旅程1/2 进入 chat_screen，conversation 已绑定 plan
  ↓
用户在 chat_screen 输入框打字 → 点击发送
  ↓
前端: WS send （带 mode/subject/grade_band）
  {
    "user_id": "user_xxx",
    "conversation_id": "conv_uuid",
    "token": "auth_token",
    "message": "老师好！请开始教我集合的概念",
    "mode": "structured",          ← plan 提供的 mode
    "subject": "数学",
    "grade_band": "g7-9"
  }
  ↓
后端 ws.rs handle_ws:
  1-3. 同上（鉴权）
  4. build_plan_context() → domain="数学_g7-9", mode="structured",
     ctx="当前阶段: 几何变换 (in_progress)\n  - 集合的概念: in_progress\n  - ..."
  5. 读取最近10轮 conversation_turns
  6. 选择 prompt → `chat_system_structured.md` + `chat_system_math.md`
     (按 subject 路由)
  7. 构建完整 prompt (含 plan_ctx + 最近对话)
  8. 调用 LLM API
  ↓
  LLM 回复 → WS token → done
  ↓
  对话结束后台:
    INSERT conversation_turn
    CP1: domain="数学" → ✅ 运行（有 plan）
         prompt 含 {plan_context} → 限定提取与当前 task 相关概念
         (2026-05-31 新增 task 预置卡 fronts 注入 plan_context)
    CP2: → ✅ 运行，analyze_turn_progress()
         prompt 含当前 task 上下文 → 区分测验 vs 整课完成
  ↓
用户看到:
  Teacher 回复 + PlanPanel（当前阶段+任务列表+状态）+ 偶尔 candidates 弹窗
  ↓
完成信号（用户回答考核问题 → Teacher 说"通过"）
  → CP2 检测到 → plan_updated → PlanPanel 自动刷新
  → 下一任务出现
```

### 结构化 vs 自由的 prompt 差异

| 维度 | 自由 (free) | 结构化 (structured) | 阅读 (reading) |
|:-----|:------------|:--------------------|:---------------|
| prompt 文件 | `chat_system.md` | `chat_system_structured.md` + 学科 prompt | `chat_system_reading_primary.md` |
| plan_ctx 注入 | 无 plan 时为空 | 全量注入（阶段/任务/状态） | 全量注入（课文/学段）|
| 任务完成信号 | CP2 判断 | Teacher 输出 `{task名}学习已经完成` | Teacher 输出"这一课学完了" |
| 制卡 domain | N/A (不运行) | LLM 根据对话上下文推断 | 固定为"语文" |

---

## 3c. 历史对话续接

### 旅程

```
用户想要: "继续上次没学完的内容"
  ↓ 在会话列表找到旧对话 → 点击进入
  ↓
前端: chat_screen initState
  conversation_id = 旧对话的 id
  ↓
_loadPlan(): GET /api/plans?conversation_id=旧对话uuid
  → 返回该对话的 plan（含 task_status 中的 done/pending 状态）
  → PlanPanel 显示上次的进度
  ↓
WS 连接:
  send {user_id, conversation_id: 旧对话uuid, message: "我回来了，继续学"}
  ↓
后端:
  1. 校验 token
  2. 校验 subscription
  3. conversation 存在 + deleted_at IS NULL → ✅
  4. build_plan_context() → 读取已有 plan，看到上次推进到的任务
  5. 读取最近10轮 conversation_turns（历史对话内容）
  6. 构建 prompt (含 plan_ctx + 历史对话)
  7. 调用 LLM
  ↓
用户看到:
  上次的对话历史 + 上次的 plan 进度 + Teacher 延续教学
```

### 续接时的数据一致性检查

| 检查点 | 预期 | 风险 |
|:-------|:-----|:-----|
| plan 状态 | 上次推进到的 task_status | ✅ learning_plans 表持久化 |
| 对话历史 | 最近10轮 conversation_turns | ✅ 已存储 |
| plan 面板 | PlanPanel 显示上次推进结果 | ✅ _loadPlan() 在 initState 触发 |
| CP1/CP2 | 每轮照常运行 | ✅ 不受"续接"影响 |
| 预置卡 | 之前 unlock_next_cards 已导入的 card 仍然存在 | ✅ cards 表持久化 |
| **domain 续接** | 续接后 domain 匹配原 plan domain | **⚠️ 如果续接时 plan 的 domain 格式变了（如 2026-05-30 从"数学"改为"数学_g7-9"），可能找不到 plan** |

### 续接失败的场景

```
用户: 在旧版本（domain="数学"）创建了对话和 plan
        → conversation_id="A", plan.domain="数学"
        
某次更新后: domain 格式改为 "数学_g7-9"
        → 后续 k12/init 按 "数学_g7-9" 写入

用户从会话列表点击 conversation_id="A"
  → _loadPlan() → GET /api/plans?conversation_id=A
  → 按 conversation_id 查询，不依赖 domain
  → ✅ 仍然能找到 plan（因为按 conversation_id 查）

但 k12/init 续接:
  → 查已有 conversations: user_id + "数学" + "g7-9"
  → 找 conversation_id="A" (如果 A 的 grade_band 也是 "g7-9")
  → 但 DELETE domain="数学_g7-9"
  → ⚠️ A 的 domain="数学" 不被删除，但新 plan 的 domain="数学_g7-9"
  → 存在两个 plan！一个 conversation 绑两个 plan？
```

**续接风险总结**：`_loadPlan()` 按 conversation_id 查 plan，只要 plan 没被误删，续接总能找到。风险主要来自 `k12/init` 的 DELETE 操作——2026-05-30 修复前误删了同科目所有 plan，修复后只删同学段。如果旧对话的 grade_band 与新入口一致，DELETE 会命中旧 plan。

### 三种对话模式的统一时序

```
WS send
  │  ~0.5s (LLM 首 token)
  ▼
thinking → token 流 → ~3-8s → done
                                │
                  ┌─────────────┴─────────────┐
                  ▼                           ▼
            CP1 spawn (500ms延迟)          CP2 spawn (500ms延迟)
            (仅 structured/reading)        (仅当有 plan 时)
                  │                           │
                  ▼                           ▼
            LLM 提取概念 (~2-3s)          LLM 分析进度 (~2-3s)
                  │                           │
          ┌───────┴───────┐                   │
          ▼               ▼                   ▼
      candidates    无候选(跳过)         plan_updated(mpsc)
          │               │                   │
          └───────┬───────┘                   │
                  ▼                           ▼
            WS candidates                 WS plan_updated
            (~done+3s)                    (~done+3s)
```

**三种模式在此时序上的差异**：

| 阶段 | 自由对话 (3a) | 结构化 (3b) | 阅读 (3b) | 历史续接 (3c) |
|:-----|:-------------|:------------|:----------|:--------------|
| CP1 运行 | ❌ 第1轮跳过, 第2轮起✅ | ✅ 每轮 | ✅ 每轮 | ✅ 同源 |
| CP2 运行 | ✅ 每轮（第1轮创建plan） | ✅ 每轮 | ✅ 每轮 | ✅ 同源 |
| plan_updated | 第1轮可能迟到 | ✅ 正常 | ✅ 正常 | ✅ 正常 |
| candidates | 第1轮无 | ✅ 有 | ✅ 有 | ✅ 有 |

---

## 4. 概念确认制卡（CP1）

### 旅程

```
用户想要: "记住刚才学的这个概念"
  ↓ 无操作 — 系统自动弹窗
  ↓
前端收到 candidates WS:
  {"type":"candidates","candidates":[
    {"front":"集合的定义","back":"把确定的对象放在一起","domain":"数学","source_sentence":"..."},
    {"front":"元素与集合的关系","back":"属于∈/不属于∉","domain":"数学","source_sentence":"..."}
  ]}
  ↓
前端弹窗: _showCandidateDialog()
  ┌─────────────────────────────────┐
  │  发现新的知识点!                 │
  │                                 │
  │  ☑ 集合的定义                   │
  │  ☑ 元素与集合的关系             │
  │                                 │
  │  [全部确认]  [全部跳过]  [取消]  │
  └─────────────────────────────────┘
  ↓
用户点击[全部确认]
  ↓
前端: POST /api/cards/batch-create
  Body: {
    user_id: "user_xxx",
    conversation_id: "conv_uuid",
    candidates: [
      {front:"集合的定义", back:"把确定的对象放在一起",
       source_sentence:"...", domain:"数学"},
      {front:"元素与集合的关系", back:"属于∈/不属于∉",
       source_sentence:"...", domain:"数学"}
    ]
  }
  ↓
后端: cards_batch_create_handler (routes.rs)
  1. 校验 token
  2. 遍历 candidates → 逐一去重 + 格式化 + 写入
  3. 去重: LOWER(front) 精确匹配 vs cards + skipped_concepts
  4. 写入 cards + card_memory (BEGIN TRANSACTION)
  5. 触发 N7 成就检测
  6. 返回: {created: 2, duplicates: 0, achievements: [...]}
  ↓
DB:
  cards: INSERT id=uuid, domain="数学", front="集合的定义", ...
  card_memory: INSERT state=0(New), due=now()
  ↓
用户看到:
  "✓ 已确认 2 个知识点"
  + 卡片出现在复习页的"数学" tab 中（下次打开复习时可见）
```

### 边界情况

| 场景 | 表现 | 处理 |
|:-----|:-----|:-----|
| 用户选择[跳过] | POST /api/cards/skip → skipped_concepts 写入 | 同 front 不再出现 |
| 用户关掉弹窗不操作 | 候选概念丢失 | 不会再次提取 |
| 候选概念已被制卡 | batch-create 返回 duplicates | 跳过，不重复插入 |
| candidates WS 因网络丢失 | 弹窗不出现 | 概念永久丢失（除非再次对话提取）|

---

## 5. 学习计划自动推进（CP2）

### 旅程

```
用户/系统状态: 教师完成了当前 task 教学，学生通过考核
  ↓
教师回复中包含完成信号: "集合的概念学习已经完成"
  ↓
后端 CP2: analyze_turn_progress()
  prompt: final_reply + 当前 plan 上下文
  → LLM 判定: {"action":"complete_task","reason":"集合的概念教学全部完成"}
  ↓
handle_plan_update()
  → apply_plan_mutations()
    → 合并 plan_content + plan_json
    → task_status["集合的概念与表示"] = "done"
    → task_status["集合的运算"] = "in_progress"
    → unlock_next_cards() 导入预置卡
  → UPDATE learning_plans SET plan_json = ...
  ↓
mpsc channel: cp2_tx.send(true)
  ↓
主循环 select! → cp2_rx 收到 → WS send {"type":"plan_updated"}
  ↓
前端 _loadPlan():
  GET /api/plans?conversation_id=xxx
  → 收到新 plan 数据
  → setState → PlanPanel 刷新
  ↓
用户看到:
  PlanPanel 更新:
    ▼ 几何变换 (in_progress)
      ✔ 集合的概念与表示 (done)    ← 新增对勾
      ▶ 集合的运算 (in_progress)   ← 蓝色箭头移到下一任务
```

### 失败的场景

| 场景 | 用户看到 | 根因 |
|:-----|:---------|:-----|
| Teacher 没输出完成信号 | Plan 不更新，停在原地 | CP2 prompt 没检测到完成 |
| plan_updated WS 丢失 | Plan 不更新，但 DB 已改 | mpsc channel 写入失败（罕见）|
| unlock_next_cards 未执行 | 复习页没有预置卡 | CP2 推进时的时序问题 |
| 前端 _loadPlan 未触发 | Plan 显示旧数据 | plan_updated handler 未调 _loadPlan |

---

## 6. 到期复习

### 旅程

```
用户想要: "复习一下之前学的"
  ↓ 点击底部导航"复习"
  ↓
前端: 进入 review_screen
  initState:
    GET /api/plans?user_id=xxx     → _planTabs 生成
    GET /api/review/due?user_id=xxx → _cards 加载
  ↓
后端 review/due handler:
  SELECT ... FROM cards c JOIN card_memory cm
  WHERE c.user_id = ? AND cm.state IN (0,1,2,3) AND cm.due <= now()
  ORDER BY cm.due ASC LIMIT 500
  ↓
响应:
  {cards: [{id, front, back, domain, card_type, state, due, reps}], total_due: 12}
  ↓
前端: 渲染 tab
  Tab: ["全部", "数学_g10-12", "语文"]
  角标: [12, 4, 8]
  ↓
用户点击 "数学_g10-12" tab
  ↓
_filteredCards:
  domainFilter = "数学_g10-12"
  模式 A 匹配: card.domain == "数学" + card 无 _
  → 显示 4 张数学卡
  ↓
用户点击第一张卡:
  ┌─────────────────┐
  │  集合的定义       │  ← front
  │                  │
  │  [点击翻转]      │
  └─────────────────┘
  ↓ 点击翻转
  ┌─────────────────┐
  │  把确定的对象     │  ← back
  │  放在一起        │
  │                  │
  │  [我记住了] [忘了]│  ← Again/Good
  └─────────────────┘
  ↓
用户点击[我记住了(Good)]
  ↓
POST /api/review/submit
  Body: {user_id, card_id, rating: 3, verification_type:"review"}
  ↓
后端:
  FSRS.repeat(card_memory, 3) → 更新 state/due
  UPDATE card_memory SET state=2(Review), due=now()+86400, reps+=1
  INSERT review_log
  触发 N7 成就检测
  ↓
响应: {status:"ok", achievements:[], next_due: ...}
  ↓
前端: 从 _cards 中移除已评分卡，显示下一张
  ↓
用户看到: 下一张卡或"今日复习完成"
```

### 域匹配的边界情况

| Domain 组合 | Tab 显示 | 卡片匹配 | 用户看到 |
|:------------|:---------|:---------|:---------|
| plan domain="数学_g10-12", card domain="数学" | "数学_g10-12" | 模式 A ✅ | 数学卡在数学 tab |
| plan domain="数学_g1-2", card domain="数学" | "数学_g1-2" | 模式 A ✅ | 同 domain 的卡出现在两个数学 tab |
| plan domain="语文", card domain="语文" | "语文" | 模式 B ✅ | 正常 |
| plan domain="语文_g7-9", card domain="语文" | "语文_g7-9" | 模式 B ❌ | **语文卡不出现在语文_g7-9 tab 中！** |

**⚠️ 最后一行是潜在问题**：如果语文 plan 的 domain 带学段后缀，但卡片 domain 是纯"语文"，纯学科名 tab（无 `_`）用精确匹配 → 匹配失败。但带学段后缀的 tab（`"语文_g7-9"`）用前缀匹配 → 匹配成功。所以语文卡会出现在 `"语文_g7-9"` 中，但不会出现在 `"语文"` 中。如果用户只有 `"语文_g7-9"` 一个 tab，卡片仍然可见。这只有在同时有 `"语文"` 和 `"语文_g7-9"` 两个 tab 时才会有感知差异。

### UUID tab 过滤（2026-05-31 新增）

```
自由对话的 plan domain 是 conversation UUID（如 "conv_1780211615933"）。
这个 domain 对用户没有意义，不应该显示为 tab。

前端 _loadPlans() 中过滤:
  _planTabs = planList.where((p) {
    final domain = p['domain'] as String? ?? '';
    return !domain.contains('-');  // UUID 含连字符，学科 domain 不含
  }).toList();

同时后端 ws.rs 将 CP1 提取的卡片 domain 强制覆写为 "general":
  if extract_domain.contains('-') → candidates.domain = "general"

效果:
  - UUID 格式的 plan domain 不产生 tab ✅
  - 自由对话 CP1 卡片 domain="general"，在"全部卡片"tab 可见 ✅
  - K12 结构化/阅读卡片不受影响 ✅
```

---

## 7. 查看成就与进度

### 旅程

```
用户想要: "看看我的学习进度"
  ↓ 点击底部导航"成就"
  ↓
前端: initState → _loadAll()
  并行发起 3 个 API 请求:
  ↓
  ├─ GET /api/user/{uid}/learning-report
  │    → 返回: plans[], stats{total_cards,streak_days,...}, cefr_stats[]
  │
  ├─ GET /api/k12/progress?user_id={uid}
  │    → 返回: progress[{subject,grade_band,total_cards,mastered_cards}]
  │
  └─ GET /api/activity?user_id={uid}&days=90
       → 返回: days[{date,reviews,score,cards,conversations}]
  ↓
前端渲染:
  ┌─────────────────────────────┐
  │  🔥 7 天连续 · 📝 156 次   │
  │                             │
  │  42张卡  5今日  3领域       │
  │                             │
  │  [学习日历 - 5月]           │
  │  一 二 三 四 五 六 日       │
  │        1  2  3  4  5  6    │
  │  ...                       │
  │                             │
  │  K12 学习进度               │
  │  数学                       │
  │  g10-12 ████░░░░ 11%      │
  │  g1-2   ░░░░░░░░ 0%       │
  │  语文                       │
  │  g1-2   ██░░░░░░ 3%        │
  │                             │
  │  词汇掌握度                  │
  │  A1 ████████░░ 12/150      │
  │  A2 ██░░░░░░░░ 5/200       │
  └─────────────────────────────┘
```

### 数据一致性检查

| 字段 | 来源 API | 预期 | 潜在问题 |
|:-----|:---------|:-----|:---------|
| streak_days | learning-report | 连续学习天数 | 依赖后端统计逻辑，如果后端未正确记录每日活动→显示 0 |
| done_tasks | learning-report.plans[] | >0 | **2026-05-30 曾为 0**，因只读 plan_json.stages |
| mastered_cards | k12/progress | 和 cards 表一致 | 后端独立统计，可能与 learning-report 的 done_tasks 不同步 |
| reviews | activity.days[].reviews | 和 review_log 一致 | 依赖 activity 聚合逻辑 |

---

## 8. 个人设置

### 旅程

```
用户想要: "改一下我的名字"
  ↓ 点击首页左上角头像 → 进入 profile_screen
  ↓
前端 initState:
  GET /api/user/profile → {display_name, real_name, phone, avatar_url}
  GET /api/preferences  → {subscription_expires, tts_speed, ...}
  ↓
用户编辑显示名称 → 点击保存
  ↓
POST /api/user/profile
  Body: {display_name: "新名字"}
  ↓
后端: 校验 token → UPDATE users SET display_name = ?
  ↓
前端: setState → 显示新名字
  ↓
用户看到: 名字已更新
```

---

## 9. 对比分析: 架构意图 vs 用户旅程

### 9.1 逐旅程对比

#### 旅程 1-2: K12 入学

| # | 架构意图 | 用户旅程实际 | 差距 | 影响 |
|:-:|:---------|:------------|:-----|:-----|
| G1 | 续接会话时 plan 进度保留 | resumed=true 返回 old conv_id，但前端重新 initState 重新 _loadPlan | ❌ 无差距 | ✅ |
| G2 | 不同学段互不干扰 | domain 从 "数学" 改为 "数学_g7-9" | ❌ 已修复 | ✅ |
| G3 | 预置卡在入学时导入 | 数学按 task 逐步导入，语文一次性导入全部 | ⚠️ 两者策略不同 | 语文一次性导 775 张卡，内存开销大 |

#### 旅程 3a: 自由对话

| # | 架构意图 | 用户旅程实际 | 差距 | 影响 |
|:-:|:---------|:------------|:-----|:-----|
| G4 | 自由对话无 plan 时 CP1 不运行 | `extract_domain=""` 跳过 CP1 | ✅ 2026-05-31 实现 | |
| G5 | 自由对话第 1 轮 CP2 创建 plan | CP2 检测教学内容 → upsert_learning_plan → plan_updated | ⚠️ plan_updated 在第 1 轮 done 后到达，前端刷新才稳定 | 用户可能看不到第 1 轮的 plan |
| G6 | 自由对话无 plan 时 Teacher 看不到 plan_ctx | `build_plan_context` 返回空 | ✅ 设计如此 | |

#### 旅程 3b: 结构化对话

| # | 架构意图 | 用户旅程实际 | 差距 | 影响 |
|:-:|:---------|:------------|:-----|:-----|
| G7 | `plan_updated` 在 `done` 之后 0.5-3s 到达 | 实际通过 mpsc channel，非同步 | ⚠️ 时序窗口 | 用户快速连发时 CP1/CP2 可能被覆盖 |
| G8 | `candidates` 总是在 `done` 之后到达 | 正确，CP1 在 `done` 后 500ms spawn | ✅ | |
| G9 | 前端 15s 超时强制转为 idle | 实现正确 | ✅ | |
| G10 | WS token 在 done 前连续到达 | 正确，逐 token 追加 | ✅ | |
| G11 | 结构化对话的 Task 完成信号输出 | Teacher prompt 要求 `{task名}学习已经完成` | ✅ 2026-05-31 修复 | |

#### 旅程 3c: 历史对话续接

| # | 架构意图 | 用户旅程实际 | 差距 | 影响 |
|:-:|:---------|:------------|:-----|:-----|
| G12 | 续接时按 conversation_id 找回 plan | `_loadPlan(conv_id)` 按 id 查询 | ✅ | |
| G13 | 续接时 plan 状态保留 | learning_plans 持久化 task_status | ✅ | |
| G14 | 续接时历史对话保留 | conversation_turns 表存储 | ✅ | |
| **G15** | **旧 domain 格式升级后 plan 不被误删** | **2026-05-30 domain 从"数学"改为"数学_g7-9"，k12/init DELETE 按新 domain** | **⚠️ 边界** | **如果旧 plan.domain="数学" 而新 init 用 "数学_g7-9"，DELETE 不会命中旧 plan，但同一个 conversation 可能有两个 plan** |

#### 旅程 4: CP1 制卡

| # | 架构意图 | 用户旅程实际 | 差距 | 影响 |
|:-:|:---------|:------------|:-----|:-----|
| **G16** | **CP1 不要提取已有 task 卡片的概念** | **当前现有算法去重依赖 `unlock_next_cards` 是否已执行** | **⚠️ 时序差距** | **CP1 可能提取 task 预置卡已覆盖的概念** |
| G17 | candidates 弹窗 → 用户确认 → 入库 | 实现正确，路径完整 | ✅ | |
| G18 | 用户跳过 → 同 front 不再出现 | skipped_concepts LOWER(front) 精确匹配 | ✅ | |

#### 旅程 5: CP2 推进

| # | 架构意图 | 用户旅程实际 | 差距 | 影响 |
|:-:|:---------|:------------|:-----|:-----|
| G19 | CP2 区分"小测验通过" vs "整课完成" | prompt 已注入 plan_ctx + 负例约束 | ✅ 2026-05-31 修复 | |
| G20 | `apply_plan_mutations` 合并 plan_content + plan_json | 双向合并，同步 task_status | ✅ 2026-05-30 修复 | |
| G21 | `plan_updated` WS 推送到前端 | mpsc channel 方式，非嵌入 WS 主循环 | ⚠️ channel 竞争丢失风险低 | 极少发生 |

#### 旅程 6: 复习

| # | 架构意图 | 用户旅程实际 | 差距 | 影响 |
|:-:|:---------|:------------|:-----|:-----|
| G22 | 同 domain 卡出现在对应 tab | 模式 A/B 按 `_` 区分 | ⚠️ 边界情况 | 纯学科名 tab 不匹配带学段的卡片 domain |
| G23 | 所有到期卡都能被加载 | `LIMIT 500` | ✅ 2026-05-31 修复 | |
| G24 | 复习评分后 FSRS 更新 | `POST /review/submit` 完整 | ✅ | |

#### 旅程 7: 成就

| # | 架构意图 | 用户旅程实际 | 差距 | 影响 |
|:-:|:---------|:------------|:-----|:-----|
| G25 | 学习报告显示所有 plan 的 done/total | 从 plan_content + plan_json 双源合并计算 | ✅ 2026-05-30 修复 | |
| G26 | K12 进度与学习报告一致 | 两个独立 API，数据来源不同 | ⚠️ 可能不一致 | 学习报告按 task 数，K12 按卡片掌握数 |

#### 旅程 8: 个人设置

| # | 架构意图 | 用户旅程实际 | 差距 | 影响 |
|:-:|:---------|:------------|:-----|:-----|
| G27 | PII 加密存储 | AES-256-GCM，依赖 COEVO_PII_KEY | ✅ | |
| G28 | 修改后立即生效 | POST 成功后 setState | ✅ | |

### 9.2 关键差距汇总（设计意图 vs 实际表现）

| 级别 | # | 差距描述 | 影响 |
|:-----|:-:|:---------|:-----|
| 🔴 **P0** | G16 | CP1 去重不包含 task 预置卡 fronts → 可能提取语义重复概念 | 用户看到的制卡建议中包含已覆盖的概念 |
| 🟡 **P1** | G21 | mpsc channel 非同步 → plan_updated 偶发性丢失 | 极小概率 plan 面板不刷新 |
| 🟡 **P1** | G22 | 纯学科名 tab 不匹配带学段后缀的卡片 domain | 特定 domain 配置下卡片不显示 |
| 🟢 **P2** | G26 | 学习报告(task进度)与 K12卡片掌握度 API 数据来源不同 | 两个页面显示的"进度"含义不同 |

**已排除的非差距（设计如此）**：

| # | 原标记 | 纠正说明 |
|:-:|:------|:---------|
| G5 | 曾标为 🟡P1 | 自由对话第 1 轮无 plan 是**正确行为**——CP2 需要先检测到教学意图才创建 plan。强行创建 plan 才是错的 |
| G7 | 曾标为 🟡P1 | 快速连发时 CP1/CP2 各自独立运行，每轮处理自己的上下文。自由对话前几轮本就没有 plan，CP1 不运行，不影响结果 |
| G15 | 曾标为 🟡P1 | 旧 domain 格式升级是 2026-05-30 的单次迁移事件，上线后不会复现。当前所有新 conversation 的 domain 格式一致 |

### 9.3 用户体验问答（已与架构文档同步）

以下用户旅程中的常见问题，在架构文档 8.6 节 FAQ 中已有解答：

| 用户意图 | 解答位置 | 状态 |
|:---------|:---------|:-----|
| "我发了两条消息，为什么第二条没看到 plan 更新？" | 架构 8.6 FAQ 第 1 行 | ✅ 已回答 |
| "我刷新页面为什么进度丢了？" | 架构 8.6 FAQ 第 2 行 | ✅ 已回答 |
| "我复习了一半退出了，下次会从头开始吗？" | 架构 8.6 FAQ 第 3 行 | ✅ 已回答 |
| "我点了跳过，以后还能再看到这个知识点吗？" | 架构 8.6 FAQ 第 4 行 | ✅ 已回答 |
| "成就页的数字和对话页的 plan 不一样" | 架构 8.6 FAQ 第 5 行 | ✅ 已回答 |
| "为什么自由对话没有 plan 面板？" | 架构 8.6 FAQ 第 6 行 | ✅ 已回答 |
| "复习页有个奇怪的 UUID tab" | 架构 8.6 FAQ 第 7 行 | ✅ 已回答 |

---

## 修订记录

| 版本 | 日期 | 修改人 | 变更内容 |
|:-----|:-----|:-------|:---------|
| v1.0 | 2026-05-31 | Qi | 初始版本：8 条用户旅程 + 20 项对比差距分析 |

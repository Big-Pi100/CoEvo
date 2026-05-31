# UI 设计意图追踪 — 体系架构与契约整编

> 版本: v2.0 · 2026-05-31
> 定位: 从体系架构出发，串联原始设计意图与当前代码实现，建立可追踪的前后端契约视图。
> 适用: 生产维护 / 诊断排查 / 新功能设计
> 前置阅读: `docs/operations/maintenance-spec.md`

---

## 目录

1. [体系总架构](#1-体系总架构)
2. [Hot Path（对话热路径）](#2-hot-path对话热路径)
3. [Cold Path（对话后处理）](#3-cold-path对话后处理)
4. [Review Cycle（复习循环）](#4-review-cycle复习循环)
5. [Learning Plan（学习计划管线）](#5-learning-plan学习计划管线)
6. [Achievement System（成就系统）](#6-achievement-system成就系统)
7. [Data Store（数据存储）](#7-data-store数据存储)
8. [跨层诊断协议](#8-跨层诊断协议)
9. [契约偏离清单](#9-契约偏离清单)
10. [附录: 原始设计与现状对照](#10-附录原始设计与现状对照)

---

## 1. 体系总架构

### 1.1 三流架构

CoEvo 的所有用户可见行为由 **3 条核心数据流** 驱动，外加 4 条支撑流：

```
═══════════════════════════════════════════════════════════════════
  Flow A: Hot Path      AI 对话（用户感知最强的流）
  Flow B: Cold Path     制卡 + 计划推进（对话后异步，静默运行）
  Flow C: Review Cycle  复习循环（用户主动触发，单页交互）
  ───────────────────────────────────────────────────────────────
  Flow D: Achievements  成就检测（附属于 Flow B 和 Flow C 的触发器）
  Flow E: Skip          跳过管理（附属于 Flow B 的去重数据）
  Flow F: Conversation   对话生命周期（软删除/恢复）
  Flow G: User Settings  用户偏好 + 订阅（独立配置文件）
═══════════════════════════════════════════════════════════════════
```

### 1.2 用户会话流程

```
入口                        核心对话                    复习        成就/统计
┌──────┐     ┌──────────┐     ┌───────────────┐     ┌────────┐     ┌──────────┐
│ 登录   │ ──→ │ 会话列表  │ ──→ │ 对话页          │──→ │ 复习页  │ ──→ │ 成就页    │
└──────┘     └──────────┘     └───────┬───────┘     └────────┘     └──────────┘
                                       │
                   每轮对话结束 ──── Flow B (Cold Path)
                   CP1: 概念提取 → candidates WS → 弹窗确认
                   CP2: 计划分析 → plan_updated WS → 刷新面板
                                       │
         首页左上角 ──── Flow G (ProfileScreen: 个人设置)
```

### 1.3 页面 → 流程 → 节点 映射

| 页面 | 主流程 | 涉及节点 | 关键 API | WS 消息 |
|:-----|:-------|:---------|:---------|:---------|
| **ChatScreen** | Hot Path (A) + Cold Path (B) | N1, N2, N8 | `POST /ws` | token, done, candidates, plan_updated, thinking, planning, error |
| **ReviewScreen** | Review Cycle (C) | N5, N6a, N6b, N6c | `GET /review/due`, `POST /review/submit` | 无 |
| **AchievementsScreen** | Flow D + 聚合查询 | N7 | `GET /user/{uid}/learning-report`, `GET /api/k12/progress`, `GET /api/activity` | 无 |
| **ConversationList** | Flow F | - | `GET /api/conversations` | 无 |
| **ProfileScreen** | Flow G | - | `GET /api/user/profile`, `GET /api/preferences` | 无 |

### 1.4 契约断裂热力图

标注历史上每个断裂点发生在哪个层、涉及哪个页面：

```
页面        GUI层断裂          API层断裂           DB层断裂
────────  ────────────────  ────────────────  ────────────────
Chat      plan不刷新(#6)    CP1字段名写错       - 
          Teacher「剧本」    stage无默认值(#3)   
                            task_status未注入(#2)
                            UTF-8 panic(#1)   

Review    domain前缀过宽    limit=20不够       card.domain 与 
          纯学科精确匹配      导致卡"消失"        plan.domain 不统一
          被遗漏                                                    

Achieve   K12进度字段名     learning_report    -  
          被遗漏(done_tasks) 不读plan_content   (数据存在但读不到)
          
Profile   -                 -                  -
          (无复杂交互)
```

---

## 2. Hot Path（对话热路径）

### 2.1 架构定位

```
Flow A: Hot Path — 用户最直接感知的流程。必须首 token < 1s，全量回复 < 5s。
```

```
用户输入 ──→ WS send ──→ ws.rs handle_ws ──→ LLM Caller ──→ 流式 token
                              ↑                        ↓
                          plan_context 注入          done 事件
                          (build_plan_context)          │
                                                        ├─→ WS send done
                                                        ├─→ 触发 Cold Path
                                                        └─→ 存 conversation_turns
```

### 2.1a 三种对话模式

Hot Path 根据会话是否绑定了 plan 以及 plan 的 mode，分流到三条不同路径：

| 模式 | 步骤 1: 入口 | 步骤 2: plan 上下文 | 步骤 3: prompt 路由 | CP1 行为 | CP2 行为 |
|:-----|:-------------|:--------------------|:--------------------|:---------|:---------|
| **自由对话** | 会话列表"新建对话" | `build_plan_context` → domain="" (无 plan) | `chat_system.md` (通用兜底) | 第 1 轮跳过，第 2 轮起✅ (plan 创建后) | 第 1 轮检测教学意图→创建 plan |
| **结构化** | K12/理化 init 入口 | `build_plan_context` → domain="数学_g7-9" | `chat_system_structured.md` + 学科 prompt | ✅ 每轮运行 | ✅ 每轮推进 |
| **阅读** | K12/语文 reading init | `build_plan_context` → domain="语文_g1-2" | `chat_system_reading_primary.md` | ✅ 每轮运行 | ✅ 每轮推进 (课文粒度) |

**自由对话特有的处理逻辑**：

```
WS send 不带 mode/subject/grade_band
  → ws.rs 无 plan → free prompt
  → LLM 回复 → done → CP2 spawn
  → CP2 检测到教学内容 → 创建 plan (domain=conversation UUID)
  → plan_updated WS → 前端 _loadPlan()
  → 第 2 轮起: plan 已存在，按"结构化"模式运行
  → CP1 domain: 强制改写为 "general"(2026-05-31修复)

注意: 第 1 轮无 plan 是正确行为——CP2 需要先检测到教学意图才创建。
      强行创建 plan 才是错的。
```

### 2.2 WS 协议完整版本

#### 客户端 → 服务器

```json
{
  "user_id": "uuid",
  "conversation_id": "uuid",     // 空串=新建对话
  "token": "auth_token",         // 每条消息必传(后端每次校验)
  "message": "用户输入文本",
  "mode": "reading|structured|free",  // 可选，无 plan 时不传
  "subject": "数学|语文|...",         // 可选
  "grade_band": "g1-2|g7-9|..."       // 可选
}
```

#### 服务器 → 客户端（8 种消息）

| # | 类型 | 触发时机 | 载荷 | 前端行为 | 可靠性 |
|:-:|:-----|:---------|:-----|:---------|:-------|
| 1 | `kicked` | Token 校验失败 | `{}` | 立即跳转登录页 | 高 |
| 2 | `thinking` | LLM 开始推理 | `{}` | 显示"思考中..."，替换输入框为取消按钮 | 中(可能被后续token冲刷) |
| 3 | `planning` | LLM 正在生成 plan JSON | `{}` | 显示"规划中..."，不显示占位文本 | 中 |
| 4 | `token` | LLM 流式输出 | `{"content":"片段"}` | 追加到回复文本框 | 高(每token都发) |
| 5 | `done` | LLM 回复完成 | `{"reply":"完整回复"}` | 停止接收，显示完整文本+公式渲染 | 高 |
| 6 | `candidates` | CP1 概念提取完成 | `{"candidates":[...]}` | 弹窗确认/跳过 | 低(最多等15s,超时丢弃) |
| 7 | `plan_updated` | CP2 计划变更 | `{}` | 调用 `_loadPlan()` 刷新plan显示 | 低(通过mpsc channel,可能丢失) |
| 8 | `error` | 任意异常 | `{"code":"xxx","message":"..."}` | 显示错误提示 | 高 |

**关键时序保证**：
- `done` → `candidates`：candidates 总是在 done 之后到达，前端**不能假设**它们同批到达
- `done` → `plan_updated`：CP2 的 channel 通知与 done 非同步，可能延迟 500ms-3s
- `token` 在 `done` 之前连续到达，前端逐块追加
- `thinking` → `planning`：当 LLM 输出 `<plan_update` 标签时，ws.rs 拦截剩余 token 并转为 `planning`

#### candidates 格式

```json
{
  "type": "candidates",
  "candidates": [
    {
      "front": "勾股定理的相似三角形证明法",
      "back": "利用直角三角形相似关系：a² + b² = c²",
      "domain": "数学",
      "source_sentence": "老师，我理解勾股定理了..."
    }
  ]
}
```

#### error 类型

| code | 含义 | 触发条件 |
|:-----|:------|:---------|
| `auth_expired` | Token 过期/无效 | Token 校验失败 |
| `rate_limited` | 请求频率超限 | 后端限流中间件触发 |
| `llm_error` | LLM API 调用失败 | DeepSeek/Qwen 返回错误或超时 |
| `subscription_required` | 未激活订阅 | 用户无有效 subscription_expires |
| `subscription_expired` | 订阅已过期 | subscription_expires < now() |
| `conversation_not_found` | 会话不存在 | conversation_id 无效或已删除 |
| `internal_error` | 未捕获异常 | panic 或 DB 错误 |

### 2.3 前端处理状态机

```
  ┌──────────┐    WS send     ┌───────────┐   收到 thinking    ┌──────────┐
  │   idle    │ ───────────→ │  waiting   │ ───────────────→ │ thinking │
  └──────────┘               └───────────┘                   └──────────┘
       ↑                           │                              │
       │                   收到 token/planning                     │
       │                           ▼                              │
       │                    ┌───────────┐                         │
       │                    │ streaming │ ←──────────────────────┘
       │                    └─────┬─────┘
       │                          │ done
       │                          ▼
       │                    ┌───────────┐
       │                    │  done     │ ← 公式渲染+启用CP1/CP2等待
       │                    └─────┬─────┘
       │                          │ candidates? plan_updated?
       │                          ▼ (超时或收到)
       └────────────────── ← ── ┌──────────┐
                                │  idle    │ ← 输入框恢复
                                └──────────┘
```

**转移条件备注**：
- `waiting → streaming`：收到第一个 `token` 即转入
- `streaming → done`：收到 `done`，开始公式渲染
- `done → idle`：CP1 完成(收到candidates或超时) + CP2 完成(收到plan_updated或超时)。前端设 15s 超时，超时后强制 idle
- `done → error`：任一步骤出错

### 2.4 ChatScreen UI Widget 映射

#### 整体结构

```
chat_screen.dart (~830 行，拆分自原 1453 行)
  ├── _ChatScreenState
  │   ├── _buffer: String          ← token 累积
  │   ├── _reply: String           ← done 后完整回复
  │   ├── _isStreaming: bool       ← streaming 状态
  │   ├── _planData: Map?          ← _loadPlan() 结果
  │   ├── _planLoading: bool       ← plan 加载中
  │   │
  │   ├── _handleWsMessage()       ← WS 消息分发器
  │   │   ├── "kicked"    → Navigator.pushReplacementNamed('/login')
  │   │   ├── "thinking"  → setState(() => _isStreaming = true)
  │   │   ├── "planning"  → setState(() => _planLoading = true)
  │   │   ├── "token"     → _buffer += content  (逐字追加)
  │   │   ├── "done"      → _reply = reply; _isStreaming = false; _loadPlan()
  │   │   ├── "candidates"→ showCandidatesDialog(candidates)
  │   │   ├── "plan_updated"→ _loadPlan()
  │   │   └── "error"     → showErrorSnackBar(message)
  │   │
  │   ├── _loadPlan()     ← GET /api/plans?conversation_id=xxx
  │   │                     触发时机:
  │   │                       ✅ 页面 initState()
  │   │                       ✅ 收到 "done" (hotPath plan_updated=true 时)
  │   │                       ✅ 收到 "plan_updated" (CP2 channel)
  │   │                       ❌ 每次 token 到达 (不会)
  │   │                       ❌ 每次 candidates 到达 (不会)
  │   │
  │   └── _showCandidateDialog()  ← candidates 弹窗
  │        调用 POST /api/cards/batch-create 确认
  │        或 POST /api/cards/skip 跳过
  │
  ├── build()
  │   ├── AppBar(leading: 返回按钮)
  │   ├── PlanPanel (可折叠)
  │   │   └── _planData 渲染: 当前阶段名 + 任务列表 + 状态
  │   ├── MessageList
  │   │   └── _buildRichContent(text, isStreaming)
  │   │       ├── isStreaming=true → Text(纯文本，防闪烁)
  │   │       └── isStreaming=false → RegExp 解析 \(...\) 和 \[...\] 公式
  │   │            → flutter_math_fork 渲染
  │   └── InputBar
  │       └── TextField + sendButton
```

#### PlanPanel 数据流

```
数据源: GET /api/plans?conversation_id=xxx

响应:
{
  "plans": [{
    "plan": {
      "stages": [{
        "name": "几何变换",
        "status": "in_progress",
        "tasks": [{"name": "尺规作图", "status": "done"},
                   {"name": "坐标系", "status": "in_progress"}]
      }]
    },
    "domain": "数学_g10-12",
    "mode": "structured"
  }]
}

前端渲染:
  PlanPanel
    ├── goal: "K12: 数学 g10-12"
    ├── Stage: 几何变换 (in_progress)
    │   ├── ✔ 尺规作图
    │   └── ▶ 坐标系 (当前)
    └── 下一阶段: 函数与极限
```

**关键注意点**：
- `_loadPlan()` 的触发时机决定了用户看到的 plan 是否实时。如果 `plan_updated` 消息因 channel 竞争丢失，用户需等下一轮或手动刷新。
- `PlanPanel` 在 `_planData` 为 null 时不渲染（无 plan 时完全隐藏）。

#### CandidateDialog 数据流

```
触发: WS "candidates" → _showCandidateDialog(candidates)

UI:
  ┌─────────────────────────────────┐
  │  发现新的知识点!                 │
  │                                 │
  │  □ 勾股定理的相似三角形证明法     │
  │  □ 锐角三角函数的定义(sin/cos)   │
  │                                 │
  │  [全部确认]  [全部跳过]  [取消]  │
  └─────────────────────────────────┘

确认 → POST /api/cards/batch-create → candidates 入库 → review 可见
跳过 → POST /api/cards/skip → skipped_concepts 表 → 该 front 不再出现
```

### 2.5 过去事故映射

| 事故 | 断裂模式 | WS 消息链 | 根因 |
|:-----|:---------|:----------|:-----|
| CP2 plan 不更新 | 消息缺失 | `done` → 无 `plan_updated` | CP2 在 tokio::spawn 中无 ws sender |
| Teacher 输出剧本 | 内容异常 | `token`/`done` 正常但内容错误 | prompt 缺少红线规则 |
| 自由对话 plan 不显示 | 时序竞态 | `done` → `plan_updated` 延迟 > 用户等待 | 第 1 轮 CP2 创建 plan 需等下一轮 |

---

## 3. Cold Path（对话后处理）

### 3.1 架构定位

```
Flow B: Cold Path — 对话结束后的异步处理，与 Hot Path 解耦。
包含两条并行通道:
  CP1: 概念提取 → candidates WS
  CP2: 计划分析 → plan_updated WS + plan_json UPDATE
```

```
          done 事件
              │
              ▼
     ┌─────────────────┐
     │  ColdPath spawn  │
     └────────┬────────┘
              │
      ┌───────┴───────┐
      ▼               ▼
┌──────────┐   ┌──────────┐
│  CP1     │   │  CP2     │
│ 概念提取  │   │ 计划分析  │
└────┬─────┘   └────┬─────┘
     │               │
     ▼               ▼
candidates WS   plan_updated WS
(through        (through mpsc
 cold_tx         cp2_tx channel)
 channel)
     
     ┌───────┐   ┌───────────┐
     │ CP1   │   │ CP2 还看  │ ← 2026-05-31 新增
     │ 只跑   │   │ 当前 task │
     │ 有plan │   │ 上下文    │
     │ 的会话 │   │ (防误判)  │
     └───────┘   └───────────┘
```

### 3.2 CP1: 概念提取

| 属性 | 值 |
|:-----|:----|
| **位置** | `tokio::spawn` → `concept_extractor.rs` |
| **触发** | 每轮对话 `done` 后（**仅当会话关联 plan 时**） |
| **输入** | user_message + ai_reply + existing_fronts(算法去重) + skipped_fronts + **plan_context(含task绑卡fronts, 2026-05-31+)** |
| **输出** | candidates list → `cold_tx.send` → 主循环 → WS `candidates` 推送 |
| **Plan 上下文** | 2026-05-31 新增：注入 `build_plan_context`，限定 LLM 只提取与当前 task 相关概念 |

**去重机制（双层）**：

```
┌────────────────────────────────────────────────────────────────┐
│  Layer 1: 算法精确去重 (concept_extractor.rs)                    │
│  输入: existing_fronts (cards 表) + skipped_fronts              │
│  方式: LOWER(front) 精确匹配                                     │
│  限制: 措辞不同则漏（"集合" vs "集合的概念"）                    │
│  覆盖: 已入库的卡 + 已被跳过的概念                                │
└────────────────────────────────────────────────────────────────┘
        ↑ 加上：
┌────────────────────────────────────────────────────────────────┐
│  Layer 2: LLM 语义去重 (通过 build_plan_context 注入提示词)      │
│  输入: task_card_fronts → 注入 build_plan_context               │
│        → 通过 {plan_context} 传给 CP1/Teacher/CP2               │
│  方式: LLM 看到"当前 task 已绑定的卡片列表"，主动避免重复提取      │
│  覆盖: 预置卡数据（即使 unlock_next_cards 尚未执行）              │
│  优势: 语义去重，"集合的概念" vs "集合"也能识别为重复             │
└────────────────────────────────────────────────────────────────┘
```

**实现路径**（注入 `build_plan_context`）：

```
build_plan_context() 当前输出:
  "当前阶段: 集合与常用逻辑用语 (in_progress)
     - 集合的概念与表示: in_progress
     - 集合的运算: pending
  下一阶段: 函数基础"

build_plan_context() 改进后输出:
  "当前阶段: 集合与常用逻辑用语 (in_progress)
     - 集合的概念与表示: in_progress  ← 当前task
         已绑定的卡片: 集合的定义、元素与集合的关系、...  ← 新增！
     - 集合的运算: pending
  下一阶段: 函数基础"
```

**数据来源**：从 plan_content 读当前 task → `gold_cr_ids`/`vocab_card_ids`/`reading_card_id`
→ `curriculum_loader::get_cards()` / `reading_loader::get_card()` 查预置卡 fronts。

此操作不依赖 `unlock_next_cards` 是否已执行（直接查预置卡源数据），始终拿到正确列表。Teacher prompt 也受益——教师知道自己已经给了学生什么材料。

**CP1 prompt 的核心请求结构** (`concept_extract.md`):
```
### 对话上下文
{conversation_history}

### 当前学习任务（决定提取方向）
{plan_context}            ← 2026-05-31 新增

### 当前 AI 回复
{text}
```

### 3.3 CP2: 计划分析

| 属性 | 值 |
|:-----|:----|
| **位置** | `tokio::spawn` → `analyze_turn_progress()` |
| **触发** | 每轮对话 `done` 后 |
| **输入** | `final_reply` + **当前 plan 上下文(2026-05-31 修复)** |
| **输出** | `complete_task` 判定 → `handle_plan_update()` → mpsc channel → `plan_updated` WS |
| **Plan 上下文** | 2026-05-31 修复：将 `build_plan_context` 注入 CP2 prompt，帮助区分"小测验通过" vs "整课完成" |

**CP2 prompt 的关键约束**:
```
注意不要因为教师通过了某个小测验或问题就标记完成
——只有整个教学任务/课文学习完毕才标记。

完成信号: "这一课学完了"、"通关"、"全课完成"
不完成信号: "回答正确"（小测验）、"很好下一题"、"前半段你已掌握"
```

### 3.4 CP1 与 CP2 的关系

| 维度 | CP1 | CP2 |
|:-----|:----|:----|
| 目的 | 从对话中提取值得记住的概念 | 检测教师是否完成了当前教学任务 |
| 是否需要 plan | ✅ 是（2026-05-31 起） | ✅ 是 |
| 输出 | `candidates` WS 消息 | `plan_updated` WS 消息 + DB UPDATE |
| 通信方式 | mpsc channel (`cold_tx`) | mpsc channel (`cp2_tx`) |
| 并行性 | 两者可同时运行，互不依赖 |
| 无 plan 时的行为 | 跳过（不浪费 LLM 调用） | 跳过 |

### 3.5 过去事故映射

| 事故 | 断裂点 | 修复 |
|:-----|:-------|:-----|
| 无 plan 时也跑 CP1 | 启动守卫缺失 | `ws.rs:451` 加 `if !extract_domain.is_empty()` |
| CP1 提取无关概念 | prompt 缺 plan 上下文 | `concept_extract.md` 加 `{plan_context}` |
| CP2 把小测验误判为完成 | prompt 缺 plan 上下文 + 负例约束不足 | CP2 prompt 注入 plan_ctx + 明确负例规则 |
| CP2 plan_updated 不到前端 | 无消息通道 | mpsc channel `cp2_tx/cp2_rx` |

---

## 4. Review Cycle（复习循环）

### 4.1 架构定位

```
Flow C: Review Cycle — 用户主动触发的记忆巩固流程。
完全独立于 Hot/Cold Path，数据来源是 cards + card_memory 表。
```

```
用户点"复习"
     │
     ▼
GET /api/review/due?user_id=xxx
     │
     ▼ 返回 cards[]
┌──────────────────────────────────────┐
│ FSRS 排序: due ASC                   │
│ WHERE state IN (0,1,2,3) AND         │
│       due <= now()                   │
│ LIMIT 500 (2026-05-31 从 20 改为 500)│
└──────────────────┬───────────────────┘
                   │
                   ▼
       ┌─────────────────────┐
       │ 翻牌 (Flutter)       │ ← N6a
       │ front → 回忆 → flip │
       └─────────┬───────────┘
                 │
          ┌──────┴──────┐
          ▼              ▼
     ┌────────┐   ┌──────────┐
     │ 打字验证 │   │ AI 问答   │ ← N6b
     │ (本地)  │   │ (后端LLM) │
     └────┬───┘   └─────┬────┘
          └──────┬──────┘
                 ▼
          ┌──────────┐
          │ 评分提交   │ ← N6c
          │ POST      │
          │ /review/  │
          │ submit    │
          └─────┬────┘
                │
          ┌─────┴─────┐
          ▼           ▼
    N7 成就检测  继续下一张
```

### 4.2 Due Cards 查询

```sql
SELECT c.id, c.front, c.back, c.domain, c.card_type, c.source_sentence,
       cm.state, cm.difficulty, cm.stability, cm.due, cm.reps, cm.lapses
FROM cards c
JOIN card_memory cm ON c.id = cm.card_id
WHERE c.user_id = ?1
  AND cm.state IN (0, 1, 2, 3)  -- New, Learning, Review, Relearning
  AND cm.due <= ?2              -- now()
ORDER BY cm.due ASC
LIMIT ?3                        -- 当前=500
```

**前端 tab 生成规则**:
```
Plan list → 提取 DISTINCT domain → 排序 → 生成 tab
例:
  plan.domain = "数学_g10-12" → tab: "数学_g10-12"
  plan.domain = "语文"       → tab: "语文"
  plan.domain = "语文_g7-9"   → tab: "语文_g7-9"

Tab 数量 = 去重后的 plan.domain 数量
```

### 4.3 Domain 匹配协议（三模式）

这是前后端**最容易断裂**的契约点，之前已出事 3 次。

```
请求: GET /api/review/due?user_id=xxx
返回: cards[].domain = "数学" | "语文" | "vocabulary" | ...

前端 filter:
  if (tabDomain.contains('_')) {
    // 模式 A: 带学段后缀 → 前缀匹配
    //   tab "数学_g10-12" 匹配 card "数学" ✅
    //   tab "数学_g10-12" 匹配 card "数学_g7-9" ❌ (精准: card 无 _)
    base = tabDomain.split('_').first
    card.domain == tabDomain || (card.domain 无 '_' && card.domain == base)
  } else {
    // 模式 B: 纯学科名 → 精确匹配
    //   tab "语文" 匹配 card "语文" ✅
    //   tab "语文" 匹配 card "语文_g7-9" ❌
    card.domain == tabDomain
  }
```

**CP1 制卡后的卡片 domain 与 Tab 的匹配关系**：

| CP1 提取 domain | 目标 tab | 匹配规则 | 能否出现 |
|:----------------|:---------|:---------|:--------|
| `"数学"` | `"数学_g10-12"` | 模式 A | ✅ |
| `"数学"` | `"数学_g1-2"` | 模式 A | ✅（同时出现在两个 tab！) |
| `"语文"` | `"语文"` | 模式 B | ✅ |
| `"语文"` | `"语文_g7-9"` | 模式 B | ❌ |

**⚠️ 已识别的潜在问题**：CP1 domain `"数学"` 同时匹配 `"数学_g10-12"` 和 `"数学_g1-2"` 两个 tab。如果用户有多个数学学段，卡片会出现在所有数学 tab 中。

### 4.4 ReviewScreen UI Widget 映射

#### 整体结构

```
review_screen.dart
  ├── _ReviewScreenState
  │   ├── _cards: List<DueCard>        ← GET /api/review/due 结果
  │   ├── _plans: List<Map>            ← GET /api/plans 结果（用于 tab 生成）
  │   ├── _domainFilter: String?       ← 当前选中的 tab domain
  │   ├── _isLoading: bool
  │   │
  │   ├── _loadDueCards()              ← 初始化 / 下拉刷新时调用
  │   │   └── GET /api/review/due?user_id={uid} → _cards
  │   │
  │   ├── _loadPlans()                 ← 初始化时调用，提取 domain 列表
  │   │   └── GET /api/plans?user_id={uid} → 提取 DISTINCT domain → tab 列表
  │   │
  │   ├── get _planTabs: List<String>  ← tab 标题列表
  │   │   从 _plans 提取 domain，去重排序
  │   │   例: ["全部", "数学_g10-12", "语文", "语文_g7-9"]
  │   │
  │   ├── get _filteredCards            ← 【关键契约】过滤逻辑
  │   │   代码:
  │   │     if (_domainFilter == null) return _cards;
  │   │     if (_domainFilter!.contains('_')) {
  │   │       // 模式 A: 带学段后缀 → 前缀匹配
  │   │       final base = _domainFilter!.split('_').first;
  │   │       return _cards.where((c) =>
  │   │           c.domain == _domainFilter ||
  │   │           (c.domain != null && !c.domain!.contains('_') && c.domain == base)).toList();
  │   │     }
  │   │     // 模式 B: 纯学科名 → 精确匹配
  │   │     return _cards.where((c) => c.domain == _domainFilter).toList();
  │   │
  │   ├── get _domainDueCount(domain)  ← tab 角标数字
  │   │   同样按模式 A/B 匹配，返回 count
  │   │
  │   └── _onCardRated(cardId, rating)  ← 复习评分后回调
  │       └── 从 _cards 中移除已评分的卡
  │
  ├── build()
  │   ├── TabBar (domain tabs)         ← _planTabs 渲染
  │   ├── TabBarView
  │   │   └── ReviewCardList
  │   │       ├── DueCard 列表（_filteredCards 渲染）
  │   │       ├── 翻牌交互 (front → tap → back)
  │   │       ├── 验证区
  │   │       │   ├── 打字验证: TextField + submit
  │   │       │   └── AI 问答: 3 轮依次展示
  │   │       └── 评分按钮 (Again/Good)
  │   └── 空状态: "暂无到期复习" (当 _filteredCards 为空)
  ```

#### DueCard 数据契约

```json
{
  "id": "uuid",
  "front": "卡片正面文本",
  "back": "卡片背面文本",
  "domain": "数学|语文|vocabulary",    // ← 前端 filter 的依据
  "card_type": "concept|vocab|word|reading",
  "state": 0,          // 0=New, 1=Learning, 2=Review, 3=Relearning
  "due": 1717113600,   // Unix 时间戳
  "reps": 3,
  "source_sentence": "对话上下文来源"
}
```

#### 状态机

```
页面初始化
  │
  ├─→ _loadPlans() + _loadDueCards()
  │      │              │
  │      ▼              ▼
  │  [加载 tab]    [加载卡片] ← loading indicator
  │      │              │
  │      ▼              ▼
  │  Tab列表就绪    _cards 就绪
  │      │              │
  │      └──────┬───────┘
  │             ▼
  │      ┌──────────────┐
  │      │  _cards 为空? │
  │      └──────┬───────┘
  │        是    │  否
  │         ▼    ▼
  │     [empty]  [data]
  │     "暂无     TabBar + 卡片列表
  │     到期复习"
  │
  └─→ 用户点击 tab → _domainFilter 更新 → _filteredCards 更新 → UI 刷新
```

#### Tab 角标计算

```
每个 tab 显示数字: _domainDueCount(tab.domain)
  例: "数学_g10-12" → 按模式 A 匹配 → 12 张到期
  "全部" → _cards.length
  "语文" → 按模式 B 精确匹配 → 5 张到期
```

### 4.5 过去事故映射

| 事故 | 断裂模式 | 根因 | 修复 |
|:-----|:---------|:-----|:-----|
| 语文 g1-2/g7-9 重复 | 模式 B 缺精确匹配 | 纯 `"语文"` 也用前缀匹配 | 区分纯学科名 vs 带学段后缀 |
| CP1 卡不出现 | API limit 不足 | `LIMIT 20` 排不到数学卡 | 改为 `LIMIT 500` |
| Plan 进度不显示 | API 查询路径错 | 读 `plan_json.stages` 但被 CP2 改写 | 回退到 `plan_content` |

---

## 5. Learning Plan（学习计划管线）

### 5.1 架构定位

```
Flow F/N8 — 结构化学习管线的核心。
贯穿 Hot Path（prompt 注入 plan_ctx）、Cold Path（CP2 推进）、
和数据库状态（plan_content + plan_json）。
```

### 5.2 数据双轨结构

这是当前系统**最容易混淆的设计**。学习计划在 DB 中由**两个字段**共同表达：

```
learning_plans 表:
┌──────────────────────────────────────────────────────────────┐
│ plan_content  TEXT   — 静态结构（stages/tasks 的模板）        │
│                       例: {"stages":[{"name":"几何变换",      │
│                            "tasks":[{"name":"尺规作图"},     │
│                                      {"name":"坐标系"}]}]}  │
│                                                              │
│ plan_json     TEXT   — 动态状态（task_status 的运行时状态）   │
│                       例: {"task_status":{                   │
│                            "尺规作图":"done",                │
│                            "坐标系":"in_progress"}}          │
│                                                              │
│ 合并规则: plan_content（结构）+ plan_json（状态）→ 完整 plan  │
│ 来源: `apply_plan_mutations()` 和 `build_plan_context()`     │
└──────────────────────────────────────────────────────────────┘
```

**数据流向**：

```
               plan_content                          plan_json
               ───────────                          ─────────
k12/init 写入  预置课程模板(stages/tasks)          初始 task_status={}
CP2 推进后     不变                                task_status.xxx="done"
apply_plan_mutations()   ← 读取合并两个字段 →   新 plan_json(w/ embedded stages)
build_plan_context()     ← 读取合并两个字段 →   供 LLM 的 plan 上下文
learning_report          ← 从 plan_content 读   ← 或从 plan_json.task_status 读 状态
```

### 5.3 Plan 创建入口差异

| 模式 | 创建方式 | plan_content 来源 | plan_json 初始状态 |
|:-----|:---------|:------------------|:------------------|
| **自由对话** | CP2 检测教学内容 → LLM 生成 JSON | LLM 生成的 stages/tasks | `task_status: {task1: "pending", ...}` |
| **K12 结构化** | `POST /api/k12/init` | 从预置 plan JSON 文件读取 | `task_status: {task1: "in_progress", ...}`（首任务激活） |
| **K12 阅读** | `POST /api/k12/reading/init` | 从预置 reading_plans 目录读取 | `task_status` 包含所有课文 |

**session 续接逻辑**（`k12/init` 和 `k12/reading/init`）：

```
1. 查询已有 conversations: user_id + subject + grade_band + deleted_at IS NULL
2. 如果有 → 返回已有 conversation_id (resumed=true)
3. 如果没有 → 创建新 conversation，生成 plan
4. ⚠️ 先 DELETE 同 subject+grade_band 的旧 plan（2026-05-30 修复前误删了所有学段）
```

### 5.4 Plan 状态推进链

```
Teacher LLM 输出 "几何变换学习已经完成" (task完成信号)
  │
  ▼
CP2 `analyze_turn_progress()`
  → LLM 判断: `{"action": "complete_task", "reason": "..."}`
  │
  ▼
`handle_plan_update()`
  → `apply_plan_mutations()` ← 合并 plan_content + plan_json
  → UPDATE plan_json.task_status.{task_name} = "done"
  → 查找下一个任务 → 标记 "in_progress"
  │
  ▼
`build_plan_context()` 下次注入 Teacher prompt
  → Teacher 看到新任务名称
  │
  ▼
前端收到 `plan_updated` WS
  → `_loadPlan()` → GET /api/plans → 刷新 plan 面板
```

**正确性校验点**：
- `plan_json.task_status` 中 `done` 计数与预期一致
- `plan_content` 未被 CP2 改写（保持原始结构）
- `plan_updated` 通过 mpsc channel 成功送达前端
- 前端 `_loadPlan()` 调用后 plan 面板显示正确

### 5.5 过去事故映射

| 事故 | 断裂模式 | 根因 | 修复 |
|:-----|:---------|:-----|:-----|
| `apply_plan_mutations` 不注入 task_status | plan_json 格式 | 旧实现只读 stages，但 plan_json 已是 `{task_status:{}}` | 注入 task_status 到每个 task 对象 |
| stage 无 status 默认值 | 代码鲁棒性 | `stage["status"] == "in_progress"` 返回 false | 加 `unwrap_or("pending")` |
| k12/init 误删所有学段 plan | DELETE WHERE 不精确 | `domain = subject` 不区分学段 | 改为 `domain = subject_grade_band` |
| learning_report 读不到进度 | 双轨读取路径缺失 | 只读 `plan_json.stages` 不回退到 plan_content | 加回退逻辑：`compute_plan_totals()` |

---

## 6. Achievement System（成就系统）

### 6.1 架构定位

```
Flow D — 附属于制卡和复习的被动触发器，不独立存在。
```

### 6.2 成就数据流

```
制卡完成 (N4)
  │
  ▼
N7 成就检测 (achievements.rs)
  → 统计: total_cards, total_reviews, streak_days, domains_covered
  → 检查条件: 已满足但未解锁 → INSERT achievements
  → 返回 new_achievements[] 给调用方
  │
  ▼
学习报告 API 聚合:
  GET /api/user/{uid}/learning-report
  → 遍历 learning_plans → 计算 done_tasks/total_tasks
  → 读取 achievements 表 → tier 汇总
```

### 6.3 成就层级与计划绑定

```
固定成就（阈值触发）:
  ┌─────────────┬──────────────┬────────┐
  │ 成就         │ 条件          │ 层级   │
  ├─────────────┼──────────────┼────────┤
  │ 初识         │ 第1张卡       │ fixed  │
  │ 收集者       │ 50张卡        │ fixed  │
  │ 图书馆       │ 200张卡       │ fixed  │
  │ 学者         │ 500张卡       │ fixed  │
  │ 坚持3天      │ 连续3天       │ fixed  │
  │ 坚持7天      │ 连续7天       │ fixed  │
  │ 坚持30天     │ 连续30天      │ fixed  │
  │ 探索者       │ 3个领域       │ fixed  │
  │ 博学家       │ 5个领域       │ fixed  │
  │ 百炼         │ 100次复习     │ fixed  │
  │ 千锤         │ 1000次复习    │ fixed  │
  └─────────────┴──────────────┴────────┘

动态成就（学习计划绑定）:
  task done    → bronze  / "{task_name}入门"
  stage done   → silver  / "{stage_name}精英"
  domain done  → gold    / "{domain}大师"
  cross-domain → platinum/ "{goal}宗师"
```

### 6.4 AchievementsScreen UI Widget 映射

#### 整体结构

```
achievements_screen.dart
  ├── _AchievementsScreenState
  │   ├── _data: Map?           ← GET /api/user/{uid}/learning-report
  │   ├── _activityData: Map?   ← GET /api/activity?user_id={uid}&days=90
  │   ├── _k12Progress: List    ← GET /api/k12/progress?user_id={uid}
  │   ├── _calendarMonth        ← 热力图当前月份
  │   └── _isLoading: bool
  │
  ├── initState() → _loadAll()  ← 3 个 API 并行拉取
  │
  └── build()
      ├── 🔥 连续学习天数 + 累计复习（_data['stats']）
      │     读取: streak_days, total_reviews
      │
      ├── 📊 学习统计卡片
      │     读取: total_cards, today_reviews, domains_covered
      │
      ├── 🗓️ 学习热力图（_activityData）
      │     字段: days[].{date, reviews, score}
      │     渲染: 月历网格，月份导航，Tooltip 详情
      │
      ├── 📚 K12 学习进度（_k12Progress）
      │     字段: subject, grade_band, total_cards, mastered_cards
      │     渲染: 按学科分组 → 学段进度条 + 百分比
      │
      └── 📖 词汇掌握度（_data['cefr_stats']）
            字段: level, count, max_count
            渲染: CEFR 等级进度条 + 总计
```

#### 3 个 API 的关键字段

```json
// learning-report 主数据源
{"stats":{"total_cards":42,"total_reviews":156,"streak_days":7},
 "cefr_stats":[{"level":"A1","count":12,"max_count":150}],
 "plans":[{"goal":"K12: 数学 g10-12","done_tasks":4,"total_tasks":37}]}

// k12/progress
{"progress":[{"subject":"数学","grade_band":"g10-12","total_cards":37,"mastered_cards":4}]}

// activity
{"days":[{"date":"2026-05-30","reviews":12,"score":85,"cards":3}]}
```

#### 过去事故

| 事故 | 断裂层 | 根因 |
|:-----|:-------|:-----|
| K12 进度不显示 | API | `learning_report` 只读 `plan_json.stages`，但 CP2 改写后 plan_json 只剩 `task_status` |
| done_tasks/total_tasks 为 0 | API | 只读 plan_json 不做回退，修复后从 plan_content 合入 |

---

## 7. Data Store（数据存储）

### 7.1 表结构与节点映射

```
┌────────────────────────────────────────────────────────────────────────────┐
│                           SQLite (coevo.db, ~5MB)                          │
│                                                                            │
│  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐      │
│  │ users             │    │ cards             │    │ card_memory       │      │
│  │ N1 鉴权           │    │ N2 去重查询       │    │ N4 初始创建       │      │
│  │ N7 streak_days    │    │ N3 格式化输出     │    │ N5 队列筛选       │      │
│  └──────────────────┘    │ N5 复习队列       │    │ N6c 每次更新     │      │
│                          │ N6a UI展示        │    └──────────────────┘      │
│                          └──────────────────┘                               │
│                                                                            │
│  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐      │
│  │ conversations     │    │ conversation_    │    │ review_log        │      │
│  │ Flow F 生命周期   │    │ turns            │    │ N6c 每次写入     │      │
│  │ N1 会话管理      │    │ N1 历史上下文     │    │ N7 计数          │      │
│  └──────────────────┘    │ N2 概念提取输入   │    └──────────────────┘      │
│                          └──────────────────┘                               │
│                                                                            │
│  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐      │
│  │ learning_plans    │    │ achievements      │    │ skipped_concepts  │      │
│  │ N8 创建/更新     │    │ N7 写入          │    │ N2 去重          │      │
│  │ CP2 推进         │    │ API 聚合读取     │    │ Flow E 跳过管理  │      │
│  │ Flutter 面板      │    └──────────────────┘    └──────────────────┘      │
│  └──────────────────┘                                                       │
│                                                                            │
│  ┌──────────────────┐                                                      │
│  │ user_preferences  │                                                      │
│  │ Flow G 用户偏好  │                                                      │
│  │ subscription     │                                                      │
│  └──────────────────┘                                                      │
└────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 关键索引

| 表 | 索引 | 用途 |
|:---|:-----|:-----|
| `cards` | `(user_id, domain)` | N5 复习队列按用户+领域过滤 |
| `card_memory` | `(user_id, due)` | N5 due 排序 |
| `learning_plans` | `(user_id, domain)` UNIQUE | N8 唯一约束 |
| `conversations` | `(user_id, deleted_at)` | 会话列表查询 |

### 7.3 备份与安全

| 项目 | 策略 |
|:-----|:------|
| DB 备份 | 每日 03:00 crontab `.backup` + gzip，保留 7 天 |
| PII 加密 | AES-256-GCM 加密 real_name/phone/id_number，密钥 `COEVO_PII_KEY` |
| DB 操作底线 | 禁止直接 DML/DDL；SELECT 需带 WHERE |

---

## 8. 跨层诊断协议

### 8.1 通用诊断流程

当用户报任何 GUI 问题时，按此协议定位断裂层：

```
用户: "[屏幕 X] 的 [功能 Y] 不正常"
  │
  ▼
Step 1: 确定断裂层 ← 如果是前后端交互问题，按"三层追溯法"
  │
  ├─ GUI 层: 前端收到了什么数据? filter 逻辑是否正确?
  │   验证: 通过 Web Inspector / 直接 API 调用复现
  │
  ├─ API 层: 后端返回的是什么? handler 逻辑是否正确?
  │   验证: curl API 端点，检查 JSON 响应
  │
  └─ DB 层: 数据存在吗? 格式正确吗?
      验证: SELECT 查询，检查字段值
```

### 8.2 分屏幕快速验证

| 屏幕 | 一句话验证 | 如果失败··· |
|:-----|:-----------|:------------|
| **ChatScreen** | WS 发送消息 → 收到 `done` + `candidates` + `plan_updated` | check WS handler / CP1/CP2 日志 |
| **ReviewScreen** | `GET /api/review/due?user_id=X` 返回 >0 条 | check N5 SQL / card_memory due |
| **Achievements** | `GET /api/user/X/learning-report` 的 plans >0 | check learning_plans 表 |
| **Profile** | `GET /api/user/profile` 的 display_name 非空 | check 加密/鉴权 |
| **ConversationList** | `GET /api/conversations?user_id=X` 返回列表 | check conversations 表 |

### 8.3 Plan 诊断步骤

```bash
# 1. 查看该 conversation 的 plan 是否存在
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> "
  sudo sqlite3 /opt/coevo/data/coevo.db \"
  SELECT id, conversation_id, goal, mode, updated_at
  FROM learning_plans
  WHERE user_id = 'user_xxx' ORDER BY updated_at DESC LIMIT 5;\"
"

# 2. 查看 plan 状态
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> "
  sudo sqlite3 /opt/coevo/data/coevo.db \"
  SELECT goal, length(plan_json), substr(plan_json,1,200)
  FROM learning_plans WHERE conversation_id = 'uuid';\"
" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read().strip())
ts = d.get('task_status', {})
done = [k for k,v in ts.items() if v=='done']
print(f'已完成: {len(done)}/{len(ts)} 个任务')
if done: print(f'已完成任务: {done}')
"

# 3. 通过 API 检查前端能看到什么
curl -s 'https://keyievolution.fun/api/plans?conversation_id=uuid' \
  -H 'Authorization: Bearer <token>'
```

### 8.4 Domain 诊断步骤

```bash
# 1. 检查 plan domain vs card domain 是否对齐
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> "
  echo '=== Plan domains ==='
  sudo sqlite3 /opt/coevo/data/coevo.db \
    \"SELECT DISTINCT domain FROM learning_plans ORDER BY domain;\"
  echo ''
  echo '=== Card domains ==='
  sudo sqlite3 /opt/coevo/data/coevo.db \
    \"SELECT DISTINCT domain, count(*) FROM cards GROUP BY domain ORDER BY domain;\"
"

# 2. 验证前端 filter 能否匹配
# 检查 tab domain 与 card domain 的关系:
#   tab "数学_g10-12" ← 前缀匹配 → card "数学" ✅
#   tab "语文"        ← 精确匹配 → card "语文" ✅
#   tab "语文"        ← 精确匹配 → card "语文_g7-9" ❌
```

### 8.5 WS 诊断步骤

```bash
# 检查 CP1/CP2 是否正常触发
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> "
  grep -i 'cp2.*complete\|Plan mutation\|candidates' \
    /opt/coevo/data/logs/coevo.log.$(date +%Y-%m-%d) 2>/dev/null | tail -10
"

# 如果 candidates 为空: 检查 plan 是否存在
# 如果 plan_updated 无: 检查 cp2_tx channel
```

### 8.6 常见问题 FAQ

| 用户说 | 诊断方向 | 解答 |
|:-------|:---------|:------|
| "我发了两条消息，为什么第二条没看到 plan 更新？" | CP1/CP2 顺序 | `tokio::spawn` 不保证顺序。如果用户在 done → plan_updated 之间又发了一条消息，新轮的 CP1/CP2 会覆盖上一轮的。Plan 状态存在 DB，最终会有一轮 CP2 推进它 |
| "我刷新页面为什么进度丢了？" | 状态持久化 | Plan 状态 (task_status) 存在 `learning_plans.plan_json` 中，刷新后 `_loadPlan()` 重新拉取，不会丢。如果丢了说明 `plan_json` 写入失败，检查 CP2 日志 |
| "我复习了一半退出了，下次会从头开始吗？" | 复习状态保持 | `review_screen` 每次 initState 重新加载 `GET /api/review/due`。已经评分过的卡 POST /review/submit 后从 due 队列消失。未评分的卡下次仍然到期 |
| "我点了跳过，以后还能再看到这个知识点吗？" | 跳过管理 | 跳过写入 `skipped_concepts` 表。如需恢复：`DELETE /api/cards/skipped/{skip_id}` |
| "成就页的数字和对话页的 plan 不一样" | 数据源一致性 | 成就页读 `learning-report` API (task 数统计)，对话页读 `GET /api/plans` (plan_json)。task 进度 vs 卡片掌握度是两个概念 |
| "为什么自由对话没有 plan 面板？" | 自由对话模式 | 正确行为。CP2 需先检测到教学意图才创建 plan。第 2 轮起 plan 面板可见 |
| "复习页有个奇怪的 UUID tab" | UUID 过滤 | 2026-05-31 已修复。前端过滤了 domain 含 `-` 的 plan。如仍然看到，说明前端未更新 |

---

## 9. 契约偏离清单

原始设计文档与当前代码实现之间的已知偏差：

| # | 设计文档表述 | 当前实现 | 影响 | 状态 |
|:-:|:------------|:---------|:-----|:-----|
| 1 | `domain = conversation_id` (N8 唯一约束) | **已改为** `domain = subject_grade_band` (k12/init) + `conversation_id` (自由对话) | plan 按学段分组而非按对话 | ✅ 与设计一致 |
| 2 | N5 `LIMIT 20` | **已改为** `LIMIT 500` (2026-05-31) | 前端一次加载所有到期卡 | ✅ 修复 |
| 3 | N2 概念提取 "每轮都跑" | **已改为** "只在有 plan 时跑" (2026-05-31) | 减少无用 LLM 调用 | ✅ 修复 |
| 4 | N8 `plan_updated` "发 done + plan_updated WS 事件" | HotPath 正常，**ColdPath(CP2) 缺 plan_updated** → 后加 mpsc channel | 修复已完成 | ✅ 修复 |
| 5 | `plan_content` 与 `plan_json` 双轨分离 | 实现 OK，但 `learning_report` 一开始只读了 `plan_json.stages` | 数据存在但读不到 | ✅ 修复 |
| 6 | N6b 验证 "打字/AI三联问" | 前端有 `LanguageVerificationStrategy`，但 `AchievementsScreen` 无验证入口 | 验证入口未完整实现 | ⚠️ 待确认 |
| 7 | 对话流式 token 描述 | 实现 OK | - | ✅ 匹配 |
| 8 | **CP1 去重: 应包含 task 已绑定的预置卡 fronts** | 当前 `build_plan_context` 不输出 task 的预置卡 fronts | `unlock_next_cards` 异步导入的卡在 CP1 启动时可能尚未入库；即使已入库，LLM 也可能用不同措辞提取语义重复概念 | 🔴 **待实现** |

**#8 待实现的修复方向**：

在 `build_plan_context()` 中，读取当前 in_progress task 的 `gold_cr_ids`/`vocab_card_ids`/`reading_card_id`：
1. 从 `curriculum_loader::get_cards()` 或 `reading_loader::get_card()` 查预置卡数据
2. 提取这些卡的 `front` 字段值
3. 追加到 plan context 字符串末尾（如：`当前 task 已绑定的卡片: 集合的定义、元素与集合的关系`）
4. 此操作不依赖 `unlock_next_cards` 是否已执行

受益路径：
- CP1 的 `{plan_context}` → LLM 看到已绑卡，避免语义重复提取（双层去重：LLM 语义层 + 算法精确层）
- Teacher prompt 的 plan_ctx → 教师知道自己给过什么材料
- CP2 的 plan_ctx → 更精确判断当前 task 完成

涉及文件：
- `plan_handler.rs`（`build_plan_context` 函数，追加预置卡 fronts 到 ctx 字符串）

---

## 10. 附录: 原始设计与现状对照

### 10.1 节点落地状态

| 节点 | 设计文档 | 当前实现文件 | 完成度 |
|:-----|:---------|:------------|:------:|
| N1 AI 对话 | `llm_caller.rs` + `chat_screen.dart` | `chat_engine/src/llm_caller.rs`, `app/lib/screens/chat_screen.dart` | ✅ 完整 |
| N2 概念提取 | `concept_extractor.rs` | `chat_engine/src/concept_extractor.rs` | ✅ 完整(2026-05-31 加 plan_context) |
| N3 卡片格式化 | `card_formatter.rs` | `card_engine/src/card_formatter.rs` | ✅ 完整 |
| N4 卡片入库 | `card_repository.rs` | `card_engine/src/card_repository.rs` | ✅ 完整 |
| N5 FSRS 队列 | `fsrs_scheduler.rs` | `card_engine/src/fsrs_scheduler.rs` | ✅ 完整(limit 已改 500) |
| N6a 翻牌 | (Flutter) | `app/lib/screens/review_screen.dart` | ✅ 完整 |
| N6b 验证 | `verify.rs` | `card_engine/src/verify.rs` | ✅ 完整 |
| N6c 评分 | `POST /api/review/submit` | `routes.rs` | ✅ 完整 |
| N7 成就 | `achievements.rs` | 复用 LinguaFlow | ✅ 完整(缺少跨域成就？待确认) |
| N8 学习计划 | `plan_handler.rs` | `api_server/src/plan_handler.rs` | ✅ 完整(2026-05-30/31 多次修复) |

### 10.2 原始设计文档引用

| 文档 | 路径 | 最后更新 | 适用性 |
|:-----|:------|:---------|:-------|
| DevPlan V3.0 | `E:\CoEvo\CoEvo_Devplan.md` | 2026-05-07 | 产品概念层，节点框架 |
| 数据流分析 | `E:\CoEvo\CoEvo_DataFlow.md` | 2026-05-07 | 流程设计层，API 契约 |
| 代码审查报告 | `docs/code-review-2026-05-16.md` | 2026-05-16 | 安全/代码质量 |
| CP2 评估报告 | `docs/architecture/cp2-eval-report-2026-05-30.md` | 2026-05-30 | CP2 修复评估 |
| 部署指南 | `docs/deploy/web-deploy-guide.md` | 2026-05-31 | 运维操作 |
| 维护规范 | `docs/operations/maintenance-spec.md` | 2026-05-31 | 生产纪律 |

---

## 修订记录

| 版本 | 日期 | 修改人 | 变更内容 |
|:-----|:-----|:-------|:---------|
| v1.0 | 2026-05-31 | Qi | 初始版本（按屏幕分块） |
| v2.0 | 2026-05-31 | Qi | **重写为体系架构版**: 三流架构 → 节点 → UI 映射 → 契约偏离清单。整合原始开发文档与当前代码 |

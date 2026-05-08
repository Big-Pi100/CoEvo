# 刻意进化学习 · coevo — 开发计划 V3.0 定稿

> **如果不想被 AI 取代，你需要刻意进化。**
>
> AI 对话中自动提取概念、用户确认制卡、FSRS 调度复习、客观验证内化。
> Rust + Flutter · TDD 先行 · 3-4 周 MVP

---

## 〇、品牌

| 层级 | 内容 |
|------|------|
| **品牌** | 刻意进化 |
| **产品** | 刻意进化学习 |
| **英文** | coevo |
| **Slogan** | 如果不想被AI取代，你需要刻意进化。 |
| **品牌故事** | 每一次AI对话，每一次刻意复习，都是你的进化。 |

```
刻意进化
 coevo
━━━━━━━━━━━━━━━━
不想被AI取代
你需要刻意进化
```

---

## 一、产品定位

### 一句话

> AI 对话中自动发现值得记住的概念，用户确认即制卡，按记忆曲线复习，通过客观验证完成内化。

### 核心理念

```
用户和 AI 对话学习任何东西
    → 每轮对话后，系统自动提取候选概念
    → 用户勾选确认，或对话中直接说"把XX制成卡片"
    → 按 FSRS 记忆曲线在最佳时间弹出复习
    → 翻牌回忆 + 客观验证（打字/快问快答）
    → 日积月累，刻意记住 → 真正进化
```

### 对标差异化

| | Anki | ChatGPT | 刻意进化 |
|------|------|---------|---------|
| AI 对话 | ❌ | ✅ | ✅ |
| 自动提取概念 | ❌ | ❌ | **✅** |
| 用户确认制卡 | ❌ | ❌ | **✅** |
| 记忆曲线 | ✅ | ❌ | **✅ FSRS** |
| 客观验证 | ❌ | ❌ | **✅ 打字/AI快问快答** |
| 通用领域 | ✅ | ✅ | ✅ |

---

## 二、制卡流程（完整）

```
每次对话结束
    │
    ▼
┌─────────────────────────────────────────┐
│ N2 检测用户消息                          │
│                                         │
│ 包含"制卡"/"记住"等意图？                 │
│   ├─ 是 → LLM 生成卡片 → N4 入库         │
│   └─ 否 ↓                               │
│         LLM 提取候选概念（最多 5 个）      │
│         去重：vs 已有卡片 + vs 跳过记录    │
│         去重后为空 → 不弹窗（零打扰）      │
│         有剩余 → 弹窗展示                 │
│              ├─ 用户勾选 → N4 入库        │
│              └─ 用户跳过 → 写入跳过记录    │
└─────────────────────────────────────────┘
```

### 两条制卡路径

| 路径 | 触发 | 场景 |
|------|------|------|
| **对话后建议** | 每轮对话结束 | 系统提取候选，用户勾选确认 |
| **对话指令** | 用户对 AI 说"把XX制成卡片" | LLM 根据上下文直接生成卡片 |

### 跳过记录

```sql
skipped_concepts (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    front TEXT NOT NULL,
    domain TEXT,
    source_text TEXT,
    skipped_at INTEGER
)
```

**原则**：用户主动制卡（对话指令）时，若匹配到跳过记录，自动移除跳过记录——当前意图优先。

---

## 三、复习流程（完整）

```
N5 调度到期卡片
    │
    ▼
N6a 翻牌
  看到正面，尝试回忆，点击翻转看反面
    │
    ▼
N6b 验证（客观，不依赖自我判断）
    │
    ├─ 语言类：打字输入
    │     看词写释义 / 看释义写词 / 听发音写词
    │     正确 → pass   错误 → fail
    │
    └─ 通用类：AI 三轮快问快答
          LLM 根据卡片内容生成三个问题
          测试用户是否真正理解
          3/3 或 2/3 → pass
          1/3 或 0/3 → fail
    │
    ▼
N6c 评分 → FSRS 更新记忆状态
  通过 → Good
  未通过 → Again
```

---

## 四、节点定义

### N1: AI 对话

| 属性 | 值 |
|------|-----|
| **位置** | 后端 Rust |
| **技术** | DeepSeek V4 Flash / Qwen3 Max，OpenAI 兼容 API |
| **输入** | 用户消息 + 最近 10 轮历史 |
| **输出** | 流式 AI 回复 |

---

### N2: 意图识别 + 概念提取

| 属性 | 值 |
|------|-----|
| **位置** | 后端 Rust（每轮对话后触发） |
| **输入** | 用户消息 + AI 回复 + user_id |
| **输出** | 候选概念列表 或 直接生成的卡片 |

**逻辑**：

```
1. 检测用户消息是否包含制卡意图关键词
   是 → 调用 LLM 生成卡片 → 进入 N4

2. 否 → 调用 LLM 提取候选概念（最多 5 个）
        → 去重（vs 已有卡片 + vs 跳过记录）
        → 去重后为空：不弹窗
        → 有剩余：返回给客户端展示
```

---

### N3: 卡片格式化

| 属性 | 值 |
|------|-----|
| **位置** | 后端 Rust（纯函数） |
| **输入** | 概念数据 |
| **输出** | `Card` + 初始 `CardMemory`（state=New） |

---

### N4: 卡片入库

| 属性 | 值 |
|------|-----|
| **位置** | 后端 Rust |
| **输入** | `Card` + `CardMemory` |
| **逻辑** | 去重（front 相似度 > 0.85 跳过）+ 写入 |

---

### N5: 待复习队列

| 属性 | 值 |
|------|-----|
| **位置** | 后端 Rust |
| **算法** | FSRS（`fsrs` crate） |
| **输入** | `user_id` + 当前时间 |
| **输出** | 到期卡片列表（按 due 升序，上限 20 张） |

**FSRS 状态**：New → Learning → Review → Relearning
**评分**：Again(1) / Hard(2) / Good(3) / Easy(4)

---

### N6: 复习交互 + 验证

| 属性 | 值 |
|------|-----|
| **位置** | 客户端 Flutter + 后端 Rust |

**N6a 翻牌**：显示正面 → 用户回忆 → 点击翻转 → 显示反面 + 来源句

**N6b 验证**：

| 卡片类型 | 验证方式 | 实现 |
|---------|---------|------|
| 语言类 | 打字输入 | 文本匹配，不需要 LLM |
| 通用类 | AI 三轮快问快答 | LLM 生成问题，判断对错 |

**N6c 评分**：通过→Good，未通过→Again，更新 FSRS 状态

---

### N7: 成就检测

| 属性 | 值 |
|------|-----|
| **位置** | 后端 Rust |
| **触发** | 每次制卡后 + 每次复习后 |

**成就列表**：

| 成就 | 条件 |
|------|------|
| 初识 | 第一张卡片 |
| 收集者 | 50 张卡片 |
| 图书馆 | 200 张卡片 |
| 学者 | 500 张卡片 |
| 坚持3天 | 连续 3 天复习 |
| 坚持7天 | 连续 7 天复习 |
| 坚持30天 | 连续 30 天复习 |
| 探索者 | 覆盖 3 个领域 |
| 博学家 | 覆盖 5 个领域 |
| 百炼 | 累计复习 100 次 |
| 千锤 | 累计复习 1000 次 |

---

## 五、节点汇总

| 节点 | 位置 | 负责 |
|------|------|------|
| N1 | 后端 | AI 对话 |
| N2 | 后端 | 意图识别 + 概念提取 + 去重 |
| N3 | 后端 | 卡片格式化 |
| N4 | 后端 | 卡片入库 |
| N5 | 后端 | 待复习队列（FSRS） |
| N6 | 客户端+后端 | 翻牌 + 验证 + 评分 |
| N7 | 后端 | 成就检测 |

**7 个节点 · 8 张表 · 1 天 MVP 核心完成**

---

## 六、数据库设计 (8 张表)

```sql
-- 1. 用户
users (
    id TEXT PRIMARY KEY,
    username TEXT,
    password_hash TEXT,
    streak_days INTEGER DEFAULT 0,   -- 连续复习天数 (N7)
    last_active_date TEXT,           -- 最后活跃日期
    created_at TEXT
)

-- 2. 会话容器 (N1 对话持久化)
conversations (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    turn_count INTEGER DEFAULT 0,
    started_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
)

-- 3. 对话轮次 (N1 历史上下文 + N2 概念提取)
conversation_turns (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id)
)

-- 2. 卡片
cards (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    domain TEXT,
    card_type TEXT,        -- "vocabulary" | "concept"
    front TEXT NOT NULL,
    back TEXT NOT NULL,
    source_sentence TEXT,
    created_at INTEGER,
    FOREIGN KEY (user_id) REFERENCES users(id)
)

-- 3. 记忆状态 (1:1 cards)
card_memory (
    card_id TEXT PRIMARY KEY,
    state INTEGER,         -- 0:New, 1:Learning, 2:Review, 3:Relearning
    difficulty REAL,
    stability REAL,
    due INTEGER,
    last_review INTEGER,
    reps INTEGER,
    lapses INTEGER,
    FOREIGN KEY (card_id) REFERENCES cards(id)
)

-- 4. 复习日志
review_log (
    id TEXT PRIMARY KEY,
    card_id TEXT NOT NULL,
    rating INTEGER,        -- 1-4
    verification_type TEXT,-- "spelling" | "ai_dialogue"
    verification_result TEXT, -- "pass" | "fail"
    reviewed_at INTEGER,
    FOREIGN KEY (card_id) REFERENCES cards(id)
)

-- 5. 成就
achievements (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    achievement_key TEXT,
    unlocked_at INTEGER,
    FOREIGN KEY (user_id) REFERENCES users(id)
)

-- 6. 跳过记录
skipped_concepts (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    front TEXT NOT NULL,
    domain TEXT,
    source_text TEXT,
    skipped_at INTEGER,
    FOREIGN KEY (user_id) REFERENCES users(id)
)
```

---

## 七、技术栈

| 层 | 技术 |
|----|------|
| 后端 | Rust (axum + tokio) |
| 客户端 | Flutter 3.x (iOS + Android) |
| 数据库 | SQLite (rusqlite + Drift) |
| 记忆算法 | fsrs crate (FSRS-5) |
| LLM | OpenAI 兼容 API |
| 通信 | REST + WebSocket |
| 跨语言类型 | REST JSON + 手动 Dart 类型 |

---

## 八、实施计划（已全部完成 ✅）

```
2026-05-07 第一天完成全部 MVP 核心功能

✅ W1 ─────────────────────────
  项目脚手架
  数据库 Schema + Migration (8 表)
  用户认证 (注册/登录/Token)
  N1 AI 对话 (REST + WebSocket 流式)

✅ W2 ─────────────────────────
  N2 意图识别 + 概念提取 (含去重 + 过滤占位)
  N3 卡片格式化 (纯函数)
  N4 卡片入库（Jaro-Winkler 去重 + 事务）
  FSRS 调度 (手动实现简化版状态机)

✅ W3 ─────────────────────────
  N5 待复习队列 (到期查询 + streak 签到)
  N6 翻牌 + 验证（打字 + AI 快问快答批量判断）
  N7 成就检测 (11 个成就)

🔄 W4 ─────────────────────────
  ✅ 跳过记录 API + 管理
  ✅ E2E 测试 (26 个)
  ✅ 对话上下文窗口优化 (5000 字滑动)
  ✅ 卡片列表排序实现
  ✅ 成就前端展示 + 庆祝动画
  ⏭️ 部署上线 (Docker) — 已确认跳过
  ⏳ UI 打磨 (部分完成: 气泡颜色/空状态)

--- 新增功能 (超出原计划) ---
  ✅ WebSocket 流式对话 (打字机效果)
  ✅ 对话历史持久化 + 跨页面恢复
  ✅ 批量制卡 API + 前端确认弹窗
  ✅ 卡片搜索/状态过滤/领域过滤
  ✅ 学习计划队列视图 (搜索+过滤)
  ✅ Prompt 外部化 (文件驱动)
  ✅ TTS 朗读 (flutter_tts)
  ✅ 语音输入 (speech_to_text, 微信风格长按)
  ✅ 卡片详情弹窗
  ✅ 对话列表页面 (会话管理+切换)
  ✅ 词库英文词汇匹配 (cefr_catalog.json, 10万词)
  ✅ 个人页真实统计 + 成就展示
  ✅ 跳过记录管理页 (查看/取消跳过)
```

---

## 九、设计原则

```
1. 系统不替用户决定什么值得学，系统建议，用户确认
2. 跳过的概念不再骚扰，主动制卡覆盖跳过记录
3. 复习不依赖自我判断，客观验证才能通过
4. 语言类走轻量路径（词库+文本匹配），通用类走 LLM
5. 每个节点独立可测，纯函数直接测，有依赖注入 mock
```

---

*文档版本: V3.0 定稿*
*日期: 2026-05-07*
*产品: 刻意进化学习 · coevo*
*核心: AI 对话 → 提取建议 → 用户确认 → FSRS 调度 → 客观验证 → 成就闭环*
# LinguaFlow 独立项目调查报告

> 调查日期：2026-07-18
> 目的：将 CoEvo 项目中的语言学习模块提取为独立项目（暂名 LinguaFlow）

---

## 一、当前 CoEvo 中的语言学习模块范围

### 1.1 覆盖的语种

| 语种 | 预制卡片数 | 课程计划 | 对话 Prompt | 前端 Tab |
|------|-----------|---------|------------|---------|
| **英语** | 12,839 张 | 4 阶段 / 80 任务 | 3 个阅读级别 | ✅ 常驻 Tab |
| **汉语** | 2,714 张 | 131 阶段 / 681 任务 | 3 个阅读级别 | ✅ 常驻 Tab |
| **日语** | 1,787 张 | 3 阶段 / 10 任务 | 3 个文件（与汉语同内容） | ❌ 隐藏 |
| **俄语** | 98 张 | 3 阶段 / ~13 任务 | 3 个文件（与汉语同内容） | ❌ 隐藏 |

**卡片总量：17,438 张**（prebuilt_cards.json）+ 17,438 行附属语言数据（prebuilt_language_cards.json）

### 1.2 核心功能模块

```
语言学习功能架构
├── [数据层]  预置词库 (data/curriculum/v4/cards/language/)
│   ├── prebuilt_cards.json              (17,438 条通用卡片索引)
│   └── prebuilt_language_cards.json     (17,438 条语言专属字段)
│
├── [数据层]  课程计划 (data/curriculum/v4/plans/)
│   ├── english.json     (4 stages / 80 tasks)
│   ├── chinese.json     (131 stages / 681 tasks)
│   ├── japanese.json    (3 stages / 10 tasks)
│   └── russian.json     (3 stages / ~13 tasks)
│
├── [后端]   API 路由 (routes.rs)
│   ├── GET  /review/due[?language=]           ← 语言过滤
│   ├── GET  /k12/plans                        ← 列表含语言学科
│   ├── GET  /k12/subjects                     ← 语言学科配置
│   ├── GET  /k12/plans/:plan/stages           ← 加载课程
│   ├── POST /k12/init                         ← 初始化含预置词库激活
│   └── POST /cp1/activate                     ← 词库静默激活
│
├── [后端]   WebSocket 对话 (ws.rs)
│   ├── CP1 词库激活: AI 回复匹配预置词汇 → 静默制卡
│   ├── B2 用户输入验证: 匹配词库词汇 → 激活（已实现未接通 hot path）
│   └── 对话路由: english/chinese 科目跳过 CP1 概念提取
│
├── [后端]   Prompt 体系 (prompts/)
│   ├── prompts/chat/english/          (reading-nursery/primary/secondary)
│   ├── prompts/chat/chinese/          (reading-nursery/primary/secondary)
│   ├── prompts/chat/japanese/         (reading-nursery/primary/secondary)
│   ├── prompts/chat/russian/          (reading-nursery/primary/secondary)
│   ├── prompts/concept/language/      (extract + signal/format 分拆)
│   └── prompts/format/concept/        (共享格式池: language.md)
│
├── [后端]   数据库表 (schema.rs)
│   ├── prebuilt_cards          (通用卡片)
│   ├── prebuilt_language_cards (语言专属: pronunciation/pos/definitions/level)
│   ├── user_cards              (用户卡片, 含 language/level 列)
│   └── user_language_cards     (用户语言卡: pronunciation/definitions)
│
└── [前端]   页面与组件 (app/)
    ├── screens/review_screen.dart   (含 [英语] [汉语] 常驻 Tab)
    ├── screens/chat_screen.dart     (语言对话 + 词库激活)
    ├── config/k12_subjects.dart     (语言学科颜色/图标配置)
    ├── screens/curriculum_cards_page.dart (管理端: 编辑预置卡片)
    └── screens/curriculum_plans_page.dart (管理端: 编辑课程计划)
```

---

## 二、语言学习 vs 通用/K12 的分界线

### 2.1 语言学习独有的逻辑

| 特性 | 说明 | 区别于 K12 其他学科 |
|------|------|-------------------|
| **预置词库** | 17K+ 预制词汇，对话中静默匹配激活 | K12 学科（数学/物理等）无此能力 |
| **CP1 跳过** | english/chinese 科目跳过 LLM 概念提取 | K12 学科走 CP1 LLM 提取 |
| **语言 Tab** | 复习页有 [英语] [汉语] 独立 Tab | K12 学科按 plan/conversation 过滤 |
| **卡片渲染** | 词典格式（front+pronunciation+definitions+pos） | K12 学科卡片按 domain 渲染 |
| **验证策略** | 语言类可能用拼写/打字验证 | K12 学科用 LLM 三联问 |
| **FSRS 激活** | 匹配即激活，无需用户确认 | K12 学科需用户确认弹窗 |
| **无课标绑定** | 英语/日语/俄语与课标无关 | K12 学科（数学/物理/化学等）绑课标 |
| **逐课激活** | 按 task 渐进激活词汇（第 1 个 task 激活第 1 批） | K12 学科一次 init 激活一批 |

### 2.2 共享/通用逻辑（不能独立）

| 模块 | 说明 | 需要剥离或共享？ |
|------|------|----------------|
| **用户系统** | users/tokens/auth | 共享通用模块 |
| **FSRS 调度** | card_memory/fsrs5.rs | ✅ 可独立 crate |
| **复习界面** | review_screen.dart（翻牌/验证/评分） | ✅ 可复用，含语言 Tab 特殊逻辑 |
| **LLM 对话** | chat_engine/ws.rs 对话框架 | ✅ 可独立复用 |
| **卡片模型** | user_cards/card_memory/review_log | ✅ 通用 schema |
| **成就系统** | achievements | 共享通用模块 |
| **支付/订阅** | pay/subscription | 初期不需要 |
| **营销** | campaigns/referral | 初期不需要 |
| **家长端** | guardian screen | 初期不需要 |
| **管理端** | admin screen（含 curriculum admin） | 初期不需要 |
| **审核日志** | audit log | 初期不需要 |

---

## 三、文件清单（可提取内容）

### 3.1 后端 Rust 代码

#### 可复用 Crate 结构（保留在 CoEvo 也需要的）
```
crates/
├── shared_types/     ← 通用类型定义（CardState/FSRS 状态等）— 可独立
├── card_engine/      ← FSRS 调度引擎（不含语言特定逻辑）— 可独立
└── fsrs5.rs          ← FSRS-5 算法实现（自实现，无外部依赖）— 可独立
```

#### 语言专用代码（需要提取或 Fork）
```
crates/api_server/src/
├── routes.rs         ← review_due 的 language 过滤、k12 路由
├── ws.rs             ← CP1 词库激活逻辑（~200 行）
├── curriculum_loader.rs  ← V4 数据加载
├── curriculum_admin.rs   ← 管理端课程编辑
├── schema.rs         ← language 相关表定义（可保留通用部分）
└── plan_handler.rs   ← 计划处理中的语言科目逻辑
```

### 3.2 前端 Flutter 代码

```
app/lib/
├── screens/review_screen.dart       ← [英语] [汉语] Tab + 语言过滤
├── screens/chat_screen.dart         ← 对话页（含词库激活）
├── screens/card_list_screen.dart    ← 卡片列表
├── config/k12_subjects.dart         ← 语言学科配置
├── screens/k12_subject_screen.dart  ← K12 学科页面
├── screens/curriculum_cards_page.dart   ← 管理端：编辑卡片
├── screens/curriculum_plans_page.dart   ← 管理端：编辑计划
├── api/                             ← API 客户端
├── models/                          ← 数据模型
├── providers/                       ← Riverpod 状态
├── widgets/                         ← 共享组件
├── pipelines/verification_strategy.dart  ← 验证策略
└── theme/                           ← 主题
```

### 3.3 数据文件

```
data/curriculum/v4/cards/language/
├── prebuilt_cards.json              (17,438 条, 3.5 MB)
└── prebuilt_language_cards.json     (17,438 条, 10.9 MB)

data/curriculum/v4/plans/
├── english.json                     (711 KB)
├── chinese.json                     (445 KB)
├── japanese.json                    (100 KB)
└── russian.json                     (~50 KB)
```

### 3.4 Prompt 文件

```
prompts/chat/english/        (3 files, ~13 KB)
prompts/chat/chinese/        (3 files, ~13 KB)
prompts/chat/japanese/       (3 files, ~6 KB, 内容需重写)
prompts/chat/russian/        (3 files, ~6 KB, 内容需重写)
prompts/concept/language/    (extract + signal/format, ~5 KB)
prompts/format/concept/      (language.md, 共享格式)
```

---

## 四、提取方案评估

### 方案 A：独立仓库（Fork 模式） ⭐ 推荐

从 CoEvo 仓库 Fork 出来，删除非语言模块，保留通用基础设施。

**保留的组件：**
- 用户系统（简化版，去掉 PII 加密/家长端/营销）
- FSRS 调度引擎（card_engine + fsrs5.rs）
- LLM 对话框架（chat_engine）
- 卡片系统（预置词库 + user_cards + review）
- 复习界面及验证
- Prompt 体系（仅保留语言相关）

**删除的组件：**
- K12 课标绑定（数学/物理/化学/历史/地理/政治/生物/科学/信息技术/艺术/劳动/体育）
- 营销系统（推广返现/协同进化/注册有礼）
- 家长端/教师端
- 成就系统（可选保留）
- 支付/订阅（初期可保留简化版或去掉）

**优势：** 代码已有完整实现，删减比重写成本低
**劣势：** CoEvo 主仓库的增量变更需要手动同步

### 方案 B：crate 级重构（共享复用）

在 CoEvo monorepo 内将语言学习提取为独立 crate `linguaflow`，与 CoEvo 共享用户/FSRS/LLM 等通用基础设施。

**优势：** 代码复用最大化，无需额外仓库维护
**劣势：** 耦合度高，独立部署困难，不适合作为独立产品

### 方案 C：全新重写

从零开始实现语言学习 App，参考 CoEvo 的设计。

**优势：** 架构清爽，无历史包袱
**劣势：** 开发周期长，重复造轮子

---

## 五、建议的下一步

1. **确认提取范围**：是否只做英语？还是包括汉语/日语/俄语？
2. **确认产品形态**：Web App（Flutter Web）还是移动端？目标用户群体？
3. **确认技术栈**：继续用 Rust + Flutter？还是换更轻量的方案？
4. **确认与 CoEvo 的关系**：独立运作还是共享用户/数据？
5. **代码清理**：删除 ~70% 的非语言代码（K12 学科、营销、家长端等）
6. **Prompt 重写**：日语/俄语的 prompt 内容与汉语相同，需要重写为真正的目标语种教学内容

> 按最小 MVP 估算，基于方案 A 从现有代码提取并清理，预计 **1-2 周** 可产出可运行的独立版本（仅英语）。

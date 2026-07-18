# Echo Loop vs CoEvo 竞品对比分析

> **分析日期**: 2026-07-18
> **数据来源**: Echo Loop README.en.md (实际抓取) + CoEvo Devplan V2.1 / DataFlow V2.2 (实际读取)
> **对比原则**: 基于双方实际代码/文档，不凭记忆比较

---

## 一、一句话定位

| 项目 | 定位 |
|------|------|
| **Echo Loop** | 科学、高效的 AI 英语听说训练 App — 把一段音频从"听过"练到"会说" |
| **CoEvo** | AI 对话中自动发现概念、用户确认制卡、FSRS 调度复习、客观验证内化 — K12 全学科学习 |

**核心差异**：Echo Loop 是**技能训练工具**（听说技能），CoEvo 是**知识内化平台**（概念记忆 + 课标驱动）。

---

## 二、产品理念对比

| 维度 | Echo Loop | CoEvo |
|------|-----------|-------|
| **解决什么问题** | 拿到音频后怎么真正练透（听懂→会说→记住） | 学完之后怎么真正记住（对话→制卡→复习→内化） |
| **学习闭环** | 盲听→精听→跟读→复述→间隔复习 | 对话→概念提取→制卡→FSRS复习→LLM三联问验证 |
| **用户主动 vs 被动** | 用户导入素材，系统自动驱动训练节奏 | 用户与 AI 对话，系统建议概念，用户确认制卡 |
| **学科范围** | 仅英语 | K12 全学科（英语/语文/数学/物理/化学/生物/历史/地理/政治 + 日语/俄语） |
| **学习哲学** | 对合适材料重复拆解模仿复述，而非不断换新材料 | 系统建议，用户确认 — 不替用户决定学什么 |

---

## 三、技术栈对比

| 层 | Echo Loop | CoEvo |
|----|-----------|-------|
| **UI 框架** | Flutter + Material 3 | Flutter + Material 3 ✅ 相同 |
| **状态管理** | Riverpod（代码生成） | Riverpod ✅ 相同 |
| **后端** | Supabase（BaaS） | Rust (axum + tokio + rusqlite) 自研 |
| **数据库** | Drift (SQLite) + shared_preferences | SQLite (rusqlite, 后端独有) + 18-20 张表 |
| **LLM** | 未明确（用于翻译/解析/转录） | DeepSeek V4 Flash (OpenAI 兼容) |
| **通信** | REST (Supabase) | REST + WebSocket (流式 SSE) |
| **ASR** | sherpa_onnx（本地离线） | 无（语言类走文本匹配） |
| **TTS** | flutter_tts | 有（TTS 音色持久化） |
| **音频引擎** | just_audio + audio_session（核心） | 无音频训练功能 |
| **认证** | Supabase Auth + Google | 自研（JWT + AES-256-GCM PII 加密） |
| **支付** | Paddle / StoreKit | 微信支付 Native 扫码 |

**关键差异**：
- Echo Loop 是**纯前端 + BaaS** 架构，轻量；CoEvo 是**前后端分离 + 自研后端**，更重但可控
- Echo Loop 有**本地 ASR**，CoEvo 没有（语言类验证目前是文本匹配）
- CoEvo 有**WebSocket 流式对话**，Echo Loop 无实时对话

---

## 四、间隔复习算法对比（核心差异）

| 维度 | Echo Loop | CoEvo |
|------|-----------|-------|
| **算法** | 艾宾浩斯遗忘曲线（固定间隔） | FSRS-5（自适应，自实现 fsrs5.rs） |
| **间隔策略** | 1+7 固定模式：6h→1d→2d→4d→7d→14d→28d | 动态计算：基于 difficulty/stability/due 实时调整 |
| **调度粒度** | 材料级（整段音频） | 卡片级（每个概念/词条独立调度） |
| **状态机** | 简单线性推进 | New→Learning→Review→Relearning 四态机 |
| **用户反馈影响** | 固定间隔，不受表现影响 | Again/Hard/Good/Easy 评分影响下次间隔 |
| **mastered 判定** | 完成 7 轮复习 | state=2 + reps>=3 |
| **测试覆盖** | 未披露 | 16/16 测试通过 |

**分析**：
- Echo Loop 的固定间隔**简单可靠**，用户无需决策，但**不个性化**
- CoEvo 的 FSRS-5 **根据用户表现自适应**，记忆效率更高，但实现复杂度也更高
- 两者哲学不同：Echo Loop 追求"自动化驱动"，CoEvo 追求"记忆效率最优"

---

## 五、验证机制对比（核心差异）

| 维度 | Echo Loop | CoEvo |
|------|-----------|-------|
| **验证方式** | ASR 跟读评测（sherpa_onnx 对齐+高亮+评分） | LLM 三联问（3/3→pass, <3→fail） |
| **验证对象** | 发音/口语流利度 | 概念理解/记忆内化 |
| **评判标准** | 词级对齐 + 评级 | LLM 批量判断对错 |
| **历史注入** | 无 | 注入近10轮考题历史，避免重复出题 |
| **异步性** | 本地即时 | 后台异步不阻塞 UI |
| **失败处理** | 继续练习 | 卡片留在队列，不计为复习 |

**分析**：
- Echo Loop 验证的是**技能表现**（能不能说出来）
- CoEvo 验证的是**知识内化**（能不能答对三道题）
- 两者不可替代，针对不同学习目标

---

## 六、数据模型对比

### Echo Loop（轻量）
```
models/
├── AudioItem        # 音频材料
├── Sentence         # 句子（含时间戳、意群拆分）
└── Collection       # 合集

持久化: Drift (SQLite) + shared_preferences
统计维度: 练习时间 / 输入输出比 / 独立词汇量
```

### CoEvo（重量级，18-20 张表）
```
核心表:
├── users                    (Auth + PII AES-256-GCM 加密)
├── cards                    (Data + K12 关联: plan_id, task_key, subject)
├── card_memory              (FSRS State 1:1: state/difficulty/stability/due)
├── conversation_plans       (K12 + CP2 计划)
├── user_plan_progress       (按 task_key 分列存储, 非 JSON)
├── review_log               (details_json 存考题历史)
├── achievements             (23+ 成就)
├── knowledge_graph          (177 节点, 275 边)
├── k12_quiz_bank/attempts   (课标题库)
├── guardian_assignments     (家长绑定)
├── admin_users/audit_log    (管理后台)
└── subscription_requests    (订阅)

卡片类型:
├── 词典卡 (英语12,791 牛津级 / 语文2,714 新华字典级, 结构化 JSON)
├── 课文卡 (full_text + translation + 语法)
├── 概念卡 (LLM 提取, 用户确认)
└── 预制卡 (K12 课标驱动, 4 种 domain 子表)
```

**分析**：
- Echo Loop 数据模型**极简**，3 个核心模型
- CoEvo 数据模型**复杂**，支持 K12 课标关联、家长看板、管理后台、订阅系统
- 两者复杂度差异源于产品定位不同

---

## 七、学习计划对比

| 维度 | Echo Loop | CoEvo |
|------|-----------|-------|
| **计划来源** | 用户自选素材 | K12 课标预制 + LLM 自由生成（双路径） |
| **课标覆盖** | 无 | 高中 10 科课标 + 义务教育课标摘要 (7.5KB) |
| **知识图谱** | 无 | 177 节点 275 边（高中 10 科） |
| **分级体系** | 无明确分级 | CEFR A1-C1（英语）+ nursery/primary/secondary 三级 prompt |
| **计划推进** | 素材完成度 | task 级推进（copy_prebuilt_card 逐个激活） |
| **考核机制** | 无 | 2-3 题递进 + CP2 自动分析 |

---

## 八、平台与成熟度对比

| 维度 | Echo Loop | CoEvo |
|------|-----------|-------|
| **已上架** | App Store + Google Play ✅ | Flutter Web (VPS 部署) |
| **平台支持** | iOS + Android + macOS(开发中) + Windows(规划) | Web + 移动端 |
| **开源状态** | AGPL-3.0 开源 | 私有项目 |
| **社区** | 1,336 stars / 95 forks / 微信群 | 无公开社区 |
| **学术背书** | 北大英语博士指导方法论 | FSRS-5 算法（学术基础） |
| **商业化** | 完全免费（有订阅代码但未强制） | 订阅制 + 微信支付 |
| **测试体系** | 单元/Widget/集成测试 | 16/16 FSRS 测试 + e2e-quality-eval 5维评分 |

---

## 九、核心差异化总结

### Echo Loop 的优势
1. **聚焦单一场景做到极致** — 英语听说训练闭环完整
2. **本地 ASR** — sherpa_onnx 离线评测，无需后端
3. **已上架应用商店** — 1,336 stars 社区认可
4. **轻量架构** — 纯前端 + Supabase，部署运维简单
5. **学术背书** — 北大英语博士方法论指导

### CoEvo 的优势
1. **K12 全学科覆盖** — 不止英语，10+ 学科 + 课标驱动
2. **FSRS-5 自适应算法** — 比 Echo Loop 的固定间隔记忆效率更高
3. **LLM 客观验证** — 三联问验证知识内化，而非技能表现
4. **自研后端** — 数据自主可控，支持复杂业务（家长看板/管理后台/订阅）
5. **知识图谱** — 177 节点 275 边，支持课标关联
6. **结构化词典** — 牛津级/新华字典级，而非简单文本

### 两者不可替代
- Echo Loop 解决"**会说**"问题（技能训练）
- CoEvo 解决"**记住并内化**"问题（知识记忆）
- 如果 CoEvo 要做口语方向，可以借鉴 Echo Loop 的 sherpa_onnx 方案

---

## 十、对 CoEvo 的启发

| # | 启发点 | 来源 | 可落地性 |
|---|--------|------|---------|
| 1 | **引入本地 ASR** | Echo Loop sherpa_onnx | 中 — 可用于语言类口语验证，补充现有文本匹配 |
| 2 | **素材级训练闭环** | 盲听→精听→跟读→复述 | 中 — CoEvo 目前以概念卡为主，可考虑增加"素材练习"模式 |
| 3 | **AGPL-3.0 开源策略** | Echo Loop 协议选择 | 低 — CoEvo 已商业化，开源需谨慎 |
| 4 | **学术合作背书** | 北大博士指导 | 高 — CoEvo 可寻找教育学/认知科学合作 |
| 5 | **应用商店上架** | Echo Loop 已双端上架 | 高 — CoEvo 目前仅 Web，移动端上架可扩大覆盖 |
| 6 | **社区运营** | 1,336 stars + 微信群 | 中 — 开源社区可带来反馈和贡献 |

---

## 十一、风险提示

1. **Echo Loop 与 CoEvo 在英语听说赛道有部分重叠** — Echo Loop 的间隔复习 + 英语训练可能与 CoEvo 的英语词卡复习形成竞争
2. **Echo Loop 开源免费** — 如果 CoEvo 英语模块收费，用户可能转向 Echo Loop
3. **Echo Loop 已上架应用商店** — 先发优势明显，CoEvo 移动端尚未上架

---

*报告生成: 2026-07-18*
*数据时效: Echo Loop (2026-07-16 更新) / CoEvo (V2.1, 2026-06-08 同步)*

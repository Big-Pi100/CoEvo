# K12 预生成方案 — 代码影响评估 V3

> 日期：2026-05-26 | V3 — 管线完成，考试设计转向运行时

---

## 一、架构变更概述

| 组件 | V1 | V2.2 | V3 |
|:----|:---|:----|:------|
| 课程内容 | 规则提取 | LLM 提取概念 | LLM 提取概念 + 推演补全 ✅ |
| 学业质量 | 规则提取 | 分割完整条目 → 预出题 | 分割完整条目 → **运行时 LLM 动态出题** |
| 附录词表 | 规则+LLM | 规则提取+LLM 生成卡背 | 规则提取+LLM 富集 + **Plan 绑定** ✅ |
| 学习计划 | 两两分组 | 概念排序+语言类场景×技能 | ✅ 全量产出 |
| 概念卡 | — | 按 Plan 生成 | ✅ 8路由生成器 |
| 考题 | 无 | 预生成 + 预存答案 | **不预生成，LLM 运行时按框架出题 + 判卷** |
| 知识图谱 | 无 | 新增 + 跨学科链接器 | ⏳ 待实施 |
| 大考系统 | 无 | 无 | **新增后端 crate + 前端考试页** |

---

## 二、总览

| 组件 | V1 影响 | V2.0 影响 | V2.2 影响 |
|:----|:-------:|:---------:|:---------:|
| 后端 Rust | 大 | **不变** | **表格移+字段新增**（1新表+5个ALTER） |
| Python 管线 | 10+解析器 | 2-3通用脚本 | **3个核心脚本**（清洗+提取+Plan）+ **并行Runner** |
| 前端 Flutter | 大 | **不变** | **不变** |
| 数据库 | 小 | **不变** | **小（迁移）** |
| **总工时** | **~26h** | **~8h** | **~5h（含并行）** |

---

## 三、Python 脚本

### 3.1 已删除文件（2026-05-23 ~ 2026-05-25）

```
scripts/gold/parsers/                          # 11 个规则解析器
scripts/gold/orchestrator.py                   # 旧管线
scripts/gold/llm_validate_3round.py            # 三轮验证
scripts/gold/plan_builder.py                   # 旧计划生成（两两分组）
scripts/gold/card_generator.py                 # 旧卡片生成
scripts/gold/manual_patches.py                 # 手动补丁
scripts/gold/restructure_math.py               # 数学重构
scripts/gold/build_senior_prebuilt.py          # 高中预生成
scripts/gold_extractor_senior.py               # 高中提取器
scripts/gold/llm_bulk_extract.py               # 旧 LLM 提取（被 V3 替代）
scripts/gold/extract_perfect.py                # 编号条目脚本（被 V3 替代）
scripts/gold/extract_nobullets.py              # 纯段落脚本（被 V3 替代）
scripts/gold/validate_concepts.py              # 概念验证（被 V3 内置交叉验证替代）
scripts/gold/llm_extractor.py                  # 备用提取器（不再需要）
backend/crates/k12_tests/                      # 整个 crate
backend/crates/quality_eval/                   # 整个 crate
backend/src/bin/e2e_k12_runner.rs              # K12 测试
backend/src/bin/e2e_k12_prebuilt_runner.rs     # 预生成测试
backend/src/bin/evaluate.rs                    # 评估工具
backend/src/bin/e2e_quality_eval.rs            # 质量评估
scripts/test_plan_creation.py                  # 计划测试
```

### 3.2 核心脚本（V3 已全部产出）

| 脚本 | 状态 | 用途 | 
|:----|:----|:------|
| `scripts/clean_curriculum.py` | ✅ 已完成 | 原始MD三段清洗（raw→cleaned） |
| `scripts/gold/extract_v3.py` / `extract_language.py` | ✅ 已完成 | 统一概念提取（22科） |
| `scripts/gold/build_plans_v3.py` | ✅ 已完成 | Plan 生成（含逻辑推演补全+语言类场景×技能） |
| `scripts/gold/generate_cards_v2.py` | ✅ 已完成 | 卡片生成器（8 学科路由） |
| `scripts/gold/extract_appendix_vocab.py` | ✅ 已完成 | 附录词表提取 |
| `scripts/gold/enrich_vocab.py` | ✅ 已完成 | 词汇卡 LLM 富集（并发批量） |
| `scripts/gold/rebuild_vocab_cards.py` | ✅ 已完成 | 词卡重建 + Plan 绑定 |
| `scripts/gold/extract_quality_items.py` | ✅ 已完成 | 学业质量条目分割 |
| `scripts/gold/fill_missing_vocab.py` | ✅ 已完成 | 补齐剩余词汇富集 |
| `build_graph.py` | ⏳ 待实施 | 跨学科链接器 |

### 3.3 产出统计

| 产出 | 数量 |
|:----|-----:|
| gold JSON（概念） | 22 科 |
| Plan | 22 科，共 185 阶段，501 任务 |
| 卡片总数 | **27,677 张**（概念卡 2,147 + 富集词卡 25,530） |
| 学业质量条目 | 21 科，共 2,117 条 |

### 3.4 设计变更：预出题 → 运行时动态出题

原计划的 `generate_assessment.py`（预生成考题）已废弃，改为后端 crate `k12_assessment`：

| 旧方案 | 新方案 |
|:------|:------|
| 预生成考题+答案 | 出题框架配置（预生成）+ LLM 运行时出题+判卷 |
| 题目固定 | 每次动态生成，适配学生水平 |
| 题库存前端有安全风险 | 试卷运行时生成，不留痕迹 |
| 无法覆盖所有薄弱点 | LLM 按质量条目判断，精准定位薄弱点 |

---

## 四、后端代码影响

### 4.1 新增

| 文件 | 说明 |
|:----|:------|
| `backend/crates/api_server/src/curriculum_loader.rs` | 预生成数据加载（150行） |
| `backend/src/routes/k12_init.rs` (内联在 routes.rs) | POST /api/k12/init |

### 4.2 V3 新增：k12_assessment crate

```
backend/crates/k12_assessment/
├── Cargo.toml
├── src/
│   ├── lib.rs              # 主入口: assess_stage()
│   ├── framework.rs         # 出题框架配置加载 + 质量条目
│   ├── generator.rs         # LLM 调用: 按框架出题
│   └── grader.rs            # LLM 判卷 + 评分汇总
```

API：
- `POST /k12/exam/start` — 开始考试（出题框架 + LLM → 试卷）
- `POST /k12/exam/submit` — 交卷（LLM 判卷 → 成绩+薄弱点分析）

### 4.3 数据库迁移

| 变更 | SQL |
|:----|:----|
| 新表 `knowledge_graph` | 待实施 |
| 新表 `exam_frameworks` | `CREATE TABLE (id, subject, level, stage, config_json)` |
| 新表 `exam_attempts` | `CREATE TABLE (id, user_id, subject, stage, score, weak_tasks, attempted_at)` |
| cards 加 `gold_cr_id` | ✅ 已迁移 |
| cards 加 `plan_task_id` | ✅ 已迁移 |
| cards 加 `origin` | ✅ 已迁移 |

### 4.4 前端新增

| 页面 | 说明 |
|:----|:------|
| 考试页面 | 独立路由，模拟真实考场（倒计时/题号导航/交卷） |
| 成绩结果页 | 总分、每题评分、薄弱点分析 |
| 消息中心面板 | 显示待完成的阶段测试通知 |

### 4.5 后端无变更的组件

- `POST /api/k12/init` — 不变
- WS 对话接口 — 不变
- 卡片 CRUD 接口 — 不变
- 小考（对话中 LLM 考核）— 不变

---

## 五、数据格式变更

### 5.1 gold JSON 格式（V3 产出）

```json
{
  "subject": "math",
  "level": "compulsory",
  "version": "课程标准2022/2017",
  "extracted_at": "2026-05-25T...",
  "extracted_by": "extract_v3",
  "content_requirements": [
    {"front": "...", "back": "定义:...\n\n关键要素:...", "source_sentence": "...", "domain": "数学"}
  ],
  "stats": {"total_crs": 131}
}
```

### 5.2 Plan JSON 格式（V3 待写）

```json
{
  "plans": [{
    "id": "math_g1-2",
    "subject": "math",
    "grade_band": "g1-2",
    "goal": "...",
    "stages": [{
      "name": "数与运算",
      "prerequisite_stages": [],
      "tasks": [{
        "name": "20以内加减法",
        "gold_cr_ids": ["cr_001"],
        "dependencies": [],
        "cross_subject_refs": [],
        "origin": "extracted"
      }]
    }],
    "total_crs": 10
  }]
}
```

### 5.3 Card JSON 格式（V2 待写）

```json
{
  "cards": [{
    "id": "math_g1-2_001",
    "subject": "math",
    "grade_band": "g1-2",
    "domain": "数学",
    "front": "...",
    "back": "...",
    "source_sentence": "...",
    "card_type": "concept",
    "gold_cr_id": "cr_001",
    "plan_task_id": "task_001",
    "origin": "extracted"
  }]
}
```

---

## 六、实施步骤（V3 真实状态）

| 步 | 内容 | 状态 | 
|:--|:------|:----:|
| ✅ | 清洗脚本 + 三段分割 | 已完成 |
| ✅ | V3 概念提取 | 已完成 |
| ✅ | Plan生成+推演补全 | 22科全部产出 |
| ✅ | 卡片生成 | 27,677张 |
| ✅ | 词卡富集+Plan绑定 | 25,530张富集 |
| ✅ | 学业质量条目分割 | 21科, 2,117条 |
| ✅ | 清理废弃脚本 | 18个文件已删除 |
| ⏳ | **curriculum_loader.rs 适配 V3 数据** | **P0（阻塞项）** |
| ⏳ | 出题框架配置生成 | P1 |
| ⏳ | k12_assessment crate | P1 |
| ⏳ | 前端考试页面 | P2 |
| ⏳ | 消息中心面板 | P2 |
| ⏳ | 跨学科链接器 build_graph.py | P1 |
| - | 旧版 k12_quiz 系统 | ✅ 已有（小考用，无需改动） |

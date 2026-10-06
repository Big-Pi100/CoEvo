# Python 脚本库存报告 — 清理 vs 保留

**日期**: 2026-06-08  
**总计**: 86 个 `.py` 文件  

---

## 一、✅ 可清理（一次性任务，完成后不再需要）

### `scripts/gold/` — 旧卡片生成管线（28个）

这批脚本是 v3 课标数据构建的"一次管线"：从 PDF 课标提取概念 → 生成卡片 → 修复缺陷 → 评估。**所有卡片数据已经生成完毕并部署到 prebuilt 目录**，不需要再跑。

| 脚本 | 用途 | 替代 |
|:--|:--|:--|
| `extract_v3.py` | 从课标 MD 提取概念 | 数据已就位 |
| `extract_language.py` | 语言类科目提取 | 同上 |
| `extract_appendix_vocab.py` | 附录词汇提取 | 同上 |
| `extract_quality_items.py` | 学业质量条目分割 | 同上 |
| `build_plans_v3.py` | Plan 生成器 V3 | 同上 |
| `assign_grade_bands.py` | 年级段标注 | 同上 |
| `audit_plans.py` | Plan 审计 | 同上 |
| `merge_plans.py` | Plan 合并 | 同上 |
| `check_remaining.py` | 剩余问题检查 | 同上 |
| `run_parallel.py` | 并行执行器 | 同上（仅用于管线编排） |
| `generate_cards_v2.py` | 卡片生成 V2 | 同上 |
| `generate_reading_cards.py` | 阅读卡生成 | 同上 |
| `generate_extended_reading_cards.py` | 拓展阅读卡生成 | 同上 |
| `gen_missing_cards.py` | 缺失卡补全(g1-2) | 同上 |
| `gen_missing_reading_cards.py` | 缺卡课文补全 | 同上 |
| `retry_reading_cards.py` | 阅读卡重试 | 同上 |
| `rebuild_appreciation.py` | 赏析字段重建 | 同上 |
| `rebuild_technique.py` | 手法字段重建 | 同上 |
| `rebuild_vocab_cards.py` | 词汇卡重建 | 同上 |
| `remap_concept_cards.py` | 概念卡重新映射 | 同上 |
| `link_vocab_to_tasks.py` | 词汇→任务关联 | 同上 |
| `add_missing_primary_data.py` | 小学数据补充 | 同上 |
| `add_primary_reading_plan.py` | 小学阅读计划 | 同上 |
| `build_full_reading_plan.py` | 完整阅读计划 | 同上 |
| `enrich_vocab.py` | 词汇富集 | 同上 |
| `fill_missing_vocab.py` | 词汇补齐 | 同上 |
| `fill_highschool.py` | 高中数据补充 | 同上 |
| `**fix_*.py` (11个) | 各种字段修复 | 已修复 |

### `scripts/gold/card_generators/` — **保留**（核心模块）

`base.py` + 8 个学科生成器是有价值的框架，建议保留。

### `scripts/english_rebuild/` — 英语课标重建管线（9个）

| 脚本 | 用途 |
|:--|:--|
| `phase1_dedup.py` | 去重 |
| `phase2_llm_grade.py` | LLM 年级标注 |
| `phase3_fill_missing.py` | 缺失补全 |
| `phase3_generate_passages.py` | 语段生成 |
| `phase4_rebuild_plan.py` / `_v2.py` | 计划重建 |
| `enrich_dictionary.py` / `_v2.py` | 词典富集 |
| `convert_chinese_to_json.py` / `convert_dict_to_json.py` | 格式转换 |

**结论**: 一次性数据构建，任务完成。**建议清理**。

### `scripts/v3_scripts/` — V3 迁移脚本（8个）

| 脚本 | 用途 |
|:--|:--|
| `rebuild_chinese_card_ids.py` | 卡片 ID 重建 |
| `gen_missing_cards.py` | 缺失卡生成 |
| `gen_missing_cards_batch2.py` | 第2批缺失卡 |
| `gen_batch2_safe.py` | batch2 安全版 |
| `gen_batch2_final.py` | batch2 最终版 |
| `fix_quotes.py` | 引号修复 |
| `verify_pinyin_fix.py` | 拼音修复验证 |
| `english_dedup_analysis.py` | 英语去重分析 |

**结论**: 一次性迁移任务。**建议清理**。

### `scripts/rebuild_subject_cards/` — 学科卡重建（1个）

`assign_cards_by_task.py` — 按 task 重新分配卡片。一次性任务。**建议清理**。

### 根目录一次性脚本

| 脚本 | 用途 | 建议 |
|:--|:--|:--|
| `migrate_v3.py` | 旧 JSON 转 UUID 格式 | ✅ 清理 |
| `migrate_grade_mapping.py` | 年级映射迁移 | ✅ 清理 |
| `restore_grade_band.py` | 年级段恢复 | ✅ 清理 |
| `clean_curriculum.py` | 课标 MD 清洗 | ✅ 清理 |
| `extract_all_senior_pdfs.py` | 高中 PDF 课标提取 | ✅ 清理 |
| `build_knowledge_graph.py` | 知识图谱构建 | ✅ 清理 |
| `import_ape210k.py` | Ape210K 题库导入 | ✅ 清理 |
| `fix_chinese_vocab_binding.py` | 语文词汇绑定修复 | ✅ 清理 |

---

## 二、📦 保留（可复用工具）

### `scripts/stress/` — 压测工具集（5个）

| 脚本 | 用途 | 保留理由 |
|:--|:--|:--|
| `vps_stress_test.py` | 多用户并发压测 | 每次部署后验证性能 |
| `chat_stress_test.py` | 真实 LLM 对话流压测 | 同上 |
| `ws_stress_test.py` | WS 并发+持续负载 | 同上 |
| `vps_setup_test_users.py` | 创建压测用户 | 配套工具 |
| `vps_cleanup.py` | 清理压测用户 | 配套工具 |

### `scripts/e2e/` — E2E 测试集（4个）

| 脚本 | 用途 | 保留理由 |
|:--|:--|:--|
| `frontend_flow_test.py` | 完整前端用户流程 | 新版本发布前冒烟测试 |
| `plan_flow_verify.py` | Plan 显示推进验证 | 回归测试 |
| `review_pipeline_nows.py` | 复习管线(无WS) | 回归测试 |
| `review_pipeline_verify.py` | 复习管线完整验证 | 回归测试 |

### `scripts/eval/` — 质量评估套件（4个）

| 脚本 | 用途 | 保留理由 |
|:--|:--|:--|
| `card_quality_eval.py` | 全量卡片 6 维评估 | 新增/修改卡片后评估质量 |
| `batch_fix_eval.py` | 批量修复评估 | 配合评估使用 |
| `fix_remaining_eval.py` | 剩余评估修复 | 同上 |
| `quality_review.py` | 教学质量评审 | E2E 测试后评审 |

### 根目录可复用工具

| 脚本 | 用途 | 保留理由 |
|:--|:--|:--|
| `live_llm_stream_test.py` | LLM 流式输出验证 | 切换模型/改 prompt 后验证 |
| `llm_match_cards.py` | LLM 辅助卡片匹配 | 新增学科时需要 |
| `yn_match_cards.py` | YY/NN 卡片匹配 | 同上 |

### `scripts/gold/card_generators/` — 卡生成核心模块（10个）

| 文件 | 用途 | 保留理由 |
|:--|:--|:--|
| `base.py` | 卡片生成基类框架 | 核心框架，新增学科时复用 |
| `chinese_lang.py` | 语文卡片生成 | 学科模块 |
| `english_lang.py` | 英语卡片生成 | 学科模块 |
| `japanese_lang.py` | 日语卡片生成 | 学科模块 |
| `russian_lang.py` | 俄语卡片生成 | 学科模块 |
| `science.py` | 科学卡片生成 | 学科模块 |
| `history.py` | 历史卡片生成 | 学科模块 |
| `geography.py` | 地理卡片生成 | 学科模块 |
| `politics.py` | 政治卡片生成 | 学科模块 |
| `it.py` | 信息技术卡片生成 | 学科模块 |
| `__init__.py` | 模块入口 | 必需 |

### `backend/tests/` — 后端测试脚本（12个）

这些是 Python 编写的后端冒烟/验证脚本，对 `http://localhost:8080` 或 VPS 进行测试。与 Rust 的单元测试互补：

| 脚本 | 用途 | 保留理由 |
|:--|:--|:--|
| `cp2_accuracy_test.py` | CP2 精度测试 | 回归验证 |
| `prod_plan_e2e_test.py` | Plan E2E 双 LLM | 生产验证 |
| `prod_cn_stage.py` | 语文 Stage 完成 | 回归测试 |
| `prod_dual_agent_g1-2.py` | 小学双代理 | 回归测试 |
| `prod_stage_complete.py` | 多模式 Stage 完成 | 回归测试 |
| `test_cp2_create.py` | CP2 创建测试 | 回归测试 |
| `verify_cp1_domain.py` | CP1 domain 验证 | 回归测试 |
| `verify_g16.py` | g1-6 验证 | 回归测试 |
| `check_due_api.py` | Due API 检查 | 快速调试 |
| `audit_chicn.py` | 用户审计 | 运维调试 |
| `add_task_signal.py` | 添加 task signal | 已执行，可清理 |
| `fix_plan_handler.py` | SSH 更新 VPS | 已执行，可清理 |

**建议**: 保留前10个，清理后2个。

---

## 三、建议清理汇总

| 目录 | 文件数 | 保留 | 清理 |
|:--|:--:|:--:|:--:|
| `scripts/gold/` (非 generators) | 39 | 0 | **39** |
| `scripts/english_rebuild/` | 9 | 0 | **9** |
| `scripts/v3_scripts/` | 8 | 0 | **8** |
| `scripts/rebuild_subject_cards/` | 1 | 0 | **1** |
| `scripts/` 根目录一次性 | 8 | 3(保留) | **5** |
| `backend/tests/` | 12 | 10(保留) | **2** |
| **总计 清理** | | | **64** |
| **建议保留** | | **22** | |

### 保留清单（22个）

| 组 | 文件 |
|:--|:--|
| 压测工具 | stress/*.py (5) |
| E2E 测试 | e2e/*.py (4) |
| 质量评估 | eval/*.py (4) |
| 卡片生成核心 | gold/card_generators/*.py (10) |
| 可复用工具 | llm_match_cards.py, yn_match_cards.py, live_llm_stream_test.py (3) |
| 后端测试 | backend/tests/ (保留10个) |

### 注意事项

清理前建议：
1. 先**吊销**泄露的 API Key `sk-****`（2026-10-06 掩码；该 Key 已吊销）
2. 确认 `data/curriculum/prebuilt/` 数据文件完整可用（生成管线不再需要跑）
3. 检查 `.gitignore` 确保 `.env` 不提交

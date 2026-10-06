# Python 脚本安全审计报告

**日期**: 2026-06-08  
**范围**: `scripts/` + `backend/tests/` 下全部 `.py` 文件  
**总文件数**: 86  

---

## 🔴 P0 — API Key 硬编码泄漏

**同一 DeepSeek API Key 硬编码在 18 个文件中**:

```
sk-****
（2026-10-06 掩码：原文此处为完整 Key。保留「曾发现该泄漏」这一事实，
  但不保留明文 —— 报告本身不应成为二次泄漏源。该 Key 已于 2026-10 吊销。）
```

### 泄漏清单

| 目录 | 文件 | 行号 |
|:--|:--|:--:|
| `scripts/gold/` | `assign_grade_bands.py:15` | `API_KEY = "sk-..."` |
| `scripts/gold/` | `audit_plans.py:15` | 同上 |
| `scripts/gold/` | `build_plans_v3.py:12` | 同上 |
| `scripts/gold/` | `enrich_vocab.py:20` | 同上 |
| `scripts/gold/` | `extract_appendix_vocab.py:8` | 同上 |
| `scripts/gold/` | `extract_language.py:18` | 同上 |
| `scripts/gold/` | `extract_v3.py:20` | 同上 |
| `scripts/gold/` | `fill_missing_vocab.py:6` | 同上 |
| `scripts/gold/` | `generate_extended_reading_cards.py:7` | 同上 |
| `scripts/gold/` | `generate_reading_cards.py:14` | 同上 |
| `scripts/gold/` | `gen_missing_reading_cards.py:7` | 同上 |
| `scripts/gold/` | `remap_concept_cards.py:15` | 同上 |
| `scripts/gold/` | `retry_reading_cards.py:6` | 同上 |
| `scripts/gold/card_generators/` | `chinese_lang.py:17` | 同上 |
| `scripts/english_rebuild/` | `phase2_llm_grade.py:13` | 同上 |
| `scripts/english_rebuild/` | `phase3_fill_missing.py:4` | 同上 |
| `scripts/english_rebuild/` | `phase3_generate_passages.py:12` | 同上 |
| `scripts/english_rebuild/` | `enrich_dictionary.py:14` | 同上 |
| `scripts/english_rebuild/` | `enrich_dictionary_v2.py:9` | 同上 |
| `scripts/rebuild_subject_cards/` | `assign_cards_by_task.py:14` | 同上 |

**严重度**: ⚠️ 该 Key 可以调用 DeepSeek API，产生费用。如果仓库是公开的，任何人可用。

**建议**: 
1. 立即在 DeepSeek 控制台 **吊销** 此 Key
2. 生成新 Key，仅通过 `.env` 或环境变量使用
3. 使用 `.gitignore` 确保 `.env` 不会被提交

---

## 🟡 P1 — .env 文件读取（风险较低但仍需改善）

以下脚本在运行时从 `backend/.env` 读取 API Key，比硬编码好，但 `.env` 文件不应在仓库中：

| 文件 | 读取方式 |
|:--|:--|
| `scripts/eval/card_quality_eval.py:16` | `open("backend/.env").read().split("DEEPSEEK_API_KEY=")` |
| `scripts/eval/fix_remaining_eval.py:8` | 同上 |
| `scripts/gold/batch_fill_gaps.py:11` | 同上 |
| `scripts/gold/fill_highschool.py:9` | 同上 |
| `scripts/gold/fix_non_pinyin_cards.py:16` | 同上 |
| `scripts/gold/fix_non_pinyin_cards_v2.py:11` | 同上 |
| `scripts/gold/fix_remaining_fulltext.py:7` | 同上 |
| `scripts/gold/fix_remaining_precise.py:8` | 同上 |
| `scripts/gold/fix_truncated_fulltext.py:7` | 同上 |
| `scripts/gold/fix_truncated_v2.py:7` | 同上 |
| `scripts/gold/fix_truncated_twostep.py:7` | 同上 |
| `scripts/gold/fix_worst_cards.py:6` | 同上 |
| `scripts/gold/gen_missing_cards.py:8` | 同上 |

**建议**: 统一改为 `os.environ.get("DEEPSEEK_API_KEY")`，与环境变量方式一致。

---

## 🟢 P2 — 环境变量方式（最佳实践，无需修改）

以下脚本正确使用环境变量获取 API Key，是推荐的做法：

| 文件 |
|:--|
| `scripts/eval/quality_review.py` |
| `scripts/live_llm_stream_test.py` |
| `scripts/llm_match_cards.py` |
| `scripts/yn_match_cards.py` |

---

## 🟡 P3 — 测试脚本中的硬编码密码

| 文件 | 密码 | 说明 |
|:--|:--|:--|
| `scripts/stress/*.py` | `stress123` | 压测用户密码 |
| `scripts/e2e/*.py` | `test123` / `flowtest123` | E2E 测试用户密码 |

这些是临时的测试用户密码，如果 VPS 上的测试用户已被删除则无风险。建议统一从环境变量读取测试用户凭据。

---

## 汇总

| 等级 | 问题 | 文件数 | 建议 |
|:--:|:--|:--:|:--|
| 🔴 P0 | API Key 硬编码泄漏 | **18** | 立即吊销 Key，替换为环境变量 |
| 🟡 P1 | .env 文件读取 | **13** | 统一改为环境变量 |
| 🟢 P2 | 环境变量方式（正确） | 4 | 维持现状 |
| 🟡 P3 | 测试密码硬编码 | 6 | 可改可不改 |

**⚠️ 最紧急行动**: 吊销 `sk-****` 并生成新 Key。（2026-10-06 掩码；已吊销）

# English Rebuild - Phase 1+2 Complete

## 输出文件
- `phase1_dedup_result.json` — Phase 1 合并结果
- `phase2_graded.json` — Phase 2 LLM 分级后最终结果 ✅
- `phase1_words_detail.json` — 详细词条数据

## 核心指标
- **原始词卡**: 20,688 → **瘦身后**: 12,791（-38%）
- **CEFR-J 词根**: 6,691（A1-B2 权威分级）
- **Extra 词 LLM 分级**: 6,066/6,100（99.4%）
- **分级失败**: 34 词（跳过）

## 最终 CEFR 分布
| Level | 词数 | Grade Band |
|-------|------|-----------|
| A1 | 1,401 | g1-2 |
| A2 | 1,797 | g3-4 |
| B1 | 3,569 | g7-9 |
| B2 | 4,897 | g10-12 |
| C1 | 1,127 | g10-12 |

## 待完成
- Phase 3: 分级阅读课文生成（按 CEFR 级别创建 A1-B2 短文）
- Phase 4: 重建 english.json plan（课文驱动）
- Phase 5: 验证

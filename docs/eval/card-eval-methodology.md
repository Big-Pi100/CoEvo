# 卡片质量评估方法

## 概述

卡片质量评估采用**LLM 逐卡评价**，将评分和理由直接嵌入卡片 JSON 的 `_eval` 和 `_eval_r` 字段，实现自我文档化——无需独立报告即可通过卡片数据本身做筛选和诊断。

## 评估文件

| 文件路径 | 范围 |
|:---------|:----|
| `docs/curriculum/prebuilt/cards/chinese_reading_primary.json` | 小学课文 409 张 |
| `docs/curriculum/prebuilt/cards/chinese_reading_extended.json` | 拓展阅读 142 张 |
| `docs/curriculum/prebuilt/cards/chinese_reading_missing.json` | 补录课文 45 张 |

## 数据结构

每个卡片现在包含两个评估字段：

```json
{
  "...其他卡片字段...": "...",
  
  "_eval": {
    "全文完整度": 100,
    "赏析质量": 85,
    "手法分析": 80,
    "主旨概括": 92,
    "易错提示": 65,
    "整体质量": 78
  },
  
  "_eval_r": {
    "全文完整度": "评分已修正（原文完整）",
    "赏析质量": "赏析选取具体动作细节和心理描写...",
    "手法分析": "准确指出白描、首尾呼应等手法...",
    "主旨概括": "清晰点明父爱主题及思念情感...",
    "易错提示": "卡片未设置易错提示栏目，按缺失处理",
    "整体质量": "核心内容完整，但缺易错提示，影响学习效果"
  }
}
```

| 字段 | 类型 | 说明 |
|:----|:----|:-----|
| `_eval` | dict[str, int] | 6 维度评分（0-100），用于快速筛选和排序 |
| `_eval_r` | dict[str, str] | 6 维度评分理由，用于诊断具体问题和指导修复 |

## 查询示例

```bash
# 查询"赏析质量"或"手法分析"为空的卡片（需补字段）
python3 -c "
import json
from pathlib import Path
for f in ['primary','extended','missing']:
    d=json.load(open(Path(r'E:\CoEvo\docs\curriculum\prebuilt\cards')/f'chinese_reading_{f}.json'))
    for c in d['cards']:
        ev=c['_eval']
        if ev['赏析质量']<30 or ev['手法分析']<30:
            print(f'{c[\"front\"]:20s}  赏析={ev[\"赏析质量\"]:3d}  手法={ev[\"手法分析\"]:3d}  | {c[\"_eval_r\"][\"赏析质量\"][:30]}')
"

# 查询"易错提示"缺失的卡片
python3 -c "
import json
from pathlib import Path
for f in ['primary','extended','missing']:
    d=json.load(open(Path(r'E:\CoEvo\docs\curriculum\prebuilt\cards')/f'chinese_reading_{f}.json'))
    for c in d['cards']:
        if c['_eval']['易错提示']<30:
            print(f'{c[\"front\"]:20s}  {c[\"file\"]:10s}  | {c[\"_eval_r\"][\"易错提示\"][:40]}')
"
```

## LLM 调用参数

- **模型**: `deepseek-v4-flash`
- **并发**: 5
- **温度**: 0.0
- **最大输出**: 700 tokens
- **重试**: 3 次，间隔 5 秒
- **批大小**: 50 张/批，每批完成后保存文件

## 提示词结构

```
评估学习卡片质量，逐项0-100分并给出简短理由（10-30字）。只回JSON。

卡片: {front}
内容: {full_text[:600]}
赏析: {appreciation}
手法: {technique}
主旨: {theme}
易错: {common_mistakes}

{"全文完整度":{"s":85,"r":"理由"},"赏析质量":{"s":80,"r":"理由"},
 "手法分析":{"s":75,"r":"理由"},"主旨概括":{"s":90,"r":"理由"},
 "易错提示":{"s":70,"r":"理由"},"整体质量":{"s":82,"r":"理由"}}
```

### 解析

LLM 返回 JSON 格式（使用 `s`=score, `r`=reason 短键名以减少 token 消耗）：

```json
{
  "全文完整度": {"s": 85, "r": "原文完整，与卡片名称匹配"},
  "赏析质量": {"s": 80, "r": "赏析引用了原文具体语句..."},
  ...
}
```

若 JSON 解析失败，回退为正则提取，再失败则全维度赋默认分 50 并标记"评估失败"。

## 全文完整度评分修正（现实标准）

LLM 评分倾向于保守，对篇幅较短的课文也给出低分。为真实反映卡片质量，**评估完成后**对 `全文完整度` 按以下规则修正：

| 条件 | 修正后分数 | 理由 |
|:----|:---------:|:-----|
| `card_type == "whole_book"` 且 `summary/back ≥ 100字` | **100** | 整本书概览，有摘要即完整 |
| `card_type == "whole_book"` 且 `summary/back ≥ 20字` | **80** | 有简要摘要 |
| `full_text 长度 ≥ 100字` | **100** | 有实质性原文，视为完整 |
| `full_text 长度 ≥ 50字` | **85** | 短文（古诗、儿歌等），内容完整 |
| `full_text 长度 ≥ 15字` | **50** | 极短文（识字卡等） |
| `full_text 长度 < 15字` | **0** | 无有效全文 |

修正后 `_eval_r` 的对应维度记录为"评分已修正（原文完整）"或"短文/非标准课文"。

## 分批保存策略

为避免长时间运行因网络波动导致数据丢失，采用分批保存策略：

1. 每 50 张卡片为一个批次
2. 每批次完成后立即写入文件
3. 已评估的卡片通过 `_eval_r` 字段是否存在来判断（可跳过）
4. 恢复运行时自动跳过已有 `_eval_r` 的卡片

## 低分卡片定义

- **整体质量 < 60 分**：标记为低分卡片
- 低分卡片的 `_eval_r` 可直接指出各维度低分原因，用于定向修复
- **拼音/儿歌类卡片**（`card_type="nursery_rhyme"`）不含 appreciation/technique/theme 字段，LLM 给低分是合理的，不视为质量问题

## 注意事项

1. **LLM 评分波动**：重复运行可能产生 ±5 分的差异，原因字段比分数更可靠
2. **整本书/名著类卡片**（`card_type="whole_book"`）没有"全文"概念，全文完整度基于 `summary` 字段长度
3. **被截断的全文**：`full_text` 不应有长度限制。若发现 `_eval_r` 中提及"文本截断""内容不完整"，说明该卡片的 full_text 被截断，需重新获取
4. **字段结构差异**：拓展阅读卡片使用 `summary`/`core_technique` 而非 `appreciation`/`technique`，评估时若这些字段为空会得到低分，需区分处理
5. **前后对比**：修复前后对比 `_eval` 分数变化来验证修复效果

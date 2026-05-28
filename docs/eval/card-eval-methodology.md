# 卡片质量评估方法

## 概述

卡片质量评估采用 **LLM 逐卡评价**，将评分和理由直接嵌入卡片 JSON 的 `_eval` 和 `_eval_r` 字段。每次修复后保存带时间戳的分段分布存档到 `docs/eval/stats_*.md`，使用 Git 跟踪 JSON 变动，实现"修复→验证→存档"的三步闭环。

## 评估文件

| 文件路径 | 范围 | 数量 |
|:---------|:----|:----:|
| `docs/curriculum/prebuilt/cards/chinese_reading_primary.json` | 小学课文 | 409 |
| `docs/curriculum/prebuilt/cards/chinese_reading_extended.json` | 拓展阅读 | 142 |
| `docs/curriculum/prebuilt/cards/chinese_reading_missing.json` | 补录课文 | 45 |

## 评估脚本

`scripts/eval/fix_remaining_eval.py`

```bash
python3 scripts/eval/fix_remaining_eval.py       # 补全缺失的 _eval
```

该脚本读取三份卡片 JSON，对缺少 `_eval` 字段的卡片逐张调 LLM 评估并写入。

## 数据结构

每个卡片包含两个评估字段：

```json
{
  "_eval": {
    "全文完整度": 100,
    "赏析质量": 85,
    "手法分析": 80,
    "主旨概括": 92,
    "易错提示": 65,
    "整体质量": 78
  },
  "_eval_r": {
    "全文完整度": "原文完整，与卡片名称匹配",
    "赏析质量": "赏析选取具体动作细节和心理描写...",
    "手法分析": "准确指出白描、首尾呼应等手法...",
    "主旨概括": "清晰点明父爱主题及思念情感...",
    "易错提示": "指出了曹无伤误认等三个常见错误",
    "整体质量": "核心内容完整，但缺易错提示，影响学习效果"
  }
}
```

| 字段 | 类型 | 说明 |
|:----|:----|:-----|
| `_eval` | dict[str, int] | 6 维度评分（0-100），用于快速筛选和排序 |
| `_eval_r` | dict[str, str] | 6 维度评分理由，用于诊断具体问题和指导修复 |

### 特殊标记

| 标记字段 | 含义 |
|:---------|:-----|
| `_eval_r["全文完整度"] = "评分已修正（原文完整）"` | 该维度已被现实标准覆盖修正 |
| `_eval_r["赏析质量"] = "儿歌/拼音卡，不适用此维度"` | 卡片类型无需此维度 |
| `_eval 中整体质量由剩余维度均值重算` | 针对拼音卡，排除不适用维度后重算 |

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
            print(f'{c['front']:20s}  赏析={ev['赏析质量']:3d}  手法={ev['手法分析']:3d}  | {c['_eval_r']['赏析质量'][:30]}')
"
```

## LLM 调用参数

- **模型**: `deepseek-v4-flash`
- **并发**: 5
- **温度**: 0.0
- **最大输出**: 700 tokens
- **超时**: 120 秒
- **重试**: 3 次，间隔 3-5 秒
- **批大小**: 50 张/批，每批完成后写入文件

## 提示词结构

```
评估学习卡片质量，逐项0-100分。
理由限制40字内，只用一行，禁止换行。
只回JSON，禁用markdown。

卡片: {front}
全文: {full_text[:500]}
赏析: {appreciation[:150]}
手法: {technique[:150]}
主旨: {theme[:80]}
易错: {common_mistakes[:80]}

{"全文完整度":{"s":85,"r":"理由"},"赏析质量":{"s":80,"r":"理由"},
 "手法分析":{"s":75,"r":"理由"},"主旨概括":{"s":90,"r":"理由"},
 "易错提示":{"s":70,"r":"理由"},"整体质量":{"s":82,"r":"理由"}}
```

关键约束（解决 LLM 输出多行 JSON 导致 json.loads 失败的问题）：
- **理由限制 40 字内，只用一行，禁止换行**——避免 `r` 字段包含换行符破坏 JSON
- **禁用 markdown**——避免 LLM 用 ` ```json ` 包裹输出

### 解析流程

```python
raw = API响应["choices"][0]["message"]["content"]

# 1. 剥离 markdown 代码块
raw = re.sub(r'^```(?:json)?\s*', '', raw)
raw = re.sub(r'\s*```$', '', raw)

# 2. 解析 JSON
try:
    j = json.loads(raw)
except json.JSONDecodeError:
    # 回退：正则提取 JSON 块
    m = re.search(r'\{.*"全文完整度".*\}', raw, re.DOTALL)
    if not m: m = re.search(r'\{.*\}', raw, re.DOTALL)
    j = json.loads(m.group(0)) if m else None

if j:
    for dim in EVAL_DIMS:
        v = j.get(dim, {})
        if isinstance(v, dict):
            score = v.get('s', v.get('score', 50))
            reason = v.get('r', v.get('reason', ''))
        elif isinstance(v, (int, float)):
            score = int(v); reason = ''
        else:
            score = 50; reason = ''
        # 清洗理由中的换行
        reason = re.sub(r'\s+', ' ', str(reason)).strip()[:60]
        card['_eval'][dim] = int(score)
        card['_eval_r'][dim] = reason
```

若全部重试失败，返回 `{dim: {s: 50, r: "超时"}}`。

## 拼音/儿歌卡片特殊处理

对于 `card_type == "nursery_rhyme"` 的卡片（拼音课、儿歌），以下维度不适用：

| 维度 | 处理方式 | 理由 |
|:----|:---------|:-----|
| 赏析质量 | **强制 100** | 儿歌/拼音无需文学赏析 |
| 手法分析 | **强制 100** | 儿歌/拼音无需手法分析 |
| 主旨概括 | **强制 100** | 儿歌/拼音无需主旨概括 |
| 易错提示 | **保留原分**（如无内容则 100） | 拼音卡可能有易错点 |

整体质量重算：`(全文完整度 + 赏析质量 + 手法分析 + 主旨概括 + 易错提示) / 5`。

处理后所有 24 张拼音/儿歌卡的整体质量 ≥ 80。

## 全文完整度评分修正（现实标准）

LLM 评分倾向于保守，对篇幅较短的课文也给出低分。评估完成后修正：

| 条件 | 修正后分数 |
|:----|:---------:|
| `card_type == "whole_book"` 且 `summary/back ≥ 100字` | **100** |
| `card_type == "whole_book"` 且 `summary/back ≥ 20字` | **80** |
| `full_text 长度 ≥ 100字` | **100** |
| `full_text 长度 ≥ 50字` | **85** |
| `full_text 长度 ≥ 15字` | **50** |
| `full_text 长度 < 15字` | **0** |

## 分批保存策略

每 50 张卡片为一个批次，每批次完成立即写入文件。
已评估的卡片通过 `_eval` 字段存在判断，恢复运行时自动跳过。

## 存档与版本管理

### 分布存档

每次评估/修复后保存带时间戳的分段分布统计：

```bash
# 手动生成
python3 -c "...统计脚本..." > docs/eval/stats_$(date +%Y%m%d_%H%M%S).md
```

存档位于 `docs/eval/stats_*.md`，包含三份文件各维度的五段分布表（=100 / 85-99 / 70-84 / 60-69 / <60）。
通过对比不同时间戳的存档，验证修复是否生效。

### Git 版本管理

卡片 JSON 和评估文档由 Git 跟踪：

```bash
git log --oneline -- docs/curriculum/prebuilt/cards/chinese_reading_*.json
git diff <commit1> <commit2> -- docs/curriculum/prebuilt/cards/chinese_reading_primary.json
```

基线提交：`cad41f8 "card quality evaluation baseline v1"`

后续每次修复后：
```bash
git add docs/curriculum/prebuilt/cards/chinese_reading_*.json docs/eval/
git commit -m "fix(cards): 具体修复内容描述"
```

## 修复流程规范

每轮修复按此顺序执行，确保不遗漏不倒退：

```
1. 精确扫描 → 基于 _eval/_eval_r 定位问题
2. 精准修复 → 只修有问题的具体字段
3. 重新评估 → 跑 fix_remaining_eval.py 补 _eval
4. 分段存档 → 保存 stats_{timestamp}.md
5. Git 提交 → git commit 记录变更
6. 对比验证 → 对比前后存档确认改善
```

## 低分卡片排查规则

| 卡片类型 | 低分是否正常 | 说明 |
|:---------|:-----------:|:-----|
| `nursery_rhyme` | ❌ 不应低分 | 不适用维度已标记 100，整体 ≥ 80 |
| `poem` | 全文短可能低分 | 古诗全文 20-50 字，全文完整度受长度修正影响 |
| `whole_book` | 全文完整度基于 summary | 应有摘要，赏析/手法字段需单独补充 |
| `vernacular` | 不应低分 | 应有完整全文和分析字段 |
| `foreign` | 不应低分 | 同 vernacular |

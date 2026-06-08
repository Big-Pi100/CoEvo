# chinese.json card_ids 重建方案

## 问题

当前 `chinese.json` 中每个 task 的 `card_ids` 是随机分配的：80% 的词汇卡出现在 2+ 个 task 中，一张卡最多出现在 681 个 task 里，task→卡片的关联没有语义意义。

## 方案

### 核心原则

1. **课文/诗歌/文学卡 → task：一对一**
   - 文学卡（poem/classical/vernacular/nursery_rhyme/foreign/whole_book）的 `front` 与 task `name` 一致
   - 一个 task 匹配一篇文学卡，一张文学卡只属于一个 task（92% 已符合）

2. **词汇卡 → 首次出现的文学卡**
   - 按课标顺序（年级→stage→task）扫描所有文学卡的 `full_text`
   - 词汇卡绑定到**第一个**包含该字的文学卡
   - 一个字在整个学习过程中只出现一次，不会重复

3. **词汇卡 → task**：通过绑定的文学卡传递

### 数据流

```
语文课标顺序（年级 → 册 → 单元 → 课文）
    │
    ▼
文学卡（《沁园春·长沙》full_text="独立寒秋，湘江北去..."）
    │
    ├── 自身 ↔ task "沁园春·长沙"（1:1）
    │
    └── 词汇卡扫描 full_text → 首次出现的字
        如 "独"、"立"、"寒"、"秋"、"湘"、"江"...
        绑定到本 task
```

### 效果对比

| 维度 | 改造前 | 改造后 |
|------|--------|--------|
| 词汇卡-task 唯一性 | 19.9% | 100% |
| 最多 task 引用数 | 681 | 1 |
| 每 task 平均词卡数 | ~240（随机） | 按课文实际字数（几~几十） |
| 语义关联 | ❌ 无 | ✅ 词从课文来 |

### 实施步骤

1. **Python 脚本重建 `chinese.json` 的 `card_ids`**
   - 读取 `chinese_compulsory.json`（3516 张卡）
   - 按课标顺序遍历 plan stages/tasks
   - 对每个 task，匹配文学卡 → 扫描 full_text → 收集首次出现的词卡 UUID
   - 写回 `chinese.json`

2. **清理 DB 中已加载的错误关联**
   - 删除该用户下因旧数据加载的词汇卡（或保持不动，复习 tab 的 task 过滤不受影响）

# Bug Report: 复习页面卡片状态更新问题

## 报告日期
2026-06-08

## 复现场景
1. 账号 test1 / 密码 test123，测试卡片"歌"、"爱"、"徽"。前两张正常，第三张"徽"的状态不更新
2. 判定阶段点击卡片外部（或头部），卡片关闭但判断结果不提交

---

## Bug 1: 间歇性卡片状态更新失败

### 根因分析

**竞态条件**: `_judgeInlineAnswers` 中的 5 秒延迟回调捕获的是**执行时的 `_activeCardIndex`**，而非闭包创建时的值。

**代码位置**: `review_screen.dart:424-426`
```dart
Future.delayed(const Duration(milliseconds: 5000), () {
    if (mounted) _submitInlineReview(_activeCardIndex);  // ← 5秒后 _activeCardIndex 可能已变
});
```

**触发路径**:
1. 用户完成 AI 问答 → 显示结果（pass/fail）
2. 5 秒倒计时开始
3. 在这 5 秒内用户：
   - 点击卡片头部收起（`_activeCardIndex = -1`）
   - 切换到其他卡片（`_activeCardIndex = i'`）
4. 5 秒后回调执行 → `_activeCardIndex` 指向错误的位置
5. `_submitInlineReview(440)` 的越界检查 `if (index >= displayCards.length) return;` 静默退出
6. 卡片状态**永远不更新**

**为什么"徽"容易触发？** 因为"徽"可能是字迹辨认较难的汉字，用户看完判断结果后需要更长时间思考，在 5 秒等待期间更容易操作其他卡片。

### 影响范围
- **频率**: 中（取决于用户操作速度）
- **严重度**: **P1** — 卡片状态不更新意味着 FSRS 调度失效，复习进度丢失
- **波及**: 所有卡片都可能触发，与科目无关

---

## Bug 2: 判定过程中关闭卡片不保存

### 根因分析

`onTap` 处理程序直接设 `_activeCardIndex = -1`，没有判断当前是否处于判定流程中。

**代码位置**: `review_screen.dart:872-874`
```dart
onTap: () {
    if (isActive) {
        setState(() => _activeCardIndex = -1);  // ← 直接关闭，不检查判定状态
    } else {
```

### 影响范围
- **频率**: 高（用户很容易误触）
- **严重度**: **P2** — 体验问题，用户失去本次判定结果
- **波及**: 所有卡片

---

## 修复方案

### 方案 A（推荐，同时修复两个 Bug）

| 变更 | 文件 | 描述 |
|------|------|------|
| **A1** | review_screen.dart:424 | 用 `card.id` 替代 `_activeCardIndex`，按 ID 查找提交 |
| **A2** | review_screen.dart:872-874 | 判定进行中时阻止关闭，提示用户"判定进行中" |

**A1 具体代码**:
```dart
// 改为通过 card ID 提交，消除索引竞态
final cardId = card.id;
Future.delayed(const Duration(milliseconds: 5000), () {
    if (mounted) _submitInlineReviewByCardId(cardId);
});
```

新增方法 `_submitInlineReviewByCardId`：
```dart
Future<void> _submitInlineReviewByCardId(String cardId) async {
    final idx = _filteredCards.indexWhere((c) => c.id == cardId);
    if (idx < 0) return;
    await _submitInlineReview(idx);
}
```

**A2 具体代码**:
```dart
onTap: () {
    if (isActive) {
        if (_isVerifying || _isJudging) {
            // 判定进行中，阻止关闭
            return;
        }
        setState(() => _activeCardIndex = -1);
    } else {
        if (_isVerifying || _isJudging) {
            // 同样阻止切换
            return;
        }
        setState(() => _activeCardIndex = i);
        _resetInlineReview();
        ...
    }
}
```

### 方案 B（仅修复 Bug 1）

只改 A1，不阻止切换。Bug 2 不予处理。

### 方案选择建议

**选方案 A**：两个 Bug 都修，改动量小（~10 行），风险低。

# iOS 独有：松手后选区**手柄消失**，无法两头调整（2026-10-11）

> 白哥：「iOS 端有个独有的 BUG，长按的时候只有一直按着直接选择，**停了以后就不能用两头光标调整**，
> 而安卓端的选中内容两头是有光标的，可以调整。」

**只调查，未改码。**

---

## 〇、结论先行

| 问题 | 判断 |
|---|---|
| 是 Flutter 的已知平台差异吗 | **一半是** —— iOS 确实与 Android 不同（见 §一），但**它本来应该正常工作** |
| 真正的触发者 | 🔴 **我们自己的代码**：`WordLookupSelection` 在选区出现时 `setState`，**改变了 `SelectionArea` 的 child widget 类型** ⇒ 选区子树被重建 ⇒ 手柄 overlay 被销毁 |
| 为什么安卓没事 | ✅ **安卓有兜底**：它在「长按**结束**」时**重新显示手柄**；iOS 只在「长按**开始**」显示一次 ⇒ **iOS 一旦丢了就再也回不来** |
| 修法 | 让 child **结构恒定**（`GestureDetector` 始终在场，只切换 `onTap` 是否为 `null`）—— 与原行为**等价**（`onTap == null` 时 Flutter 本就不注册识别器） |

---

## 一、Flutter 源码：两个平台的**时机不同**（这是「iOS 独有」的前置条件）

`packages/flutter/lib/src/widgets/selectable_region.dart`：

```dart
void _handleTouchLongPressStart(LongPressStartDetails details) {      // :1000
  ...
  // Platforms besides Android will show the text selection handles when
  // the long press is initiated. Android shows the text selection handles when
  // the long press has ended, usually after a pointer up event is received.
  if (defaultTargetPlatform != TargetPlatform.android) {
    _showHandles();            // ← iOS：**长按一开始**就显示手柄
  }
  _updateSelectedContentIfNeeded();
}

void _handleTouchLongPressEnd(LongPressEndDetails details) {          // :1020
  _finalizeSelection();
  _updateSelectedContentIfNeeded();
  _finalizeSelectableRegionStatus();
  _showToolbar();
  if (defaultTargetPlatform == TargetPlatform.android) {
    _showHandles();            // ← Android：**长按结束**再显示一次（= 兜底）
  }
}
```

⇒ **`_handleTouchLongPressEnd` 里 iOS 没有 `_showHandles()`** ——
这是设计（iOS 期望手柄从长按一开始就一直在），但**它是一个「没有兜底」的路径**。

### 手柄是怎么被销毁的（同文件）

```dart
void _updateSelectionStatus() {                                       // :544
  ...
  if (_hasSelectionOverlayGeometry) {
    _updateSelectionOverlay();
  } else {
    _selectionOverlay?.dispose();
    _selectionOverlay = null;      // 🔴 手柄 overlay 被销毁
  }
}
```

而 `_hasSelectionOverlayGeometry` 要求**两端都能算出选区几何**：

```dart
bool _showHandles() {                                                 // :1329
  if (_selectionOverlay != null) { _selectionOverlay!.showHandles(); return true; }
  if (!_hasSelectionOverlayGeometry) return false;   // 🔴 几何取不到 ⇒ 手柄建不出来
  _createSelectionOverlay();
  _selectionOverlay!.showHandles();
  return true;
}
```

---

## 二、🔴 触发者：我们把 `SelectionArea` 的 child **换了一种 widget**

`app/lib/widgets/word_lookup_selection.dart`：

```dart
void _onSelectionChanged(SelectedContent? content) {
  final text = _cleanPicked(content?.plainText);
  _picked = text;
  final active = text.isNotEmpty;
  if (active != _selectionActive) {
    setState(() => _selectionActive = active);     // ← 选区一出现就重建
  }
}

// build 里：
final body = widget.child;
final withTap = widget.onTap == null || _selectionActive
    ? body                                                    // ← 有选区 ⇒ 裸 body
    : GestureDetector(onTap: widget.onTap, behavior: ..., child: body);   // ← 无选区 ⇒ 包一层

return SelectionArea(child: withTap);                          // ← child 的**类型变了**
```

⇒ `_selectionActive` 从 `false` 变 `true` 时，`SelectionArea` 的 child 从
**`GestureDetector`** 变成 **`body`** —— **widget 类型不同 ⇒ Flutter 卸载旧 Element 树、重建新的**
（这是 Flutter 的确定性行为，不是推断）。

### 为什么这会让手柄消失

| 环节 | 后果 |
|---|---|
| `Selectable`（选区子树）被重建 | 新的 RenderObject 注册进 `SelectionRegistrar` |
| 而 `_selectionDelegate.value` 里的 `SelectionPoint` **仍指向旧 RenderObject** | 旧对象已 unmount ⇒ **算不出选区几何** |
| ⇒ `_hasSelectionOverlayGeometry == false` | `_updateSelectionStatus()` 走 else 分支 ⇒ **`_selectionOverlay.dispose()`** |
| iOS：长按**结束**不再 `_showHandles()` | ⇒ **手柄永久消失** ❌ |
| Android：长按结束 `_showHandles()` | ⇒ **手柄恢复** ✅ |

**⚠️ 菜单为什么还在？** 因为 `_showToolbar()` 里若 overlay 为 `null` 会**重新创建**它
（`:1366-1368`）⇒ 菜单正常、手柄不显示 —— 与白哥「能点划线、但两头没光标」**逐字吻合**。

### 时序（与白哥的描述完全对应）

```
① 长按开始 → _selectWordAt（选中一个词）→ _showHandles()   ← 手柄出现 ✅
② onSelectionChanged → 我们 setState → 下一帧 rebuild
   → child 类型变 ⇒ 选区子树重建 ⇒ 几何失效 ⇒ overlay dispose   ← 手柄消失
③ 继续拖动 → _selectEndTo → 选区在更新（所以「一直按着能选」）✅
   但 MoveUpdate 里**没有** _showHandles ⇒ 手柄不回来
④ 松手 → _showToolbar（菜单出现 ✅）· iOS 不再 _showHandles ⇒ 手柄永远不回 ❌
```

---

## 三、修法（1 处）

**让 child 结构恒定** —— `GestureDetector` 始终在场，只切换 `onTap`：

```dart
final body = widget.child;
final withTap = widget.onTap == null
    // 这个页面本来就没有「单击」需求 ⇒ 结构恒定（永远是 body）
    ? body
    // 🔑 **两种情况下都是 `GestureDetector`** —— 只有 `onTap` 在 null 与回调之间切换。
    //    ⚠️ 这是**等效**的：Flutter 的 `GestureDetector` 在 `onTap == null` 时
    //    **不注册** `TapGestureRecognizer` ⇒ 事件照旧落到 `SelectableRegion`
    //    （原实现「整块不创建」与「创建但不注册识别器」在事件分发上等价）。
    : GestureDetector(
        onTap: _selectionActive ? null : widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: body,
      );
```

✅ **不违反原判据**：文件头写的是「必须靠**注册与否**分流，不能靠 handler 里 `return`」——
这里正是「注册与否」（`onTap: null` ⇒ 不注册），不是 handler 短路。

✅ **行为等价性**：`hitTestChildren` 先跑（子节点照常进竞技场，内层先赢）；`GestureDetector`
自身在无识别器时不消费事件。

⚠️ 代价：`onTap != null` 的页面会**恒多一个 `Listener`**（无手势时只多一次 hit test entry）。可忽略。

---

## 四、为什么本地验不了 / 怎么验

| 项 | 说明 |
|---|---|
| ❌ 本机无 iOS 模拟器 / 无 Mac | 这个 bug **只在 iOS 上出现**（安卓有兜底）⇒ **必须真机验** |
| ✅ 可加断言 | `word_lookup_selection.dart` 里 `_selectionActive` **不得出现在「决定 widget 类型」的位置**（只允许出现在参数里）—— 见 §五 |
| ✅ 真机判据 | iOS 上长按选中后**松手** → 应出现**两头手柄**且能拖动调整；安卓行为**不得变化** |

---

## 五、建议加的断言（防复发）

```dart
// ① 结构恒定：`_selectionActive` 只能出现在 onTap 的**参数**位置
check('withTap 的 widget 类型不随选区变化',
    src.contains('onTap: _selectionActive ? null : widget.onTap'));
// ② 反向：不得再有「有选区 ⇒ 裸 body」的三元分支
check('不再有 `|| _selectionActive` 决定是否包 GestureDetector',
    !src.contains('widget.onTap == null || _selectionActive'));
```

⚠️ 这两条是**文本断言**（弱判据）—— 真正的证据只能是真机。
📌 但它们能锁住「**别把结构改回去**」，而这正是本次的唯一成因。

---

## 六、附带值得记的一条

🔴 **「平台差异掩盖的结构问题」**：同一个反模式（选区变化 → 重建选区子树）在 Android 上
被它的「长按结束再显示一次」掩盖了整整一个开发周期 ⇒ **只在 iOS 上暴露**。
📌 判据：**两个平台行为不同时，先查「是不是某一方有兜底」，而不是直接假定「平台差异不可修」**。

---

## 附：关键代码位置

| # | 位置 | 作用 |
|---|---|---|
| 1 | `selectable_region.dart:1000` / `:1020` | 手柄显示的**平台时机差异**（iOS 开头 / Android 结尾） |
| 2 | `selectable_region.dart:544` | `_updateSelectionStatus` —— 几何失效时 **dispose 手柄 overlay** |
| 3 | `selectable_region.dart:1329` | `_showHandles` —— 几何取不到就**建不出来** |
| 4 | `selectable_region.dart:1366` | `_showToolbar` 会**重建** overlay ⇒ **菜单在、手柄不在** |
| 5 | `word_lookup_selection.dart` → `_onSelectionChanged` + `build` 的 `withTap` | 🔴 **触发点** |

*2026-10-11 · 方法：读 Flutter SDK 源码（本机 D:\flutter）+ 读本项目手势层；未采信记忆*

---

## 七、实施记录（白哥批「修」）

### 7.1 改动（1 处）

`app/lib/widgets/word_lookup_selection.dart` → `build`：

```dart
// 🔴 旧（这次 iOS 手柄消失的成因）
final withTap = widget.onTap == null || _selectionActive
    ? body
    : GestureDetector(onTap: widget.onTap, behavior: HitTestBehavior.opaque, child: body);

// ✅ 新（child 类型恒定，只切参数）
final withTap = widget.onTap == null
    ? body                                          // 该页无「单击」需求 ⇒ 恒定不包
    : GestureDetector(
        onTap: _selectionActive ? null : widget.onTap,   // ← 只切 onTap，不切 widget 类型
        behavior: HitTestBehavior.opaque,
        child: body,
      );
```

**行为等价性**：`onTap: null` ⇒ Flutter **不创建** `TapGestureRecognizer`
（`GestureDetector` 的 `gestures` 里没有它）⇒ 事件照旧落到 `SelectableRegion`
⇒「单击清空选区」**一字不差**。
✅ **不违反原判据** —— 文件头写的是「要让出事件，**只能不注册识别器**」，
这里正是「不注册」（而非 handler 里 `return`，那会吃掉这次点击）。

### 7.2 新增断言脚本（防复发）

`scripts/query_verify/bin/verify_selection_gesture_structure.dart` —— **10 项**：

| # | 判据 |
|---|---|
| ①-2 | 🔴 `withTap` 的**三元条件**里不得含选区状态（= child 类型恒定）——**本 bug 的直接判据** |
| ①-3 | 「让出单击」必须是 `onTap: _selectionActive ? null : widget.onTap` |
| ①-4 | `GestureDetector(` 在该语句里**只有一处**构造（两分支各写一个同样是错的） |
| ①-5 | 🔴 **反向**：短路反模式 `\|\| _selectionActive` 不得再出现 |
| ② | `withTap` 仍挂在 `SelectionArea(child:)` 上 · `SelectionArea(` 只构造一处 |
| ③ | **全项目**扫描：凡用 `SelectionArea` 的文件，child 不得用「三元 + 选区状态」 |

📌 ③ 是 ① 的**通用版** —— ① 只锁 `withTap` 这个名字，**将来别处复发它看不见**。

### 7.3 验证

| 项 | 结果 |
|---|---|
| 新脚本 | ✅ **10 项全过** |
| 人为证伪（改回旧反模式） | ✅ **精确红 3 项**（①-2 / ①-3 / ①-5），复原后回绿 · 无 `ZF-` 残留 |
| `analyze_inproc --errors-only` | ✅ **0 error** |
| `query_verify` 全套 53 个脚本 | ✅ **fail = 0** |

### 7.4 ⚠️ 这条修复**本机证不了** —— 只能真机

| 平台 | 真机判据 |
|---|---|
| **iOS** | 长按选中 → **松手后应出现两头手柄**，且能拖动调整（这是本次要修的唯一目标） |
| **安卓** | 行为**不得变化**：单击正文仍弹「阅读设置」、**有选区时单击仍清空选区**、长按拖动仍能选 |

📌 本脚本是**防复发**（锁结构），**不是证真**（iOS 渲染本机跑不了）。

*2026-10-11 · 实施：改 1 处 + 新增 10 项结构断言 + 证伪*

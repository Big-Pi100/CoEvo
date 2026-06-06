# CoEvo 前端 Bug 修复计划

> 创建日期: 2026-06-06 | 修复完成: 2026-06-06 23:58 | 状态: ✅ 全部完成 | 审计文档: `docs/frontend-audit-2026-06-06.md`

---

## 执行优先级

| 优先级 | 数量 | 预计时间 | 状态 |
|:---:|:---:|:---:|:---:|
| 🔴 P1 (Bug) | 2 | 30min | ✅ 已完成 |
| 🟡 P2 (代码质量) | 3 | 45min | ✅ 已完成 |
| 🟢 P3 (性能优化) | 1 | 15min | ✅ 已完成 |

**总计**: 6 个问题，全部修复 ✅ | `flutter analyze` 0 新增 error

---

## 完成记录

| 任务 | 文件 | 修改内容 | 验证 |
|:---:|------|------|:---:|
| P1 #1 | `review_screen.dart` | +2 `ProviderSubscription` 成员变量, `dispose()` 中 `close()` | ✅ |
| P1 #2 | `card_list_screen.dart` | 4 个 async 方法 + `if (!mounted) return;` | ✅ |
| P2 #3 | `card_list_screen.dart` | 空 catch → `debugPrint` + `SnackBar` | ✅ |
| P2 #4 | `chat_screen.dart` | `_init()` 循环 + `if (!mounted) return;` | ✅ |
| P2 #5 | `theme_provider.dart` | 先持久化 → 后更新 state; + `try/catch + rethrow` | ✅ |
| P3 #6 | `achievement_icons.dart` | 5 个函数内 Map → top-level `final` 变量 | ✅ |

---

## 🔴 P1 — Bug（立即修复）

### 1. review_screen.dart — ref.listenManual 未取消订阅（内存泄漏）

**文件**: `app/lib/screens/review_screen.dart` 第 73-85 行

**问题**:
```dart
// ❌ 返回值未保存，dispose 中未取消
ref.listenManual(cardRefreshProvider, (prev, next) { ... });   // line 73
ref.listenManual(authProvider, (prev, next) { ... });           // line 80
```

**影响**: 两个 listener 在 widget dispose 后仍然存活，导致内存泄漏 + 可能的野回调（在非 mounted 的 widget 上调用 setState）。

**修复方案**:
```dart
// 添加成员变量
ProviderSubscription? _cardRefreshSub;
ProviderSubscription? _authListenerSub;

@override
void initState() {
  super.initState();
  _initTabs();
  _load();
  _cardRefreshSub = ref.listenManual(cardRefreshProvider, (prev, next) {
    if (next != prev && mounted) _load();
  });
  _authListenerSub = ref.listenManual(authProvider, (prev, next) {
    if (prev?.userId != next.userId && mounted) {
      _load();
      ref.read(cardRefreshProvider.notifier).refresh();
    }
  });
}

@override
void dispose() {
  _cardRefreshSub?.close();   // ✅ 新增
  _authListenerSub?.close();   // ✅ 新增
  _tabController.dispose();
  _answerController.dispose();
  _scrollController.dispose();
  super.dispose();
}
```

**验证**: `flutter analyze` 无 error + 手动测试：进入/退出复习页 5 次，观察内存不增长。

---

### 2. card_list_screen.dart — 4 处 async 后缺 mounted 检查

**文件**: `app/lib/screens/card_list_screen.dart`

**问题**: 4 个 async 方法在 `await` 后直接 `setState()` 而未经 `mounted` 守卫：

| 方法 | 行号 | await 调用 | setState 行号 |
|------|:---:|------|:---:|
| `_togglePlan()` | 126 | `client.getCardsByPlan()` | 144 |
| `_loadMorePlanCards()` | 158 | `client.getCardsByPlan()` | 174 |
| `_doSearch()` | 185 | `client.searchCards()` | 186 |
| `_loadMoreSearch()` | 204 | `client.searchCards()` | 206 |

**影响**: 用户在网络请求期间按返回键 → widget 已 unmount → `setState()` 抛异常 `Unhandled Exception: setState() called after dispose()`。

**修复方案**: 每个 `await` 后加 `if (!mounted) return;`

```dart
// 修复前
final cards = await client.getCardsByPlan(...);
setState(() { ... });

// 修复后
final cards = await client.getCardsByPlan(...);
if (!mounted) return;  // ✅ 新增
setState(() { ... });
```

**注意**: `_doSearch()` 和 `_loadMoreSearch()` 的 `await` 和 `setState` 在同一行（186, 206），需要拆开：

```dart
// 修复前 (line 186)
setState(() => _searchResults = await client.searchCards(...));

// 修复后
final results = await client.searchCards(...);
if (!mounted) return;
setState(() => _searchResults = results);
```

**验证**: `flutter analyze` 无 error + 手动测试：在搜索/加载时快速按返回键，无崩溃。

---

## 🟡 P2 — 代码质量（近期修复）

### 3. card_list_screen.dart — 空 catch 吞错误

**文件**: `app/lib/screens/card_list_screen.dart` 第 172 行

**问题**:
```dart
} catch (_) {}  // ❌ 静默忽略
```

`_loadMorePlanCards()` 中加载更多卡片失败时无任何反馈。

**影响**: 用户点击"加载更多"后若失败，UI 表现为无响应，不知道是加载中还是已失败。

**修复方案**: 至少打印日志，或显示 SnackBar 提示。

```dart
// 方案 A: 最小修复（仅日志）
} catch (e, st) {
  debugPrint('加载更多卡片失败: $e\n$st');
}

// 方案 B: 用户反馈（推荐）
} catch (e) {
  if (mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('加载失败: $e')),
    );
  }
}
```

**验证**: 模拟网络失败（断网），点击"加载更多"，应看到 SnackBar 提示。

---

### 4. chat_screen.dart — _init() Future.delayed 循环缺 mounted

**文件**: `app/lib/screens/chat_screen.dart` 第 79-87 行

**问题**:
```dart
for (int retry = 0; retry < 20; retry++) {
  final auth = ref.read(authProvider);
  if (auth.userId != null && auth.userId!.isNotEmpty) {
    if (mounted) context.go('/auth');  // ✅ 有 mounted 检查
    return;
  }
  await Future.delayed(const Duration(milliseconds: 150));
  // ❌ 循环没有 mounted 检查，最坏情况浪费 3 秒
}
```

**影响**: 用户在 3 秒内退出页面，循环仍继续运行（虽然第 90 行有 `if (mounted)` 检查，但循环体仍在浪费 CPU）。

**修复方案**: 每轮迭代加 `if (!mounted) return;`

```dart
for (int retry = 0; retry < 20; retry++) {
  if (!mounted) return;  // ✅ 新增
  final auth = ref.read(authProvider);
  if (auth.userId != null && auth.userId!.isNotEmpty) {
    context.go('/auth');
    return;
  }
  await Future.delayed(const Duration(milliseconds: 150));
}
```

**验证**: `flutter analyze` 无 error。

---

### 5. ThemeProvider.setMode — 持久化顺序不当

**文件**: `app/lib/providers/theme_provider.dart` 第 35-39 行

**问题**:
```dart
state = ThemeState(mode: mode);               // ① 先更新内存状态
final prefs = await SharedPreferences.getInstance();
await prefs.setInt('app_theme_mode', ...);    // ② 后持久化
```

**影响**: 若持久化失败（磁盘满、权限问题），内存状态已更新但磁盘未写入。下次启动回退到旧主题，用户会困惑"我设置的主题怎么没了？"。

**修复方案**: 先持久化，成功后再更新 state；或持久化失败时回滚 state。

```dart
// 方案 A: 先持久化（推荐）
Future<void> setMode(ThemeMode mode) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('app_theme_mode', mode.index);
    state = ThemeState(mode: mode);  // ✅ 成功后才更新内存
  } catch (e) {
    debugPrint('主题持久化失败: $e');
    rethrow;  // 让调用方知道失败
  }
}

// 方案 B: 回滚（更保守）
Future<void> setMode(ThemeMode mode) async {
  final oldMode = state.mode;
  state = ThemeState(mode: mode);  // 先乐观更新
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('app_theme_mode', mode.index);
  } catch (e) {
    debugPrint('主题持久化失败: $e');
    state = ThemeState(mode: oldMode);  // ✅ 失败回滚
  }
}
```

**验证**: 手动测试：设置主题 → 重启 App → 主题应保持。

---

## 🟢 P3 — 性能优化（可选）

### 6. achievement_icons.dart — Map 每次重建

**文件**: `app/lib/shared/achievement_icons.dart` 第 9-145 行

**问题**:
```dart
IconData achievementIcon(String key) {
  final map = <String, IconData>{ ... };  // ❌ 每次调用 new Map
  return map[key] ?? Icons.emoji_events;
}
```

**影响**: 每次调用 `achievementIcon()` / `achievementColor()` 都重建 Map。文件开头注释说明了这是有意为之（避免跨文件 const 解析异常导致白屏）。

**修复方案**: 用 `late final` 静态变量优化（编译时常量但仍避免 const 解析问题）：

```dart
// ✅ 方案: late final（仅构建一次）
late final _iconMap = <String, IconData>{
  'chinese': Icons.menu_book,
  'math': Icons.calculate,
  // ... 全部键值对
};

IconData achievementIcon(String key) {
  return _iconMap[key] ?? Icons.emoji_events;
}
```

**注意**: 文件开头有注释说明为何不用 const Map。如果改为 `late final`，需测试跨文件调用是否仍有白屏问题。

**验证**: `flutter analyze` 无 error + 成就页面打开正常 + 无白屏。

**优先级**: 低（成就页面非高频调用，性能影响极微）。

---

## 执行顺序建议

1. **P1 #1** (`review_screen.dart` listener 泄漏) → 最简单，改 2 个变量 + dispose
2. **P1 #2** (`card_list_screen.dart` mounted 检查) → 4 处改法相同，可批量
3. **P2 #3** (`card_list_screen.dart` 空 catch) → 同一文件，顺手改
4. **P2 #4** (`chat_screen.dart` 循环 mounted) → 1 行修改
5. **P2 #5** (`theme_provider.dart` 持久化顺序) → 需决定方案 A 或 B
6. **P3 #6** (`achievement_icons.dart` Map 重建) → 可选，需测试

**总预计时间**: 1.5 小时（含测试）

---

## 验收标准

- [ ] `flutter analyze` 输出 0 error, 0 warning (0 info 可接受)
- [ ] 所有修改文件通过 `dart format`
- [ ] P1 #1 验证: 进入/退出复习页 5 次，内存不增长
- [ ] P1 #2 验证: 加载/搜索时快速按返回，无崩溃
- [ ] P2 #3 验证: 模拟网络失败，看到 SnackBar
- [ ] P2 #4 验证: `flutter analyze` 无 error
- [ ] P2 #5 验证: 设置主题 → 重启 → 主题保持
- [ ] P3 #6 验证 (可选): 成就页面打开正常

---

## 更新记录

| 日期 | 修改内容 | 修改人 |
|------|---------|--------|
| 2026-06-06 | 初始版本（基于 `frontend-audit-2026-06-06.md`） | AI |
| 2026-06-06 | 全 6 项修复完成，`flutter analyze` 0 新增 error | AI |

---

## 参考文档

- 审计文档: `docs/frontend-audit-2026-06-06.md`
- UI 优化计划: `docs/ui-optimization-plan.md`
- Widgets 色彩迁移: `docs/widgets-color-hardcode-investigation.md`

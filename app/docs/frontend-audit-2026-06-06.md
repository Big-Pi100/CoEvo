# CoEvo 前端审计报告

> 日期: 2026-06-06 | 审计范围: `app/lib/` (screens / widgets / shared / providers / api)

## 审计总结

对 Flutter 前端进行多维扫描：色彩一致性、状态管理、错误处理、内存泄漏、异步安全、空安全。共发现 **2 个 P1 Bug、3 个 P2 代码质量、1 个 P3 优化**。

---

## P1 — Bug（建议立即修复）

### 1. review_screen.dart — ref.listenManual 未取消订阅（内存泄漏）

**文件**: `app/lib/screens/review_screen.dart` 第 73-85 行

```dart
// ❌ 返回值未保存，dispose 中未取消
ref.listenManual(cardRefreshProvider, (prev, next) { ... });   // line 73
ref.listenManual(authProvider, (prev, next) { ... });           // line 80
```

`ref.listenManual()` 返回 `ProviderSubscription`，必须手动关闭。当前 `dispose()` 只清理了 `_tabController/_answerController/_scrollController`，两个 listener 泄漏。

**对比**: `profile_screen.dart` 正确保存了 `_authSub` 并在 dispose 中 `_authSub?.close()`。

**修复**:
```dart
ProviderSubscription? _cardRefreshSub;
ProviderSubscription? _authListenerSub;

@override
void initState() {
  super.initState();
  _cardRefreshSub = ref.listenManual(cardRefreshProvider, (prev, next) { ... });
  _authListenerSub = ref.listenManual(authProvider, (prev, next) { ... });
}

@override
void dispose() {
  _cardRefreshSub?.close();
  _authListenerSub?.close();
  _tabController.dispose();
  _answerController.dispose();
  _scrollController.dispose();
  super.dispose();
}
```

### 2. card_list_screen.dart — async 后缺 mounted 检查

**文件**: `app/lib/screens/card_list_screen.dart`

4 个 async 方法在 `await` 后直接 `setState()` 而未经 `mounted` 守卫：

| 方法 | 行号 | await 调用 | setState 行号 |
|------|:---:|------|:---:|
| `_togglePlan()` | 126 | `client.getCardsByPlan()` | 144 |
| `_loadMorePlanCards()` | 158 | `client.getCardsByPlan()` | 174 |
| `_doSearch()` | 185 | `client.searchCards()` | 186 |
| `_loadMoreSearch()` | 204 | `client.searchCards()` | 206 |

如果用户在网络请求期间按返回键，widget 已 unmount，`setState` 会抛异常。

**修复**: 每个 `await` 后加 `if (!mounted) return;`

---

## P2 — 代码质量（建议近期修复）

### 3. card_list_screen.dart — 空 catch 吞错误

**文件**: `app/lib/screens/card_list_screen.dart` 第 172 行

```dart
} catch (_) {}  // ❌ 静默忽略
```

`_loadMorePlanCards()` 中加载更多卡片失败时无任何反馈。用户点击"加载更多"后若失败，UI 表现为无响应且无提示。

**修复**: 至少打印日志，或显示 SnackBar 提示。

### 4. chat_screen.dart — _init() Future.delayed 循环缺 mounted

**文件**: `app/lib/screens/chat_screen.dart` 第 79-87 行

```dart
for (int retry = 0; retry < 20; retry++) {
  final auth = ref.read(authProvider);
  if (auth.userId != null && auth.userId!.isNotEmpty) { ... }
  await Future.delayed(const Duration(milliseconds: 150));
}
```

循环内没有 `if (!mounted) break;`。如果用户在 3 秒内退出页面，循环可能继续运行并在 unmount 后调用 `context.go('/auth')`（第 90 行虽已有 `mounted` 检查，但循环体仍浪费 3 秒）。

**修复**: 每轮迭代加 `if (!mounted) return;`

### 5. ThemeProvider.setMode — 持久化顺序不当

**文件**: `app/lib/providers/theme_provider.dart` 第 35-39 行

```dart
state = ThemeState(mode: mode);               // ① 先更新内存状态
final prefs = await SharedPreferences.getInstance();
await prefs.setInt('app_theme_mode', ...);    // ② 后持久化
```

若持久化失败（磁盘满、权限问题），内存状态与磁盘不一致。下次启动回退到旧主题。

**修复**: 先持久化，成功后再更新 state；或持久化失败时回滚 state。

---

## P3 — 性能优化（可选）

### 6. achievement_icons.dart — Map 每次重建

**文件**: `app/lib/shared/achievement_icons.dart` 第 9-145 行

```dart
IconData achievementIcon(String key) {
  final map = <String, IconData>{ ... };  // 每次调用 new Map
  return map[key] ?? Icons.emoji_events;
}
```

文件开头注释说明了这是有意为之（避免跨文件 const 解析异常导致白屏）。可优化为 `late final` 静态变量，编译时常量但仍避免 const 解析问题：

```dart
late final _iconMap = <String, IconData>{ ... };
```

不过性能影响极微（成就页面非高频调用），优先级低。

---

## 其他观察

### debugPrint 残留（50+ 处）

分布在 10+ 个文件中。Flutter 的 `debugPrint` 在 release 模式下**仍会输出**（不像 `assert` 被编译移除）。对性能无影响但对生产日志有噪音。建议统一用 `if (kDebugMode) debugPrint(...)` 包裹。

### 空安全 — 审查通过

大部分 `auth.userId!` 使用前都有 `if (auth.userId == null) return;` 守卫。仅 `_togglePlan()` 和 `_loadMorePlanCards()` 缺守卫，但由于这两个方法仅从已认证页面调用，实际不会触发 null。

### widgets/ 色彩迁移 — 确认完成

参见 `docs/widgets-color-hardcode-investigation.md`，widgets/ 目录已零残余。

---

## 验证过的误报

| 检查项 | 结论 |
|------|------|
| AuthProvider.isLoading 未重置 | ✅ 状态正常。`AuthState` 构造函数默认 `isLoading: false` |
| profile_screen listener 未取消 | ✅ 已保存 `_authSub` 并在 dispose 中 `close()` |
| chat_client.dart 空 catch | ✅ 未找到。该文件错误处理完整 |
| Image.network 无 errorBuilder | ✅ 未使用 Image.network |
| ListView.builder 无 itemCount | ✅ 全部指定了 itemCount |

---

## 修复计划

详细修复步骤、代码示例、验证方法已整理到独立文档：

📋 **修复计划**: [`docs/frontend-bug-fix-plan.md`](./frontend-bug-fix-plan.md)

| 优先级 | 问题数 | 预计时间 | 文档章节 |
|:---:|:---:|:---:|:---:|
| 🔴 P1 (Bug) | 2 | 30min | [P1 — Bug](#p1--bug立即修复) |
| 🟡 P2 (代码质量) | 3 | 45min | [P2 — 代码质量](#p2--代码质量近期修复) |
| 🟢 P3 (性能优化) | 1 | 15min | [P3 — 性能优化](#p3--性能优化可选) |

**建议执行顺序**: P1 #1 → P1 #2 → P2 #3 → P2 #4 → P2 #5 → P3 #6

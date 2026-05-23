# 复习 + 卡片页合并计划

> 日期: 2026-05-17

---

## 一、影响范围总览

| 文件 | 改动类型 | 行数 | 说明 |
|------|---------|------|------|
| `app.dart` | 删 3 行 + 改 1 行 | ~5 | 删 /cards 分支 + 导航项 |
| `review_screen.dart` | 重构 | 846 | 加 TabController，嵌入卡片列表 |
| `card_list_screen.dart` | 改为 widget | 691 | 提取为可嵌入组件 |
| `home_screen.dart` | 改 1 行 | ~1 | "我的卡片"按钮跳转目标 |

**不涉及**: `profile_screen.dart`, `chat_screen.dart`, API client, models, providers

---

## 二、具体改动

### Step 1: `card_list_screen.dart` → 嵌入式 Widget

- 保留 `CardListScreen` 类，但去掉 `Scaffold`
- 改为接收 `TabController` 作为可选参数，页面内不重复创建
- 实际内容提取为 `CardListBody` widget

### Step 2: `review_screen.dart` → 合并页

```
Scaffold
  appBar: "复习"
  body: Column
    ├── TabBar [待复习(3), 全部卡片]
    └── TabBarView
         ├── 待复习 (现有复习逻辑)
         └── 全部卡片 (CardListBody)
```

- 顶部加水平 Tab，和对话列表风格一致
- `DefaultTabController(length: 2)` 管理
- 待复习 Tab 保留现有复习流程
- 全部卡片 Tab 嵌入 `CardListBody`

### Step 3: `app.dart` → 删分支 + 导航项

```diff
- StatefulShellBranch(routes: [
-   GoRoute(path: '/cards', builder: ...),
- ]),
- NavigationDestination(icon: Icons.auto_stories..., label: '卡片'),
```

底部导航: 对话 / 复习 / 个人（3 项）

### Step 4: `home_screen.dart` → 按钮目标

```diff
- onTap: () => context.push('/cards'),
+ onTap: () => context.go('/review'),
```

---

## 三、风险评估

| 风险 | 等级 | 缓解 |
|------|------|------|
| 复习页变大 | 🟢 | Tab 隔离，不互相影响 |
| Tab 切换丢失复习状态 | 🟡 | `IndexedStack` 保持两个 Tab 存活 |
| 卡片列表嵌入后样式异常 | 🟢 | CardListScreen 已有独立 Scaffold → 去掉包裹 |
| 底部导航 3 项不稳定 | 🟢 | GoRouter StatefulShellRoute 天然支持可变数量 |
| HomeScreen 按钮失效 | 🟢 | 仅改一行跳转 |

---

## 四、预估

| 步骤 | 时间 |
|------|------|
| card_list_screen 去 Scaffold / 提取 Body | 15 min |
| review_screen 加 Tab + 嵌入 | 20 min |
| app.dart 删路由 + 导航项 | 5 min |
| home_screen 改按钮 | 1 min |
| 编译验证 + 路由测试 | 10 min |
| **合计** | **~50 min** |

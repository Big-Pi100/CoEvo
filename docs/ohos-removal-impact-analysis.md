# 移除鸿蒙环境后 Web 构建失败 · 根因分析报告

> 日期：2026-05-16
> 触发事件：删除 `app/ohos/` 目录，使用 ohos Flutter SDK 运行 `flutter run --release -d edge`

---

## 一、因果关系链

```
删除 app/ohos/ 目录（330MB 构建配置）
  │
  ├─ 意图：放弃鸿蒙平台支持，回归纯 Web 开发
  │
  └─ 事实：PATH 仍指向 ohos Flutter SDK (D:/flutter_ohos)
       │
       ├─ ohos Flutter SDK 在 Flutter Framework 中引入了 TargetPlatform.ohos
       │   路径：D:/flutter_ohos/packages/flutter/lib/src/foundation/platform.dart
       │
       └─ 第三方包 flutter_math_fork ^0.7.4 的 switch 语句覆盖了所有
          标准 TargetPlatform 值，但不含 ohos
            │
            └─ Dart 编译器的 exhaustive switch 检查报错
                4 个文件 × 4 处 switch = dart2js 编译失败
                  │
                  └─ Web 构建失败
```

---

## 二、SDK 版本对比

| 项目 | ohos SDK (当前 PATH) | 标准 SDK (D:/flutter/flutter) |
|------|---------------------|------------------------------|
| 版本 | 3.35.8-0.0.pre-2037 (user-branch) | 3.41.1 stable |
| Dart | 3.9.2 | 3.11.0 |
| 来源 | gitcode.com/openharmony-sig | github.com/flutter/flutter |
| TargetPlatform.ohos | ✅ 存在 | ❌ 不存在 |
| Edge 设备支持 | ✅ 支持 | ❌ unsupported |

---

## 三、受影响的包

| 包名 | 版本 | 影响 |
|------|------|------|
| `flutter_math_fork` | ^0.7.4 | 4 处 exhaustive switch 不含 `TargetPlatform.ohos` 分支 |

### 具体受影响的 switch 语句

| 文件（位于 pub cache） | 行号 | 上下文 |
|---|---|---|
| `widgets/selectable.dart` | :276 | `switch (theme.platform)` |
| `widgets/selectable.dart` | :473 | `switch (Theme.of(context).platform)` |
| `render/layout/line_editable.dart` | :469 | `switch (defaultTargetPlatform)` |
| `widgets/selection/gesture_detector_builder_selectable.dart` | :42 | `switch (Theme.of(context).platform)` |

所有 switch 均覆盖了 `iOS / macOS / android / fuchsia / linux / windows` 6 个标准平台，但 ohos SDK 引入了第 7 个值 `ohos`，导致穷举失败。

---

## 四、尝试过的修复路径

| # | 方案 | 结果 |
|---|------|------|
| 1 | 直接 switch 到标准 Flutter SDK | Chrome 不可用（需 `CHROME_EXECUTABLE`）；Edge 标记 unsupported |
| 2 | `sed` 自动补丁 | 语法错误——`case` 被插入到代码块中间，破坏 Dart 语法 |
| 3 | Python 脚本精确补丁 | ✅ 成功——在 `case windows:` 后插入 `case ohos:` 作为 fall-through |

---

## 五、当前状态

| 项目 | 状态 |
|------|------|
| Flutter SDK | 仍使用 ohos SDK（PATH 未改） |
| `flutter_math_fork` | 已打补丁（3 文件 × 4 处） |
| `flutter build web` | ✅ 通过 |
| `flutter run --release -d edge` | ✅ 可运行 |
| 补丁持久化 | `scripts/patch_flutter_math_fork.py` — 每次 `flutter pub get` 后运行 |

---

## 六、推荐方案

| 优先级 | 方案 | 说明 |
|--------|------|------|
| ⭐ P0 | **切换 PATH 到标准 Flutter SDK** | 根治。`D:/flutter/flutter/bin/flutter` 比 ohos SDK 版本新（3.41.1 vs 3.35.8-pre），且不存在 `TargetPlatform.ohos` 问题。需额外配置 `CHROME_EXECUTABLE` 环境变量 |
| P1 | 维持现状 + 自动补丁 | 如果必须使用 ohos SDK（Edge 支持更好），保留 `patch_flutter_math_fork.py` 并在 `pubspec.yaml` post-get 钩子中自动运行 |

---

## 七、关键教训

1. **删除平台目录 ≠ 删除平台 SDK**：`app/ohos/` 只是构建配置，真正的平台耦合在 Flutter SDK 的 Framework 层（`TargetPlatform.ohos`）
2. **第三方包的 exhaustive switch 是隐式平台耦合**：任何在 `TargetPlatform` 上做穷举开关的包，在非标准 Flutter SDK 下都可能编译失败
3. **PATH 优先于意图**：即使删除所有鸿蒙代码，只要 PATH 指向 ohos SDK，编译环境就仍是鸿蒙模式

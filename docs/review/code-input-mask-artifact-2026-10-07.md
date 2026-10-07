# 验证码输入格「遮罩」现象 · 调查（2026-10-07）

> **触发**：白哥真机反馈 —— Apple 登录 ✅ / 邮件发送 ✅，但
> 「输入验证码的弹窗在**六个输入框上有个遮罩**，将输入框**遮住一半**」。
> **状态**：🔴 **已定位到高可信根因假设，但需一张截图确认后再改** ——
> 涉及 `ClayPainter`（**全 App 视觉基础**），改错会波及所有粘土元素。
> **本轮未改任何代码。**

---

## 一、涉及组件（已确认）

| 组件 | 位置 | 说明 |
|---|---|---|
| `CodeInput` | `app/lib/widgets/code_input.dart` | 「**1 个隐藏 TextField + 6 个展示格**」的 `Stack` |
| `Clay` / `ClayPainter` | `app/lib/theme/clay.dart` | 6 个格子各是一个 `Clay(state: pressed)` |
| 使用方 | `forgot_password_dialog.dart:512` · `change_email_dialog.dart:381` | 白哥说的「输入验证码的弹窗」 |

---

## 二、已排除的可能（逐条有依据）

| # | 候选原因 | 排除依据 |
|---|---|---|
| 1 | **`Clay` 的尺寸档参数不成立**（月牙伪影）| 算了：高 47 ⇒ `ClayScales.forHeight` = **md 档**（minHeight 40）。<br>`geometryOkFor(47)` 要求 `radiusFor(47) ≥ |shade.dx|×3 = 9`：<br>· 墨 `26×0.55=14.3` ✅ · 夜 `24×0.55=13.2` ✅ · 格 `14`（`scaleRadius:false`）✅<br>⇒ **几何检查成立**，`Clay` 文档里说的「月牙状伪影」不成立 |
| 2 | **`Clay` 有覆盖层** | `ClayPainter` 是纯 `CustomPainter`，只画「填充 + 外阴影 + 两个 inset」，无 `Positioned`/遮罩层 |
| 3 | **`Clay` widget 包了 `Opacity`** | 只有 `state == disabled` 时才 `Opacity(0.5)`；`CodeInput` 传的是 `pressed` ⇒ 不走该分支 |
| 4 | **弹窗容器有渐隐/遮罩** | `CoDialog` = `Dialog(transparent, elevation:0)` → `ConstrainedBox` → `Container(圆角+阴影+padding)` → `SingleChildScrollView` → `Column`。<br>**无 `ShaderMask` / 无渐变层 / 无 `Positioned` 覆盖** |
| 5 | **隐藏 `TextField` 画了背景** | 查 Flutter SDK 源码：`InputDecorator` 用 `_BorderContainer`，**不画 Material 背景**；`text_field.dart` 只有 `assert(debugCheckHasMaterial)`，自身不画底。<br>且调用处 `border: none ×4` + `counterText: ''` + 透明文字 ⇒ 它**什么都看不到** |

---

## 三、🔴 高可信根因假设：`ClayPainter._inset` 的模糊溢出

### 3.1 机制

`ClayPainter._inset()` 用 **`MaskFilter.blur` + `canvas.clipRRect`** 造内阴影：

```dart
canvas.save();
canvas.clipRRect(rrect);                      // ← 靠这一句把模糊限制在格子内
final ring = Path()..fillType = evenOdd
  ..addRect(rrect.outerRect.shift(delta).inflate(s.blur + 40))   // ← 比格子大 48px 的矩形
  ..addRRect(rrect.shift(delta));
canvas.drawPath(ring, paint);                 // paint 带 MaskFilter.blur
canvas.restore();
```

- `md` 档的 shade 是 `CoShadow(-3,-3,8)` ⇒ `blur = 8` ⇒
  **模糊扩散半径约 3σ ≈ 15px**（`σ = 8×0.57735+0.5 ≈ 5.1`）
- 而格子只有 **38×47**，相邻间距 **7px**
- ⇒ 一旦 `clipRRect` 约束不足，**每个格子糊出约 15px 的暗色**，
  6 个格子互相覆盖 ⇒ **连成一整片暗色**

### 3.2 为什么只在 CodeInput 显眼

| 场景 | 结果 |
|---|---|
| 单个 `Clay` 元素（按钮 / `ClayField`）| 糊出的暗色落在**背景**上 ⇒ 像一圈淡晕，**不易察觉** |
| **6 个格子紧挨（间距 7px）** | 各自糊 15px ⇒ **完全覆盖间隙并互相叠加** ⇒ **成片可见** ✅ |

⇒ 与白哥「**在六个输入框上有个遮罩**」的描述吻合。

### 3.3 为什么 Android 上不明显

- Android 用 **Skia**、iOS 用 **Impeller**
- 已有公开记录：**Impeller 下 `canvas.save()` + clip 不足以隔离绘制**，
  需要 `saveLayer()` 才能分配独立的离屏层
  （来源：Flutter Impeller 已知问题整理 —— 「CustomPainter Layer Bleed … **save() fails to isolate**…
  `saveLayer()` is required」）
- 另一篇 Impeller 排查文也把「**半透明弹窗边缘糊化**」归因于 **blur 半径映射偏差**，
  修复方向写的是「**调整 blur sigma**」

⚠️ 但**这是假设，不是已证事实** —— 本机**无法渲染验证**（跑不了 `flutter`，`dart:ui` 不可用）。

---

## 四、需要白哥给一张截图（**这一条是必要的，不是客气**）

**为什么必须看图**：改的是 `ClayPainter` —— **全 App 每一个粘土元素都走它**。
按「先报告 → 请示 → 再改」的规矩，我不能凭假设改基础组件。

**看什么**（一句话就够）：

| 问题 | 用于区分 |
|---|---|
| 遮罩是**半透明暗色**，且**每个格子各自**被压暗（尤其**左上或上缘更深**）| ⇒ 支持 §三 的内阴影溢出假设 ✅ |
| 还是**一整片纯色**盖在 6 格区域上、与格子边界**无关** | ⇒ 另有原因，我换方向查 |
| 格子里的**数字还能看清**吗 | 判断是"糊"还是"实心覆盖" |

---

## 五、修法候选（确认后择一，你说哪个）

| 选项 | 做法 | 影响 | 风险 |
|---|---|---|---|
| **A · `saveLayer` 隔离**（推荐）| `_inset` 里 `canvas.save()` → `canvas.saveLayer(rrect, Paint())` | 正常视觉**完全不变**；每次绘制多一个离屏层 | ⚠️ **性能**：Clay 元素多，`saveLayer` 有代价 —— 需实测帧率 |
| **B · 几何限制环形** | 用 `Path.combine(difference, 格子, 偏移格子)` 取代 `evenOdd` 大矩形 —— **环本身就在格子内** | 视觉不变；**无性能代价** | ⚠️ 模糊仍会向外扩散 ~15px，**仍依赖 clip** ⇒ 若不修好 clip，只是减轻 |
| **C · 小尺寸格子改用无 inset 档** | 把 `clayNoInsetBelow`（现 24）提到 48，或给 `CodeInput` 传 `ClayState.raised` | 格子失去「凹陷」感 ⇒ **视觉变化明显** | 需白哥确认是否接受形态变化 |

🔑 **我倾向 A**（治本、视觉不变），**但先要确认根因**。
若 A 的性能有影响，则 **A + C 组合**（只在小尺寸格子上关 inset）。

---

## 六、本轮未做

- ❌ **未改任何代码**（按铁律：先报告 → 请示 → 再改）
- ✅ 只做了**代码阅读 + 常量计算**（未改文件、未部署、未碰服务器）
- ⚠️ 本机**无法渲染复现**（`flutter` 命令跑不了 ⇒ 渲染类问题只能靠真机反馈）

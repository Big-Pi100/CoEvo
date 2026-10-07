# 验证码输入格「遮罩」现象 · 调查（2026-10-07）

> **触发**：白哥真机反馈 —— Apple 登录 ✅ / 邮件发送 ✅，但
> 「输入验证码的弹窗在**六个输入框上有个遮罩**，将输入框**遮住一半**」。
>
> ## ✅ 状态：根因已由真机截图**证实**，修复**已实施**（2026-10-07 18:1x）
>
> | | |
> |---|---|
> | **根因** | `ClayPainter._inset` 的两处写法**都依赖 Impeller 不可靠的行为**（详见 §三）|
> | **修复** | ① `evenOdd` → `Path.combine(difference)`　② `save()` → `saveLayer()` |
> | **验证** | `analyze_inproc` error=0/warning=0 · 断言 698+75+43+60+71+60 全过 |
> | **待办** | ⏳ **重新出包在真机复验**（本机跑不了 Flutter ⇒ 渲染效果**无法本地验证**）|

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

## 三、🔴 根因（**已由截图证实**）

### 3.0 截图证据 → 逐条对上

白哥提供截图后，**三个特征同时出现**，只有「`evenOdd` 失效 + `clip` 失效」能全部解释：

| 截图特征 | 说明什么 |
|---|---|
| 那一块是**纯黑实心**（不是半透明晕）| `evenOdd` 的「大矩形 − 圆角矩形」被渲染成**实心填充** —— **空洞失效** |
| 黑块**比 6 格区域更宽**（左右都超出）| `canvas.clipRRect` **未生效** —— `save()` 在 Impeller 下不足以隔离 |
| 下边缘仍有 **6 个格子圆弧** | 偏移格子的"空洞"**部分生效** ⇒ 不是"没画"，而是**画成了实心 + 没被裁** |

🔑 **关键推论**：**`evenOdd` 与 `clip` 只要有一个生效，就不会出现实心黑块。**
⇒ 两处**必须同时改**，只改一处会残留另一半症状（只改 `evenOdd` ⇒ 环形正确但模糊仍糊出格子；
只改 `saveLayer` ⇒ 被裁在格子内的**实心黑块**）。

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

### 3.3 为什么 Android 上没出现

- Android 用 **Skia**、iOS 用 **Impeller**
- 已有公开记录：**Impeller 下 `canvas.save()` + clip 不足以隔离绘制**，
  需要 `saveLayer()` 才能分配独立的离屏层
  （来源：Flutter Impeller 已知问题整理 —— 「CustomPainter Layer Bleed … **save() fails to isolate**…
  `saveLayer()` is required」）
- 另一篇 Impeller 排查文的速查表里，「**渐变区域出现矩形色块**」与
  「**自定义绘制图形错位**」都被归为 Impeller 的已知花屏类问题 —— 与本例吻合

⚠️ 但**具体是 `evenOdd` 的填充规则、还是 `MaskFilter` 的隔离、抑或两者叠加**，
   本机**无法进一步区分**（跑不了 `flutter`，`dart:ui` 在纯 Dart VM 不可用）。
   ⇒ 所以修复**两处一起改**（见 §五），不赌单一成因。

---

## 四、截图证据（白哥 2026-10-07 18:13 提供）

已并入 §3.0。**结论**：`evenOdd` 失效 + `clip` 失效 —— **两处同时**。

---

## 五、✅ 已实施的修复（`app/lib/theme/clay.dart` → `_inset`）

```dart
// 改前
canvas.save();                                     // ← ① Impeller 下隔离不足
final ring = Path()
  ..fillType = ui.PathFillType.evenOdd             // ← ② 被渲染成实心
  ..addRect(rrect.outerRect.shift(delta).inflate(s.blur + 40))
  ..addRRect(rrect.shift(delta));
canvas.drawPath(ring, paint);
canvas.restore();

// 改后
canvas.saveLayer(rrect.outerRect, Paint());        // ① 真正隔离（bounds 取格子本身）
canvas.clipRRect(rrect);
final outer = Path()..addRRect(rrect);
final inner = Path()..addRRect(rrect.shift(delta));
final ring = Path.combine(ui.PathOperation.difference, outer, inner);  // ② 几何差集
canvas.drawPath(ring, paint);
canvas.restore();
```

| 改动 | 为什么 |
|---|---|
| `evenOdd` → `Path.combine(difference)` | 差集结果**几何上就落在 `outer`（格子）内**，不依赖渲染器的填充规则 |
| `save()` → `saveLayer(rrect.outerRect, …)` | Impeller 下需要**独立离屏层**才能隔离 `MaskFilter` 的绘制 |

🔑 **几何结果与改前完全一致** ⇒ **正常渲染下视觉不变**（只是不再有 iOS 的异常）。
⚠️ **代价**：`saveLayer` 有离屏合成开销 —— **需在真机复验时一并留意滚动帧率**
（`Clay` 元素遍布全 App）。若帧率受影响，退路是「只对**小尺寸**元素用 `saveLayer`」。

### 断言同步（`verify_tokens.dart`）

| 原断言 | 处理 |
|---|---|
| `check('用 evenOdd 差集挖空成环', clay.contains('PathFillType.evenOdd'))` | 🔴 **锁的是实现手段** ⇒ 改为锁**意图**：`PathOperation.difference` |
| — | 🆕 **反向断言**：`!clay.contains('PathFillType.evenOdd')`（不得再用）|
| — | 🆕 正向：`clay.contains('saveLayer')`（Impeller 下 `save()` 不够）|

📌 这是本日第 **4** 次遇到「**断言保护错误**」（锁住已废止的实现 ⇒ 改对了反红）。
**反向断言天然免疫**这一点 —— 因此「禁止某写法」的判据应尽量写成反向断言。

---

## 六、本轮做了什么 / 没做什么

- ✅ **改了 2 个文件**：`app/lib/theme/clay.dart`（`_inset`）· `scripts/tokens_verify/bin/verify_tokens.dart`（断言）
- ✅ 验证：`analyze_inproc` **error=0 / warning=0**；断言 **698 + 75 + 43 + 60 + 71 + 60** 全过
- ❌ **未部署后端**（本次是 App 端改动，与原定「部署」无关）
- ⏳ **待办：重新出包 → 真机复验**（渲染效果本机无法验证）
  · 复验点：① 遮罩消失 ② **其余粘土元素（按钮/卡片/输入框）视觉无变化** ③ 滚动帧率

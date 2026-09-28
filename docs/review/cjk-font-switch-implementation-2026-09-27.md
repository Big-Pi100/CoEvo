# 中文字体更换 —— 实施报告

> 日期：2026-09-27｜依据：白哥「把换 OFL 中文字体省 21 MB 也提上日程」→ 选 **Noto Sans SC · 4 字重**
> 状态：✅ **已实施并验证**（生产代码/资产已改，验收全绿）
> 前置评估：`docs/review/cjk-font-switch-evaluation-2026-09-27.md`（含许可取证与对比图）

---

## 〇、一句话结果

**24.16 MB → 4.83 MB，省 19.33 MB**；同时**补上真 `w600`**（代码里 69 处在用而旧字体没这个字重）。

---

## 一、改动清单（7 处）

| # | 文件 | 改动 |
|---|---|---|
| 1 | 🆕 `app/assets/fonts/NotoSansSC-{Regular,Medium,SemiBold,Bold}.ttf` | 4 个子集（各 ≈1.24 MB） |
| 2 | 🆕 `app/assets/fonts/NotoSansSC-OFL.txt` | 官方许可原文（4,388 B） |
| 3 | 🗑️ `app/assets/fonts/AlibabaPuHuiTi-3-*.ttf` | **删除 3 个**（git 可恢复） |
| 4 | `app/pubspec.yaml` | 字体声明换新（4 字重）+ **声明 OFL.txt 为 asset** |
| 5 | `app/lib/theme/coevo_tokens.dart` | `CoFonts.cjk`: `AlibabaPuHuiTi` → **`NotoSansSC`**（**单一出处，只此一行**） |
| 6 | `scripts/fetch_fonts.py` | 加 `noto-sc` 条目（含真实 sha256） |
| 7 | `scripts/build_fonts.py` | 加 CJK 字符集 + `noto-sc` 候选 + `_fix_names` + **`--verify-coverage`** |

### 1.1 附带新增/修订的脚本

| 文件 | 说明 |
|---|---|
| 🆕 `scripts/build_cjk_font_compare.py` | 对比图生成器（PIL 渲染 PNG，**不内联字体**） |
| `scripts/tokens_verify/bin/verify_tokens.dart` | §7 更新 + 11 条新断言 |
| `docs/design/design-system-spec-2026-09-25.md` | **§4.4 整节重写**（原「保留全量」结论作废但理由仍成立）+ 3 处同步 |
| `docs/plan-and-progress-2026-09-26.md` | 实测快照加 2 行 |

---

## 二、关键技术点（每条都有实测依据）

### 2.1 🔑 子集字符集 = **4,014 码位**，来自**真实数据**

| 来源 | 汉字数 |
|---|---|
| `word.db` 全部文本字段 | 3,868 |
| `app/lib/**.dart` 源码 | 1,144 |
| **并集** | **3,873** |
| + ASCII 95 + 中英标点 | **4,014 码位** |

⚠️ **收费项已计入**：源码里的**中文注释**也会被收进（无法可靠区分注释与字符串）。
注释用字与 UI 用字高度重叠 → 多收成本极小，漏收代价是「界面上某个字变方块」→ **宁可多收**。

### 2.2 🔴 CFF 风险已规避

系统里的 `Noto Sans SC (TrueType).otf` 是 **OTF/CFF** 格式（Flutter 的 Impeller 对 CFF 有已知不确定性）。
从 google/fonts 取的 `NotoSansSC[wght].ttf` 实测 magic = `\x00\x01\x00\x00`（**TTF/glyf**）✅

### 2.3 🔴 VF 默认值是 **Thin**

```
fvar: wght 100.0 – 900.0  (默认 100.0)
```

→ 构建期**必须显式 pin 每个字重**。不 pin 会得到极细的字重；
而 Flutter 的 `fontWeight` **不会**驱动 VF 轴（要用得上 `FontVariation` API）→ 构建期转静态。

### 2.4 🆕 发现并修复：name 表字重信息丢失

VF 实例化时用 `updateFontNames=False` 会**原样保留 VF 的 name 表** →
4 个静态字重**全都叫「Noto Sans SC Thin」**（用字体查看器一看就发现）。

**为什么不影响 Flutter 但要修**：Flutter 按 `pubspec.yaml` 的 family 别名 + `weight` 索引，
**不看 TTF 内部 name 表** → 渲染正常。但名字错会误导一切用系统工具查字体的人。

→ 加 `_fix_names()` **显式写死**（不用 `updateFontNames=True`，那依赖字体自身的命名实例、不可控）：

| ID | 值 |
|---|---|
| 1 Family | `NotoSansSC` |
| 2 Subfamily | `Regular` / `Bold`（**只允许 RIBBI 四值**，非 RIBBI 归 Regular） |
| 4 Full / 6 PostScript | `NotoSansSC SemiBold` / `NotoSansSC-SemiBold` |
| **16/17 Typographic** | `NotoSansSC` / **真正的字重名**（`SemiBold`）← 现代工具的权威来源 |

实测修正后：4 个字重 Family 均为 `NotoSansSC`，Typo Sub 分别为 `Regular/Medium/SemiBold/Bold` ✅

### 2.5 🔑 顺带修一个**长期存在**的缺陷

代码里 `FontWeight.w600` 用了 **69 处**（用得最多），而阿里普惠体**只声明了 400/500/700**
→ 那 69 处一直是 Flutter「**就近取**」（拿 500 或 700）。

→ 本次补上**真 `600`（SemiBold）**。这是从 3 字重变 4 字重的原因，也是多花 1.2 MB 的理由。

### 2.6 🔴 OFL 合规三件事（都已落实）

| # | 要求 | 落实 |
|---|---|---|
| 1 | **许可文本随包分发** | `NotoSansSC-OFL.txt` 已放进 assets **且已在 `pubspec.yaml` 的 `assets:` 声明**<br>⚠️ 只放文件不声明 → **不会被打包**（本项目已踩过 `user_db_schema.sql`） |
| 2 | **不得用 Reserved Font Name** | 官方 OFL.txt 写的保留名是 **`Source`**（继承思源黑体）<br>`NotoSansSC` **不是**保留名 → 合规（已加断言锁住） |
| 3 | 保留版权声明 | OFL.txt 原文保留 Copyright 行未改 |

---

## 三、🔴 新增的关键防线：cmap 覆盖校验

### 3.1 为什么必须有

子集把字体裁到 **4,014 码位**，而 `word.db` 是**会长大的**。
将来加词若引入**新汉字** → 那个字：

1. 缺字形 → **回退系统字体**（**不是报错**）
2. 一条释义里出现**两种字体**，肉眼能看出不齐

🔑 这正是本项目已知教训「**有 fallback ≠ 视觉一致**」的又一形态
（93.9% 的音标曾栽在同一件事上）。

### 3.2 实现

```bash
python3 scripts/build_fonts.py --verify-coverage
```

（放在 `build_fonts.py` 而非 `tokens_verify` —— 后者是纯 Dart，**无法解析 TTF 的 cmap**；
而 `build_fonts.py` 本来就是字体构建的**单一出处**，Python 侧有 `fontTools`。）

### 3.3 与 `tokens_verify` 的分工（互补，缺一不可）

| 工具 | 管什么 | 防的是 |
|---|---|---|
| `tokens_verify`（Dart） | family 名 · pubspec 声明 · 4 个字重 · OFL.txt 已声明 · 无保留名 | 「**写了但没接上**」 |
| `build_fonts.py --verify-coverage`（Python） | **字体 cmap ⊇ 词库汉字** | 「**字体被换 / 词库增长后缺字**」 |

### 3.4 证伪测试（确认它会红）

```python
# 人为给「词库汉字」集合加入 3 个生僻字
bf.collect_cjk = lambda: _orig() | {'龘', '𠮷', '㐂'}
bf.verify_coverage()
```

**结果**：4 个字重全部报红，`退出码 = 1`，并打印**可执行的修复指引**：

```
 🔴 NotoSansSC-Regular.ttf  缺 3 个汉字：㐂龘𠮷
🔴 4 个字体文件缺字。
   → 「字库或词库变过」——重跑：
     python3 scripts/build_fonts.py --candidate noto-sc --ttf
     然后复制 data/fonts-build/NotoSansSC-*.ttf → app/assets/fonts/
```
✅ **不只会报红，还告诉你怎么修** —— 避免「断言红了但没人知道下一步」。

---

## 四、验证结果

| 验收 | 改前 | 改后 |
|---|---|---|
| `analyze_inproc` | 78 文件 · error=0 | ✅ **error=0** / warning=13 / info=4 |
| `verify_tokens` | 354 | ✅ **368**（+14） |
| `verify_bookmark` | 52 | ✅ 52 |
| `verify_word_query` / `pos_display` / `review_list` / `worddb_sync` / `worddb_bootstrap` | 42/31/37/6/22 | ✅ 全不变 |
| **cmap 覆盖** | — | ✅ 4 字重均覆盖 3,873 汉字 |
| **体积** | 24.16 MB | ✅ **4.83 MB**（**省 19.33 MB**） |

### 4.1 新增断言（14 条）

| 类 | 断言 |
|---|---|
| 字体名 | `CoFonts.cjk == 'NotoSansSC'` |
| 声明 | pubspec 声明了 `NotoSansSC` · 4 个 asset 路径 · **文件真的存在**（逐个） |
| 字重 | 声明了 400/500/**600**/700 · **不多不少正好 4 个** |
| **许可** | OFL.txt **已声明为 asset**（防「放了但没打包」）· 文件存在 · **family 名未用保留名 `Source`** |

🔑 其中「**不多不少正好 4 个**」是反向检查：多声明一个字重意味着多一个没用的文件进包。

### 4.2 顺带清理：删掉一处已无理由的特例

`tokens_verify` 原有一行：

```dart
if (f == CoFonts.cjk) continue; // 阿里普惠体不按此命名，单独跳
```

跳过的原因是**旧字体文件名与 family 名不同**（`AlibabaPuHuiTi-3-55-Regular` vs `AlibabaPuHuiTi`）。
换成 `NotoSansSC-*` 后命名一致 → **通用检查已能覆盖它** → 特例已删除。

🔑 「**功能取消，其子功能一并失去理由**」的又一处应用。

---

## 五、⏳ 待办 / 遗留

| 项 | 说明 |
|---|---|
| ⚠️ **需真机肉眼过一遍** | 三档主题下的中文渲染（字体是**视觉资产**，断言保证不了观感） |
| ⚠️ **中英混排需重看** | `Noto Sans SC × Literata` 的视觉重量匹配（design-system-spec 待办已标注） |
| 🔴 **git 历史里的阿里普惠体** | 3 个字体文件**已在 git 历史中**，其条款禁止「上传、发布、**转载**」<br>仓库当前 **private** → 暂可；**若将来转 public/开源，需先把它从历史清除**<br>（做法见 `git-history-purge` skill 与 `git-history-purge-plan-2026-09-27.md`） |
| 历史评估文档 | `font-candidates-assessment` / `ui-ux-refactor-assessment` 里提到阿里普惠体的部分**未改** —— 那是**当时的事实记录**，不该改写。已在 spec §4.4 标注作废 |

---

## 六、构建与复现

```bash
# 1) 取源（可复现，含 sha256 校验）
python3 scripts/fetch_fonts.py --only noto-sc

# 2) 子集构建（VF 实例化 + 子集 + name 修正）
python3 scripts/build_fonts.py --candidate noto-sc --ttf
cp data/fonts-build/NotoSansSC-*.ttf app/assets/fonts/

# 3) 🔴 覆盖校验（词库增长时必跑）
python3 scripts/build_fonts.py --verify-coverage

# 4) 构建 App（🔴 务必用官方 SDK 全路径）
cd app && D:/flutter/bin/flutter.bat build apk --debug
```

> ⚠️ 对比图生成器 `build_cjk_font_compare.py` 现在会**主动报错退出**（对照字体已删）——
> 那是**预期行为**，它已完成使命；提示里给出了恢复命令与「不得用于生产」的警告。

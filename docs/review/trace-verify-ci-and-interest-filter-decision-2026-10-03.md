# trace_verify 接入 CI + 兴趣筛选语义定案（2026-10-03）

> **白哥指示**：「『到底了』不要；`trace_verify` 脚本要进 CI；兴趣选择：**筛选**。CI 全绿」
>
> **本轮产出**：`.github/workflows/ci.yml`（新 job）· `implementation-plan-v2` §10.3.2 · `home_screen.dart` 注释定案
> **提交**：`a6b8ebf`（CI + 规格）· `79fbc60`（注释定案）· `b33acef`（记忆）

---

## 一、「到底了」不要 → ✅ 零行为改动

**先核实再回答**（不凭记忆）：`grep` 全 `app/lib/`，**没有任何用户可见的「到底了 / 没有更多了」文案**
—— `_feedFooter` 在「已经到底」态只返回一段空隙。

唯一需要处理的是**代码注释里留着一个「⚠️ 待定项」**：

```
| **已经到底** | 空 —— ⚠️ 待定项：是否显示「没有更多了」属 UI 文案，规格未定 |
```

⇒ 改成 **✅ 已定案（2026-10-03 白哥：不要）**，并写明 `🔴 不要再加`。

🔑 **为什么值得单独改**：注释里留「待定项」，后来人会**反复把它当未完成工作重新提出来**
—— **决策不落进代码就等于没定**。
（同族判据：`hasMore` 写了没人调用 = 迟早失效；这里是「定了没写下来」= 迟早重问。）

---

## 二、CI 全绿 → ✅ 覆盖了本机盲区

`feed_provider.dart` / `home_screen.dart` 的改动在**官方 Flutter 3.41.1** 下通过了
`flutter analyze` —— 正是本机（鸿蒙定制版 Dart，`CreateFile 231`）**验不到**的那部分。

⇒ 上一轮我如实标注的「🔴 UI 接线 / provider 数据流无法本机验证」**已被 CI 覆盖**。

---

## 三、`trace_verify` 接入 CI（本轮实质改动）

### 3.1 新增 job（照 `fsrs-verify` 既有写法）

```yaml
trace-verify:
  name: Trace Verify (pure Dart)
  runs-on: ubuntu-latest
  defaults:
    run:
      working-directory: scripts/trace_verify
  steps:
    - uses: actions/checkout@v4
    - uses: dart-lang/setup-dart@v1
      with:
        sdk: 3.11.0
    - run: dart pub get
    - run: dart run bin/verify_unescape.dart
    - run: dart run bin/verify_trace_markdown.dart
    - run: dart run bin/verify_feed_pager.dart
```

**无 `continue-on-error` ⇒ 是真门禁**（对比 `native-readiness` / `ios-build` 的 advisory 定位）。

### 3.2 🔴 为什么之前没有这个 job

这三个脚本**从建好起就一直在仓库里、从没被 CI 跑过** ——
与 `feed_provider` 里那个「`FeedPage.hasMore` 写好了却**零调用**」是**同一类病**：

> **写了没人跑 = 迟早失效。**

### 3.3 逐条核实依赖后**只接 3 个**

| 脚本 | 项数 | 能进 CI 的理由 |
|---|---|---|
| `verify_unescape.dart` | 71 | 不 import Flutter；需 2 份 fixture，**都已入库**（手动挑选的样本）|
| `verify_trace_markdown.dart` | 43 | 不 import Flutter；**零文件依赖** |
| `verify_feed_pager.dart` | 54 | 不 import Flutter；零依赖（上一轮新增）|
| | **168** | |

⛔ **不能接的**（理由已写进 `ci.yml` 注释，防后人「顺手都搬进来」）：

| 类 | 数量 | 为什么不行 |
|---|---|---|
| `probe_*.dart` | 4 | 读 `all_bodies.json`(22 MB) / `prod_bodies.json` / `prod_content_all.json` —— 全是**从生产批量导出**、在 `.gitignore` 里**故意不入库**的正文 ⇒ **干净检出里没有** |
| `*.py` | 7 | 要 SSH 连**生产库**（dump / verify / del）⇒ CI 不该、也不能访问生产 |

📌 **判据：能进 CI 的只有「自带全部输入」的脚本**；依赖生产数据的是「**人肉诊断工具**」，
只能本地或连生产跑。

### 3.4 🔴 `sdk` **钉死 `3.11.0`**（不写 `stable`）

与 `frontend` / `ios-build` 钉 `flutter-version: 3.41.1` 是**同一条教训**：
`stable` 随上游漂移，而 **lint 规则集 / stdlib 行为随版本变化** ⇒「本地绿 / CI 红」会变成常态。

**核实过（不是猜）**：
- 本项目 Dart = `3.11.0`（`/d/flutter/bin/cache/dart-sdk/version` 实测）
- 该版本 dart-archive **实测可下载**（`dartsdk-linux-x64-release.zip` → HTTP 200）
- `setup-dart` 官方文档明写支持「A specific SDK version, e.g. `2.19.0`」✅

⚠️ **顺带记录一处已知不一致（未改 · 待批）**：上面的 `fsrs-verify` 仍写 `sdk: stable`
—— 同样有漂移风险，但**不在本轮授权范围**内 ⇒ 只报告，不擅自改。

---

## 四、验证（五层 · 全过）

| # | 验证项 | 方法 | 结果 |
|---|---|---|---|
| ① | YAML 语法 | PyYAML `safe_load` | ✅ |
| ② | job 结构 | 解析后断言 `runs-on` / `working-directory` / 无 `continue-on-error` / 6 步 | ✅ |
| ③ | 脚本引用有效 | `git ls-files` 比对：**存在 + 已入库** | ✅ 3/3 |
| ④ | **门禁有效（证伪）** | 注入真实回归 ⇒ 确认退出码变 1 | ✅ 3/3 |
| ⑤ | 干净检出可复现 | 删 `.dart_tool` → `dart pub get` → 三脚本 | ✅ 全绿 |

### ④ 证伪明细（**这是「门禁不是装饰」的唯一凭据**）

| 脚本 | 注入的回归 | 结果 |
|---|---|---|
| `verify_feed_pager` | `nextOffset`: `fetched` → `fetched + 1` | 50 通过 / **4 失败** → **exit 1** |
| `verify_unescape` | `kUnescapablePunct` 移除 `'.'` | 63 通过 / **8 失败** → **exit 1** |
| `verify_trace_markdown` | `kTraceMarkerPattern` 改匹配 `\u0003/\u0004`（永不命中）| 40 通过 / **3 失败** → **exit 1** |

- 三次注入**均字节级还原**（`md5` 前后一致）
- 还原后 `git status` 三份被测源码**零残留** ✅

📌 **判据：门禁必须证伪过** —— 没证伪过的断言集，可能是「**永远绿的装饰**」。

### ⑤ 干净检出模拟

CI 的 `.dart_tool/package_config.json` 不存在（未入库、被 `.gitignore` 忽略）
⇒ 必须靠 `dart pub get` 生成。本地实测：**删掉后 `pub get` 正常、三脚本仍全绿** ✅

---

## 五、兴趣选择：语义定案 = **筛选**

写进规格 **`implementation-plan-v2-2026-09-25.md` §10.3.2**（新增，+71 行）。

### 5.1 语义：筛选（不是排序）

| 方案 | 行为 | 是否需要「全部」出口 |
|---|---|---|
| **筛选** ⭐ 定案 | 勾 N 类 ⇒ **只**显示这 N 类 | ✅ **必须**（否则用户出不去）|
| ~~排序~~ | 勾 N 类 ⇒ 这 N 类排前，其余仍在 | ❌ 不需要 |

依据：产品定位是「**今天有什么可读**」；且本项目**没有**个性化权重 / 已读未读 / 热度排序。
⚠️ **实施时必须给「全部」出口**（默认值 = 全部）。

### 5.2 🔴 更正：分类数 7 → 12

§10.3.1 写的 **7 类已过时**；**权威来源是代码** `CONTENT_CATEGORIES`：

```
news tech business science sports culture entertainment health education history law family   （12）
```

变化：**+`news`**（定稿 7 类漏了它，但它是主力源 NPR 的落点）· **+4**（`education history law family`，三轮扩类）

📌 **标注而非删除**：§10.3.1 旧值**原样保留**（可追溯「曾经定过 7 类」），只加一条指向 §10.3.2 的更正说明。

### 5.3 🔴🔴 卡点仍是**内容供给不足**

2026-10-03 实测（生产库 990 条）：

| category | 全量 | 近 7 天 | | category | 全量 | 近 7 天 |
|---|---|---|---|---|---|---|
| tech | 438 | 438 ✅ | | history | 10 | 3 ⚠️ |
| science | 284 | 281 ✅ | | family | 10 | **1** ⚠️ |
| news | 168 | 144 ✅ | | entertainment | 9 | 3 🔴 |
| culture | 30 | 13 🟡 | | education | 7 | 5 🔴 |
| health | 16 | 6 ⚠️ | | law | 5 | 5 🔴 |
| sports | 10 | 8 ⚠️ | | business | 3 | **3** 🔴 |

**12 类里 8 类近 7 天 < 13 条** ⇒ 勾 `business` 得 **3 条**、`family` 得 **1 条**。
🔴 用户会理解为「**App 里没这类内容**」，而不是「被我筛掉了」——
正是本项目反复踩的那条：**「静默失败 + 无出口」比「报错」更糟**。

### 5.4 ✅ 基础设施 100% 就位（属**接线活**）

| 层 | 状态 |
|---|---|
| 后端 | `/api/feed?category=<key>` ✅ |
| 客户端 | `fetchFeed(category:, limit:, offset:)` ✅ |
| Provider | `FutureProvider.family<String>` 当初**就是为兴趣筛选预留的** |
| ⚠️ 缺口 | UI 写死 `feedProvider('')` ⇒ **参数从没被传过非空值** |

### 5.5 实施顺序

```
① 定语义  ✅ 2026-10-03（= 筛选）
② 补内容供给（或定「空类怎么处理」：隐藏 / 提示 / 不可选）   ← ⏳ 当前卡点
③ 做界面（位置见原决策 #3：放进「我的」，替换「学习设置」）
```

---

## 六、🐛 本轮自己踩的坑（如实记录，未掩盖）

### 坑 ①：提交信息里的反引号被 bash 吃掉

```bash
git commit -m "... 把 `_feedFooter` 的文档注释 ..."
#               ^^^^^^^^^^^^ 双引号内反引号 = 命令替换 → bash 去执行了 _feedFooter
```

结果：stderr 只有一行 `_feedFooter: command not found`，**退出码仍是 0**，
提交信息变成「只把　　的文档注释…」（**静默缺字**）。

- **教训**：提交信息**一律**用 `$(cat <<'MSGEOF' … MSGEOF)` —— **定界符加引号**才不展开。
  （上一条 `a6b8ebf` 用的就是这种写法，完好；`79fbc60` 偷懒用双引号 ⇒ 中招。）
- **同族**：属「**工具/写法错 → 静默篡改内容，而退出码是 0**」，
  与 `heredoc` 吃反斜杠、模板脚本验错文件同源 ⇒ 已补入
  `references/verification-rules.md` 的「同族」表。
- **未修历史**：`79fbc60` 已推送 ⇒ **不做 force-push**（破坏性操作，且缺的词从上下文可复原）。
  **如实登记，不掩盖**；若要改写历史请明说。

### 坑 ②：`dart format` 报 `Changed` 差点被当成自己的回归

`dart format --output=none home_screen.dart` 报 `Changed` —— 听起来像「我的改动把格式弄坏了」。
✅ **对照基线**（`git show HEAD:…` 同样 `Changed`）才确认：项目**本就不用 dartfmt 作标准**
⇒ **不是回归**。

📌 **判据：「工具报异常」先与基线对照**，再判定是不是自己引入的。

---

## 七、⏳ 待白哥确认 / 后续

| # | 事项 | 说明 |
|---|---|---|
| 1 | **CI 结果复核** | 我**无法查私有仓库的 CI 状态**（`gh` 未登录、无 token）⇒ 请看一眼 `trace-verify` job 是否绿 |
| 2 | `fsrs-verify` 的 `sdk: stable` | ⚠️ 与本次钉版本的做法不一致（同漂移风险）—— **未改，待批** |
| 3 | **兴趣选择下一步** | 卡点是**供给不足**。先 **补供给**，还是先做界面（同时定「空类怎么处理」）？ |
| 4 | App 出包实测 | 上一轮的下拉刷新 + 分页仍需白哥终端验证（本机不可验） |

---

## 八、产出物

| 文件 | 说明 |
|---|---|
| `.github/workflows/ci.yml` | 🆕 job `trace-verify`（+63 行，含全部「为什么/为什么不行」注释）|
| `docs/design/english-app-implementation-plan-v2-2026-09-25.md` | 🆕 §10.3.2（+71 行）· §10.3.1 加更正指针 |
| `app/lib/screens/home_screen.dart` | `_feedFooter` 注释：待定项 → **已定案**（零行为改动）|
| `.workbuddy/memory/MEMORY.md` | 16,358 → 16,320 B · 新 2 条状态 + 2 条判据 |
| `.workbuddy/memory/ARCHIVE.md` | 🆕 §十八（v0.1.3 / 非英语闸门 / HN 残留细节迁入）|
| `.workbuddy/memory/references/verification-rules.md` | 「同族」表补「提交信息双引号」一行 |

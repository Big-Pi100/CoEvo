# CoEvo 计划总览与进度（单一入口）

> ## ⛔ 局部作废（2026-10-01）：免费层「生词本 200 词上限」已取消
>
> ⛔ 白哥定：**生词本上限取消**，免费用户**可全量使用现有功能**；收费点另行考虑。
> ⛔ **本文中凡以「200 词上限」为依据的条目（含「生词本**新增**（超 200 词上限）｜✅ 只有这里
> 需要登录」这一行）一律失效** —— 连带后果是**「需要登录」不再有任何依据**。
> ⛔ 代码侧已完成（上限逻辑已删 · 文案/成就已改），本条标注为**历史记录**。
>
> 📄 依据：`docs/review/free-tier-limit-removal-assessment-2026-10-01.md`

> 2026-09-26 ｜ **用途：回答「整个计划是什么、现在走到哪一步」**
> **口径**：所有状态以**实测产物**为准（命令 + 输出），不靠文档推断 —— 文档说「已完成」不算，有产物才算。
> 配套：`README.md`（文档地图）· `v1-final-design-authoritative-2026-09-25.md`（L0 原文）· `visual-word-card-target-2026-09-26.html`（L1 界面锚点）
>
> 🔴 **2026-09-26 本轮变更**：**Phase 2（语音包）整条轨道取消** —— TTS 全量端侧 `flutter_tts`
> （文章朗读 + 词卡都是）→ 权威文档 `docs/design/tts-unified-client-side-2026-09-26.md`
>
> 🆕 **2026-10-05 本轮变更**：**「找回密码」前后端全部交付**（「账号维护功能」的另一半 ——
> 与已交付的「修改密码」并列）。**忘记密码** = 自助重置，邮件 **6 位码**
> （腾讯云 SES · 国内 · **数据不出境**）。
>
> | 层 | 产物 |
> |---|---|
> | 后端 | 表 `password_reset`（**两处**：`schema.rs` + `main.rs` 迁移）· 端点 `POST /api/auth/forgot-password` / `reset-password` · 🆕 TC3 签名公共层 `tencent_sign`（ASR 与 SES **共用**，消除第二份实现） |
> | 前端 | `widgets/code_input.dart`（6 格）· `services/code_box_logic.dart`（零 import 纯逻辑）· `widgets/forgot_password_dialog.dart`（3 屏 + 倒计时）· 入口 **A**（登录弹层）+ **B**（修改密码弹层尾部） |
> | 断言 | `verify_forgot_password.dart` **60 项** · **已接入 CI** · **证伪 6/6** |
>
> **白哥 2026-10-05 定案 4 点**：入口 **A+B** · 未注册邮箱 **明说** · SES 密钥 **独立命名** ·
> 验证码 **6 个独立格子**（后两条与我原建议相反，按白哥的定案落地）。
>
> 验证：`cargo test` **228 passed / 0 failed** · 断言 60/60 · `codestatic` error 0 / warning 0
> · 可移植性 19 项过 · 纯逻辑冒烟 21/21。
> 🆕 **2026-10-05 发信链路进度**（找回密码的最后一个前置）：
> **SES 已开通** · DNS **四项已验证通过**（含 DKIM 2048 位深度校验）·
> 发信地址已设（`noreply@mail.keyievolution.fun`）·
> 🆕 **邮件模板已提交**（TemplateID **`221378`** · **审核中**，1 个工作日）·
> 🆕 端到端检查工具已备好（`scripts/tencent_ses_check.py`，**一条命令验通**）。
> ⏳ **只剩**：模板审核通过 → 把密钥 + TemplateID 配到服务器 → 端到端发一封。
> ⚠️ 渲染未验（本机跑不了 flutter）。
>
> 📄 设计稿 `docs/design/forgot-password-ui-2026-10-05.html` ·
> **发信通道对比** `docs/review/mail-channel-comparison-2026-10-05.md`（vibedollar 那套 vs SES）·
> 开通指引 `docs/operations/tencent-ses-onboarding-2026-10-05.md`

---

## 🔍 实测核对快照（2026-09-**28 01:13** · 全部为本机实测输出）

> ⚠️ **本轮（09-28）又发现快照 5 行已过时**（均已修正，都是「状态比记录更靠前」）：
> `app/lib` 行数 +159 · **`视觉 token 层` 验收 307 → 382 项** · **`痕迹` 「仍零实现」→ 已建**
> · **`字体资产` 「阿里普惠体」→ 已换 Noto Sans SC** · 🔴 **`前端静态分析` 「error=3」→ `error=0`**（后者是历史教训的残留）
>
> 🆕 **09-28 稍后又补两行**：`user.db` 接入（**表尚未建** → **v1.3 五表全建 + 查词链路已通**）· 新增 `user.db 迁移` 行
> 🆕 **09-28 22:2x（两处真机 Bug 修复）**：token 验收 **382 → 609 项**（途中 597）——
>    新增【16】「Clay 容器里的输入框必须**完全无框**」组（六个 border 字段全 none）
>    ＋ `HeaderChip` 宽度口径由**写死像素**改为**引擎实测**（见下表「视觉 token 层」行）。
> 🆕 **09-28 23:0x（`word_form` 补漏）**：`data/word.db` **33.1 MB / md5 `a0097f19…`**（原 32.9 MB / `e7495c54…`）·
>    `word_form` **22,829 → 24,062** · 「真·查不到」**1,233 → 4**（4 条为故意排除的假映射）·
>    🔴 **同时定了路线转向：不再补库，改走 LLM 制卡**（见下表「词库缺口」行）
> 🔑 **教训复现：快照会持续漂移** —— 每次核对**必须重跑命令**，别信上一版快照。

> 🔑 **本节的意义**：文档里的数字会随开发漂移。**核对时以本节为准，或重新跑一遍下表命令。**
> ⚠️ **教训（本轮踩过）**：核对数字时**判据要可靠** —— 我用 `grep "dart:html"` 查出「5 个 web-only 文件」，
> 实际**只有 2 个**（另外 3 个的 `dart:html` **只出现在注释里**）→ 换 ripgrep 精确匹配 import 才对上。

| 项 | 实测值 | 核对命令 |
|---|---|---|
| **中文字体** | ✅ **Noto Sans SC（OFL）· 4 字重 · 4.83 MB** —— 2026-09-27 由阿里普惠体（24.16 MB，**条款禁子集化**）更换，**省 19.33 MB** | `ls -la app/assets/fonts/NotoSansSC-*.ttf` |
| **字体覆盖校验** | ✅ 4 字重均覆盖 `word.db` 全部 **3,873 汉字** | `python3 scripts/build_fonts.py --verify-coverage` |
| **`data/word.db`** | **19 张表**（业务表 **18** + SQLite 内部 `sqlite_sequence`）· **33.1 MB** · mtime **`09-28 23:02`**（`word_form` 补漏 1,233 后）· md5 `a0097f19…` | `sqlite3 data/word.db ".tables"` |
| `word` / `card` | **11,523** / **11,523**（唯一分母） | `SELECT COUNT(*) FROM word` |
| `card_audio` | **0**（暂不写入 · 预留收费扩展） | 同上 |
| `word_morpheme` / `card_extra` / `word_form` | 13,489 / 13,812 / **24,062**（🆕 09-28 补漏 **+1,233**，原 22,829） | 同上 |
| `aggregate_page` / `etymon` / `word_etymon` / `affix` | 1,777 / 8,384 / 16,790 / 841 | 同上 |
| **`card.content_hash`** | ✅ **100% 与 `content` 一致**（11,523/11,523）—— 2026-09-26 回填 **8,255 条**（原仅 28.4%）· ⚠️ 前端**只存不用** | `sha256(content)[:32] == content_hash` |
| `app/lib` | **95 文件 / 27,897 行**（本行 09-28 记 78 / 22,906 —— 此后累计增长：3.33 删 web 录音 −417 · 3.5 收藏清单 +743 · 09-28 导航 ±159 · **10-02 S4 内容管线 + 死代码清理**） | `find app/lib -name '*.dart' \| wc -l` |
| **web-only 文件** | ✅ **0 个** —— 3.33 删 web 录音后**已清零**（本行曾记 2 个：`chat_input` / `review_card_widget`，**已过时**） | 🔴 **必须用 `^import 'dart:(html\|js\|ui_web)'` 精确匹配** —— 搜文本会把注释算进去 |
| 划词查词 | ✅ **已建**（`reader_screen.dart`：`SelectionArea` + `contextMenuBuilder`）—— 本行曾记「仍 0 命中」，**已过时** | `rg "SelectableText\|SelectionArea"` |
| 信息流 / 阅读器 | ✅ **两者均已建**：信息流 `home_screen` + `widgets/feed_card.dart`（⚠️ 数据仍是 **mock**，真 feed 在 Phase 3）｜阅读器 `screens/reader_screen.dart`（3.4a，含划词长按查词） | `find app/lib -iname '*feed*' -o -iname '*reader*'` |
| 收藏清单 | ✅ **已建**（3.5）：`screens/bookmark_list_screen.dart` + `widgets/bookmark_toggle.dart`（共用交互）· 路由 `/home/bookmarks`（**shell 子路由，保留 tabbar**） | `ls app/lib/screens/bookmark_list_screen.dart` |
| `user.db` 接入 | ✅ **v1.3（Step 3.4c）** —— 5 张表全建：`card_review_state` · `review_log` · `bookmark` · 🆕 **`user_word`（生词本）** · 🆕 **`lookup_event`（查词记录）**｜✅ **查词链路已接通**（长按 → 浮层 → 异步写入，不阻塞渲染）｜✅ **连接所有权统一**（`userDbProvider` 唯一 open/close）｜⏳ **待真机验「老库升级」** | `rg "openUserDb" app/lib`（应只有 1 处调用） |
| **视觉 token 层** | ✅ **已建且已接入**（`coevo_tokens.dart` **811 行** · 零 Flutter 依赖）· ✅ `buildTheme` 已接 `app.dart` → **三档主题生效**（旧 4 套主题已删）· 验收 **663 项全过 / 0 规格冲突**（【9】接线 · 【10】粘土+动效 · 【11】插值 · 【13】底部栏配套 · 【15】导航侧滑 · 【16】Clay 容器内的输入框完全无框 · 🆕 【22】正文来源 body/summary 降级必须可见） | `cd scripts/tokens_verify && dart run bin/verify_tokens.dart` |
| 🆕 **粘土 / 痕迹** | ✅ **两者均已实现并接入**：粘土 `theme/clay.dart`（**四态 + 真 inset**）→ 已用于底部导航 · **痕迹** 🆕 **2026-10-02（S4）改走 Markdown 渲染**：`services/trace_markdown_source.dart`（往源里注标记）+ `widgets/trace_markdown.dart`（渲染）+ `widgets/trace_style.dart`（样式映射）+ `widgets/trace_locator.dart`（判定）｜🔴 **旧区间路径已删**（`trace_text.dart` / `trace_segmenter.dart` / `locateTraceMarks`）—— 依据 `docs/review/content-pipeline-rebuild-plan-2026-10-02.md` §十四 | `rg "ClayPainter\|TraceMarkdown" app/lib` |
| **字体资产** | ✅ **9 个 .ttf · 5.11 MB** = 中文见上行 + **Literata(3) + CharisSIL(2)**（拉丁/音标，均已子集化）· pubspec 已声明 | `ls -la app/assets/fonts/` |
| 🆕 **IPA 真实字符集** | ✅ **30 个**（含 **4 个组合符号**）—— 从 11,523 张卡的 `card.content.ipa` 提取 | `python scripts/build_fonts.py --list` |
| **`scripts/` 入库** | **111 文件**（git 跟踪）· **+3 待入库**（本轮新增 `fetch_fonts` / `build_fonts` / `build_font_compare`）· 工作区 129（已排除 `__pycache__`） | `git ls-files scripts/ \| wc -l` |
| **`data/coevo.db`（生产库）** | **45 表 · 30 空** · `users` 2 · `tokens` 2 · `user_cards`/`card_memory`/`review_log` **全 0** · mtime **`09-25 22:48`（未被本轮触碰 ✅）** | `SELECT COUNT(*) FROM ...` |
| 前端静态分析 | ✅ **error=0** · warning=13 · info=4（**本行曾记「error=3」，那正是「把故障当基线」的历史残留** —— web-only 清零后已归零） | `scripts/analyze_inproc/` |
| 🆕 **`user.db` 迁移** | **schema v1.3**（`version` 1→2）｜🆕 **`verify_userdb_migration`（20 项）专测「老库升级」** —— 🔑 现有验收全跑在**新建临时库**上、**天然覆盖不到升级路径**，故必须显式造 v1 老库 | `dart run bin/verify_userdb_migration.dart` |
| ✅ **真机运行** | ✅✅ **已真机验证多轮**（Android APK）—— **Step 3 界面已上线**（本行曾记「仍是 K12 遗留页面」，属 09-26 时点，**已过时**）｜⚠️ 构建只能由白哥执行（我的环境无法跑 `flutter`，见 §3.3x） | `D:\flutter\bin\flutter.bat build apk --release` |
| 🆕 **SDK** | 官方 **`D:\flutter`（3.41.1 / Dart 3.11.0）不在 PATH**；PATH 里是**鸿蒙定制版** `D:\flutter_flutter`（3.27.5-ohos）→ **必须写全路径** | `D:\flutter\bin\flutter.bat --version` |
| 后端编译 | ✅ `cargo check` **EXIT=0** | `cd backend && cargo check` |


---

## 〇、先看这一节：计划有两套编号，别混用

| 体系 | 出处 | 范围 | 关系 |
|---|---|---|---|
| **Phase 0–7** | 主方案 `english-app-implementation-plan-v2` §七 | **产品全生命周期**（资质→词库→~~语音包~~→内容→端侧→变现→增长） | **主编号** —— 说「到哪步了」用它 · 🔴 **Phase 2 已取消**（TTS 全量端侧，2026-09-26） |
| **Step 1–5** | `ui-ux-refactor-assessment` §7.1 | **UI/UX 重构**（清障→设计系统→核心界面→复习页→分享） | **Phase 4 的细化**（子编号） |

**对照关系**：

```
Phase 1 词表数据库        ← 独立轨道（脚本，不涉 UI）
Phase 2 语音包            ← ⛔ 已取消（2026-09-26：TTS 全量端侧 `flutter_tts`）
Phase 3 内容抓取          ← 独立轨道（服务端）
Phase 4 端侧 MVP  ────────┐
                          ├─ Step 1 清障        （Phase 4 的前置）
                          ├─ Step 2 设计系统
                          ├─ Step 3 核心界面     （对应 Phase 4 #2/3/4/5）
                          ├─ Step 3.5 内容扩展   （对应 Phase 4 #12/13）
                          └─ Step 4 复习与个人页 （对应 Phase 4 #5 + 我的页）
Phase 5 云端与变现
Phase 5.5 三主题验收
Phase 6 激励与增长
```

**→ 结论：Phase 1/2/3 可并行推进；Phase 4 必须先做 Step 1（清障），否则无法编译到原生。**

---

## 一、计划全貌 + 当前状态

图例：✅ 完成（有产物证据）｜🟠 部分｜⏳ 未开始｜❌ 已取消

### 🔵 Phase 0 · 资质与账号

| 项 | 状态 | 实测证据 / 说明 |
|---|---|---|
| **ICP 备案** | ✅ | **粤ICP备2026061557号-1**（`keyievolution.fun`）—— Apple 中国区要的是这个（非经营性备案），**已满足** |
| 公安备案 | ✅ | 已有 |
| **Apple Developer Program（Individual）** | ⏳ | **$99/年，未办** —— 🟠 **白哥 2026-09-26 决定放到最后做**（不阻塞当前开发；但**上架前必须办**，是所有上架动作的前置） |
| 🔴 **Small Business Program** | ⏳ | 未办 —— 佣金 **30% → 15%**（首年即生效，收入 +21%） |
| **810 号令合规填报** | ⏳ | 未办 —— 依赖 Apple 账号（App Store Connect → 商务 → 协议 → 合规，填**身份证号 + 姓名**，不填影响打款） |
| 隐私政策页 | ⏳ | 未办（法定必需） |
| ~~软著 / 微信开放平台 / 安卓商店 / 厂商推送 / ICP 经营许可~~ | ❌ | **已核实不需要** |

### 🔵 Phase 1 · 词表数据库（11 项）

| # | 事项 | 状态 | 实测证据 |
|---|---|---|---|
| 1 | 建 `word_form` 词形映射表 | ✅ | 旧映射表 **36,856 条**；新链式表落 `word.db` = **24,062 行**（🆕 09-28 补漏 +1,233，原 22,829；⚠️ **口径不同，见 §三 偏差 1**） |
| 2 | 中文内联拆分 | ✅ | 修复 199 条，残留 0 |
| 3 | 剔除专有名词/缩写 | ✅ | 累计删 **876 条** → 词表 12,791 → 11,917 |
| 4 | ~~清理污染短词~~ | ✅ | 并入 #3（原「长度≤2/无元音」判据被实测推翻 —— y 是半元音） |
| 5 | 词族聚合 | ✅ | 🔄 **方式已更换**：原「规则法 + 组 C 人工判断」**被白哥否定**（规则判断不了自己的遗漏）→ 改 **LLM 全库重跑 + `aggregate_page`**，实测 **1,777 页**（etymon 1,181 + root 596） |
| 6 | 补拼写变体映射 | ✅ | 生成 48 条（英美变体对） |
| 7 | 甲型空壳卡补内容 | ✅ | 空壳 729 条全补，含义项 25,567 |
| 8 | 补中文释义/搭配/例句 | ✅ | 完整率 100% |
| 9 | ~~补空 CEFR 等级~~ | ❌ | **伪任务**（实测空的全是日语/俄语，英语侧 0 条空） |
| **10** | **卡片结构重组**（首义优先 + 记忆法） | ✅ **已完成（2026-09-26）** | 见下方「#10 详情」—— **`sense` 归零 · `context` 99.72% · `definition` 100% · `root` 排第一 100%** |
| **11** | **索引化查询** → 🔄 **更正为「建立端侧索引化查询能力」** | ✅ **已完成（2026-09-26）** | 🔴 原定性不成立（`match_text()` **死代码**、索引已齐、划词不走后端）→ 白哥定 **方案 A + 冗余 spelling** → 已实施 `WordQueryService` / `ReviewListQuery` / user.db **schema v1.1** · **79 项断言全过**。📄 `word-query-indexing-audit` §九 |
| 🆕 | **LLM 全库重跑**（不在原 11 项） | ✅ | **11,917 / 11,917 = 100%** · 生成 42 秒 · 全链路 ≈9 min · **≈¥69** · 落 **18 表** · 外键 0 违规 |

#### ✅ #10 卡片结构重组详情（2026-09-26 本轮完成）

**做了什么**：把 card 组装从「第 5 步（素材落库前）」**移到末尾**，并改为**按 v1 §4.2 的段类型组装**。

**改前 → 改后**：

| 项 | 改前 | **改后** |
|---|---|---|
| 段类型 | 只有 `sense`(24,491) + `root`(5,484) | **`definition` 11,523 · `context` 11,491 · `collocation` 11,437 · `etymology` 11,407 · `root` 5,484 · `cognate` 2,988** |
| 🔴 **例句位置** | 塞在 `sense` 里 → **朗读清单命中不了 → 240 MB 例句音频会全漏** | **独立成 `context`（99.72%）** ✅ |
| `root` 位置 | 从不排第一 | **排第一 100%**（5,484/5,484） |
| 首义 | 与其余义项混在 `sense` | **`definition` 恰好 1 条（100%）**；其余进 `card_extra`（844 → **13,812** 行） |
| 义项上限 | 卡面最多铺 4 个义项 | 首义 1 条 + **其余全部进 `card_extra`**（不丢数据） |
| 入口 | **`aggregate_link` 段缺失 → 1,777 页不可达** | **入口内嵌在记忆法段**（12,164 处 `entry.page_id`），不单列段 |
| 源数据 | 只能用 LLM 原始数据（拿不到幻觉过滤后的词素） | 用**落库后**的 `word_morpheme`（已过滤 55 条幻觉词素） |

**四条设计决定**（对应已发生的偏离）：
1. **例句独立成 `context`** —— v1 §6.2 朗读清单只认 `context`/`collocation`/`front`
2. **存全部可用素材**（不只首段）—— 白哥：「库级应该是可以就存在，而渲染端选择展示哪些、展示顺序、替换逻辑」→ **改渲染规则不用重跑全库**
3. **`aggregate_link` 不单列段**（白哥裁决）→ 入口 id 内嵌
4. **其余义项 → `card_extra`**（v1 §5.2）

**验证**（`scripts/verify_card_structure.py`，**13 项断言全过，退出码 0**）：

| 检查 | 结果 |
|---|---|
| 段类型合法性（只允许 v1 的 8 种） | ✅ 无非法 |
| **`sense` 残留在 `card.content`** | ✅ **0 条** |
| **例句在 `context`** | ✅ **11,491 / 11,523 = 99.72%**（旧结构为 **0**） |
| 每卡恰好 1 条 `definition` | ✅ **11,523 / 11,523 = 100%** |
| 记忆法顺序（root→cognate→collocation→etymology） | ✅ 0 处错误 |
| **`root` 存在时排第一** | ✅ **100%** |
| 无 `aggregate_link` 段 | ✅ 0 |
| 入口内嵌 | ✅ 12,164 处 |
| **渲染后段数 ≤ 4**（v1 §5.1） | ✅ 最大 4（**98.3% 正好 4 段**） |
| 渲染文本字符 | ✅ **p50 76 · max 172**（v1 上限 200–300 → **不超限**） |

**副作用核验**（逐表对比备份，**只有预期内的一张表变了**）：

| 表 | 变化 |
|---|---|
| `card_extra` | 844 → **13,812**（+12,968）← **预期内**（其余义项从卡面移到 extra） |
| **其余 17 张表** | **全部 +0** ✅ |

**成本**：**零 LLM**（只重跑组装，数据全在）· 库 25.0 MB → 31.4 MB（content 合计 10.7 MB）

**→ 附带解锁**：~~**Phase 2 语音包的前置条件已满足**（此前若生成，例句音频会全漏）~~ → ⛔ **2026-09-26：语音包取消，此解锁已无意义**（#10 卡片重组本身的价值不受影响）。

**Phase 1 产物**：`data/word.db`（**18 表 · 25 MB**）—— `word` **11,523** · `card` 11,523 · `aggregate_page` **1,777** · `word_morpheme` 13,489

### 🔵 Phase 2 · 语音包生成

> ## ⛔ 整条轨道已取消（2026-09-26 白哥决策）
>
> **TTS 全量端侧 `flutter_tts`**（文章朗读 + 词卡都是）· **腾讯云语音包不生成**（63,048 条 / ¥48.7 / 290 MB 全部取消）
> → **Phase 2 不再有工作项**（无「批量生成」任务，端侧合成无生成期）。
>
> 👉 权威：`docs/design/tts-unified-client-side-2026-09-26.md`
> 🔑 **编号处理**：Phase 2 **槽位保留、标注取消**，**不重排后续编号**（重排会让所有历史文档引用失效）

| 项 | 状态 | 证据 |
|---|---|---|
| ~~63,048 条音频（单词+例句+搭配）· ¥48.7~~ | ⛔ **已取消** | 不再生成；`card_audio` 表**永久为空**（作废，`word-db-schema-frozen` §1.10 已标注） |

> 🔄 **原「前置条件已解除」说明已无意义**：此前指出「例句放在 `sense` 段会导致例句音频漏生成 240 MB」——
> 语音包取消后**该风险归零**。但 **Phase 1 #10 卡片重组（例句 → `context` 段 99.72%）的价值不受影响**（它是卡片结构修复，与音频无关）。

### 🔵 Phase 3 · 内容抓取（服务端）

| 项 | 状态 | 证据 |
|---|---|---|
| RSS 抓取器 + 内容池 + 去重 + 难度估算 + 定时调度 + 打标 | ⏳ **未开始** | 🔴 后端 **无 RSS/feedparser 实现**；`coevo.db` **无 `content_cache` 表** |

### 🔵 Phase 4 · 端侧 MVP（14 项 · 核心）

| # | 模块 | 状态 | 证据 |
|---|---|---|---|
| 1 | 端侧 SQLite（`word.db` + `user.db`） | 🟠 | `word.db` ✅ **19 张表**（业务表 18 + `sqlite_sequence`）；**`user.db` 表结构已定义**（`app/assets/sql/user_db_schema.sql`）+ **查询层已建**（`word_query_service` / `review_list_query`），🔴 **未接入 UI** |
| 2 | 信息流 UI | ⏳ | 🔴 **无 feed 文件**（`app/lib/screens/` 无 feed/reader） |
| 3 | 阅读视图 | ⏳ | 🔴 同上 |
| 4 | **划词查词** | ⏳ | 🔴 **全库 0 命中**（无 `SelectableText`/`SelectionArea`/`contextMenuBuilder`）—— UI 最大工作量项 |
| **5** | **生词本 + FSRS 复习** | 🟠 | ✅ **FSRS 服务层已完成**（本轮）：`app/lib/services/fsrs_service.dart` + **39 项断言全过**；🔴 **UI 未做**（`review_screen.dart` 是旧 K12 概念卡，需重写） |
| 6 | 词卡朗读 | ⏳ | ~~依赖 Phase 2~~ → ✅ **不再依赖**（Phase 2 取消）；改为**端侧 `flutter_tts` 实现**，依赖 #1（user.db）+ 词卡文本 |
| 7 | 内容同步 | ⏳ | 依赖 Phase 3 |
| 9 | 私密笔记 | ⏳ | |
| 10 | 结构化交互 | ⏳ | |
| 11 | 收藏 | ⏳ | |
| 12 | 文章 TTS 朗读 | ⏳ | 依赖 #3 |
| 13 | 电子书导入（EPUB/TXT） | 🟠 | 「用 CoEvo 打开」✅ 已实施；**解析器未做** |
| 14 | 「用 CoEvo 打开」 | ✅ | `Info.plist` + `AppDelegate.swift` + `open_with_handler.dart` |

### 🔵 Phase 5 · 云端与变现 / Phase 5.5 三主题验收 / Phase 6 激励增长 / Phase 7

| Phase | 状态 | 证据 |
|---|---|---|
| Phase 5 云端与变现（8 项） | ⏳ **未开始** | `coevo.db` 里有 `users` 2 / `tokens` 2 行（骨架在），但**订阅/降级/合规材料全未做**；`user_cards`/`card_memory`/`review_log` **全 0 行** |
| Phase 5.5 三主题验收（9 项） | 🟢 **前置全部就绪，可开始** | 三档 token + `buildTheme` 接线（§3.15）· **粘土组件**（§3.17）· **280ms 过渡**（§3.18）全部落齐 → 「三档 × 粘土四态」验收（spec §八）**现在可做** |
| Phase 6 激励与增长 | ⏳ **未开始** | |
| Phase 7 后续可选 | ⏳ | |

### 🔵 UI/UX Step 1–5（Phase 4 的细化）

| Step | 内容 | 状态 | 证据 |
|---|---|---|---|
| **1** | **清障** | ✅ **已推进（2026-09-26）** | ✅ **admin 已全删**（app 内 0 行 + `app_admin` 项目已删）· `app/lib` **76 → 60 文件 / 29,799 → 21,818 行**（清障当刻）· 累计删除 **17,205 行**（app 内 7,981 + app_admin 9,224）· **web-only 13 → 2 文件**（详见 §3.5）<br>⚠️ **当前值**：**61 文件 / 22,065 行**（清障后新增 6 个文件共 1,658 行：`fsrs_service` / `open_with_handler` / `review_list_query` / `word_query_service` / `image_export` / `math_expr`）—— 见顶部实测快照 |
| **2** | **设计系统** | ✅ **五批全落 · Step 2 完成（§3.12–§3.19）** | ✅ token 层（811 行）· ✅ **中文换 OFL 字体（Noto Sans SC，省 19.33 MB）**· ✅ **旧主题整体删除** + `buildTheme` 接线 + 设置页三档切换 · ✅ **粘土渲染层**（`clay.dart` · 四态 + 真 inset · 已接入设置页预览 + **底部导航**）· ✅ **280ms 主题切换动效** · ✅ **token 插值** —— 验收 **382 项全过**（含【13】底部栏配套 · 【15】导航侧滑）｜⏳ 剩：真机目视（三档观感） |
| 3 | 核心界面（信息流/阅读器/划词/复习列表） | ⏳ | 🔴 **全部未开始** |
| 3.5 | 内容扩展（文章朗读 + 电子书导入） | 🟠 | 「用 CoEvo 打开」✅；其余未做 |
| 4 | 复习与个人页 | 🟠 | FSRS 服务层 ✅（本轮）；翻卡 UI + 我的页未做 |
| 5 | 激励与分享 | ⏳ | 未开始 |

---

## 二、一张表看全貌

| 轨道 | 进度 | 是否阻塞别人 |
|---|---|---|
| **Phase 0 资质** | 🟠 `1/6`（备案✅，Apple 账号未办） | 🔴 **阻塞 Phase 5 变现 + 上架** |
| **Phase 1 词库** | ✅ **`11/11` 全部完成** | ✅ #10 卡片重组 · ✅ #11 查询层（含定性更正）→ **Phase 1 收口** |
| ~~**Phase 2 语音包**~~ | ⛔ **已取消**（2026-09-26） | TTS 全量端侧 `flutter_tts` → 不生成音频资产，轨道无工作项 |
| **Phase 3 内容抓取** | ⏳ `0/6` | 🔴 **阻塞 Phase 4 #7/12**（无内容可读/可听） |
| **Phase 4 端侧 MVP** | 🟠 **`2/14`**（FSRS 服务层 ✅ + 用 CoEvo 打开 ✅） | — |
| **Phase 5 变现** | ⏳ `0/8` | 依赖 Phase 0 |
| **UI Step 1 清障** | 🟠 **`3/5`** | 🟠 **已清 90%**：admin 全删 · web-only 13→2 文件 · 依赖已加；**剩 2 个 web-only 文件落在「待重写」范围内**（见 §3.5） |

---

## 三、🔴 关键路径与阻塞

### 3.1 真正的阻塞链

```
UI Step 1（清障）                  ✅ 主体已完成 2026-09-26（§3.5）
   └─ 删 admin 14,946 行 ✅ + 改造 web-only 13 文件 → 2 文件 ✅
        └─ 🟠 剩 2 个 web-only 文件（chat_input / review_card_widget）
           **本身就在「待删/待重写」范围内** → 并入 Step 3/4
             └─ 原生才能编译 ← 否则 Phase 4 的所有 UI 都写不了
             └─ Phase 4 #2/3/4（信息流/阅读器/划词）
                  └─ 依赖 Phase 3（内容抓取）→ 无内容可读

Phase 1 #10（卡片结构重组）  ✅ 已完成 2026-09-26
   └─ 例句 type: sense → context（99.72%）
        └─ ⛔ Phase 2 语音包 ~~✅ 已解除阻塞~~ → **整条轨道已取消**（TTS 全量端侧，2026-09-26）

Phase 0（Apple 账号）
   └─ Phase 5 变现（订阅 / 810 号令 / 隐私政策）
```

### 3.2 🔴 一个必须说明的问题：本轮工作**跳过了顺序**

本轮做的 **FSRS 端侧调度**属于 **Phase 4 #5 / Step 4** 的内容 ——
但 **Step 2（设计系统）、Step 3（核心界面）仍全未做**（Step 1 清障已于 2026-09-26 完成主体，见 §3.5）。

**这不是浪费，但要清楚它的性质**：

| 角度 | 说明 |
|---|---|
| ✅ **为什么可以先做** | FSRS 是**纯 Dart 服务层**，不依赖 UI 与 Flutter（正是为此才刻意设计成不 import Flutter）→ **本地可验证**（39 项断言全过） |
| ✅ **价值** | 它是复习闭环的算法内核，且修掉了后端两处硬 bug（四档单调性全反 + elapsed 被忽略） |
| 🟠 **受限已减轻** | UI 界面**仍被 Step 1 阻塞**（清障未做），但「**改完无法验证**」这条**已解除** —— 本地已有进程内 analyzer（语义层）+ 结构检查，CI 补平台编译（见 §3.3） |

### 3.3 🔴 第二个阻塞：「验证链路」的真实情况（**此节已于 2026-09-26 更正**）

> ⚠️ **更正说明**：本节初版写「**无任何 CI 配置**，UI 重写只能盲改」——**这个结论是错的**。
> 错因：只查了 `codemagic.yaml`，**没有查 `.github/workflows/`**。实际核查后如下。

#### 实测：已有 GitHub Actions CI

| 位置 | 内容 | 会被执行吗 |
|---|---|---|
| **`.github/workflows/ci.yml`** | **Rust**（fmt + clippy `-D warnings` + test）· **Flutter**（`pub get` + `analyze --no-fatal-infos` + `test`） | ✅ **会**（push/PR 到 main/master） |
| ~~`app_user/.github/workflows/build.yml`~~ | 216 行：Android APK/AAB · **iOS 归档 + App Store 上传** · Web | 🔴 **不会**（子目录）；🗑️ **2026-09-26 已随 `app_user` 删除**，参考已抢救（见 §3.4） |

**→ 结论修正**：不是「没有 CI」，而是：
- ✅ **有可用的 CI**（analyze/test 能抓编译错误与测试失败）
- 🟠 但它**只在 push 后跑** → 本地没有快反馈
- ✅ **iOS 构建已补齐**（`.github/workflows/ci.yml` 的 `ios-build` job，macOS 手动触发）—— 但**只做 `--no-codesign` 验证**；**归档/签名/上传**仍无实现（参考见 `docs/operations/ios-appstore-ci-reference.md`）
- 🔴 **不需要 Codemagic** —— GHA 自带 `macos-latest` runner，且已有基础设施与模板

#### 实测：本地验证能力（🔴 **2026-09-26 二次更正**）

> ⚠️ **二次更正**：本节初版把 `dart analyze` 崩溃归因为「**本地只有鸿蒙定制版 Flutter**」——**这个归因也错了**。
> 白哥指出本机另有官方版 `D:\flutter`；实测后确认真相如下。

**本机有两个 Flutter SDK，但都崩在同一行**：

| SDK | 版本 | `dart analyze` |
|---|---|---|
| **`D:\flutter`**（官方 stable） | Flutter **3.41.1** / Dart **3.11.0**（2026-02 构建） | 🔴 崩 |
| `D:\flutter_flutter`（鸿蒙定制） | Flutter 3.27.5-ohos / Dart 3.6.2 | 🔴 崩（**同一个失败点**） |

**真正根因：本机无法创建任何子进程。**

```dart
// 最小复现：连 cmd /c echo 都起不来
Process.run('cmd', ['/c', 'echo', 'hi'])
// → ProcessException: 所有的管道范例都在使用中
//   (process_win.cc:742 · CreateFile failed 231 = ERROR_PIPE_BUSY)
```

- `dart analyze` / `flutter analyze` **架构上必须 fork 一个 `analysis_server` 子进程**
  → 必然失败（**与 Flutter 来源无关**，两个 SDK 都崩在 `AnalysisServer._startProcess`）
- **关沙箱重试同样失败** → 不是沙箱策略，是 **Windows 命名管道实例耗尽**
  （现场：272 进程 / **13 个 conhost.exe**，每个 conhost 都占管道；疑为长会话累积）

**能 / 不能跑的边界（实测）**：

| 命令 | 本地 | 说明 |
|---|---|---|
| `dart pub get --offline` | ✅ | 🔑 **必须加 `--offline`** —— 不加会卡在 `Resolving...` 直到超时（联网慢），**不是崩溃** |
| `dart run <脚本>` | ✅ | **同进程**执行，不 fork |
| **进程内 analyzer** | ✅ | 🆕 见下节（本轮突破） |
| `dart analyze` / `flutter analyze` | ❌ | 必须 fork `analysis_server` |
| `flutter build` | ❌ | 需 fork + 无 Mac 环境 |

#### ✅ 突破：进程内静态分析（本轮新增）

既然 `dart run` 可用，就把**分析器跑在本进程内** → 🆕 **`scripts/analyze_inproc/`**

```bash
cd scripts/analyze_inproc
/d/flutter/bin/cache/dart-sdk/bin/dart.exe run bin/analyze.dart /e/CoEvo/app/lib
# → error=15  warning=16  info=35   （76 文件 / 22 秒；15 全是 web-only 库 → 清障后应为 0）
```

**这补上了「本地代码层快反馈」** —— 不必等 push 到 CI 才知道有没有类型/引用错误。

**能力边界（必须知道）**：

| 能查 | 不能查 |
|---|---|
| ✅ 语法 / 类型 / 未定义引用 / 未解析 import | ❌ **真正的平台编译**（`flutter build ios` 只能在 CI 上跑） |
| ✅ 未使用成员 / 未使用 import / 弃用 API | ❌ 完整 lint 规则集（`flutter analyze` 在 CI 上更全） |
| ✅ **平台可用性** —— 🆕 **本脚本自建**（按 AST 扫 web-only 库的 import） | |

🔑 **为什么 analyzer 自己查不出 `dart:html`**：它用完整 Dart SDK，`dart:html` 作为 web 库**是存在的**
→ import 合法 → 它只报 `unused_import`。**→ 脚本改为直接扫 AST 的 import 指令**，
命中 `dart:html` / `dart:js` / `dart:ui_web` 等 web-only 库即判 **ERROR**。

🎉 **收益（立刻见效）**：原 grep 口径 `dart:(html|js)` **漏掉了 `dart:ui_web`**
（`lib/pages/admin/campaign/admin_campaign_detail.dart`）—— 语义判据抓到了它，口径已同步扩展。
**实测命中 15 处 / 13 个文件**（`dart:html` 11 + `dart:js` 3 + `dart:ui_web` 1）。

→ ⚠️ 分析 `app/lib` 前**必须先 `dart pub get --offline`** —— 否则像 `package:fsrs` 未解析会连锁报一串假错误（本轮实测踩到）。

#### ✅ 由此得出的五层验证策略

| 层 | 在哪跑 | 覆盖 | 成本 |
|---|---|---|---|
| **① 本地结构检查** | 本地 | `scripts/check_native_readiness.py` —— **把「清障目标」变成断言**（web-only 库残留 / admin 残留 / 代码量 / 字体权重） | 0（grep 级） |
| **② 本地语义分析** | 本地 | 🆕 `scripts/analyze_inproc/` —— 类型 / 引用 / 未使用 + **web-only 库判据**（**本轮的「本地快反馈」**） | 0（同进程） |
| **③ 本地纯 Dart 验收** | 本地 | `scripts/fsrs_verify/`（19 + 39 项，退出码可判） | 0 |
| **④ CI 编译验证** | GHA ubuntu | `flutter analyze`（完整 lint）+ `flutter test` | 便宜 |
| **⑤ CI iOS 构建** | GHA **macOS** | `flutter build ios --no-codesign` —— 🔴 **最终裁决：真编译一次** | ⚠️ 私有仓库 **10x** 计费 → **仅手动/tag 触发** |

**→ 缺的从来不是「CI」，而是「本地快反馈」** —— 已用层 ①② 补上（本轮新增）。

**已实施**（本轮）：
- `scripts/check_native_readiness.py` ✅（本地可跑，退出码 1 = 仍有阻塞；**口径已扩到 `dart:ui_web`**）
- 🆕 `scripts/analyze_inproc/` ✅（**进程内 analyze + 自建平台可用性判据**；
  `app/lib` 76 文件 → **error=15（全部是 web-only 库）**，即**除清障项外语义层 0 错误**；`app/test` 5 文件 → **error=0**）
- `.github/workflows/ci.yml` 扩展 ✅ 3 个新 job：`fsrs-verify`（纯 Dart 验收）· `native-readiness`（结构检查，**advisory**）· `ios-build`（macOS，手动触发）

### 3.4 ✅ `app_user` 的 iOS 构建配置 —— 已抢救并**随旧项目删除**（2026-09-26）

**原状况**：`app_user/.github/workflows/build.yml`（216 行）含 Android APK/AAB · **iOS .xcarchive** ·
**iOS App Store 上传（导出 IPA + 上传）** · Web —— 但放在**子目录**，
**GitHub Actions 只读仓库根的 `.github/workflows/`** → 🔴 **从未执行过**。

**处置（本轮）**：`app_user` 整个旧项目（**16,519 行**）已删除，但**该 workflow 是全项目唯一的
iOS 归档→导出→上传参考实现**，故先抢救到文档再删：

| 产物 | 位置 | 说明 |
|---|---|---|
| **参考实现** | 🆕 **`docs/operations/ios-appstore-ci-reference.md`** | 完整流程 + **6 处修正标注**（原配置照抄会失败） |
| **导出配置** | 🆕 **`app/.github/export-options.plist`** | 已修正（去 Bitcode、加 `signingStyle`），`teamID` 待填 |

**修正的 6 处**（原文**照抄会直接失败**）：

| # | 原配置 | 问题 |
|---|---|---|
| 1 | `xcrun altool --upload-app -u -p` | 🔴 **Apple 已弃用**（2023-11 起）→ 改 **App Store Connect API Key** |
| 2 | `teamID: YOUR_TEAM_ID` | 占位符未填 |
| 3 | `PROVISIONING_PROFILE_SPECIFIER="match AppStore …"` | 依赖 fastlane match 证书管理 → 改**自动签名** |
| 4 | ~~`flutter-version: 3.27.x`~~ | ✅ **已定 3.41.1**（2026-10-01 · CI 已钉 · 与项目 SDK 一致） |
| 5 | `--dart-define=API_HOST=keyievolution.fun` | 旧项目注入方式，`app/` 待确认 |
| 6 | `uploadBitcode` / `compileBitcode` | Bitcode 自 Xcode 14 起**已废弃** → 删除 |

**⚠️ 为什么现在不建这份 workflow**：Phase 0 未完成（Apple 账号 / Team ID / API Key 都不存在）
→ 配了也跑不了，且 macOS runner 按 **10x** 计费。
→ **待真正要上架时，按参考文档 §3.2 建立。**

**可回滚**：`data/backups/app_user_and_shared_20260926_194206/app_user.tar.gz`（320 条目，含原始 `build.yml` 与 `export-options.plist`）

### 3.5 ✅ Step 1 清障实施记录（2026-09-26 · 白哥「开始做吧」）

#### ① 删除（累计 **17,205 行**）

| 项 | 内容 | 行数 |
|---|---|---:|
| **app 内 admin** | `lib/pages/admin/**`（10 文件）+ `lib/screens/admin_screen.dart` | **5,722** |
| **K12 家长端** | `lib/screens/guardian_screen.dart` | 855 |
| **K12 学科** | `lib/screens/k12_subject_screen.dart` | 227 |
| **对话列表** | `lib/screens/conversation_list_screen.dart` | 361 |
| **跳过概念页** | `lib/screens/skipped_screen.dart` | 77 |
| **营销/分销** | `lib/pages/user/distribution/{earnings,team,withdraw}_page.dart` | 958 |
| **`app_admin` 整项目** | 21 文件（独立 Flutter 项目，**git 已跟踪**） | **9,224** |

**实测**：`app/lib` **76 → 60 文件** / **29,799 → 21,818 行**（**−7,981**，降 26.8%）；
累计（含 `app_admin`）**−17,205 行** —— **已超 Step 1 原目标（约 14,700 行）**。

**引用清理**：`app.dart` 删 6 条路由（`/admin` `/guardian` `/teacher` `/conversations` `/k12-subject` `/skipped`）
+ 3 条（`/earnings` `/team` `/withdraw`）+ 8 个 import + `_allScreens` 常量（dart2js 反 tree-shaking 用）。
**删后 analyzer 报 0 个悬空引用** ✅

**可回滚**：`data/backups/step1_cleanup_20260926_191714/`（42 文件 / 767 KB）；
且以上文件**均在 git 跟踪内** → 也可 `git checkout` 恢复。

#### ② web-only 改造（13 文件 / 15 处 → **2 文件 / 3 处**）

沿用 `ui-ux-refactor-assessment` §1.2 映射表：

| 文件 | 原 web API | 改造后 | 状态 |
|---|---|---|---|
| `pages/admin/campaign/admin_campaign_detail.dart` | `dart:html` + `dart:ui_web` | — | ✅ 随 admin 删 |
| `pages/admin/settlement/admin_batch_detail.dart` | `dart:html` | — | ✅ 随 admin 删 |
| `pages/admin/settlement/admin_commission_list.dart` | `dart:html` | — | ✅ 随 admin 删 |
| `screens/admin_screen.dart` | `dart:html` | — | ✅ 随 admin 删 |
| `screens/guardian_screen.dart` | `dart:html` | — | ✅ 随 K12 删 |
| **`providers/auth_provider.dart`** | `html.window.localStorage` | **`shared_preferences`**（key `coevo_trial_used`） | ✅ 改造 |
| **`pages/user/distribution/notification_panel.dart`** | `html.window.open` | **`url_launcher`**（失败退回复制链接） | ✅ 改造 |
| **`screens/profile_screen.dart`** | `html.Blob`+`AnchorElement` 下载 | **`share_plus`**（抽公共工具 `utils/image_export.dart`） | ✅ 改造 |
| **`widgets/achievement_share_card.dart`** | 同上 | 同上 | ✅ 改造 |
| **`screens/review_screen.dart`** | 同上 | 同上 | ✅ 改造 |
| **`widgets/graph_widget.dart`** | `js.context.eval` 算函数值 | 🆕 **纯 Dart 表达式求值器** `utils/math_expr.dart`（递归下降，零新依赖） | ✅ 改造 |
| 🟠 `screens/chat/chat_input.dart` | `dart:js` JS 录音模块 | — | ⏳ **属「AI 对话」待删** → 保留 |
| 🟠 `widgets/review_card_widget.dart` | `dart:html`(unused) + `dart:js` 录音 | — | ⏳ **属「复习卡待重写」** → 保留 |

**🔑 关键判断：剩下这 2 个文件不该现在改造。**
它们分别是「待删（AI 对话）」与「待重写（复习卡）」的目标文件 —— 现在改造等于**白做一遍**。
且 `chat_input` 的录音要改成 `record` 包（项目已依赖），这属于**重写**而非清障。

**新增依赖**（均在 pub 缓存内，`dart pub get --offline` 秒级完成）：
`share_plus: ^10.1.4` · `url_launcher: ^6.3.2`（映射表预期新增的两个，**正好这两个**）

**新增 2 个工具文件**（避免三处重复 / 引入新依赖）：
- `lib/utils/image_export.dart` —— `exportPngBytes()`：写临时文件 → 系统分享面板。
  **为什么不是「下载」**：原生没有「下载到本机」概念，最接近的心智模型是「存到『文件』App / 分享」。
  **为什么落盘而非用内存字节**：`XFile.fromData` 在原生无真实路径，`share_plus` 的 iOS 实现需要路径。
- `lib/utils/math_expr.dart` —— `evalMathExpr()`：递归下降解析 `+ - * / ^`、括号、`x`、`pi/e`、19 个数学函数。
  行为与原 JS `eval` 对齐（失败返回 `null`，可能返回 `NaN`/`Inf`，由调用方按 `isFinite` 过滤）。

#### ③ ⚠️ 一处语义变化（需知晓）

`AuthNotifier.hasUsedTrial()` 原为**同步**（读 `localStorage`），改用 `shared_preferences` 后**必须 `await`**
→ 已同步调整 2 个调用点（`home_screen.dart:97` 加 `await`；`:268` 回调改 `async` + `mounted` 检查）。
**行为等价**（`shared_preferences` 在 Web 上底层同样是 `localStorage`），但**调用方必须 await**。

#### ④ ✅ 验证结果（双口径）

```bash
python3 scripts/check_native_readiness.py
# ① web-only 残留 2 文件（13 → 2）  ② app 内 admin 0 行 / app_admin 已删  ④ 21,818 行
cd scripts/analyze_inproc && dart run bin/analyze.dart ../app/lib --errors-only
# error=3（全部是 web-only 判定）→ **0 个类型 / 引用错误**
```

**结论**：`app/lib` 在**语义层完全干净**；剩余 3 处 error 全部来自 2 个「待删/待重写」文件，
**清障目标（原生可编译的基础障碍）已达成 90%**。

#### ⑤ 剩余 7,045 行可删代码的处置建议

| 待删模块 | 行数 | 为什么现在不删 |
|---|---:|---|
| **AI 对话**（`chat_screen` + `chat/**`） | 2,191 | 需改 `home_screen` 入口 —— 而 **`home_screen` 本质就是 K12 学科选择页**（`getK12Subjects`/`k12SubjectFallbacks`/`k12GradeNames`），**要整体重写成信息流首页**（Step 3） |
| **理科图表** `graph_widget.dart` | 1,641 | 被 `markdown_span_nodes` 引用 → 连带 |
| **Markdown/Math 渲染** | 920 | 被 `card_list` / `review_screen` / `review_card_widget` 引用 → 连带 |
| **验证策略** `pipelines/**` | 591 | 被 `review_screen` / `review_card_widget` 引用 → 连带 |
| **成就页**（保留连续天数） | ~800 | 文档要求**保留里程碑逻辑并入「我的」页** → 属重写 |
| **临时账户认领** `claim_dialog.dart` | 219 | 被 `home_screen`/`profile_screen`/`chat_screen` 引用 → 连带 |
| **K12 配置** `config/k12_subjects.dart` | 161 | 被 `home_screen` 引用 → 连带 |

**🔑 建议：合并到 Step 3/4，不要单独做。** 理由：

> 这 7 项**全部**需要连带改 `home_screen` / `profile_screen` / `review_screen`，
> 而这三个页面**本身就是 Step 3/4 的重写目标**。
> **分两次改同一批文件 = 双倍工作**；且剩余 2 个 web-only 文件也会随重写一并消失。

**→ Step 1 到此为自然边界。**

#### ⑦ 🟠 Phase 1 #11「索引化查询」调查结论（2026-09-26 · **待白哥定范围**）

📄 完整报告 `docs/design/word-query-indexing-audit-2026-09-26.md`

**文档前提不成立**（逐条实测）：

| 文档说 | 实测 |
|---|---|
| 「`word_bank.rs` 每次调用遍历全部 **41,574** 词条（O(N) 全表扫）」 | 🔴 那个函数 `match_text()` **0 个调用点 = 死代码** |
| 「**必须重写**」 | 🔴 唯一被调用的 `lookup_cefr()` 本就是 **O(1) HashMap**；`get_cefr_catalog_stats()` 虽全遍历，但属**统计接口**、**非划词路径** |
| 「划词性能基础」 | 🔴 **划词是端侧功能**（v1 §2.1「查词（词库内）离线可用」），**不走后端** |
| （隐含）word.db 缺索引 | 🔴 **索引已齐**：9 显式 + 18 自动 = **27 个**，`EXPLAIN` 确认全部走索引 |

**关键数字澄清**：`cefr_catalog.json` = **41,574**（旧后端词表）· `word.db` = **11,523**（新端侧词库）—— **文档混用了两代数据**。

**真实缺口 = 端侧完全没有 DB 能力**：`app/pubspec.yaml` 无任何 SQLite 依赖 · `app/lib` 无 DB 访问层（0 命中）· `word.db` 不在 app 内。

**实测性能（不缺性能）**：完整查词链路 p50 **43 µs**（Python）/ **228 µs**（Dart FFI，稳态）；
首查（冷）1.3–2.6 ms；未命中不退化（70 µs）→ 确认 O(log n)。**远低于感知阈值 100 ms。**

**✅ 决定性验证**：🆕 `scripts/sqflite_probe/` 实测 **纯 Dart 可用 `sqflite_common_ffi` 打开真 `word.db` 并查询**
→ **查询层不需要 Flutter → 本地可验证**（与 `scripts/fsrs_verify/` 同思路）。

**🔴 顺带查出两处我此前引入的「写了但没接通」缺陷**：
1. **`assets/sql/` 未声明** —— `app/pubspec.yaml` 的 `flutter:` 段**只有 `fonts:` 没有 `assets:`** →
   `app/assets/sql/user_db_schema.sql` **不会被打包**（编译不报错、运行时才炸）
2. 🔴 **`/scripts` 被 gitignore，而 CI 引用了它** —— `git ls-files scripts/` = **0 个文件**，但
   `ci.yml:85`（`working-directory: scripts/fsrs_verify`）与 `:121`（`scripts/check_native_readiness.py`）
   都指向它 → **`fsrs-verify` + `native-readiness` 两个 job 必然失败**（5 个 job 中 2 个）
   · 连带有长期价值的脚本（`load_llm_results.py` / `build_chains.py` / `verify_card_structure.py` …）**全未入库**
   · **待白哥定**：A 白名单部分入库（推荐）/ B 移到 `tools/` / C 从 CI 移除这 2 个 job

**🔴 一个必须决策的跨库问题**：`user.db.card_review_state` 主键是 `word_id`、**无 `spelling`**，
而复习页要显示「单词 + 释义 + 熟度 + 到期时间」并支持**搜索** → 需跨 `user.db` 与 `word.db`。
三个方案：**冗余 `spelling`**（快，需保一致）/ `ATTACH JOIN`（无冗余，双库常开）/ 单库合并（简单但词库更新要整库替换）。

**请白哥定 5 项**（报告 §八）：① 范围（A 拆出可验证查询层 / B 推迟 Step 3 / C 仅修 assets+依赖）
② 跨库方案 ③ 后端 `word_bank.rs` 是否独立清理 ④ #11 定性是否更正为「建立端侧索引化查询能力」
⑤ 🔴 **`scripts/` 是否入库**（不修则 CI 2 个 job 红着）

**→ 白哥定案并已实施**：

| 决定 | 落地 |
|---|---|
| **① 方案 A** | ✅ `app/lib/services/word_query_service.dart`（查词/词形还原/卡片/聚合页入口）+ `review_list_query.dart`（搜索/三档排序/分组）+ 🆕 **`scripts/query_verify/`** → **79 项断言全过**（42 + 37） |
| **② 跨库 = 冗余 `spelling`** | ✅ `user.db` **schema v1.1**：`card_review_state.spelling NOT NULL COLLATE NOCASE` + `idx_crs_spelling`；`fsrs_service.toRow({required spelling})` 让**编译器**强制 |
| **④ 更正 #11 定性** | ✅ 主方案 + `word-database-design` 共 **6 处**更正并标注原因 |
| **③ 后端清理** | ✅ **已完成（2026-09-26，白哥定「本次做」）** —— `word_bank.rs`：① `get_cefr_catalog_stats()` **改为 `init()` 预计算**（原每次「我的」页加载全遍历 41,574 条，而结果完全静态）② **删死代码** `match_text()` + `WordMatch` + `is_loaded()`（0 调用点）· 模块文档补「与端侧词库的关系」表 · 单测重写为 `test_word_bank_lookup_and_stats`（含 CEFR 顺序断言）· `cargo check` **退出码 0** + `cargo test` **1 passed** |
| **⑤ `scripts/` 入库** | ✅ **已完成（2026-09-26，白哥定「追踪」）** —— `.gitignore` 去掉 `/scripts` 整目录忽略 + 补 Python 缓存规则（`__pycache__/` `*.pyc`，原先**完全未忽略**）· **106 个文件已 `git add`** · 🔴 **入库前先移除 6 处硬编码 API key**（见下） |

**顺带修掉两处静默缺陷**：

---

### 3.6 ✅ ③ 后端清理 + ⑤ `scripts/` 入库 实施记录（2026-09-26）

#### ③ 后端 `word_bank.rs` 清理（白哥「本次做」）

| 改动 | 依据 |
|---|---|
| `get_cefr_catalog_stats()` 移到 `init()` 预计算（新增 `CEFR_STATS: OnceLock`） | 🔴 原**每次「我的」页加载**（`GET /api/user/{id}/profile`）都全遍历 **41,574 条** + 分组；而结果**只依赖启动时加载的 JSON，运行期不变** → 纯浪费 |
| **删 `match_text()`**（90 行） | **0 个调用点**；且它做 O(N) 全表扫 —— 曾被文档误认为「划词瓶颈」，但**划词是端侧功能**，不走后端 |
| **删 `WordMatch` / `is_loaded()`** | 仅被 `match_text` 使用 / 0 调用点 |
| 模块文档补 §「与端侧词库的关系」 | 防后人再混用 41,574 与 11,523 |
| 单测重写 | 原测试只测 `match_text`（已删）→ 改为测 `lookup_cefr` + **CEFR 顺序**（A1→C1） |

**验证**：`cargo check -p chat_engine -p api_server --tests` **退出码 0**（1m52s）· `cargo test -p chat_engine word_bank` → **1 passed**。

> ⚠️ **`cefr_stats` 的定位**：`prebuilt_cards.card_type='vocabulary'` 共 16,516 条
> （**11,917 英文 + 4,599 中文**），英文那部分正是词库词数 → `lookup_cefr` 是**活的**。
> 但**新设计里端侧才是权威词库** → 该接口将来若改走端侧数据，`word_bank.rs` 可整体删除。

#### ⑤ `scripts/` 纳入 git 追踪（白哥「追踪」）

**改动**：`.gitignore` 第 18 行 `/scripts`（整目录忽略）→ 移除；并补 Python 缓存规则。

**为什么原先会导致 CI 失败**：`git ls-files scripts/` = **0**，而 `ci.yml:85`（`working-directory: scripts/fsrs_verify`）
与 `:121`（`scripts/check_native_readiness.py`）引用了它 → **`fsrs-verify` + `native-readiness` 两个 job 必然失败**。

**入库清单**：**106 个文件**

| 目录 | 文件数 |
|---|---:|
| 顶层 `.py` / `.sh` / `.js` / `.cmd` | 54 |
| `card_generators/` | 11 |
| `backend_tests/` | 10 |
| `query_verify/` · `fsrs_verify/` · `analyze_inproc/` | 6 + 5 + 3 |
| `stress/` · `graph_tests/` · `eval/` · `e2e/` | 5 + 4 + 4 + 4 |

**排除**（已由忽略规则挡住）：`__pycache__/` · `*.pyc` · `.dart_tool/` · `pubspec.lock`
→ **新增 `__pycache__/` + `*.pyc` 规则**：原先**完全未忽略**（仓库里已有 4 个 `__pycache__` 目录，
含 `marketing/scripts/v3/` 下的，随时可能误入库）

#### 🔴 入库前查出并移除：6 处硬编码 API key

扫描发现同一把 key 硬编码在 6 个脚本里：

| 文件 | 原内容 |
|---|---|
| `backend_tests/cp2_accuracy_test.py` · `prod_cn_stage.py` · `prod_dual_agent_g1-2.py` · `prod_plan_e2e_test.py` · `prod_stage_complete.py` | `DS_KEY = "sk-d27804d2…"` |
| `card_generators/chinese_lang.py` | `API_KEY = "sk-d27804d2…"` |

**处置**：全部改为 `os.environ.get("DEEPSEEK_API_KEY", "")`（并补 `import os`），
6 个文件 `py_compile` 全通过，`scripts/` 内 `sk-` 残留 **0**。

**🔴 但同一把 key 还有 3 处已在 git 跟踪内**（本任务范围外，需白哥定）：

| 位置 | 说明 |
|---|---|
| `docs/deploy/deployment-checklist.md:46` | 运行手册里以明文列出 env 值 |
| `docs/review/python_script_inventory_2026-06-08.md:201` | 脚本清单 |
| `docs/review/python_script_security_audit_2026-06-08.md:14,108` | **安全审计报告本身** |

另有**第二把** key（`sk-b266987d…`）在 `marketing/scripts/v3/{demo_run,complaint_discovery}.py`（**已跟踪**），
以及**第三把**在 `backend/.env`（✅ 已被 `.gitignore` 正确挡住）。

> ⚠️ **仅删文字不等于安全** —— 这三处已进 git 历史。
> **真正的修复是轮换这三把 key**；清历史（`filter-repo`/BFG）是可选加强。
> 本次只做了「阻止新增泄漏」，**未动历史、未轮换**。

#### 🔴 本轮新查出的问题：`cefr_catalog` vs `word.db` 差异（白哥提问）

📄 完整报告 **`docs/design/word-list-diff-cefr-catalog-vs-worddb-2026-09-26.md`**
（核查脚本 🆕 `scripts/audit_wordlist_diff.py`，可复跑）

**结论**：两份表是**不同抽象层级**（表面词形 vs 词元），不是「一大一小两版」：

```
41,574（旧表：语料抽词，未归一）
 ├─ 11,110  交集
 └─ 30,464  只在旧表
      ├─  7,858（25.8%）✅ 变形 → 已归一进 word_form（is→be / said→say）
      └─ 22,606（74.2%）语料长尾（freq 中位 **1**）→ 未达收录标准
```

**🔴 但查出真问题 —— `word.db` 的高频词可达率下滑**：

| 排名范围 | 可达率 |
|---|---:|
| 前 500 | **99.4%** |
| 前 2,000 | **96.0%**（**80 个查不到**） |
| 前 5,000 | 89.9% |
| 全表 | 45.6% |

**真·查不到 = 1,233 个**（`word_form` 缺映射 + 词元缺）：**plural 823** · adverb 243 · past 82 · ing 63
· 如 `things`(freq **368**) · `activities` · `products` · `leaders` · `relations` · `shown` · `opened` · `laid`

> ✅ **已修复（2026-09-28 23:0x）**：按方案 A 补入 **1,233 行** → 「真·查不到」**1,233 → 4**（余 4 条为故意排除的假映射）·
>    前 2,000 可达率 **96.0% → 97.2%** · 前 5,000 **89.9% → 92.9%**｜脚本 `scripts/fill_word_form_gap.py`
>    🔴 **同轮定下路线转向**：地名/变体/长尾**不再补库** → 改由 **LLM 兜底路径**在查词时自动补，
>    工作重心转向「**调整 LLM 制卡**」（见 `word-form-gap-and-place-names-2026-09-28.md` §四）
>    ⚠️ 下面 641–675 行的数字为 **09-26 修复前**基线，保留作对照。

**判据（本轮方法贡献）**：旧 `word_form.json`（36,856）是**规则穷举**（机械套 plural/past/ing），
必然产生假形式（`abolitioned` / `absolutelying`）。用 **`cefr_catalog.brown_freq` 当「语料真实性」过滤器**：

| 旧有新无且原形在库的 10,910 条 | 数量 | 结论 |
|---|---:|---|
| 语料**从未**出现 → 规则误加 | **9,401 (86.2%)** | ✅ 新表**正确排除** |
| 语料**出现过** → 真遗漏 | 1,509 (13.8%) | 🟠 其中 **1,233 真查不到** |

→ **换生成方式同时带来「去噪」（9,401）与「漏收」（1,233）**；**漏的是高频词，成本更痛**。
→ 🔴 **这是回归**：旧系统 `things` 可查，新系统不可查。

**另发现**：**英美变体不对称** —— `behavior`🔴 `behaviour`🔴 · `labor`🔴 `labour`🔴（**两边都没有**）·
`centre`🔴（`center`✅）· `theater`🔴（`theatre`✅）；`word_form` **无任何 variant 规则**。

**修复建议（待白哥定）**：**A** 用旧表补「语料出现过」的 1,509 条（零 LLM，天然排除 9,401 条噪音）
+ **C** 服务层加形态兜底（去 s/ed/ing 重试） + **D** 补英美变体对（≥200 对）。
**不建议**把 22,606 条语料长尾直接补录（频次 1、无等级、大量专名古语，会稀释词库质量）。

**保留物**：`data/curriculum/prebuilt/word_form.json`（36,856）**不应删** —— 它是本次补漏的数据来源。

---

### 3.7 🔄 词库策略转向：「预先建满」→「按需生长」（2026-09-26 白哥定）

> 白哥：「**词库不用了，就用 LLM 兜底就行了**，划线查询没有的就调用 LLM 生成新的词卡，
> **新生成的词卡要走完整表结构并更新聚类**，这样用不了多久词库就会很完善了，用户体验也不会差」

📄 报告 **`docs/design/wordlib-on-demand-growth-2026-09-26.md`**

#### ✅ 结论一：这不是新设计，是**回归 v1 原文**

| v1 原文位置 | 内容 |
|---|---|
| 第 26 行 | 架构图末行：「**词库外生词 → LLM 兜底制卡**」 |
| 第 40 行 | 决策表：「联网场景 = 登录/同步 + **词库外生词制卡** + ~~语音包下载~~」→ ⛔ **「语音包下载」一项已失效**（不生成语音包） |
| 第 74 行 | 云端服务：「**LLM 制卡服务 + 全局缓存**」 |
| 第 807 行 | 接口：`POST /generate-card  # 词库外生词兜底` |
| 第 1083–1086 行 | 查词流程：未命中 → `external_word_cache` → 再未命中 → **联网 LLM 制卡** → 写入缓存 |
| 第 1202 行 | 核心原则：「离线优先、**预制为主、联网兜底**……」（数字 `generated_card_cache.hit_count` 亦为此设计） |

**⚠️ 关键澄清**：v1 说的是「**预制为主**、联网兜底」→ 准确理解是
**「不废弃词库，而是不再追求预先建满，剩下的按需生长」**（已建 11,523 词仍在下用，命中即走预制卡）。
这与白哥说的「用不了多久词库就会很完善」完全一致。

#### ✅ 结论二：技术可行性**已验证**（34 项断言全过）

🆕 `scripts/incremental_clustering.py`（增量聚类引擎）+ 🆕 `scripts/verify_incremental_clustering.py`（验收）

```bash
python3 scripts/verify_incremental_clustering.py     # → 通过 34 项，失败 0 项 · 退出码 0
```

**验证内容（真数据 · 在真库副本上跑）**：

| # | 断言 | 结果 |
|---|---|---|
| 1 | 新词加入**已有大族**（`cept` 22 词）→ 复用 `root_id` · size→23 · **不新建页** · 成员入页 | ✅ |
| 2 | 🔑 **门槛跨越**：加入 `size=2` 族 → size→3 → **自动新建聚合页**（成员 3 条） | ✅ |
| 3 | 幂等：重复刷新不重复建页 | ✅ |
| 4 | **同形异源不混**（`man` OE「人」vs Latin「停留」→ 两条独立 `word_root`） | ✅ |
| 5 | 全新词根 → 新建 `word_root` + 新族 `size=1` + **不建页** | ✅ |
| 6 | 🔑 **反向**：删词 → 跌破门槛 → **自动删页** | ✅ |
| 7 | 全库不变量：**达标族数 == 页数（596==596）** · 无残留页 · 无 `member_count` 不一致 | ✅ |
| 8 | **源库 md5 未变**（`3d56f3ea…`）· 副本写入确实落盘 | ✅ |

**为什么门槛跨越是关键**：批量落库（`load_llm_results.py`）是「先建完族再统一建页」—— 门槛**天然**被处理；
增量版逐词改，跨越检测是**新增逻辑**。两条路必须产出同一个库，否则长期分叉。

#### 🔴 结论三：3 个架构取舍 + 3 个缺失环节，**待白哥定**

**架构取舍（成本差 ≈ 用户数倍）**：

| | **A 服务端生成 + 全局缓存**（v1 原设计） | **B 端侧生成 + 本地缓存** |
|---|---|---|
| 聚类一致性 | ✅ 全局唯一 | 🔴 各设备不同（聚类失去意义） |
| 成本 | **每词只付 1 次** | 🔴 **× 用户数**（同词被 N 人查 → 付 N 次） |
| 后续用户 | ✅ **瞬时**（命中全局缓存） | 🟠 仅本机瞬时 |
| 密钥 | ✅ 只在服务端 | 🔴 **App 内嵌 key 可被提取** |

**成本实测**：**¥0.0058/词**（全量 ¥69 ÷ 11,917 词）→ 日增 300 词 ≈ **¥1.7/天**。
**建议：A**（v1 原设计）。

**🔴 缺失的三个环节（白哥方案里没有，但必须有）**：

| # | 环节 | 为什么必须补 |
|---|---|---|
| 1 | **合规扫描** | 预制库的卡**经过核查**（我们查出并修正过 `taiwan`/`tibet` 涉主权错误）；**动态生成无人工环节** → 风险直接暴露。现状：生成侧**只有词法层校验**（幻觉词素白名单），**没有合规扫描器** |
| 2 | **`confidence` 门槛** | 契约自带该字段且 prompt 有指示，但**落库逻辑未读它** → 建议 0.7 / 0.4 三档（发布 / 标记 / 降级卡） |
| 3 | **新词音频** | ~~预制卡有语音包，新词没有 →~~ 建议走**端侧 `flutter_tts`**（与「文章朗读走端侧」一致，零成本）→ ✅ **2026-09-26 已成决策：预制卡与新词统一走端侧，无差异** |

#### 对现有计划的影响

| 项 | 影响 |
|---|---|
| **Phase 1 词库（11/11）** | ✅ **不废弃** —— 它是「预制为主」的主体，承担绝大多数查询（命中零延迟零成本） |
| ~~Phase 2 语音包~~ | ⛔ **2026-09-26 取消**（TTS 全量端侧 `flutter_tts`）→ `tts-unified-client-side-2026-09-26.md` |
| **Phase 4 端侧** | 🔴 **新增**：`external_word_cache` + 排队 + `word_db_version` |
| **后端** | 🔴 **新增**：`generated_card_cache` + `POST /generate-card` |
| **未在计划内** | 🔴 合规扫描器 · `confidence` 闸门 · 增量聚类接入 |

#### 建议的下一步（待批准）

1. 🆕 **合规扫描器** `scripts/scan_compliance.py`（涉主权/涉政/黄暴/歧视）+ 对现有 11,523 词跑一遍（补历史欠账 + 验证扫描器）
2. **增量聚类接入 `load_llm_results.py`**（避免两套聚类实现分叉）
3. **单卡端到端验证**：真调一次 LLM 生成 → 走增量聚类入库 → 断言卡片四段结构（成本 ¥0.006）
4. 之后（依赖架构决定）：服务端 `POST /generate-card` + `generated_card_cache`

---

### 3.8 ✅ 合规扫描已建成 + 服务端生成架构（2026-09-26 白哥决策）

> 白哥定：**① 生成放服务端 ② 合规扫描现在就做 ③ 问「confidence 阈值是指什么」 ④ 音频「如果走 flutter_tts 那就全量走 flutter_tts，不然音色不统一更奇怪」**

📄 报告 **`docs/design/on-demand-generation-server-side-2026-09-26.md`**

#### ① ✅ 合规扫描器（已建成 · 29 项验收全过）

🆕 `scripts/scan_compliance.py` + 🆕 `scripts/verify_compliance_scan.py`（**9 正例 + 17 负例 + 3 真库回归**）
+ 🆕 `data/reports/compliance_scan_2026-09-26.json`

**全库 11,523 词扫描结果**：**P0 = 2** · P1 = 6 · P2 = 2

| P0 词 | 字段 | 问题 |
|---|---|---|
| **`taiwan`** | `definition.en` | "a **self-governing democracy**" —— 把中国领土说成独立政体 |
| **`tibet`** | `definition.en` | "**historically an independent kingdom**" —— 错误历史叙述 |

**🔑 三条判据铁律（首版误报 97 处 → 三轮精修到 10 处）**：

| # | 铁律 | 首版误报实例 |
|---|---|---|
| **1** | **必须按词边界匹配** | `grape`/`scraped`/`drapery` 命中 `rape`（子串）· `schooner` 命中 `coon` |
| **2** | **敏感词条 ≠ 违规内容** | `nigger`（已标注 slur）· `retard`（"延缓"义）· `massacre`/`rape` 词条自身例句 —— **都是正确行为** |
| **3** | **「独立王国」本身不错，针对中国领土才错** | `independent`"India became an independent nation in 1947" · `hanover`"once an independent kingdom" —— **史实，不报** |

> 🔑 三条本质是同一件事：**判断「内容怎么描述」而非「出现了什么词」**（与 `data-noise-classification` 的「自述型措辞 > 描述型措辞」同源）

**⚠️ 顺带发现：`hong kong` / `macau` / `xinjiang` / `tiananmen` 等常见地名全不在词库**（但 `taiwan`/`tibet`/`china` 在）→ 用户查会失败，且这类词恰好**最需要合规把关**。

#### ② ❓ confidence 的澄清（白哥提问）—— 🔴 **它几乎没有区分度，不能当闸门**

`confidence` = **LLM 对自己的自评置信度**（契约第 175 行，定义仅一句「your overall judgement」）。

**实测全量 11,917 条的分布**：

| 值 | 条数 | 占比 |
|---:|---:|---:|
| **0.9** | **11,680** | **98.0%** |
| 0.8 | 193 | 1.6% |
| ≤0.7 | 44 | 0.4% |

→ 阈值 0.7 **只能拦掉 44 条**。**根因**：契约未给锚点 + LLM 自评**天然偏乐观**。

**⚠️ 更危险**：动态生成（单词、无上下文）质量更不确定，但 LLM **仍会自评 0.9**。

**→ 修正建议**：闸门改用 **6 条可验证的客观判据**（合规扫描 / 字段完整 / 幻觉词素 / `derived_from` / `analyzable` 一致性 / 词根真实性），`confidence` **仅作辅助**（<0.5 触发复核）。

#### ③ 🔴 音频：你的担忧成立，但 **`flutter_tts` 恰恰做不到「音色统一」**

> ## ⛔ 本节结论已被推翻（2026-09-26 白哥决策）
>
> **白哥定案**：「**还是统一走 `flutter_tts`（文章朗读和词卡都是），统一音色不是要所有用户统一，而是要当前用户统一即可**，
> 这样也不用录制音频了，腾讯云语音包都不用了，用户手动下载就手动下载。」
>
> **我的错**：把「音色统一」升级成「跨用户/跨设备统一」（**白哥没要求的更强约束**），再拿它否掉 `flutter_tts`；
> 又把「iOS 增强音色需手动下载」当成否决理由（**实为可管理的 UX 问题**，应对成本极低）。
>
> 👉 **现行权威：`docs/design/tts-unified-client-side-2026-09-26.md`**
> ⛔ 下方 §③ 的「修正建议：新词音频也走服务端腾讯云 TTS」**已作废**；
> ⚠️ 但其中 **iOS 音色三层 + 需手动下载 + 跨设备必然不同** 的**事实陈述仍然有效**（属「需应对的工程项」）。
> 🔑 **唯一必须保住的是「同一界面内音色一致」= 同一张卡内锁定同一 `voice` 实例。**

**查证发现既有的不一致**（不是新词引入）：**词卡发音走腾讯云语音包**，而**文章朗读走 `flutter_tts`** → 两条路本来就音色不同。

**但 iOS 系统 TTS 的硬约束**（决定性）：

| 层级 | 体积 | 质量 | 获取 |
|---|---|---|---|
| **Compact（默认）** | 几十 KB | 🔴 **"sounds like a robot"** | 内置 |
| Enhanced | 100–150 MB | 🟢 好 | 🔴 **用户手动下载** |
| Premium / Siri 语音 | 300–700 MB | 🟢 最自然 | 🔴 **用户手动下载** |

→ **三条件**：① 默认是机器人音 ② 增强语音**App 无法自动装** ③ **跨设备音色必然不同**
→ **`flutter_tts` 只能「同设备内统一」，做不到「所有用户同一声音」。**

**⛔ ~~修正建议：新词音频也走服务端腾讯云 TTS~~（已作废，见本节 banner）**

| 项 | 数据 |
|---|---|
| 单卡音频 | ≈115 字符 → **¥0.0034** |
| 单卡文本 | ¥0.0058 |
| **合计** | ~~**¥0.0092/卡**~~ → ✅ **现行 ¥0.0058/卡**（音频改端侧，降 37%） |
| 日增 300 词 | ~~**¥2.77/天**~~ → ✅ **¥1.74/天** |

→ ~~🎯 **音色 100% 统一** + 一次生成全局共享 + 与文本同批生成~~
→ **文章朗读仍必须 `flutter_tts`**（长文本 ¥2.8/万字符，日活 1000 读 2 篇 ≈ ¥5,400/月，不可接受）
→ 🔄 **2026-09-26**：**词卡朗读也走 `flutter_tts`** —— 两者实现统一，唯一的音色约束变成「**同一张卡内锁定同一 voice**」

#### ④ 服务端架构要点

```
划词 → ① 端侧 word.db【绝大多数，零延迟】
      → ② 端侧 external_word_cache
      → ③ 服务端 generated_card_cache（v1 已有 DDL，含 hit_count 跨用户复用）
      → ④ LLM 生成（复用 coevo_wordlib_contract）
      → ⑤ 🔴 合规扫描（P0 拒绝）→ ⑥ 🔴 客观闸门
      → ⑦ ⛔ ~~生成音频（腾讯云，同音色）~~ **已取消**（TTS 全量端侧）→ ⑧ 增量聚类入库（已就绪）
```

**🔴 必须处理竞态**：多用户同时查同一新词 → 服务端**词级互斥锁**（in-flight 去重），否则生成 N 次。
→ 🔑 这也是**服务端相对端侧的额外收益** —— 端侧各设备互不知情，**去重天然做不到**。

#### 请白哥定 5 项

| # | 事项 | 建议 |
|---|---|---|
| 1 | **P0 那 2 处是否现在就修** | ✅ **修**（`taiwan`/`tibet` 各重写一句）—— 唯一阻塞上线的合规问题 |
| 2 | **`hong kong` 等缺失地名是否补录** | ✅ **补**（这类词最需要合规把关） |
| 3 | **音频方案** | ✅ 词卡 = 服务端腾讯云 TTS；文章 = `flutter_tts` |
| 4 | **`confidence` 是否还用** | 🟠 仅作辅助；闸门用 6 条客观判据 |
| 5 | **服务端接口是否现在建** | 🟠 建议先做 1–2 项 |
- `app/pubspec.yaml` 补 `assets: - assets/sql/`（原缺 → `user_db_schema.sql` 不会被打包）
- `scripts/` 的 CI 引用问题**待白哥定**（不修则 `fsrs-verify` + `native-readiness` 两个 job 必失败）

**🔑 验收抓到 2 个真问题（靠断言，不是读代码）**：
1. 「最近」排序用 `COALESCE(last_review_at, updated_at)` → **刚加入但上次复习较早**的词排最后（与语义相反）→ 改 `updated_at DESC`
2. `sqflite` 默认 `singleInstance: true` → 同路径二次 `open` 返回**同一实例**，`close()` **连带关掉别处连接**

#### ⑥ ✅ 追加删除：`app_user` + `coevo_shared`（2026-09-26 白哥「清掉」）

| 项 | 内容 | 行数 |
|---|---|---:|
| **`app_user`** | 旧 Flutter 项目（`coevao_app`，**`app` 的前身**，40 文件） | **16,519** |
| **`coevo_shared`** | 共享 Dart 库（27 文件，**只被 `app_user` 引用**） | 3,275 |
| | **合计** | **19,794** |

**判定依据（引用图）**：全项目搜 `app_user` / `coevo_shared` → 仅 **1 处**引用（`doc-consistency-check` 脚本的路径正则），
**`app` 完全不用 `coevo_shared`**（`app/pubspec.yaml` 无此依赖）→ **纯孤儿**。

**删除前抢救**：`app_user` 里有全项目**唯一**的 iOS 归档/导出/上传流程 →
🆕 `docs/operations/ios-appstore-ci-reference.md`（含 **6 处修正标注**，原文照抄会失败）
+ 🆕 `app/.github/export-options.plist`（已修正，`teamID` 待填）。

**为什么 `app` 的 iOS 配置不需要抢救**：实测 **`app` 的更新** ——
`Info.plist` **76 行 vs app_user 53 行**（含 `CFBundleDocumentTypes`，即已实施的「用 CoEvo 打开」）、
`AppDelegate.swift` **79 行 vs 13 行**（含 `open_with` MethodChannel）。

**排除项**（未备份，可重现）：`ohos/entry` **438 MB** + `ohos/oh_modules` **81 MB**（鸿蒙构建产物/第三方，git 只跟踪 3 个文件）

**累计清障**：**17,205 + 19,794 = 36,999 行**

**可回滚**：`data/backups/app_user_and_shared_20260926_194206/`（2 个 tar.gz，320 + 44 条目）；
且两者均在 **git 跟踪**内（153 + 29 文件）→ 也可 `git checkout` 恢复。

---

### 3.9 🔴 TTS 全量端侧 + 5 项定案（2026-09-26 白哥决策）

> 📄 权威：`docs/design/tts-unified-client-side-2026-09-26.md`

**白哥决策（原文）**：
> 「**还是统一走 `flutter_tts`（文章朗读和词卡都是），统一音色不是要所有用户统一，而是要当前用户统一即可**，
> 这样也不用录制音频了，**腾讯云语音包都不用了**，用户手动下载就手动下载。」

**5 项定案**：

| # | 事项 | 定案 | 状态 |
|---|---|---|---|
| 1 | `card_audio` | **留 DDL + 标注后续收费扩展** | ✅ 文档已改（`word-db-schema-frozen` §1.10） |
| 2 | `word.sort_seq` | **保留**（兼稳定排序键） | ✅ 无需改动 |
| 3 | 后端 TTS 全链 | 🔴 **保留** + 标注「**后续 chat、AI 考核功能扩展**」 | ✅ 无需改动（`audioplayers` 连带保留） |
| 4 | `sherpa_tts.dart` | 🔴 **删** | ✅ **已实施**（实测**零引用**）｜＋ 追加批准：`sherpa-models/` **125 MB** 删除 |
| 5 | Phase 2 编号 | **留槽位不重排** | ✅ 已标注取消 |
| 6 | 🆕 **TTS 默认引擎 + 音色优选**（追加批准） | ✅ `tts_service` 3 处 + `profile_screen` 2 处默认值 → `'native'`；`_pickBestVoice()` 改按官方 `quality` 字段取最高档 | ✅ **已实施** |

**✅ 本轮代码变更（8 项，全部已获批准）**：
| # | 变更 | 验证 |
|---|---|---|
| 1 | `git rm app/lib/services/sherpa_tts.dart`（169 行，**实测零引用**） | ✅ 备份 `data/backups/sherpa_tts.dart.removed-20260926` |
| 2 | `app/pubspec.yaml` 移除 `sherpa_onnx` | ✅ `pub get --offline` → **移除 9 个包** |
| 3 | `git rm -r sherpa-models/`（**125 MB**，5 文件） | ✅ **可恢复**：`git checkout 6693766 -- sherpa-models/`（blob 大小已实测核对） |
| 4 | `tts_service.dart` 默认引擎 `'tencent'` → **`'native'`**（含 `_getTtsEngine` 兜底 2 处） | ✅ 语义：**后端不可达时降级端侧，不回落到联网 TTS** |
| 5 | `profile_screen.dart:59/139` 引擎默认值 → **`'native'`** | ✅ 修复「设置页显示腾讯云 / 运行时是原生」的 UI 不一致 |
| 6 | `tts_service.dart:_pickBestVoice()` → **按官方 `quality` 字段取最高档** | ✅ 新增 `_qualityRank`/`_pickHighestQuality`/`_qualityRankOf` |
| 7 | `scripts/doc-consistency-check-english-app.py` 移除 `sherpa-models` 前缀 | ✅ 语义残留清理 |
| 8 | `profile_screen.dart` 本地音色试听 | ✅ **新增显式试听按钮**（`_previewNativeTts`）+ 试听文本改**英文**（原「你好，这是试听语音」zh-CN）+ 下拉框标签「系统默认 (zh-CN)」→ **「系统默认（自动匹配语言）」** |

### 3.9-b 🔴 两处更正：白哥质疑后核查，我上轮建议有误（2026-09-26）

> 白哥：「**音色试听改本地；新增「朗读词卡」入口——这是指什么？原来不就有设计词卡朗读点吗？**」

**更正 1：⛔「新增朗读词卡入口」是我错了 —— 朗读点早就设计了**

| 事实 | 依据 |
|---|---|
| L1 界面稿实测 **7 处喇叭图标**（`class="spk"`，**内联 SVG**） | `visual-word-card-target-2026-09-26.html` 行 210/245/270/296（词卡页）+ 899/977/1023（复习/列表页） |
| **规律**：每个「纯英文文本元素」旁一个喇叭，中文段不配 | 词卡页每卡 2 个（单词旁 `w-meta` + 语境原句旁 `ctx-txt`）；列表页每卡 1 个（仅单词旁） |
| 🔑 **与 v1 §6.2 完全对应**（`front`✅ / `context`✅ / `collocation`✅ / 中文段❌） | 「只朗读纯英文文本」原则 |

🔴 **我错在两处**：
① **搜索界面稿只搜文字**（「🔊 / 朗读 / speaker」）→ UI 元素是**内联 SVG**，搜不到 → 错误得出「界面稿无朗读入口」
② **把 v1 §6.2「音频生成清单」当成「UI 按钮设计」** → 凭空造出界面稿里不存在的「整卡连读入口」

✅ **正确表述**：朗读入口**无需新增**；实现时要做的是 ① 把界面稿的喇叭接上 `TtsService`（**属 Step 3 核心界面范围**）② **`voice` 只在 `init()`/用户选择时 set 一次，逐次点击朗读不得重新 `setVoice`**
> 🔑 **「同一 voice 实例」的要求依然成立**，但形式从「连读时保持不换」变为「**不重复 setVoice**」—— 后者更容易满足也更正确。

**更正 2：⚠️「音色试听改本地」语义有误（已按修正方案实施）**

实测 `profile_screen.dart` —— **两个引擎分支各有独立试听**：

| 分支 | 原状 | 判断 |
|---|---|---|
| **腾讯云** | 有专门试听按钮 → `_previewTencentTts()` → 服务端 `/api/tts/preview`（带 `voice_type`+`speed`） | ✅ **语义正确** —— 试听=听你要选的音色，腾讯云音色只能用腾讯云合成才听得到 |
| **本地原生** | **无专门按钮**；靠「选音色时自动 `speak('你好，这是试听语音','zh-CN')`」 | ⚠️ 读**中文**、标签写 `zh-CN`（英语 App 应为英文）、无显式按钮不直观 |

🔴 **我的原建议错在**：把「都改端侧」**机械推广到不该推广的地方**（试听是「验证选项」不是「朗读内容」），且**没核实本地分支其实已有本地试听**。

✅ **按修正方案实施**（白哥选定）：
- 腾讯云分支**保持服务端**试听（撤回原建议；后端 TTS 已定案保留，接口本就该留）
- 本地分支：**新增显式试听按钮** + 试听文本 `'Hello. This is a sample sentence.'`（纯英文，先单词后例句）+ **跟随语速**
- 顺带修标签语义残留：「系统默认 (zh-CN)」→ **「系统默认（自动匹配语言）」**（未指定音色时 `_pickBestVoice` 按**文本语言**自动匹配）
- 🔑 实现复用 `TtsService.speak()` 而非新建 `FlutterTts` → 继承音色选择/代检查/停止逻辑，**避免两套播放状态**

⚠️ **顺带发现既有不一致（未改，记录备查）**：`TtsService` 两入口读**不同偏好源** —— `togglePlay()` 读**本地 SharedPreferences**，`speak()` 读**后端 `user_preferences`**。不一致时可能走不同引擎。属既有问题，未扩大改动范围；缓解：`_getTtsEngine()` 兜底已改 `'native'` → 异常路径安全降级端侧。

**✅ 验证**：`profile_screen.dart` **error=0**（warning/info 均既有）；全库 **error=3 与改动前完全一致** → **零新增**。

### 3.9-c 🔴 腾讯云分支整体取消 + chat 改端侧（2026-09-26 白哥追加）

> 白哥：「**腾讯云分支应该都取消，其他朗读都取消了，试听还留着干嘛？**」

**我 §3.9-b 的建议错在哪**：我主张「腾讯云音色只能用腾讯云合成才听得到 → 试听应保留服务端」——
该论证的前提是「**用户会选腾讯云引擎**」。但朗读已全改端侧，用户没有选腾讯云的理由 → **前提不成立，结论自然错**。
🔑 **教训：论证成立与否取决于前提是否还成立；功能取消后，为它服务的子功能一并失去理由。**

#### 🔴 实施前的关键核实：chat 的回复朗读**默认就在走腾讯云**

```rust
// ws.rs:1298（删除前）—— 显式选了 native 才跳过，未设置或 tencent 都走腾讯云
match engine.as_deref() {
    Some("native") => return (None, None),
    _ => {}   // ← 未设置 / tencent → 走腾讯云合成
}
```

| 事实 | 影响 |
|---|---|
| chat 的 AI 回复朗读**默认走腾讯云**（后端合成 + WS 推送） | 后端 TTS 此前**不是"预留"，是"在用"** |
| 它读的 `tts_voice_type` 默认 `101016` = **智甜-女童声（中文音色）** | 对英语 App 而言默认音色本身就是错的 |

→ 白哥选择「**chat 也改端侧**」（彻底统一，与已定决策一致）。

#### 改动清单（前后端 8 文件）

| # | 文件 | 变更 |
|---|---|---|
| 1 | `profile_screen.dart` | 删**引擎选择器** + **腾讯云分支**（13 个音色下拉 / 语速 / 试听）· `if/else` → 直接展开本地分支（缩进同步调整）· 删 3 字段 + 3 行加载 + 3 个方法 + 2 个无用 import |
| 2 | `tts_service.dart` | **475 → 295 行（−180）**：删 `bindClient`/`_client`/`_syncToBackend` · 删全部「音频字节播放」路径（`cacheAudio`/`playAutoStream`/`_playNextAuto`/`cacheAndPlay`/`_playCached`/`_listenPlayerComplete`/`_currentPlayer`/`_autoPlayer`/`_autoQueue`/`_ttsCache`）· 删 `_getTtsEngine`/`_fetchAndPlayTencent` · `togglePlay`/`speak`/`stop`/`isPlaying` 简化为纯端侧 |
| 3 | `chat_screen.dart` | 删 `case 'tts_audio'` · 删 `bindClient` · 删 `_getLastAssistantText` · 🔴 **`_finalizeStreaming` 改为端侧朗读**（`if (ttsAutoPlayProvider) speak(reply)`） |
| 4 | `review_screen.dart` | 删 `bindClient`（连带清理只为它存在的 `auth`/`client`） |
| 5 | `coevo_models.dart` | 删 `WsEvent.audio` 字段（无消费者） |
| 6 | `backend/.../ws.rs` | **−107 行**：删 `tts_semaphore()` + `Semaphore`/`OnceLock` import · 删 `tts_tx/tts_rx` channel · 删后台流式合成块（3 路并发信号量 + 失败重试）· 删 `tts_audio` 推送 · 删 `get_user_tts_prefs()` · 删 `base64::Engine` import |
| 7 | `backend/.../routes.rs` | **−110 行**：删 `POST /api/tts/preview` + `POST /api/tts/speak`（handler + 路由） |
| 8 | `backend/.../tencent_tts.rs` | ✅ **保留模块** + 加**显式模块级文档**（当前无调用方 · 预留 AI 考核 · 因是 `pub mod` 不报 `dead_code`，**无此注释后人会误删**） |

> 🔑 **顺带发现并保留 `/api/stt/transcribe`（腾讯云 ASR）** —— 与「AI 考核（口语评测）」相关，**不属 TTS 范围，未动**。

#### ✅ 验证

| 范围 | 结果 |
|---|---|
| **前端** 全库 `analyze_inproc` | **error=3 / warning=13 / info=7** —— 与改动前**完全一致** → **零新增** |
| **后端** `cargo check` | ✅ **EXIT=0**（2 个环境类 warning：Windows 增量目录权限 `os error 5`，**与代码无关**） |
| 残留扫描 | 前端 `tts_engine`/`tts_voice_type`/`tts_speed`/`tts_audio` **0 命中**；后端 `tts_speak`/`tts_preview`/`get_user_tts_prefs`/`tts_semaphore` **0 命中** |

> ⚠️ **过程中踩坑（已修正）**：脚本删大块代码时，`speak` 方法**多留 2 个闭合 `}`** → 类提前结束 → 46 个级联 error。
> 🔑 **教训：脚本删大块后必须立刻编译验证**（本次靠 `analyze.dart` 立刻发现，未扩散）。
> 另：**CRLF 文件用 `\n` 匹配会断言失败** → 先归一化处理、写回时还原。
> 另：**同一文档多次插入后必须校验章节顺序**（本轮 §9.3/§9.4 曾跑到 §十 之后，已重排）。

**累计代码量**：`tts_service` 475→295 · `sherpa_tts.dart` 169→删 · `ws.rs` −107 · `routes.rs` −110 · `profile_screen` −96 · **数据 −125 MB** · **依赖 −9 包**

**✅ 验证**：`analyze_inproc` 全库 → **error=3 与改动前完全一致**（3 个全是既有 web-only）→ **零新增**；
`tts_service.dart` **error=0/warning=0**；`profile_screen.dart` **error=0**（warning/info 均既有）。

🔑 **实施前的关键核查（避免改动落空）**：确认**没有**任何地方把 `tts_engine` 预先写成 `'tencent'` ——
全项目仅 `profile_screen._saveTtsEngine()` 写入，且**只由用户手动点击触发**（`onSelectionChanged`），加载时不自动保存。

**🔴 实施中发现并修正的一处认知错误**：
我原以为识别音色档位只能靠**名字里有没有 "(Enhanced)"**（启发式）——
实测 flutter_tts 源码发现 **iOS 侧返回官方 `quality` 字段**（`"default"`/`"enhanced"`/`"premium"`），
且 `getVoices()` **不排序**（`SwiftFlutterTtsPlugin.swift:337-357`）→ **改用官方字段排序，弃用名字猜测**。
🔑 **通用教训：「官方字段 > 名字启发式」—— 能拿到结构化字段就不要解析字符串。**

**✅ 剩余 0 项（TTS 链路三轮改动全部收口）**：
| # | 事项 | 结果 |
|---|---|---|
| ~~1~~ | ~~`_pickBestVoice()` 最终兜底 `voices.first`~~ | ✅ **已修复**（§3.9-d）：改为 `return null` → 回落 `setLanguage(lang)` |
| — | ~~音色试听改本地~~ | ✅ **已按修正方案实施**（腾讯云保持服务端 + 本地新增按钮/英文）→ 见 §3.9-b |
| — | ~~新增「朗读词卡」入口~~ | ⛔ **建议已撤回** —— 朗读入口界面稿**早有设计**（7 处喇叭）→ 见 §3.9-b |
| — | ~~腾讯云分支 / chat 朗读~~ | ✅ **整体取消 + 改端侧** → 见 §3.9-c |

### 3.9-d 🔴 修复 `_pickBestVoice()` 兜底返回非目标语言音色（2026-09-26 白哥批准）

**缺陷**：`return voices.first` —— `getVoices` 返回**系统全部音色**（含 `zh-CN`/`ja-JP`/`fr-FR`…），
前两级（精确 locale / 语言前缀）都匹配不到时，兜底返回**列表首个**，而它很可能是**设备语言**对应音色
（中文设备 → 中文音色）→ 出现「**用中文音色念英文**」。

**修复**：`return null` → 调用方走 `_tts.setLanguage(lang)`，由 iOS 选该语言默认音色。

| 项 | 说明 |
|---|---|
| ✅ 调用方**本就能处理 `null`** | 已有 `if (best != null) … else setLanguage(lang)` → 改动只涉及返回值 |
| ✅ 顺带简化调用处 | 原「`_availableVoices.isNotEmpty` 外层判断」与 `_pickBestVoice` 内部空检查**重复**，且两个 `else` 分支**完全相同** → 合并 |
| ✅ 验证 | `tts_service.dart` **error=0 / warning=0 / info=0**；全库 **error=3 / warning=13** 与基线一致 → **零新增** |

> 🔑 **`setLanguage` 比"猜一个音色"更可靠**：`setLanguage` 由 iOS 自己挑该语言默认音色；
> 而「从列表挑首个」是我们**替系统做决定且信息不足**（只有一个列表，不知道哪个是设备默认）。
> 🔑 **通用规则：拿不准时交给系统默认，比用启发式猜一个"看起来像"的更安全。**

**🟠 顺带发现一个未改的相关问题（记录备查）**：设置页音色下拉直接列出**全部系统音色**（`profile_screen.dart:621` 用 `tts.availableVoices`）
→ 英语学习 App 里混入中日韩法大量无关音色，**选择成本高**。建议**按语言过滤**（只列 `en-*`）或英语音色置顶。
⚠️ **本次未改**：属 UI 改进而非缺陷修复，超出批准范围。

---

**🔴 我的错误（已记入记忆）**：上一轮把「音色统一」**升级成「跨用户/跨设备统一」**（白哥没要求的更强约束），
再拿它否掉 `flutter_tts`。🔑 **教训：把用户诉求"升级"成更强约束再否掉它，是隐蔽的偷换。**

**收益**：单卡 ¥0.0092 → **¥0.0058**（−37%）· App 体积 **−290 MB** · 首字延迟归零 · 零服务端依赖 · 文本不出端
**新增**：仓库工作区再释放 **125 MB**（累计 −415 MB）

---

### 3.10 ✅ P0 合规修复：`taiwan` / `tibet` 释义（2026-09-26 23:24）

> 📄 问题首见 §3.8「合规扫描」· 白哥 2026-09-26「按计划进行」→ 已实施

#### 修复内容（措辞经白哥选定「简明点明归属」）

| 词 | 字段 | 修改前 | 修改后 |
|---|---|---|---|
| **`taiwan`** (w000777) | `definition.en` | "An island in East Asia that is a ~~self-governing democracy~~." | "An island off the southeast coast of China. **Taiwan is a part of China.**" |
| | `definition.zh` | "台湾" | "**中国台湾**" |
| **`tibet`** (w009864) | `definition.en` | "a region in central Asia…; ~~historically an independent kingdom~~, now an autonomous region of China." | "**An autonomous region in southwestern China**, on the Tibetan Plateau. **Tibet has been a part of China since ancient times.**" |

- ✅ **未改动**其他段（`collocation` / `etymology` / `context` 逐段核对过）
- ✅ `tibet` 的搭配 `Tibet Autonomous Region` / `Tibetan plateau` 属**官方名称**，保留

#### 🔴 实施中发现的 3 件事 → ✅ 白哥当日全部处置（见 §3.11）

**① `card.content_hash` 与 `content` 大范围不一致（既有缺陷）→ ✅ 已全库回填**

| 实测（修复前） | 值 |
|---|---|
| 全库 `sha256(content)[:32] == content_hash` | **仅 28.4%**（3,268/11,523）→ **71.6% 不一致** |
| 前端消费 | 🟠 `word_query_service` 读入 `WordLookupResult.contentHash`，但**全项目无任何读取点**（只存不用） |

> **推测根因**：Phase 1 #10 卡片重组（例句 `sense` → `context`）重写了 `content`，但**未同步 `content_hash`**。
> **白哥批准全库回填** → 见 §3.11 ①（现 **100%** 一致）。

**② 新增 1 条 P1（我判断为误报）→ ✅ 白哥确认「是误报」→ 已修扫描器**

`tibet` 新释义触发 `[涉主权] 领土主体「tibet」与「autonomous region」同现`：
- 判据依据：`scan_compliance.py` 把 `autonomous region` 列入 `SOVEREIGN_CLAIM_WORDS`（**弱词**，不在 `_STRONG_CLAIM` → 报 P1）
- 🔴 **为何是误报**：「**autonomous region（自治区）**」是中国的**正式行政区划名称**（西藏自治区 = Tibet Autonomous Region），
  说「西藏是中国的一个自治区」**恰恰是正确表述** —— 与「把中国领土说成独立政体」是两回事
- ✅ **处置**：从 `SOVEREIGN_CLAIM_WORDS` 移除，并固化为 **铁律 5「官方行政区划名 ≠ 主权主张」**（见 §3.11 ②）

**③ 验收脚本 `verify_compliance_scan.py` 有 2 项断言失败（属修复的必然连带）→ ✅ 已改为零容忍**

| 断言 | 期望（旧） | 实测 | 性质 |
|---|---|---|---|
| `P0 词的集合 == {taiwan, tibet}` | `['taiwan','tibet']` | `[]` | 🔴 断言基于**修复前状态** |
| `P0 总数 == 2` | `2` | `0` | 同上 |

> 🔑 **这是「断言随实现过期」，不是新缺陷**。✅ 白哥批准 → 改为 **「P0 == 空集」（零容忍）**（见 §3.11 ③）。
> ✅ **CI 未引用该脚本** → 不会导致 CI 变红。

#### ✅ 验证记录

| 验证 | 结果 |
|---|---|
| 落盘（**独立连接**读取） | ✅ 读到新内容 |
| 文件指纹 | ✅ md5 `3d56f3ea…` → `1e77a1b1…` |
| 库完整性 | ✅ 表数 **19** 不变 · `word`/`card` **11,523** 不变 · `word_form` 22,829 · `card_extra` 13,812 全不变 |
| 改动精确性 | ✅ 仅 `definition` 段变化，`collocation`/`etymology`/`context` 逐段核对未动 |
| `content_hash` | ✅ 2 条已同步为一致 |
| **合规扫描** | ✅ **P0 2 → 0** · 退出码 **1 → 0** · `word.db` 无 P0 违规 |
| 备份 | ✅ `data/backups/word_before_compliance_fix_20260926_232401.db`（32.9 MB） |

#### 🔑 一条工具链教训：改 SQLite 必须显式 `COMMIT`

本次用 `con.isolation_level = None` + `BEGIN IMMEDIATE` + 显式 `COMMIT` ——
因为 **Python `sqlite3` 的 `close()` 会回滚未提交事务**（此前踩过：断言全过但文件 md5 未变）。
> **验证「真落盘」的可靠方法：独立连接重读 + 文件指纹（md5）双确认。**

---

### 3.11 ✅ 三项收口：hash 回填 · 扫描器误报 · 验收断言（2026-09-26 23:40）

> 白哥批复：「**A.同步 hash；B.是误报；C.同意**」

#### ① `content_hash` 全库回填 → **28.4% → 100%**

| 项 | 内容 |
|---|---|
| 算法（实测确认） | **`sha256(content)[:32]`** |
| 回填前 | 3,268/11,523 = **28.4%** |
| 回填条数 | **8,255 条**（11,523 − 3,268 ✓ 自洽）· 耗时 0.4s |
| 回填后 | ✅ **11,523/11,523 = 100.0%** · 不一致样例 **0** |
| 🔑 **为何安全** | `idx_card_hash` 是 **`CREATE INDEX`（非 UNIQUE）**（已实测 DDL）；且重算后 **11,523 个 hash 全唯一、零重复** → 即使将来加 UNIQUE 也不冲突 |
| 🔑 **未改 `updated_at`** | 这是 **hash 修正，不是内容变更** —— 改时间戳会伪造「内容被更新」的假信号 |
| 备份 | `data/backups/word_before_hash_backfill_20260926_234023.db` |
| 验证 | 独立连接 100% ✅ · md5 `1e77a1b1… → e7495c54…` ✅ · `PRAGMA integrity_check` = **ok** ✅ · 19 表 / 11,523 行不变 ✅ |

#### ② 扫描器误报修正 → **铁律 5「官方行政区划名 ≠ 主权主张」**

| 项 | 内容 |
|---|---|
| 改动 | `SOVEREIGN_CLAIM_WORDS` **移除 `'autonomous region'`** |
| 依据 | 「自治区」是中国的**正式行政区划名称** —— Tibet / Inner Mongolia / Xinjiang / Guangxi / Ningxia **Autonomous Region** 是这五个省级行政区的**官方英文名**。说「西藏是中国的一个自治区」**恰是正确表述** → 判据方向完全反了 |
| 🔴 **固化为铁律 5** | **加词前先问：这个词出现在「正确表述」里，会不会触发？会，就不能加。** |
| 影响 | `tibet` 的 P1 **消失** → **P1 7 → 6**（回到修复前基线） |
| ⚠️ **不动正例** | `tibet` 的两条 P0 正例靠 `historically an independent kingdom` / `independent kingdom`（`HARD_BLOCK_WITH_SUBJECT`）→ **仍全中** ✅ |

#### ③ 验收断言 → **P0 零容忍**

| 项 | 内容 |
|---|---|
| 改动 | `P0 词的集合 == {taiwan, tibet}` → **`== 空集`**；`P0 总数 == 2` → **`== 0`** |
| 🆕 **新增强化负例** | 引入 `MUST_BE_SILENT`（**必须零发现**，连 P1 都不许有）—— 与 `MUST_NOT_CATCH`（只断言不得是 P0）区分开 |
| 新增用例 | ① `tibet`「an autonomous region … of China」② `taiwan`「a part of China」→ **锁住本轮修正** |
| 附带 | 真库回归**打印 P1 数**（供人工复核参考，不作断言） |
| ✅ 结果 | **通过 31 项 / 失败 0 项**（原 29 项 → 新增 2 条强化负例）· P0 = **0** · P1 = **6** |

#### 🔑 一条通用教训（本轮）

> **判据要拿「正确表述」当反例来验，不能只拿「违规表述」当正例。**
>
> 扫描器原来只验「违规的能不能抓到」（正例），**从不验「正确的会不会误伤」（负例）** ——
> 于是 `autonomous region` 这种**官方名称**混进敏感词表也无人发现。
> 本轮补的 `MUST_BE_SILENT` 就是**专治这一类**：**用官方表述当反例**。
>
> 同源教训：**搜 UI 元素按结构搜**（内联 SVG 只搜文字搜不到）· **`grep` 判据要精确匹配而非搜裸文本**（注释里的 `dart:html` 会误算）——
> 三次都是**「判据本身的选型」出了问题**，不是执行出错。

---

### 3.12 ✅ Step 2 第一批：视觉 token 层落地（2026-09-26 · 白哥「开始」）

#### ① 先说实测的现状差距（这部分比产出更重要）

> 按项目规则「**状态以实测产物为准，不靠文档推断**」逐项核对 `design-system-spec` 与代码。

| 项 | spec 要求 | 代码实测 | 差距 |
|---|---|---|---|
| **主题体系** | 三档底色 `ReadingTheme { ink, grid, night }` | `app_theme.dart` 里是**三套并存的旧主题**（Deep Blue+Emerald / Duolingo 亮 / Duolingo 暗） | 🔴 **完全不同** |
| **token 层** | `CoEvoTokens` 单类型 + 三实例 + 一个 `buildTheme`（§7.3 明确「**不要写 3 个手写的 ThemeData**」） | 🔴 **不存在** —— `app_theme.dart` **正是** 3 个手写 ThemeData（436 行） | 🔴 待建 |
| **粘土** | 三层公式 + 尺寸阶梯 + 四态 | 🔴 **零实现**（`clay/inset` 的 grep 命中全是 `EdgeInsets`） | 🔴 待建 |
| **痕迹** | 三态 × 5 项 × 3 档 | 🔴 **零实现** | 🔴 待建 |
| **字体** | Literata（英文）+ Charis SIL（IPA）+ 阿里普惠体 | 🔴 `app/assets/fonts/` **只有阿里普惠体**；pubspec 也只声明它 | 🔴 待办（见 ④） |
| **主题切换** | `ReadingTheme` + `followSystem` 两个字段 | `theme_provider.dart` 用**旧的 4 值枚举**（`system/light/dark/duolingo`），默认 `duolingo` | 🔴 需替换 |

**✅ 一个意外的好消息：迁移面比预想小。**
`AppTheme` 的 333 次引用里 **325 次是 `spacing*`（97.6%）**
（🔴 `268` 是错误口径，2026-09-27 实测更正 —— 见 §3.15 ③），颜色引用只有 8 次
（`light`×3 / `dark`×3 / `duolingo`×2）。硬编码颜色也只有 **127 处 `Color(0x…)` + 130 处 `Colors.xxx`**，
且 Top 5 全是**成就勋章**的金属色（金/银/铜/白金/钻石），**与主题无关**。

→ **结论：换主题体系不会引发全库改色**，真实改动集中在 `app_theme.dart` + `app.dart` + `profile_screen`。

#### ② 产出：`app/lib/theme/coevo_tokens.dart`（698 行）

🔴 **设计约束：零 Flutter 依赖**（与 `fsrs_service.dart` 同一条约束）——
本地 Flutter 是鸿蒙定制版、`analyze` 会崩，**纯 Dart 才能本地独立验证**。
→ 所以用自有的 `CoRgba` 值类型，**不用 `dart:ui` 的 `Color`**；转换在 `theme_builder.dart` 做。

**覆盖 spec 全部 token**：

| spec 章节 | 内容 | 落地 |
|---|---|---|
| §1.1 | 痕迹三态 × 5 项（背景/边框/前景/内边距/圆角） | `TraceTokens` / `TraceStyle` / `TraceBorder` / `TracePadding` + `TraceSyntax`（浸染/下划线/光） |
| §2.1 | 主题底色 13 项 × 3 档 | `CoEvoTokens` 的 13 个字段 |
| §3.3 | 粘土 5 项 × 3 档 | `ClayTokens`（含 `accentOut` 与 `maxSize` 强度上限） |
| §3.5 | 尺寸阶梯 3 档 × 5 项 | `ClayScale` / `CoShadow` + `ClayScales` 工具 |
| §5.2 | 排版层级 9 项 | `CoTypography`（含 `compact` 紧凑档 + `hierarchyHolds` 不变量） |
| §3.8 | 动效常数 | `transitionDuration` / `pressDuration` / `pressScale` / `releaseDuration` |

**三档实例**：`inkTokens` / `gridTokens` / `nightTokens` + `allTokens` 表 + `lightThemes`。

#### ③ 产出：`scripts/tokens_verify/`（验收 **212 项全过**）

| 节 | 覆盖 | 验证方式 |
|---|---|---|
| 【1】主题底色 | 13 项 × 3 档 | 逐值对照 |
| 【2】**对比度** | spec §2.1 声称的实测值 + 达标线 + §八 文字对比度 | 🔑 用 **spec 自己声称的实测值反验我们的实现** |
| 【3】粘土 | 5 项 × 3 档 + §3.3.1 色相同源 + §3.4 几何 + §3.9 内亮 | 含 `accentOut` 的 RGB **必须等于** `accent` |
| 【4】痕迹 | 三态 × 5 项 × 3 档 + 语法 + `forReps()` 取用逻辑 | 含「有遗忘则不算掌握」 |
| 【5】尺寸阶梯 | 3 档 × 5 项 + 档位边界 + **两 inset 反向** + 强度上限 | — |
| 【6】排版 | 9 项 + 紧凑档 + **层级不变量**（释义 ≥ 记忆法） | 含紧凑档「关系不能反转」 |
| 【7】结构不变量 | 三档齐备 · **方案甲墨/格 accent 必须相同** · 动效常数 | — |

🔑 **最有价值的一条**：【2】的对比度断言用 spec 声称的实测值（墨 4.76 / 5.56 / 3.87…）
反验我们的算法 —— 我手算 `page↔accent` = 4.751 与 spec 的 4.76 吻合，
证明**「底」指的是 `page`**（spec 表格标题只写「底」，未指明是哪个 token）。
**这一批断言同时验了两件事**：token 值对不对 + 对比度实现对不对。

**三类断言分开统计**（关键设计）：

| 类型 | 失败含义 | 退出码 |
|---|---|---|
| `eq`/`near`/`color`/`check` | **实现写错了** | 🔴 1 |
| `checkSpec`/`conflict` | **文档有歧义/矛盾** → 改文档 | ✅ 0 |

→ **避免「把文档问题当成代码 bug 去改代码」**。

#### ④ 🔴 实测发现 3 处 spec 内部问题 + 1 处缺口（**待白哥定**）

| # | 问题 | 说明与建议 |
|---|---|---|
| **1** | **墨档 `ink3` 对比度 2.94 < 3.0** | §八 验收清单声称「文字对比度**全部达标（含 `--ink3` 弱文字）**」但**未给阈值**。按 WCAG 辅助文字 3.0 算不达标：`#9A917F` 需压深到约 `#8F8675`。→ ① 压深 ② 或把 §八 的「达标」限定为 ink/ink2 |
| **2** | **「格」档圆角几何不成立** | §3.5 规定「圆角 = `clRadius` × factor」，§3.4 又定义「格 = **14px 圆角** + 偏移 3px」（`14 ≥ 3×3` ✅）。**两者相乘就冲突**：`14 × 0.55 = 7.7 < 9`。 |
| **3** | 同上（md 档同一根因） | 🔑 **根因**：`0.50/0.55` 系数显然是为「墨 26 / 夜 24」设计的（`26×0.55≈14.3`、`24×0.55≈13.2`，**都落在 14px 附近**）—— 而「格」的 14px **本身就是那个目标值**，不该再乘系数。→ 建议「格」档 `radiusFactor` 全取 **1.0** |
| **4** | 🟠 **规格缺口：`clayFill` 无定义值** | spec §7.2 示例与 §7.3 结构都引用 `clayFill`，但 §2.1 / §3.3 的表**没给它值**。当前取 `card`（推断：粘土元素是交互组件，卡面即其填充）并**在代码注释里标注缺口** |

> ⚠️ **本批「格」档的几何冲突我未擅自修改**（按「测试发现问题先报告，不直接改测试/规格」）。
> 代码按 spec 原文实现 → **矛盾显式暴露**，而不是被掩盖。

#### ⑤ ✅ 验证

| 验证 | 结果 |
|---|---|
| token 验收 | ✅ **212 项通过 / 0 项实现失败 / 3 项规格冲突**（冲突另行列示，退出码 0） |
| 静态分析（`analyze_inproc`） | ✅ 全库 **error=3 / warning=13** 与基线**完全一致** → **零新增**；新增文件 **0/0/0** |
| Flutter 影响面 | ✅ **零** —— tokens 层未接入 `app.dart`，**现有 App 行为完全未变** |
| CI 可挂 | ✅ **纯 Dart、零依赖**（`dart pub get` 秒装），不需要 iOS 真机 |

#### ⑥ 🔴 两个待定的决策点（阻塞下一批）

| # | 决策 | 选项 |
|---|---|---|
| **A** | **字体方案**（Literata 缺失） | 实测：`docs/design/fonts/*.woff2` 是 **214 码位子集**（IPA 24/25），`fontTools`+`brotli` 已装 → **Charis SIL 可解回 ttf** ✅；但 **Literata 完全没有**，且**网络不通**（沙箱 502）→ ① 先只做 Charis SIL + 英文正文用系统衬线体 ② 换通道取 Literata ③ 用 `noto-serif`（在 woff2 里）替代 |
| **B** | ~~**旧主题/`theme_provider` 处置**~~ | ✅ **已定案（2026-09-27）：直接删，不并存过渡** —— 白哥「旧主题 / theme_provider 处置——不要了吧」→ **已完成，见 §3.15** |

> ✅ **`spacing` 的处置已定（2026-09-27）**：原判「20 个引用 `AppTheme.spacing*` 的文件**不需要改**」**对了一半** ——
> 值确实与主题无关（325 处引用逻辑上零改动），但 `AppTheme` 这个**类名挂在主题文件里就是语义残留** →
> 随文件删除**改名为 `CoSpacing.*`**（机械替换，325 处逐项对账一致）。见 §3.15 ③。

---

### 3.13 ✅ Step 2 字体选型前置：可获得性实测 + 候选对照（2026-09-26 · 白哥「先从可获得的里出方案」）

> 白哥问：「字体是否应该先从可获得字体里出方案，然后我们再选一次？」
> → **对，且这一问改变了两处结论。** 详见 `docs/design/font-candidates-assessment-2026-09-26.md`

#### ① 🔴 原始阻塞**已解除**（我上一轮说「Literata 完全缺失」是**不完整的**）

| 渠道 | 实测 |
|---|---|
| **`cdn.jsdelivr.net`** | ✅ **200 —— 且能代理 GitHub 仓库** |
| pub.dev / npm / unpkg / gitee | ✅ 200 |
| `raw.githubusercontent` | ⚠️ 301 后取不到 · **`github.com` · `fonts.gstatic.com` · `npmmirror` · `tuna` 全不通** |

🔑 **`https://cdn.jsdelivr.net/gh/google/fonts@main/<path>` 是唯一可用通道** —— 实测取到：
`Literata[opsz,wght].ttf` **955,132 B** · `CharisSIL-Regular.ttf` **752,900 B**。
→ **spec 原选的 Literata 与 Charis SIL 都拿到了**（完整 TTF）。

> ⚠️ **我上一轮的判断需要修正**：当时只测了 `fonts.google.com` 与 `raw.githubusercontent`（both 失败）
> 就下了「Literata 零 + 网络不通」的结论 —— **没测 jsdelivr**。这与本轮早先那三次错误**同源**：
> **用不完整的一小批探测替代了穷尽排查。**

#### ② 真实 IPA 需求：**靠猜会少 5 个字符**（且少的是最危险的组合符号）

spec §4.3 说字符集 = 「ASCII 95 + 标点 8 + **IPA 32** = 131 码位」，但**没说 32 从哪来**。
本轮从真实数据提取（IPA 存在 `card.content` 的 JSON `ipa` 字段 —— **`word` 表根本没有 `pronunciation` 列**）：

**11,523 张卡全有 `ipa` → 非 ASCII 34 种，真·音标 30 种**：

| 高频 | 频次 | 中频 | 频次 | 🆕 低频 | 频次 |
|---|---:|---|---:|---|---:|
| `ˈ` | 9,399 | `ɒ` | 1,196 | `ɚ` | 8 |
| `ɪ` | 8,967 | `ʌ` | 1,014 | `ʁ` `ø` `ɾ` `ɐ` `œ` | 1–6 |
| `ə` | 7,904 | `ɡ` | 927 | 🔴 `̃`(U+0303) | 9 |
| `ː` | 3,764 | `ɔ` | 879 | 🔴 `̬`(U+032C) | 3 |
| `æ` | 1,676 | `ʒ` | 779 | 🔴 `̩`(U+0329) | 2 |
| `ʊ` | 1,580 | `ɑ` | 652 | 🔴 `̯`(U+032F) | 1 |
| `ɛ` | 1,490 | `ŋ` | 573 | `ᵊ` | 2 |
| `ˌ` | 1,450 | `ɜ` `θ` `ð` | 101–515 | | |

🔴 **4 个是组合符号**（附加到基础字母上：鼻化 / 清化 / 成音节）。
**缺失时变音符号会静默消失** —— 比「回退到别的字体」更糟：**读者看不到异常，但音标是错的**。

→ 所以 IPA 判定**必须逐字符**，不能抽样、不能只看 `unicode-range`（spec §4.2 已被这条坑过一次）。

#### ③ 实测：候选 × 真实字符集（**133 码位逐字符验证**）

| 字体 | 码位 | 子集 woff2 | 字重形态 | 授权 |
|---|---|---:|---|---|
| **Charis SIL** | ✅ **133/133** | 82.9 KB（**Reg+Bold+Italic**） | ✅ **静态** | OFL 1.1 |
| **Andika** | ✅ 133/133 | 50.6 KB | ✅ 静态 | OFL 1.1 |
| **Gentium Book Plus** | ✅ 133/133 | 54.7 KB | ✅ 静态 | OFL 1.1 |
| **Noto Serif** | ✅ 133/133 | **34.6 KB**（最小） | ⚠️ 仅可变 | OFL 1.1 |
| 🔴 **Literata** | **115/133** | 47.0 KB | ⚠️ 仅可变 | OFL 1.1 |
| ⚠️ Inter | 130/133 | 50.7 KB | ⚠️ 仅可变 | OFL 1.1 |

**Literata 缺 18 个**：`ɪ ː ʊ ɛ ʃ ɒ ʌ ɔ ʒ ɜ ɚ ʁ ̬ ̩ ᵊ ɾ ɐ ̯` → 与 spec §4.2 方向一致（本轮按真实用量复核）。

✅ **全部落在 `google/fonts` 的 `ofl/` 目录 → 统一 SIL OFL 1.1**（可商用/嵌入/子集化）→ **无授权风险**。

#### ④ 🔑 spec 未考虑的选项：**一个字体家族顶掉两个**

spec 的三层架构是「Literata 正文 + Charis SIL 兜底 IPA」，但实测：
**Charis SIL / Andika / Gentium / Noto Serif 单字体即 IPA 30/30** → **可同时承担正文与 IPA**，
少一层 fallback 链、少一套资源。**spec 的设计不错，只是多了一条它当时没看到的简化路径。**

#### ⑤ 候选方案（**请看对照页选**）

> 📄 🆕 **`docs/design/font-candidates-2026-09-26.html`** —— **用真实字体渲染真实词卡，离线可看**
> （子集 woff2 内联，含 IPA 全字符条 + 三档主题演示）。**选字体必须看这一页。**

| # | 方案 | 体积 | 工程复杂度 | 气质 / 取舍 |
|---|---|---|---|---|
| **A** | spec 原案：Literata + Charis SIL | ~130 KB（4 文件） | 🟠 中（**双字体 + fallback 链**） | Literata 是**为屏幕长文阅读专设**的书体 |
| **B** | **Charis SIL 单一** | **82.9 KB** | 🟢 **最低**（静态、无 fallback） | 语言学出版级书体（底座 Charter），耐读 |
| **C** | Noto Serif 单一 | **34.6 KB** | 🟢 低（仅可变→构建期 instance） | 通用书体，个性弱 |
| **D** | Gentium Book Plus 单一 | 54.7 KB | 🟢 低（静态） | 偏「古籍 / 学术」 |
| **E** | **Andika 单一** | 50.6 KB | 🟢 低（静态） | 🔵 **无衬线** + SIL 明确**为识字初学者设计** |

**E 有一个产品层理由值得单独说**：Andika 的字母形**刻意不易混淆**（`b`/`d`、`p`/`q`、`I`/`l`）
—— 对**英语学习产品**是**特征**（目标用户正是「正在学」的人）。
代价是**它不是「阅读体」气质**，长文（RSS 文章）连续阅读不如衬线体。
→ 真实取舍是「**帮助辨形** vs **长文舒适**」，不是纯审美。

> ⚠️ **我不建议**「正文 Andika + 长文衬线」混搭 —— 会把字体层级从 2 层变 3 层，
> 换来「同一 App 内两套英文阅读字体」，与 spec §2.2「品牌签名靠字体组合」相冲。

#### ⑤-b 🔴🔴 **白哥追问「原方案可行就不改了？」→ 实测发现 spec 的「用法」会制造新不一致**

> 白哥：「那既然原方案可行就不改了就可以了，是吗？」
> **不能直接点头 —— 「可行」与「没问题」是两件事。** 实测后发现一个 **spec 从未检查过的问题**。

**spec §4.2 的接入方式**是「整段用一个字体栈」：
```dart
TextStyle(fontFamily: 'Literata', fontFamilyFallback: ['CharisSIL'])
// 注释明说：「不需要在业务代码里判断字符」
```
→ 因为 Literata 缺 18 个 IPA 码位、Charis 又有 → **同一条音标里会混用两种字体**。

**实测（11,523 张卡）**：

| 情况 | 卡数 | 占比 |
|---|---:|---:|
| 🔴 **混排**（同一条音标内两种字体都用上） | **10,823** | **93.9%** |
| ✅ 纯 Literata | 695 | 6.0% |
| ✅ 整条回退 | 3 | 0.03% |

| 单词 | 音标 | 逐字符来源（`L`=Literata `C`=Charis） |
|---|---|---|
| `absurd` | `/əbˈsɜːd/` | `L L L L **C C** L` ← `ɜː` 夹在中间 |
| `achieve` | `/əˈtʃiːv/` | `L L L **C** L **C** L` |
| `agree` | `/əˈɡriː/` | `L L L L L **C**` |

→ 同一条音标内**笔画粗细 / x-height / 黑色浓度跳变** ——
**这正是白哥在音频那轮提出的同一个问题**（原话：「不统一更奇怪」）。

**🔑 修法：不换字体，只改「在哪一层指定字体」**

| | 做法 | 结果 |
|---|---|---|
| ④ spec 原法 | fallback 链挂在**整张卡的文本样式**上 → 逐字符回退 | 🔴 93.9% 混排 |
| **⑤ 修正法** | 音标作为**独立元素**、直接指定 Charis SIL | ✅ **整条一致** |

**可行性实测（IPA 到底在哪些字段）**：

| IPA 所在 | 卡数 | 性质 |
|---|---:|---|
| **`ipa` 字段** | **11,477** | ✅ **独立 UI 元素** → 可显式指定字体 |
| `etymology.text`（词源正文内嵌） | 227 | ⚠️ 正文内嵌，只能靠 fallback |
| `definition.en` / `context.text` | 4 / 1 | 同上 |

→ **改用法可把混排从 93.9% 降到 2.0%，且不需要换任何字体。**

**改后的方案命名**：**A' = spec 原案（字体一个不动）+ 音标元素级指定字体** ← **就是「原方案不改」的正确形态**

> 📄 视觉证据见对照页新增一节「🔴 但 spec 的「用法」会制造一个新的不一致」（同一字体组合、两种指定方式并排）

**🔑 一条通用教训（本轮第二有价值的一条）**

> **「字体覆盖够不够」与「渲染出不出得来」是两个问题。**
> 前者靠**解 cmap 验字形**，后者要算**逐字符的字体归属**。
> spec §4.2 只验了前者（发现 Literata 缺 IPA → 设计了 fallback），**没验后者** ——
> 于是「**有兜底**」被当成了「**没问题**」。
>
> **同源**：「有 fallback」≠「视觉一致」；「接口存在」≠「接通了」；
> 「配置写了」≠「生效了」—— **都要看最终结果，不能看中间环节是否存在**。

#### ⑥ 产物（**零 App 代码改动**）

| 文件 | 作用 |
|---|---|
| 🆕 `scripts/fetch_fonts.py` | **取字体源**（jsdelivr→google/fonts · sha256 校验 · `--verify` 检出上游改版） |
| 🆕 `scripts/build_fonts.py` | **子集构建**（源 TTF → 133 码位 · `--ttf` 给 Flutter / 默认 woff2 给对照页） |
| 🆕 `scripts/build_font_compare.py` | **对照页生成器**（内联真实字体 + 从 DB 取真实词卡） |
| 🆕 `docs/design/font-candidates-2026-09-26.html` | **对照页**（524 KB · 15 个去重字体内联 · 离线可看） |
| 🆕 `docs/design/font-candidates-assessment-2026-09-26.md` | 评估与选项 |
| 🆕 `data/reports/ipa_charset.json` | **从真实数据提取**的 IPA 字符集（入库，供后续脚本复用） |
| ✏️ `.gitignore` | 新增 `/data/fonts-src/` + `/data/fonts-build/`（源与构建产物不入库） |

**三条工程约束（已固化进脚本注释）**：
1. **Flutter 不支持 woff/woff2**（只 ttf/otf/ttc）→ `--ttf` 输出；TTF 约 woff2 的 2 倍，仍 **< 70 KB/字重**
2. **`woff2.compress()` 只接受文件路径**（不接受 `TTFont` 对象）→ 先落临时 ttf 再压
3. **可变字体在构建期 instance 成静态** → 运行时只面对普通字重（Flutter 与浏览器对可变字体都不如静态稳）

#### ⑦ 🔑 一条通用教训（本轮）

> **「拿不到」是个需要穷尽验证的结论，不能由一次失败推断。**
>
> 我上一轮只试了 `fonts.google.com` 与 `raw.githubusercontent` 就写下「Literata 零 + 网络不通」，
> **漏掉了 jsdelivr** —— 而它恰好是唯一可用的通道。
>
> 这与本轮早先那三次错误**同源**（搜 UI 元素只搜文字、`grep` 搜裸文本、只验正例不验负例）：
> **四次都是「判据/探测的覆盖不全」，不是执行出错。**

---

### 3.14 ✅ Step 2 第二批：A′ 字体落地 + 3 处 spec 冲突定案（2026-09-27 00:30）

> 白哥：「**同意 A′**」+ 三处 spec 冲突全部采纳推荐项

#### ① A′ 落地：**spec 接入方式修正 + 字体资产进 App**

**spec 改动**（`design-system-spec-2026-09-25.md`）：

| 节 | 改动 |
|---|---|
| **§4.1.1（新增）** | 🔴 **接入方式修正为 A′** —— 正文用 `Literata + fallback`、**音标元素直接指定 `CharisSIL`（不挂 fallback 链）**；含「为什么不能用整段 fallback」的 93.9% 实测表 |
| **§4.1.2（新增）** | 2026-09-26 候选复核（结论：字体**不变**）· 133 码位逐字符实测表 · 可达性通道 |
| **§4.2** | 标注原表是「清洗前口径」（12,839 张卡），并指向 §4.1.1 |
| **§7.3** | 🆕 补 `CoFonts` 结构 —— **字体是全局常量类，不进 `CoEvoTokens`**（§2.2 把字体列在「跨主题稳定」栏） |
| **§八** | 新增 2 条验收：**「同一条音标内不得混排两种字体」**（A′ 核心）· **「组合符号不静默消失」** |

**字体资产落地**：

| 项 | 内容 |
|---|---|
| 构建 | `scripts/build_fonts.py --candidate literata --candidate charis --ttf` |
| 装入 `app/assets/fonts/` | **5 个文件 · +296 KB**（Literata Reg/Bold/Italic · CharisSIL Reg/Bold） |
| `pubspec.yaml` | 新增 2 个 family：`Literata`（3 文件）· `CharisSIL`（2 文件）—— 均加🔴「只能元素级使用」注释 |
| 对比 | 阿里普惠体 24.2 MB → **英文双字体只占 296 KB** |

**🔴 一个取舍需说明**：**Literata 装 Italic 而 CharisSIL 不装** ——
Literata 有独立 Italic 可变字体（902,728 B），不装则 Flutter 只能**合成斜体**；
而词库有 **39 张卡（0.34%）** 用 `*书名*` 标记（`*Faust*` / `*Against Heresies*`）——
39 张虽少但**全是书名**，合成斜体明显不自然 → 装（成本 ~54 KB）。IPA 不用斜体 → 不装。

#### ② 三处 spec 内部冲突全部定案并修入

| # | 问题 | 白哥定案 | 落地 |
|---|---|---|---|
| **1** | 墨档 `ink3` 对比度 **2.941 < 3.0** | **降 1% 明度** → `#988F7C`（**3.020 ✅**） | spec §2.1.0 + token + 断言 |
| **2·3** | 「格」档圆角 **14×0.55 = 7.7 < 9**（lg/md 同一根因） | **「格」档 `radiusFactor` 全取 1.0** | spec §3.5.1 + `ClayTokens.scaleRadius` + 断言 |
| **4** | 🟠 `clayFill` 有引用**无定义值** | **= `card`** | spec §3.3.2 + `clayFill` 定义为 **getter**（∴ 不可能与 `card` 不一致）+ 断言 |

**修法依据（都写进 spec）**：

- **ink3**：保持色相 40° / 饱和 11.8% 不变，**只降 1% 明度**即达标 → 暖沙纸感不受影响
- **「格」圆角**：`0.50/0.55` 显然是为「墨 26 / 夜 24」整定的（`26×0.55≈14.3`、`24×0.55≈13.2`，**都落在 14px 附近**）——
  **而「格」的 14px 本身就是那个目标值**（§3.4 的 B 方案就是「从 8px 提到 14px」），再乘系数＝**重复缩了一次**
  → 代码用 `scaleRadius: false` 表达「这是**语义例外**，不是数值巧合」
- **clayFill**：§3.1 已定 claymorphism 填充色「任意色，与背景无关」→ 用卡面色成立；
  且**同值却分设字段会制造「改了 card 忘了改 clayFill」的漂移风险**

#### ③ 🔴 我在本轮犯的两个错（都被当场抓住）

**错 1：凭印象填「实测」数字**

写 spec §2.1.0 时我按印象填了一串对比度（13.83 / 7.54 / 3.36 …），**还标了「（实测）」**——
**全部与实算不符**：

| 项 | 我写的 | 实算 |
|---|---|---|
| 墨 `ink` ↔ `read` | 13.83 | **15.12** |
| 格 `ink2` ↔ `read` | 7.54 | **6.90** |
| 夜 `ink2` ↔ `read` | 7.40 | **6.90** |
| 夜 `ink3` ↔ `read` | 3.36 | **3.87** |

→ 已全部改为实算值，并把教训写进 spec：
> 🔑 **标「实测」就必须真的跑脚本** —— 凭印象填数字，等于给文档植入**假证据**。

**错 2：改了 A 忘了 B（验收脚本当场报红）**

改 `ink3` 时只改了 token 与「对比度断言」，**忘了改「数值核对表」里的 `0x9A917F`** → `🔴 墨.ink3` 报红。
> ✅ **这正是写断言的价值**：它抓住的不是「我没想到的 bug」，而是「**我改了 A 忘了 B**」。

**另有一处「断言写错」**：`latinFallback == [ipaSerif]` 判失败，但实得与期望**显示完全相同** ——
根因是 **Dart 的 `List == List` 是引用比较**。→ 新增 `listEq` helper，并把这个坑写进脚本注释。

#### ④ ✅ 验证

| 验证 | 结果 |
|---|---|
| token 验收 | ✅ **241 项通过**（212 → 229 → **241**）· **0 实现失败** · **0 规格冲突** |
| 全库静态分析 | ✅ **error=3 / warning=13** 与基线**完全一致** → **零新增** |
| `coevo_tokens.dart` | ✅ **0 / 0 / 0** |
| 验收脚本自身 | ✅ **0 / 0 / 0** |
| **pubspec 交叉验证** | ✅ 确认：代码引用的 3 个 family **都在 pubspec 声明**，且 **6 个字体文件真实存在**（打印字节数） |
| 字体资产 | ✅ 5 个文件 · 296 KB · YAML 合法 |

> 🔑 **【7】字体验证专治「写了但没接通」**：字体名写错 / pubspec 没声明 / 文件不存在，
> **运行时都不报错**，只是悄悄回退系统字体。两层交叉检查（family 声明 + 文件存在）把它挡住。

#### ⑤ 🆕 一条工具设计说明

`checkSpec` / `conflict`（「规格自洽性」分类工具）**现无调用点，但有意保留** ——
spec 会继续演进，下次出现同类矛盾时直接用它归因，不必重新设计分类。
**删掉它等于把这个教训丢掉**（已在代码里加 `// ignore: unused_element` + 说明）。

---

### 3.15 ✅ Step 2 第三批：旧主题整体删除 + `buildTheme` 接线（2026-09-27 01:05）

> 白哥：「旧主题 / theme_provider 处置——**不要了吧**」
> → 即 §3.12 ⑥ **决策 B** 的定案：**删，不并存过渡**

#### ① 🔴 先说清前提：「只删不建」会当场把全 app 主题换掉

`app_theme.dart` 是当前 `MaterialApp` **唯一的主题来源**（`app.dart` 的 4 分支 switch 全部指向它）。
只删文件、不建替代 → 全 app 退回 **Flutter 默认 M3 紫**。
所以「不要旧主题」与「建 `buildTheme`」是**同一件事**，本轮一起落。

#### ② 改动清单

| # | 对象 | 动作 | 规模 |
|---|---|---|---|
| 1 | `theme/theme_builder.dart` | 🆕 spec §7.3 的**唯一** `buildTheme(CoEvoTokens)` | +289 行 |
| 2 | `theme/co_spacing.dart` | 🆕 间距常量独立成文件 | +39 行 |
| 3 | `theme/app_theme.dart` | 🔴 **删除** | **−436 行** |
| 4 | `providers/theme_provider.dart` | `AppThemeMode` 4 值枚举 → `ThemeSettings{theme, followSystem}` | 52 → 92 行 |
| 5 | `app.dart` | 4 分支 switch → `buildTheme` + `allTokens` | −33 行 |
| 6 | `screens/profile_screen.dart` | 主题 UI：4 项（含 Duolingo 风格）→ **3 档底色 + 跟随系统开关** | ±60 行 |

`buildTheme` 的映射原则：**颜色 / 圆角 / 字号全部来自 token，文件内零硬编码色**
（【9】会拦住任何 `Color(0x…)` 或 `Colors.xxx` 回潮）。

#### ③ `spacing` 325 处的处置 —— 这才是「不能直接删文件」的真正原因

| 项 | 实测（`grep -o`） |
|---|---|
| `AppTheme` 总引用 | **333** |
| 其中 `spacing*` | **325（97.6%）** |
| 其中主题引用（`light` / `dark` / `duolingo`） | **8（2.4%，全在 `app.dart` 的 switch 里）** |
| 涉及文件 | **18 个** |

🔴 **更正 §3.12 的数字**：那里写「333 次引用里 **268** 次是 spacing（80%）」——
**实测 325 次（97.6%）**，`268` 是错误口径。
**结论方向不变但更强**：换主题**几乎不引发全库改色**，真正要动的只有 `app.dart` + 设置页。

迁移做法：按**长度降序**精确替换（先 `spacingXxxxl` 再 `spacingXl`，否则 `Xl` 会切进 `Xxl` 的前缀），
import 一并改写 → 逐项对账 **325 = 31+128+63+66+21+12+4** ✅。
`AppTheme` 这个类名随之消失（间距与主题无关，不该叫 theme）；新名 `CoSpacing.sm` 比 `AppTheme.spacingSm` 少一半噪音。

#### ④ 接线写法（三档主题怎么进 `MaterialApp`）

```dart
final lightTheme = buildTheme(allTokens[settings.lightTheme]!); // 浅色槽
final darkTheme  = buildTheme(nightTokens);                     // 深色槽 = 固定「夜」
themeMode: settings.followSystem ? ThemeMode.system
         : (settings.theme == ReadingTheme.night ? ThemeMode.dark : ThemeMode.light)
```

| 写法 | 为什么 |
|---|---|
| 不读 `MediaQuery.platformBrightness` | `MaterialApp` **之上**的 `context` 拿不到 `MediaQuery` → 交给 Flutter 的 `ThemeMode.system` 二选一才是正解 |
| `ThemeSettings.lightTheme` 把「夜」回落成「墨」 | 用户选了「夜」又开着跟随系统时，浅色环境必须回落，否则「跟随系统」在白天失效 |
| 三档共用一个 `buildTheme` | spec §7.3：「**不要写 3 个手写的 ThemeData**」→ 差异只能来自 token |

#### ⑤ 与 spec §九 #4「Duolingo 保留动效与结构」是否冲突？

**不冲突，但有一处要如实说明**：

| Duolingo 的什么 | 处置 |
|---|---|
| 配色（绿 `#58cc02` / 3D 底边色） | 🔴 **删除** —— 本就是「换成主题调色板」的字面要求 |
| 动效模式（按下 / 回弹） | ✅ **保留** —— 承接方是 §3.8 常数（按下 `.97` / 90 ms / 回弹 320 ms `elasticOut`） |
| 结构（卡片 / 导航 / 层级） | ✅ 保留，承接方是粘土 · 痕迹 · `CoTypography` |
| ⚠️ **按钮立体感** | 🟠 **组件已建、但未接入页面**（§3.17 建了 `theme/clay.dart`）→ **视觉上仍是平的**，等 Step 3 用上 |

> 🔑 「立体感」这一层现在**没人接** —— 它不是删除的副作用，
> 而是 Step 2 **剩余工作**（§7.4 的 `ClayDecoration`，约 150–200 行）本来就该建。
> **它落地前，界面会比设计目标「平」。**

#### ⑥ ✅ 验收：241 → **267 项**

| 验证 | 结果 |
|---|---|
| token 验收 | ✅ **267 项通过 / 0 实现失败 / 0 规格冲突**（241 → +26） |
| 🆕【9】**接线**（26 项） | 文件到位/删除 · **全库 `AppTheme` 零残留** · **`ThemeData` 全库唯一产出点** · builder 零硬编码色 · `app.dart` 三件套 · provider 两字段 · `CoSpacing` 8 值 |
| 全库静态分析 | ✅ **error=3 / warning=13 / info=7** 与基线**完全一致** → **零新增** |

🔑 为什么加【9】：设计系统最典型的失效**不是数值写错，而是没接上**
（token 写好了、`app.dart` 还在用旧主题）→ **编译器不报错、界面照旧**，只有结构级断言抓得住。同类先例是【7】字体。

#### ⑦ 🔴 两件需要白哥知道的事

1. ~~**本地无法 `flutter run`**~~ → 🔴 **该结论已作废（2026-09-27 01:25）**：
   实测崩溃行是 `…\.workbuddy\binaries\PortableGit\…\git.EXE` —— **崩在我这的工具沙箱**（句柄继承耗尽命名管道），
   **与项目无关**。白哥实测：官方 Flutter **3.41.1 / Dart 3.11.0** · doctor 全绿 · `pub get` ✅ · 3 设备可用。
   → 🔴 **但 `flutter run` 确实失败**，根因是**另外两个问题**，见 📄 `docs/review/flutter-run-blocker-2026-09-27.md`（**待批准**）。
2. **视觉基线已换代，但组件层还是旧的**：全 app 从「Duolingo 绿 + 白底」变为「**朱砂 `#B4432C` + 三档底色**」，
   而组件里的硬编码色（`Colors.white` / `grey.shade200` 等）**不会跟着变** → 真机上会看到「新底色 + 旧组件」的混杂观感。
   这是既定路径（Step 2 是 Step 3 的前置），**但第一次装真机要有预期**。
3. ⚠️ **本轮验收的能力边界（重要）**：`analyze_inproc` 是**自建 AST 分析器**，它**验证不了「依赖能否编译」** ——
   本轮 267 项断言全过、静态分析零新增，但 `flutter run` 仍因**第三方包与 SDK 版本不匹配**失败。
   🔑 **只有真编译才暴露这一类问题** —— 白哥跑 `flutter run` 正好补上了这个盲区。

---

### 3.16 ✅ 修复「只能在鸿蒙 Flutter 上编译」（2026-09-27 01:40 · 白哥选 A）

> 白哥实测 `flutter run -d chrome` → `Failed to compile application` → 我出根因报告 → 白哥选 **A**
> 📄 完整报告 `docs/review/flutter-run-blocker-2026-09-27.md`

#### ① 根因：仓库里有一份「鸿蒙降级改写版」依赖

| 根因 | 内容 |
|---|---|
| **A** | `app/packages/flutter_math_fork/`（**391 文件已入库**）是为**鸿蒙定制版 Flutter 3.27.5-ohos** 降级适配的改写版 —— 删掉 `RenderObjectWithLayoutCallbackMixin`（`runLayoutCallback()` → `rebuildIfNecessary()`）+ 补 **4 处 `case TargetPlatform.ohos`**（官方版 **0 处**）；由 `dependency_overrides` 指向 → **官方 Flutter 必然编译失败**｜补丁引入 `ac7a4a1` 2026-05-26 |
| **B** | `gpt_markdown: 1.0.8`（**精确锁定**）的 `_RenderSelectableAdapter` 缺 `SelectionHandler.contentLength` / `getSelection`（3.41 新增的抽象成员）→ 同样编不过 |

#### ② 方案 A 落地：**移除本地改写副本，回到官方路线**

| # | 对象 | 动作 | 规模 |
|---|---|---|---|
| 1 | `app/packages/flutter_math_fork/` | 🔴 **删除**（git rm） | **402 文件 / 3.1 MB** |
| 2 | `app/pubspec.yaml` | 删 `dependency_overrides.flutter_math_fork` | +9 / −3 行 |
| 3 | `app/pubspec.yaml` | `gpt_markdown` `1.0.8` → **`1.0.9`**（🔴 **必须一起做**，否则仍编不过） | +2 / −1 行 |
| 4 | `widgets/markdown_span_nodes.dart` | 摘除公式渲染 | **−44 行**（920 → 876） |

🔴 **对报告原描述的修正**：`flutter_math_fork` 是 **`gpt_markdown` 自己的依赖**（`^0.7.3`），**不能从依赖树移除** ——
实际做的是「**删本地改写副本 + 去 override**」→ 回落到 pub **官方 0.7.4**（我们的代码已不再直接 import 它）。

#### ③ 公式渲染的处置：**优雅降级，不报错**

摘除整条链路（`DisplayMathBlock` · `Math.tex` ×2 · `_addColorCmd` · `BlockType.displayMath` · `formulaRegex` · `_splitBySpecialBlocks` 的 `\[...\]` 分支），
并在 `_fixMarkdown` 新增第 3 步 **剥离 LaTeX 定界符**：

- `\[ x^2 \]` → 独立段落；`\( x \)` → 行内文本
- 🔑 **为什么剥而不是直接删**：内容**不能丢**。留着定界符用户会看到裸反斜杠（`\[x^2\]` 在 markdown 里还会被当转义符吃掉一部分）→ 剥掉后 `x^2` 至少可读
- ⚠️ 这是**降级**而非支持 —— 不假装能渲染数学，只是不让它变乱码

**依据**（零需求）：词库 `card.content` 含 LaTeX = **0 / 11,523**｜`DisplayMathBlock` 外部调用 **0 处**｜源头是**已废止的 K12 课程**

#### ④ ✅ 验证（静态层面全过）

| 验证 | 结果 |
|---|---|
| 改动文件分析 | ✅ **0 / 0 / 0** |
| 全库分析 | ✅ **error=3 / warning=13 / info=7** 与基线**完全一致** |
| `tokens_verify` | ✅ **287 项全过 / 0 实现失败 / 0 规格冲突** |
| 全库 `flutter_math_fork` 直接引用 | ✅ **0 处**（仅注释里的历史说明） |
| `pubspec.yaml` YAML | ✅ 合法（overrides 仅剩 `http`） |
| 官方 0.7.4 静态 API 核对 | ✅ 无 `ohos` · 有 mixin · 未用 Flutter `Selectable` mixin · 用公开 API `TextSelectionPoint` |

🔴 **但静态核对不等于终判** —— 只覆盖已知 3 类错误，**其它 API 漂移无法静态穷尽** → **真编译待白哥跑**（报告 §九）。

#### ⑤ 🔑 落定两件长期事项

| 事项 | 结果 |
|---|---|
| **「鸿蒙定制版 vs 官方 Flutter」待裁决** | ✅ **已定：官方 Flutter**（方案 A 的实质）→ ⚠️ 此后**在鸿蒙 Flutter 上编不过**，按「仅 iOS」定位这是应放弃的分支 |
| 🔴 **CI 两个 Flutter job 可能顺带修复** | CI 的 `flutter-action` 装官方版并读仓库 `pubspec.yaml` → 原来会编译那份含 `ohos` 的副本（**必失败**）；override 删掉后改用 pub 官方版 + `gpt_markdown` 1.0.9 → **很可能转绿**｜⏳ **待白哥在 Actions 页确认** |

#### ⑥ 🔑 一条方法论（已固化进 skill `safe-bulk-deletion`）

**「删除」有四种深度，风险递增**：删**文件** / 删**引用**（都编译报错，能发现 ✅）→
删**唯一提供者**（**静默降级**，上轮 `app_theme.dart` 就是）→ 🆕 删**被改写的依赖**（它不是孤儿也不是唯一提供者，而是**别人依赖树里的一员**）。

> **教训：判断「能不能删」要先看依赖图，不只是引用图。**

---

### 3.17 ✅ Step 2 第四批：粘土渲染层 `clay.dart`（2026-09-27 03:50）

> 白哥选「**先补 `ClayDecoration`（Step 2 收尾）**」—— **立体感空窗**就此关闭。
> spec §7.2 把它定为「**第二步**：若视觉不够，写 `ClayDecoration` CustomPainter（约 150–200 行）」。

#### ① 交付物

| 文件 | 规模 | 说明 |
|---|---:|---|
| `app/lib/theme/clay.dart` | 🆕 **新增** | `ClayPainter`（自绘三层阴影）+ `Clay`（容器 widget，含按下动效） |
| `app/lib/theme/tokens_ext.dart` | 🆕 **新增** | `CoEvoTokensExt`（`ThemeExtension`）—— 把 token 挂进主题，组件侧用 `CoEvoTokensExt.of(context)` 取 |
| `app/lib/theme/theme_builder.dart` | +4 行 | `extensions: [CoEvoTokensExt(t)]` |
| `app/lib/theme/coevo_tokens.dart` | +2 能力 | `CoRgba.scaleAlpha`（禁用态 ×0.55）· `CoShadow.flipped`（凸起 ↔ 凹陷互换） |
| `app/lib/screens/profile_screen.dart` | 改 `_themeOption` | 三档预览改用 `Clay`（**用该档自己的 token 画** → 所见即所得） |

#### ② 🔑 关键决策：**自绘真 inset，不停在 gradient 兜底**

spec §7.1：**Flutter 的 `BoxShadow` 不支持 `inset`** —— 而粘土的核心恰恰是两个 inset。

| 方案 | spec 定位 | 取舍 |
|---|---|---|
| gradient 模拟（外阴影原生 + 内阴影线性渐变） | §7.2 **第一步**（约 80%） | ❌ **未采用** —— spec 自陈「圆角处会出现**色带感**」（圆角几何不是线性的） |
| **`CustomPainter` 自绘** | §7.2 **第二步**（100%） | ✅ **采用** —— 画大矩形 → 圆角矩形 `evenOdd` 挖空成环 → `MaskFilter.blur` → `clipRRect` 只留**渗入内部**的那半 |

**与 Chromium 同一套做法**。`blur → sigma` 用 `× 0.57735 + 0.5`（与 Flutter 原生 `BoxShadow` **同口径**），
保证自绘阴影与 Material 组件不是「两种模糊味」。

#### ③ 四态实现（一一对应 spec §3.6 / §3.7）

| 态 | 实现 |
|---|---|
| **默认** | 外阴影 + 内暗 `(-,-)` + 内亮 `(+,+)` |
| **按下** | **外阴影消失** + 两个 inset **方向互换**（`.flipped`）+ `scale(.97)`（90ms ease-out / 320ms elasticOut 回弹） |
| **选中** | 保持凸起 + 填充 `accent` + 外阴影改 **`accentOut`**（染自身色相，§3.2） |
| **禁用** | **抽掉内亮** + 外阴影 `scaleAlpha(0.55)` + `Opacity(.5)` |

附加硬规则：高度 **< 24px** 完全去掉 inset（§3.5）；尺寸档按元素**真实高度**自动选（sm/md/lg）。

#### ④ ⚠️ 发现一处「spec 与设计稿不一致」（**按 spec 实现**）

`visual-clay-spec-2026-09-25.html` 的 `.cl-on`（选中态）内阴影用的是**硬编码值**：
`inset -5px -5px 12px rgba(0,0,0,.16)` + `inset 4px 4px 10px rgba(255,255,255,.24)`。

但 **spec §3.3.1 明文**：「彩色元素的外阴影用 `var(--accent-out)`；中性色元素继续用 `var(--cl-out)`。
**内阴影两者共用（`--cl-shade` / `--cl-light`）**。」

→ **按 spec 实现**（选中态内阴影也用 token → 零硬编码色）。
→ ⏳ **待真机目视**：若朱砂填充上 `cl-light`（墨档为纯白 `rgba(255,255,255,1)`）显得过亮，
再考虑按设计稿拆值 —— 届时须**先改 spec**（不许在代码里 if 分支）。

#### ⑤ ✅ 验收

| 验证 | 结果 |
|---|---|
| 🆕【10】粘土渲染断言 | ✅ **24 项全过**（真 inset API · 零硬编码色 · switch 覆盖四态 · 四态语义 · token 挂进 `extensions` · blur 同口径 · 🆕 **设置页已接入**） |
| `tokens_verify` 总数 | ✅ **307 项全过 / 0 实现失败 / 0 规格冲突**（267 → 307，五批累计 +40） |
| 全库静态分析 | ✅ **error=3 / warning=13 / info=7** 与基线**完全一致** |

#### ⑥ ✅ 已接入设置页档位预览（**跑起来能看到了**）

白哥选「先接设置页档位预览」→ 主题选择弹窗的三个档位**改用 `Clay` 渲染**：

- 每一档**用该档自己的 token** 画（`Clay(tokens: allTokens[theme]!)`）→ **所见即所得**
  （不传 tokens 会跟着当前主题变，失去比较意义）
- 未选中 = **凸起**（`ClayState.raised`）；选中 = **选中态**（填充 `accent` + 外阴影染 `accentOut`）
- 🔑 `Clay.tokens` 这个参数**存在的唯一理由**就是这个场景（预览其它档）

→ **其余接入点**（卡片 / 按钮 / 药丸）仍属 **Step 3 要重写的页面**。
→ 想更全面地看粘土，可开设计稿 `docs/design/visual-clay-spec-2026-09-25.html`（可实时切三主题）。

---

### 3.18 ✅ Step 2 第五批（收口）：主题切换 280ms 动效（2026-09-27 11:15）

> spec §3.8「**动效（粘土感的一半）**」的最后一项 —— 落完它 **Step 2 设计系统即全部完成**。

#### ① 交付

| 文件 | 改动 | 说明 |
|---|---|---|
| `app/lib/app.dart` | +9 行 | `themeAnimationDuration: CoEvoTokens.transitionDuration`（280ms）+ `themeAnimationCurve: Curves.fastOutSlowIn` |
| `app/lib/theme/clay.dart` | −5/+4 行 | 🔴 **修掉我上轮引入的重复定义**：按下/回弹的 `90`/`320`/`0.97` 裸值 → 改取 `CoEvoTokens.pressDuration`/`releaseDuration`/`pressScale` |

#### ② 🔑 两个核实结论（都不是猜的）

| 结论 | 依据 |
|---|---|
| **`Curves.fastOutSlowIn` 就是 spec 那条曲线**（不是近似） | Flutter `animation/curves.dart`：`static const Cubic fastOutSlowIn = Cubic(0.4, 0.0, 0.2, 1.0)` —— 与 spec §3.8 的 `cubic-bezier(.4,0,.2,1)` **逐位相同** |
| **「背景/文字/阴影/圆角同过渡」不需要逐项声明** | `AnimatedTheme` 走 `ThemeData.lerp`（`material/theme.dart`），而 `ThemeData.lerp` **会连同 `extensions` 一起插值**（`theme_data.dart` L1789）→ 上述字段自动同步过渡 |

**Flutter 默认值是 200ms `Curves.linear`** —— 比 spec 又短又生硬，所以这一项必须显式设置。

#### ③ 🔴 修掉一处「动效常数重复定义」（我上轮埋的）

`CoEvoTokens` 上**早就有**四个动效常数（`transitionDuration`/`pressDuration`/`releaseDuration`/`pressScale`），
且【8】结构不变量**已断言这 4 个值** —— 但我上轮写 `clay.dart` 时**又手写了一遍**：
`Duration(milliseconds: 90)` / `Duration(milliseconds: 320)` / `?. 0.97`。

→ 后果：**改 spec 时要改两处**，且第二处没有断言保护。
→ 已改为取常量，并**新增断言「动效常数只在 `CoEvoTokens` 定义一处（调用处零裸值）」**。

> 🔑 **可复用教训**：*数值常数已经在 token 层定义 ≠ 调用处不会再写一遍*。
> 断言要**同时验「用没用常量」和「有没有裸值」** —— 只验前者抓不到本轮这种漏。

#### ④ ✅ 验收

| 验证 | 结果 |
|---|---|
| `tokens_verify` | ✅ **307 项全过 / 0 实现失败 / 0 规格冲突**（295 → 307，见 §3.19） |
| 全库静态分析 | ✅ **error=3 / warning=13 / info=7** 与基线**完全一致** |

⏳ **仍待目视**：spec §八 那条「主题切换 280ms 过渡**无闪烁**，且不打断正在进行的阅读」——
闪烁与否**只有真机能验**（本地跑 `run -d chrome` 也可，切档时看是否闪白）。

#### ⑤ ⏸ 顺带核实出一个**未来隐患**（已核实影响，待白哥定是否现在修）

`tokens_ext.dart` 的 `CoEvoTokensExt.lerp` 目前是**阶跃实现**（`t < 0.5 ? this : other`）——
而 `ThemeData` 的 `colorScheme` / `scaffoldBackgroundColor` 等是**平滑插值**的，两者机制不一致。

| 项 | 实测结论 |
|---|---|
| **当前实际影响** | 🟢 **零** —— ① `ThemeData` 层面的颜色全部平滑过渡（`AnimatedTheme` 处理）② `CoEvoTokensExt.of(context)` 的**唯一调用点是 `clay.dart:241`**，而设置页传了显式 `tokens` → **走不到 ext** |
| **未来风险** | 🔴 Step 3 用 `Clay()`（不传 tokens）画卡片/按钮时 → 主题切换时**粘土块会在 140ms 处「啪」地跳变**，而周围背景平滑渐变 → 观感不协调 |
| **技术陷阱**（若要修） | 不能无脑逐字段插值：`ClayTokens.scaleRadius` 是 bool（只能阶跃），而 `radiusFor()` = `scaleRadius ? radius×factor : radius` → 若 `radius` 插值而 `scaleRadius` 阶跃，圆角会在 t=0.5 **从 11px 跳到 19.9px**，比不插值更难看 |

**建议方向**（供拍板）：**颜色插值 + 几何/枚举整组阶跃** —— 即 `CoRgba` 等颜色字段插值，
`radius`/`maxSize`/`scaleRadius`/`syntax` 等同侧取值（保证派生值自洽）。预估 **约 76 行**
（`CoRgba.lerp` 10 · `CoEvoTokens.lerp` 22 · `ClayTokens.lerp` 12 · `TraceTokens.lerp` 8 ·
`TraceStyle.lerp` 12 · `CoTypography.lerp` 12），且可**纯 Dart 验证**（tokens 层零 Flutter 依赖）。

---

### 3.19 ✅ Step 2 增补：token 插值（主题切换的「同过渡」补全 · 2026-09-27 11:40）

> 白哥选「**现在写**」。§3.18 的 280ms 只让 **`ThemeData` 层面**同过渡；
> 而**直接用 token 取色的组件**（粘土）此前走 `CoEvoTokensExt.lerp` 的**阶跃**实现 →
> 切主题时会在 t=0.5「啪」地跳，与周围平滑渐变的背景不协调。

#### ① 交付

| 文件 | 改动 |
|---|---|
| `coevo_tokens.dart` | **+约 130 行**：文件头 ⓪ 插值原则 · `_pick`/`_lerpD` helper · `CoRgba.lerp` · `ClayTokens.lerp` · `TraceStyle.lerp` · `TraceTokens.lerp` · `CoTypography.lerp` · `CoEvoTokens.lerp` |
| `tokens_ext.dart` | `CoEvoTokensExt.lerp` 由**阶跃**改为**调用 `CoEvoTokens.lerp`** |

#### ② 🔑 核心判断：**插值只能作用在「不会引发派生量不连续」的字段上**

| 类别 | 处理 | 理由 |
|---|---|---|
| **颜色**（12 项 `CoRgba`） | ✅ **插值** | 视觉上唯一「看得出平滑」的部分，且无派生约束 |
| **纯数值字号**（`CoTypography` 11 项 + `readLineHeight`） | ✅ **插值** | 线性插值**保序** → `hierarchyHolds` 在过渡期间仍成立 |
| **几何**（`radius` · inset 偏移 · 痕迹 padding） | ❌ **整组阶跃** | ⚠️ 见下 |
| **枚举 / bool / 字符串** | ❌ 阶跃 | 值域离散，物理上无法插值 |

⚠️ **为什么几何不能插值（本轮最关键的判断）**：
`radiusFor() = scaleRadius ? radius × factor : radius` 是**派生量**。
若 `radius` 插值而 `scaleRadius`（bool，只能阶跃）在 t=0.5 翻转，「墨→格」过渡里圆角会：
- t=0.49 → `lerp(26,14,.49) × 0.55 = 20.1 × 0.55 = 11.1px`
- t=0.51 → `lerp(26,14,.51) × 1.00 = 19.9px`

→ **从 11.1px 跳到 19.9px（跳 8.8px）**，比完全不插值更难看（还会撞 §3.4 的月牙伪影）。

> 🔑 **可复用推论**：当**输入与输出是非线性关系**时，插值要作用在**最终量**上，
> 而不是输入参数上；做不到就**整组阶跃**，别让一组关联字段各自为政。

#### ③ ⚠️ 已知取舍（如实说明）：**1.1px 的圆角阶跃**

整组阶跃的代价：各档 md（高 60）实际圆角为 墨 `26×0.55=14.3` · 格 `14×1.0=14.0` · 夜 `24×0.55=13.2`
→ 任意两档最大差 **1.1px**。

**为什么不消除它**：要消除需把 token 结构从「基准 radius + 缩放开关」改成「三档最终半径」，
会连带改 spec §3.4/§3.5 与既有【3】【5】断言 —— **代价远大于收益**。
（1.1px 在一帧内变化，肉眼基本不可察；而写错时是 8.8px。）

#### ④ ✅ 验收：**307 项全过**（295 → 307，新增【11】插值 12 项）

关键断言（`scripts/tokens_verify`）：

| 断言 | 抓什么 |
|---|---|
| t=0 / t=1 **返回原实例**（`identical`，6 组两两组合） | 防「稳态也新建对象」→ 每次 build 无谓重绘 |
| 颜色在中点取均值 · 中点色 ≠ 任一端点 | 验「**真的插了**」而非阶跃 |
| **`radius` 只取端点值** · `maxSize` 只取端点值 | 验「几何确实阶跃」 |
| 🔑 **`radius` 与 `scaleRadius` 同侧**（派生量自洽） | 防「各自为政」造出没人设计的中间形态 |
| 🔑 **`radiusFor` 全程扫描无跳变 ≤2px**（三档两两，100 步） | 端到端验「阶跃后果可接受」，与 8.8px 有 4 倍区分度 |
| `hierarchyHolds` 全程成立（21 步 × 6 组） | 验「字号插值保序」 |
| 三态痕迹 bg 都被插值 | 防「只插 fresh 漏另外两态」 |

| 另一验证 | 结果 |
|---|---|
| 全库静态分析 | ✅ **error=3 / warning=13 / info=7** 与基线**完全一致** |

#### ⑤ 🔴 顺带修掉一个**验收脚本自身的系统性缺陷**（本轮被咬到）

【11】那条「已无阶跃实现」断言**一开始是红的** —— 但命中的是**注释里**那句
「为什么不能是阶跃（`t < 0.5 ? this : other`）」，**代码里其实早已改对**。

→ 加 `_codeOnly()`：**所有对源码文本的检查先滤掉整行注释**。两个方向都会出错：

| 方向 | 误判 | 后果 |
|---|---|---|
| 「**无残留**」检查 | 注释里解释「为什么**不用** X」被当成「还在**用** X」 | 🔴 **假红** |
| 「**已接线**」检查 | 注释里提到 API 名，被当成「代码里调了」 | 🔴🔴 **假绿，更危险** |

已把【9】【10】【11】里的 `src()` 与全库扫描统一改为经 `_codeOnly()`
（**加固后 307 项仍全过** → 说明既有断言没有靠注释假通过，这是个好消息）。

> 📌 **只滤「整行注释」**（行首 `//`）—— 不敢正则去行尾 `//`，因为源码里有大量
> URL（`https://…`），会误伤字符串。刻意的折中。

---

### 3.20 ✅ Step 3.0 清退：K12 体系 + 痕迹「格」档颜色（2026-09-27 11:50）

> 白哥 4 项决策：① 痕迹改朱砂 ② 内容先用 mock ③ **先做 3.0 清退** ④ 后端 admin·plan 一并清。
> 📄 规划依据：`docs/review/step3-core-ui-plan-2026-09-27.md`

#### ① 痕迹「格」档「复习中」颜色：绿 → 朱砂

| 位置 | 改动 |
|---|---|
| `design-system-spec` §1.1 | `--tk-m-bd`：`rgba(0,192,139,.42)` → **`rgba(196,83,58,.42)`** |
| `coevo_tokens.dart` | `gridTokens.reviewing.border` 同步 |
| 断言 | 新增 2 条：**两态同色相** + **只差 alpha** |

**依据**：取值 = `accentBright`（`#C4533A` = 196,83,58）的 42% 透明版，
与 `fresh` 的实色 `accentBright` **同源**（对齐 `visual-feed-bookmark` L53）。
原绿色是**旧「翠绿进化」时代残留**，与方案甲「统一色相 = 朱砂」冲突（色相差 155°）。

#### ② 前端：删 5 个零引用死代码（**2,652 行**）

`curriculum_plans_page` 836 · `debug_logs_page` 611 · `curriculum_cards_page` 583 ·
`config_page` 433 · `user_detail_screen` 189

- 🔑 **顺带核实**：`card_list_screen`（904 行）**不是**死代码 —— 被 `review_screen:18` import
- `app/lib` **23,333 → 20,686 行** · `analyze_inproc` **error=3/warning=13/info=7 与基线一致**

#### ③ 后端 K12 清退（**≈1,293 行**）

| 文件 | 行数变化 | 内容 |
|---|---|---|
| `routes.rs` | 3162 → **2533**（−629） | 5 条 `/api/k12/*` 路由 + 4 个 handler + 1 个测试 mod |
| `main.rs` | 410 → **358**（−52） | quiz bank 加载块 + 预建写入块 + 表结构 + 数据路径变量 |
| `schema.rs` | 845 → **821**（−24） | `k12_quiz_bank` / `k12_quiz_attempts` 表定义 + 表清单项 |
| `lib.rs` | 55 → **52**（−3） | 3 行模块声明 |
| 🗑 文件 | **−504** | `k12_quiz.rs` 130 · `k12_quiz_api.rs` 100 · `k12_quiz_loader.rs` 67 · `e2e_k12_extra_lifecycle.rs` 207 |
| `e2e_api_lifecycle.rs` | 723 → **642**（−81） | 摘除 K12 / Reading 两个**失效**场景（保留 free） |
| `plan_handler.rs` | 摘掉一处调用 | 原调 `k12_quiz::should_mark_task_complete` 决定是否跳过 task → 改为不自动跳过 |

> 🔑 **保留 `activate_first_task`**：零调用，但注释明确属 **plan 体系**（非 K12 语义）。

#### ④ 🔴 重要：白哥批准的两块**实际不能删**（核实后未动）

原报告估计「`plan_handler` 1,987 + admin 3,091 ≈ **5,100 行**可一并清」—— **核实后是活代码**：

| 目标 | 核实结论 |
|---|---|
| `plan_handler.rs` **1,987 行** | 🔴 **不能删** —— `ws.rs:352-353`（**chat 对话流程**）用它的 `resolve_plan_id` / `build_plan_context` / `log_prompt_source` 来**选 system prompt** → 是 **AI 对话的依赖**，不是 K12 专属 |
| `admin_handlers.rs` **1,365 行** | 🔴 **不能删** —— **共享工具模块**（`verify_admin`/`ok`/`err`），被 `distribution_handler` / `campaign_handler` / `config_admin` **4 个要保留的模块**引用 |
| `config_admin` · `plans_handlers` | ⚠️ **混装** —— 各含非 admin 路由（`/api/public/qrcode`、`/api/pay/plans`）→ 不能整文件删 |
| `distribution_handler` **2,264 行** | ✅ **必须保留** —— 有 **8 处非 admin 路由**（含 `/api/pay/calculate`、`/api/notifications`） |

→ **教训（第 N 次复现）**：**「按名字/印象定范围」会算错量级** ——
`plan` / `admin` 这两个词听起来都属于「已定不做」，但代码里它们**同时服务着保留中的 chat 流程**。
要清 admin 路由需**逐条剥离**，属**独立一轮**。

#### ⑤ 顺带发现：既有 clippy 问题（**非本次引入**）

本机 `cargo clippy`（Rust **1.95**）对 `api_server` 报 **48 个 lint 错误** ——
分布于 **15+ 个本次未改动**的文件（`ws.rs` 5 · `review_handler` 5 · `referral_handler` 4 · `auth.rs` 2 …）。

**已核实与本次无关**：改动文件里报错的行号（如 `plan_handler.rs:368/1101/1234/1433/1572/1582`）
与本次改动区域（1536 附近）**不重叠**。

⚠️ CI 用 `actions-rust-lang/setup-rust-toolchain@v1`（默认 **stable**）
→ 若 CI 的 clippy 版本同为 1.95+，则 **clippy job 会红**（⏳ 待白哥在 Actions 页面确认）。

#### ⑥ ✅ 验证

| 验证 | 结果 |
|---|---|
| 后端 `cargo check --all-targets` | ✅ **通过**（零 error/warning，**含测试编译**） |
| 前端 `analyze_inproc` | ✅ **error=3/warning=13/info=7** 与基线**完全一致** |
| `tokens_verify` | ✅ **309 项全过**（+2 痕迹色相断言） |

🔑 **过程中被 `cargo check` 抓到一次漏网**：`backend/src/main.rs:99` 引用 `k12_quiz_loader`
—— 我后来只在 `crates/api_server/src/` 里搜引用，**漏了 `backend/src/` 与 `tests/`**。
→ **教训：搜引用图必须覆盖整个 workspace，不能只搜「主目录」**（与「按内容找全所有副本」同源）。

---

### 3.21 ✅ Step 3.1：导航骨架 + 首页信息流骨架（2026-09-27 12:00 · 白哥「是的」）

> 📄 完整记录见 `docs/review/step3-core-ui-plan-2026-09-27.md` **§十**

**改动清单**（净 **≈−1,020 行**）

| 文件 | 动作 | 规模 |
|---|---|---|
| `app/lib/app.dart` | 3 tab → **「阅读 / 复习 / 我的」** · 第 3 分支 `/achievements` → **`/mine`**（挂 `ProfileScreen`）· **删顶层 `/profile` 路由** · 🆕 **底部导航自绘 `_ClayTabBar`**（按设计稿） | +180 |
| `app/lib/screens/home_screen.dart` | **重写**：K12 科目直选 → 信息流 | 475 → **271** |
| `app/lib/widgets/feed_card.dart` | 🆕 卡片组件（信息流 + 收藏清单**共用**） | **88** |
| `app/lib/models/feed_item.dart` | 🆕 `FeedItem`（**刻意无** `newWordCount`/`isRead`） | **63** |
| `app/lib/data/mock_feed.dart` | 🆕 设计稿原文三篇（**临时**，Phase 3 后整体删） | **42** |
| `app/lib/screens/achievements_screen.dart` | **删除**（新导航无「成就」） | **−999** |
| `app/lib/api/chat_client.dart` | 删 5 个失联方法（`getK12Subjects`/`k12Init`/`getK12Progress`/`getAchievementsAll`/`getPlanAchievements`） | ≈−95 |
| `app/lib/screens/review_screen.dart` | 删 2 处 `push('/profile')` | −6 |
| `app/lib/frontend-api-alignment-review.md` | 归档 → `docs/_archive/k12-era/…-2025-06-05.md` | 移动 |

#### 🔴 三个「不是风格问题，是功能已断」的发现（**均非本次引入**）

| # | 位置 | 事实 | 处置 |
|---|---|---|---|
| 1 | 旧首页「科目直选」 | 调 `/api/k12/subjects` + `/api/k12/init` —— **端点已随 3.0 删除**（`grep k12 routes.rs` = **0 命中**）→ **点击即报错** | ✅ 随重写移除 |
| 2 | 旧首页「历史对话」 | `push('/conversations')`，而 `app.dart` **从未注册**该路由 → 命中兜底 `/:unknown` → **静默跳回首页** | ✅ 随重写移除 |
| 3 | `screens/chat/chat_reading_passage.dart` | 调 `/api/k12/reading/…` —— **该路由也已删除** → chat 阅读链路**当前必失败** | ⚠️ **只标注、不改**（属 chat 流程） |

> 🔑 **判断升级**：「主题层已生效，页面层是 K12 遗留」还**不够准** ——
> 真相是 **`页面层调用的后端接口已经不存在了`**。
> 「界面还是旧的」不是审美问题，是**功能已断** ——
> 也正因此，**3.0 清退必须在 Step 3 之前**：先断接口，残留页面才会自己暴露。

#### ⚠️ 有意留白（不是遗漏）

「收藏 N」入口 + 卡片书签 → **3.3/3.5**（需 `bookmark` 表，先做只能是死入口）。

#### ✅ 3.1 补：底部导航自绘粘土药丸（白哥定「按设计稿」）

设计稿选中态是「**强调色填充药丸 + 实体投影**」，M3 `NavigationBar` 表达不出来
（`indicatorColor` 只能改颜色）→ `_ShellScaffold` 的 `NavigationBar` 改为自绘 **`_ClayTabBar`**。

🔑 **这是 Step 2 之后第一处真正用上 `Clay` 的界面**（此前只接在设置页的档位预览）。

| 判断 | 依据 |
|---|---|
| **未选中项不能用 `Clay`** | 粘土「抬起」态**必然**画填充 + 外阴影；而设计稿未选中项是**完全平的**（`.tb` 只有 `color`）→ 硬套会凭空多出三个灰底药丸 |
| **圆角显式取 17，不走 token** | 设计稿 `.tb` 的 `border-radius:17px` **写死在组件上、不在主题变量里**（三档共用）→ 🔑 **三档里唯一「圆角不随主题变」的元素**。几何仍成立：md 偏移 3×3=9 ≤ 17 ✅ |
| **选中态 inset 取 token** | 设计稿 `.tb.on` 硬编码 `rgba(0,0,0,.15)`/`rgba(255,255,255,.26)`，而 **spec §3.3.1 明文「两者共用」** → 按 spec |
| **`navigationBarTheme` 保留不删** | 当前无组件在用，但任何页面若引入 M3 `NavigationBar`，颜色不会**静默回落成默认紫** —— 留正确兜底比删掉安全 |

⚠️ **待实机确认**：设计稿**未定义**未选中项的按下反馈 → 本实现**也不自行添加**
（「无背景 = 无物理形态 = 无回弹」自洽）。实机若觉得点击「没反应」，**再讨论**，不默默加。

#### 🔴 待办新增：**成就体系重新规划**

白哥：「后端成就系统留着吧，**不过成就要重新规划**」

- **现状**：前端入口**已全部移除**（999 行页面 + 2 个客户端方法）｜后端**完整保留**（`achievements` 表 · 2 个 handler · **chat 内嵌 `engine.check_and_persist`**）→ **两边已断开**
- **重新规划时要一并决定**：① 成就挂什么行为（旧挂 K12 进度，已不存在）② 放哪（设计稿是 3 tab，最可能进「我的」页，**不是一级 tab**）③ 是否沿用现有 `achievements` 表结构 ④ `plan_achievements` 与「**不做 plan**」的关系
- ✅ **不阻塞任何批次**（后端不动、前端无入口 → 现状是「静默休眠」）

#### ✅ 白哥另两项决策（2026-09-27）

| 事项 | 决策 |
|---|---|
| **AI 对话（chat）去留** | 🔵 **保留 —— 是 v1「AI 考核」的预留** → `chat_screen` + `ws.rs` **不动**；3.7 词卡页给它重新开入口 |
| **后端成就系统** | 🔵 **保留**（见上「重新规划」） |

#### ✅ 验证

| 项 | 结果 |
|---|---|
| `analyze_inproc`（`app/lib`） | ✅ **error=3 / warning=13 / info=7** —— 与基线**逐项一致** |
| `tokens_verify` | ✅ **309 项全过** |
| 残留引用扫查 | ✅ `grep achievements_screen\|AchievementsScreen app/lib` → **0 命中** |
| 真编译 | ⏳ **未跑**（本机沙箱跑不了 `flutter`）→ 请白哥 `flutter run` 目视 |

---

### 3.22 🔴🔴 修「首页没有卡片」+ 固化产品原则「**除生词表上限外不验证登录态**」（2026-09-27 12:20）

> 完整记录见 `docs/review/step3-core-ui-plan-2026-09-27.md` **§十一**

#### 🔴 原则（白哥定 · 架构约束）

> 「**首先我们的功能除了生词表限制以外不验证用户登录状态，所以你的方案不对**」

| 能力 | 要不要登录 |
|---|---|
| 读信息流 / 打开文章 / 划词查词 / 词卡朗读 / 复习 | ❌ **不需要** |
| 生词本**新增**（超 200 词上限时） | ✅ **只有这里** |

→ 🔑 **登录态是「能力限制开关」，不是「内容可见性开关」**。任何内容渲染都不得被登录态阻塞。

#### 缺陷与修复

白哥报「**首页没有卡片，按钮正常**」。全库核实后，**只有 `home_screen` 一处**把登录态当成内容前置条件
（`app.dart` 订阅 · `profile_screen` 个人页 · `chat_screen` 均属**正当**需要登录）。

**缺陷链**：干净浏览器 → `hasUsedTrial()=false` → `POST http://localhost:8080/api/trial/start`
（⚠️ `flutter run` 默认连 localhost，**后端在 VPS**）→ 请求失败 → `trialStart` 内部 catch（**只写 state，不打日志**）
→ `isAuthenticated` 仍 false → `_authReady` 永远 false → **首页永久转圈，无提示无重试**。
🔑 **表现为「按钮正常、没卡片」**：loading 在**内层 Scaffold**，tabbar 在**外层 `_ShellScaffold`**。

**修法（只删不加）**：删 `_authReady` + 整个 loading 分支（约 34 行）→ 信息流**无条件渲染**；
`_initAuth` 保留原逻辑但降级为 `addPostFrameCallback` 的**后台副作用**（失败静默）；
🔒 另补 `_authRestoreTries` 上限 20 次 ≈ 6s（原「等 auth 恢复」是**无界递归**，每 300ms 调自己）。

#### 🔑 三条教训（可复用）

1. **别把「易失败的外部依赖」（网络 / 身份）放在「内容渲染」的前置条件上** ——
   等于让内容可用性绑定在一个与内容无关的开关上；开关失败 → 内容整体消失。
2. **「静默失败 + 无出口」比「报错」更糟** —— 用户连一个可报告的线索都没有。
3. **方案要建立在产品原则上，不是技术自洽上** —— 我第一版方案（加三态 + 重试）技术上没错，
   但它**默认了「未登录」是合法状态**，而正确前提是「**未登录根本不该影响读**」。

#### ✅ 验证

`analyze_inproc` ✅ **error=3 / warning=13 / info=7** 与基线一致｜`_authReady` 代码中 **0 处**｜`home_screen` 302 → **265 行**

🔴 **遗留（未改，仅标注）**：`AuthNotifier.trialStart` 的 catch **不打日志** → 「试用创建失败」在生产**完全不可观测**，建议补一行（不在本轮范围）。

---

### 3.23 ✅ 补静默失败日志（白哥批准）+ 🔴 新发现待批（2026-09-27 12:25）

> 完整记录见 `docs/review/step3-core-ui-plan-2026-09-27.md` **§十二**

#### ✅ 已实施：认证模块 **5 处**静默失败补日志

批准范围是「`trialStart` 补一行」→ 实际扫查发现**同性质静默失败共 5 处**，按同一原则一并补齐：

| 方法 | 原状态 |
|---|---|
| `trialStart` | 🔴 **完全静默**（且正是「首页转圈」的源头） |
| `register` / `login` / `trialClaim` | 🔴 只写 `state.error`（UI 可见，控制台无线索） |
| `logout`（清 display_name） | 🔴 `catch (_) {}` **空吞** |

🔑 **日志必须带端点**（`endpoint=${ApiConfig.baseUrl}`）—— 本次故障根因就是「连错地址」
（`flutter run` 默认 `localhost:8080`，后端在 VPS）；只有 `Connection refused` 的话**必须靠猜**。

#### 🔴 新发现（**未改，待批**）：`auth_client` 4 个方法缺 `.timeout()`

| 文件 | 请求处 | 带 timeout |
|---|---:|---:|
| `chat_client.dart` | ≈30 | **24** → ✅ **「加 timeout」是惯例** |
| `auth_client.dart` | 5 | **1**（仅 `verifyToken`） |

缺失：`register` · `login` · `trialStart` · `trialClaim`（`ApiConfig.requestTimeout` 早已定义，只是没用）。

⚠️ **准确表述**：本次「转圈」**不是**它造成的（连无监听端口 → 立即 `ECONNREFUSED`）。
它影响的是**「IP 可达但无响应」**（防火墙 DROP / 网络黑洞 / 服务假死）——
Flutter Web 的 `http` 走浏览器 XHR，**默认超时极长**（Chrome ≈300s）→ 用户点登录后**数分钟无反馈**。

**方案 A（建议）**：4 处统一加 `.timeout(ApiConfig.requestTimeout)`（10s），与惯例一致｜**方案 B**：A + 按错误类型分文案

#### ⚠️ 顺带记录（**有意设计，非缺陷**）

`verifyToken` 网络错误时 `return {'valid': true}`（`Be lenient on network errors`）
—— **断网时把无效 token 当有效**。为「避免一断网就登出」的有意宽容，**不建议改**，记录备查。

#### ✅ 验证

`analyze_inproc` ✅ **error=3 / warning=13 / info=7** 与基线一致｜✅ 逐方法核对结构完整
（编辑时一度误删 `_setTrialUsedFlag` 的文档注释，已复原文并复核）

---

### 3.24 ✅ 方案 A：`auth_client` 全部请求补 `.timeout()`（白哥批准 · 2026-09-27 12:30）

> 完整记录见 `docs/review/step3-core-ui-plan-2026-09-27.md` **§十三**

#### ✅ A 本体：4 处补超时 → **5/5 全覆盖**

`app/lib/api/auth_client.dart`：`register` · `login` · `trialStart` · `trialClaim`
统一加 `.timeout(ApiConfig.requestTimeout)`（10s），与 `chat_client` 惯例一致。
🔑 类文档补了一句判定标准：**「连不上」和「连上了但没人应」是两回事** ——
端口无监听 → 立即 `ECONNREFUSED`（不需超时）；IP 可达但被丢弃 → **没超时就无限等**。
→ **超时不是「防连不上」，而是「防等不到头」。**

#### 🔴 A 的必要配套：`_friendlyError` 补两个映射（否则 A 让文案更糟）

加 `.timeout()` 后抛的是 `TimeoutException`，而 `_friendlyError` 是**错误文案唯一出口**、
映射不到就原样透传 → 用户会看到 `TimeoutException after 0:00:10.000000: Future not completed`。
→ 补：`TimeoutException` → 「网络超时，请检查网络后重试」；
`SocketException`/`Connection refused`/`Failed host lookup` → 「连不上服务器，请检查网络后重试」。

#### 🔴🔴 顺带挖出真 bug：`replaceFirst` 把 `SocketException:` 啃掉

原 `_friendlyError(e.toString().replaceFirst('Exception: ', ''))` ——
而 `SocketException: Connection refused` **中间也含 `Exception: `** → 命中被替换：

```
'SocketException: Connection refused'.replaceFirst('Exception: ', '') → 'SocketConnection refused'
  → contains('SocketException') == false   ← 此后 Socket 匹配永远失效
```

**「埋雷」型缺陷**：字符串已损坏 + 匹配静默失效（后人加了判断会永远不生效且查不出原因）。
→ **修法**：只在**恰好**以 `Exception: ` 开头时才剥（`startsWith`），入参改传 `e.toString()` **原文**（4 处同步改）。

#### ⚠️ `verifyToken` 的 5s 是**有意例外**（非漏改）

在**启动路径**（会话恢复）上，用户正等首屏；超时后果轻（catch 后按「已认证」继续）→ 宁可早放行。
已在注释写明「**全库唯一的有意例外，不是漏改**」，防后人「顺手统一」。

#### ✅ 验证

| 项 | 结果 |
|---|---|
| 超时覆盖 | ✅ **5/5** 逐行 grep 确认 |
| `analyze_inproc` | ✅ **error=3 / warning=13 / info=7** 与基线一致 |
| **错误映射逻辑** | ✅ **8/8** —— 用**真实异常文本**复刻验证（超时 / 两种 Socket / rate_limited / 后端业务错误 / 未知原样透传） |
| 旧实现对照 | ✅ 实证旧实现下 `contains('SocketException')` = **false**（bug 复现） |

⚠️ **验证局限**：映射验证是**复刻逻辑**跑的（该函数嵌在 import Flutter 的文件里，无法独立 import）
→ 证明**逻辑正确**，不证明**源码可编译**（后者仍需真编译）。

---

### 3.25 ✅ Step 3.2：痕迹渲染层（2026-09-27 12:40）

> 完整记录见 `docs/review/step3-core-ui-plan-2026-09-27.md` **§十四**｜依据 spec **§一 / §1.1 / §八**

#### 产出

| 文件 | 性质 | 规模 |
|---|---|---|
| `app/lib/widgets/trace_segmenter.dart` | 🆕 **区间切分 · 零 Flutter 依赖** | ~250 行 |
| `app/lib/widgets/trace_text.dart` | 🆕 渲染层（`TraceText` + `applyTraceStyle`） | ~200 行 |
| `scripts/trace_verify/` | 🆕 验收（**82 项断言**） | ~330 行 |
| `docs/design/trace-render-compare-2026-09-27.html` | 🆕 三档 × 三态 × 三字号对照页 | — |

#### 🔑 核心设计：切分与渲染拆开

| 类 | 例子 | 能否自动抓 |
|---|---|---|
| ① **切分错** | 丢字 / 重叠 / 越界 / 同起点结果不稳定 | ✅ **能**（纯逻辑） |
| ② **样子不对** | 三态不可辨、已掌握态干扰阅读 | ❌ **不能**（只能肉眼） |

→ ①抽成零 Flutter 依赖的 `trace_segmenter.dart`（仿 `fsrs_service`），②留在渲染层。
🔑 **可验证性反过来促成了更好的分层** —— 为了让切分可被脚本断言，它必须不碰 Flutter。

#### 🔴🔴 三处「设计稿能做、Flutter 文本做不到」（已核实 SDK 源码）

| 设计稿（spec §1.1） | Flutter `TextStyle` |
|---|---|
| `border-radius: 3px` | ❌ **无圆角** —— `background` 是 `Paint`，只能矩形 |
| `padding: 1px 3px` | ❌ **无 padding 字段** |
| `border-bottom: 2.5px` | ⚠️ `decorationThickness` 是**笔画倍数**，**不是像素** |
| border 贴盒底 | ⚠️ `underline` 在**基线下方**，无偏移可调 |

**按档看**：**夜 ✅ 完美还原**（就是 `color`）· **格 ✅ 语义完全对**（本来就是线，仅线宽需真机标定）·
**墨 ⚠️ 语义对但无圆角/无 padding**。

📄 **对照页**（真实 token 值 · 同一 CSS 引擎并排画）：`docs/design/trace-render-compare-2026-09-27.html` §②
🔑 **要判断的就一件事**：墨档差异是「可接受」还是「一眼觉得糙」→ 决定要不要为墨档单独上自绘。
⚠️ **不擅自决定** —— 3px 圆角在 16.5px 正文里的实际差异，**只有看的人能判断**。

#### 线的粗细需**真机标定**

`decorationThickness` = 笔画宽度倍数，而真实笔画宽度在字体元数据里、**Flutter 未暴露**
→ 用估算系数 `_kFontStrokeRatio = 0.07`（常见字体 5%–8%）。
🔑 **「目标像素」保留在 token 的 `border.width`**（2.5/1.5/1.0）—— 真机判据是「屏幕上是不是 2.5px」；
若把倍数硬编码进 token 就丢了这个判据。**改一个系数即可同时修正三态。**

#### ✅ 验证

| 项 | 结果 |
|---|---|
| **`trace_verify`** | ✅ **82 项全过** —— 含 **2,000 组随机输入**（越界/空/反向）的「覆盖全文 + 首尾相接」不变量（1,292 组确实落了痕迹，非空输出蒙过） |
| `tokens_verify` | ✅ **309 项全过** |
| `analyze_inproc` | ✅ **error=3 / warning=13 / info=7** 与基线一致（文件 62 → **64**） |
| 真机视觉 | ⏳ 未做 —— 三态**可辨性**只有肉眼能验（spec §八） |

🔑 **过程中一次「断言错 vs 实现错」的判别**：首跑 8 项失败，实际 `[_0-10]` vs 我写的 `[_-0-10]`。
按判据「先看数据是否自相矛盾」→ 区间连续、分布正确 → **实现对、断言错**（期望多打一个 `-`）。
→ **见红不要先改实现。**

---

### 3.26 🔴🔴 白哥定「已掌握 = 不标识」→ 痕迹三态改两态（2026-09-27 12:52）

> 完整记录见 `docs/review/step3-core-ui-plan-2026-09-27.md` **§十五**

#### 这条修掉了 spec 的**一处内部矛盾**

| 位置 | 原文 |
|---|---|
| spec 第 21 行（**原则**） | 「**学习的终点是痕迹的消失**」 |
| spec 原 §1.1（**值表**） | 已掌握 = 「几乎不可见（**比周围文字暖一点点**）」 |

→ **按原则改值表**：已掌握的字**回到普通文字**，与「从没查过」视觉上**完全一致**。

#### 🔑 关键判断：「不标识」**不能**用「透明样式」表达 —— 因为 `padding`

透明确实看不见**颜色**，但 `padding: 1px 3px` **仍然生效** → 撑开字距 →
被标记过的字与普通字**间距不同** → 用户看得出来「这里有东西」。
**那仍然是标识，只是更难解释（一种更糟的标识）。**

→ 用 **`null`**（**没有痕迹**）表达：`forReps` 返回 `TraceStyle?`，已掌握返回 `null`
→ 调用方**编译期强制**处理该分支。

#### 顺带收益：痕迹不再退化成「掌握度仪表盘」

若已掌握还留暖色，痕迹就同时背**两个表达**（「这里我查过」+「这个我掌握了」）
→ 违反设计稿「**一个概念，一个表达**」。掌握度去复习页看，**痕迹只表达「我和这篇文章的关系」**。

#### 改动

`TraceTokens.mastered` 删除（三态 → **两态**）· `forReps` → `TraceStyle?` · 删 `TraceStyle.isInvisible` ·
三档实例 · spec §一/§1.1/§八 · **设计稿只加注释标注失效、原样保留**（L1 锚点不擅改）·
两个 verify 脚本 · 对照页（改为两态 + 新增「已掌握 vs 无标记」并排）

🔑 **顺带修正 spec 一处失效表述**：夜档原写「**亮度递减**」——三态下靠已掌握把亮度拉到 `.291` 才成立；
**两态下实测仅 `.743 → .716`（几乎无差），实际区分靠「暖度」**（r−b：71 vs 7）
→ 改为「暖度递减」，并标注「**若真机难辨，这里是首要怀疑点**」。
⚠️ 这是白哥决策**顺带揭示**的 —— 不做两态简化，这个「表述与实测不符」会一直藏着。

#### ✅ 验证

| 项 | 结果 |
|---|---|
| `trace_verify` | ✅ **76 项全过**（含「三档 `forReps(3)` 都返回 `null`」） |
| `tokens_verify` | ✅ **295 项全过** |
| `analyze_inproc` | ✅ **error=3 / warning=13 / info=7** 与基线一致 |

---

### 3.27 ✅ Step 3.3：卡片书签 + `bookmark` 表（2026-09-27 13:10）

> 完整记录见 `docs/review/step3-core-ui-plan-2026-09-27.md` **§十六**

#### 🔴 调查结果：真实缺口比规划里写的更多

规划把 3.3 写成「只差接口 + UI」→ **核实后发现「连打开 `user.db` 这一步都不存在」**：

| 环节 | 核实前以为 | 实际 |
|---|---|---|
| `sqflite` 依赖 / schema 文件 / 查询层 | ✅ 都有 | ✅ 都有 —— 但查询层**只接受注入的 `Database`** |
| 🔴 **谁创建 `user.db`** | ❌ 不存在 | ❌ **确实不存在** —— 从无代码创建过它 |

→ 3.3 真实范围 = **连接层 + 表 + 仓储 + 状态 + UI**，其中**连接层是从来没做过的一环**
（此前所有端侧数据层验证都靠脚本自建临时库）。

#### 产出

`services/user_db.dart`（🆕 连接层 · 纯 Dart · 含 SQL 脚本拆分器）·
`services/bookmark_repository.dart`（🆕 仓储）· `providers/bookmark_provider.dart`（🆕 状态）·
schema **v1.2**（`bookmark` + 2 索引）· `FeedCard` +`BookmarkButton` · `home_screen` +toast ·
`pubspec` 显式声明 `path` · 🆕 `verify_bookmark.dart`（**49 项真库断言**）

#### 🔑 三处关键设计

1. **DDL 由调用方注入** → 连接层保持纯 Dart（`rootBundle` 是 Flutter API）
   → App 用 `rootBundle.loadString`、脚本用 `File(...).readAsStringSync`，**同一个函数、同一份 DDL**
2. **书签禁用不用 `ClayState.disabled`** —— 该态是「从凸起变瘪」，而书签未收藏本来就是**凹陷**
   → 套上去**语义反转**；只用 `Opacity(0.45)`
   （🔑 与 3.2「不标识」同源：**别用相近但语义不同的表达去代理**）
3. **UI 只用 `idsOrEmpty` / `isReady`，禁止 `when(error:)`** ——
   `when(error:)` 会把「数据库打不开」渲染成**错误界面**，而收藏坏了不该让内容页变报错页（3.22 教训）

#### 与设计稿的偏离（2 处 · 已记录在 schema 注释）

| # | 设计稿 | 本实现 | 理由 |
|---|---|---|---|
| 1 | `DEFAULT (datetime('now'))` | `DEFAULT (strftime(...'Z'))` | 🔴 `datetime('now')` **无 `Z`** → `DateTime.parse` **静默按本地时区解释** → 跨时区错位且**不报错** |
| 2 | `pending_push INTEGER DEFAULT 1` | + `NOT NULL` + `CHECK` | 与 `card_review_state` 同规格（设计稿是**草图级** DDL） |

➕ **补充**（非偏离）：另加 `idx_bm_pending` —— 设计稿自己说「跟着已有同步机制走」，
而增量 push 的查询就是 `WHERE pending_push = 1`。

#### ✅ 验证

| 项 | 结果 |
|---|---|
| **`verify_bookmark`** | ✅ **49 项全过** —— **真库**：SQL 拆分器 9 项边界 · **重开模拟应用重启** · CRUD · **幂等** · **重复点击不刷新时间戳** · 取消后可再收藏 · 待同步 · 倒序 · **时间列带 `Z`** |
| `verify_review_list` | ✅ **37 项全过**（改用连接层拆分器后**无回归**） |
| `verify_word_query` | ✅ **42 项全过** |
| `analyze_inproc` | ✅ **error=3 / warning=13 / info=7**（文件 64 → **67**） |

#### 🔑 本轮三条可复用教训

1. **`List`/`Set` 的 `==` 是引用比较** —— `eq(actual, [1,2])` 即使值相同也判失败，
   表现为「实得 `[1,2]` · 期望 `[1,2]`」→ **看起来像实现错、其实是断言错**（首跑 8 项红全是这个）
2. **同一份文件不能有两套解析** —— `verify_review_list` 原有一套**较弱的**内联 SQL 拆分
   （不处理行内注释/块注释），与新的强拆分器并存 → 迟早分叉 → **改为复用**
3. ⚠️ **`old_string` 的坑又多一种形态**：这次不是「漏含子行」，而是**截断在语句块中间**
   → 留下语法残骸 → **立刻读文件核实并修复**（该坑第 **6** 次）

#### ⚠️ 有意留白

「收藏 N」标题栏入口 + 收藏清单 → **3.5**（现在做是死入口）；
多端同步 → Phase 3（表/索引/`pending()`/`markSynced()` 已就位，**不是从零写**）；
`word.db` 落盘 → **3.4**（32.9 MB 预制库需首次启动从 assets 复制）

---

### 3.28 ✅ Step 3.4a：阅读器骨架（白哥批准 · 2026-09-27 13:40）

> 完整规划与执行记录：📄 `docs/review/step3-reader-plan-2026-09-27.md`（§一~§九）

#### 🔴 调查结论：真实范围远超原规划

原规划只有一行「3.4 阅读器 + 划词（最大未知）」。实测后**缺口大头在数据层**：

| 层 | 实测 |
|---|---|
| 数据层 | 🔴 **4 张表不存在**（`user_word` / `lookup_event` / `article` / `external_word_cache`）+ **32.9 MB `word.db` 从未落盘**（`app/assets` 零 `.db`） |
| UI | 阅读器页 · 划词触发 · 查词浮层 · 查词写入 —— 4 块 |
| 依据 | **3 份文档各管一段**（v1 §九 流程 / L1 §07 浮层 / spec §5.1 排版），**且三处正文字号互不相同** |

→ 白哥定 **只做 3.4a**（零新表 · 不需 `word.db` · 风险最低）· 正文 **17px**（L1 锚点）· 划词用**长按选择**。

#### 交付物

| 文件 | 动作 | 行数 |
|---|---|---|
| `models/article.dart` | 🆕 | 73 |
| `data/mock_articles.dart` | 🆕 | 83 |
| `widgets/trace_locator.dart` | 🆕 | 68 |
| `widgets/bookmark_button.dart` | 🆕（从 `feed_card` 抽出） | 100 |
| `screens/reader_screen.dart` | 🆕 | 346 |
| `widgets/feed_card.dart` | 改 | 208→118 |
| `app.dart` / `home_screen.dart` | 改 | +28 |

#### 🔑 四处设计判断

1. **「阅读界面零粘土」取 spec §八 的口径** —— spec §〇 说「阅读界面零粘土」（宽），§八 验收项说「**阅读区容器内**不得出现粘土类」（窄、有明确范围），而设计稿的 `.bm`（书签）**本就是卡片与阅读栏共用的粘土类** → **正文区严格零粘土，顶部栏那一个动作按钮保留**（否则同一动作在两个界面长得不一样）
2. **正文字号不进主题 token** —— 行高是**主题相关**（三档不同），字号是**用户偏好**（可调 15–24）→ 一个是「主题」一个是「设置」，混层则将来分不清谁覆盖谁
3. **`BookmarkButton` 抽成独立组件** —— 3.3 与 `FeedCard` 同文件；阅读器要用它 → 不抽就得 `import 'feed_card.dart'` 只为拿按钮，依赖方向莫名
4. **「找不到文章」与「正文未就绪」两种状态各有文案** —— 🔴 **不共用白屏**；且正文未就绪的卡片**照样可点**（进阅读器看解释），而不是做成不可点（那要用户猜原因）

#### `trace_locator` —— 词级痕迹定位（本批唯一的算法）

`正文 + 已查词(reps/lapses) → 区间 → splitTraceSpans → TraceText`

🔴 **唯一的难点是词边界**：用朴素 `indexOf` 则查过 `art` 会把 `start`/`part`/`artist` 全标上 ——
**不报错、只是多画几处底色**，肉眼极难发现 → 用 `\b` 并由 **6 条断言**锁死。

#### ✅ 验证

| 项 | 结果 |
|---|---|
| `trace_verify` | ✅ **97 项**（76 → 97 · **+21** 定位断言：6 条词边界 · 大小写 · 标点相邻 · 同词多次 · 已掌握不标 · 与 `splitTraceSpans` 集成）<br>🔴 **2026-10-02（S4）已删** —— 该脚本测的区间切分/定位随死代码作废，token 那 4 组已并入 `tokens_verify`【4】且更严。现目录只剩 `verify_trace_markdown.dart`（10 组 43 项）|
| `tokens_verify` | ✅ **300 项**（295 → 300 · 新增 §12「阅读界面零粘土」5 项 **自动检查**） |
| `verify_bookmark` / `review_list` / `word_query` | ✅ **49 / 37 / 42 项**（抽出书签组件后**无回归**） |
| `analyze_inproc` | ✅ **error=3 / warning=13 / info=7**（文件 67 → **72** / 行 20,907 → **21,517**） |

#### ⏳ 只能真机看

三档下正文的对比度舒适度 · 17px + 行高的实际观感 · 痕迹在 17px 正文里是否可辨 ·
顶部栏书签与卡片的粘土观感是否一致。

**请 `flutter run`**：点第一张卡（有正文）看顶部栏 / 标题区 / 三段正文 / **三处痕迹**
（`vertical` 刚查过 · `Instead`+`liquid` 复习中 · `produces`/`traditional`/`kilometres` **应无标记**）；
点第二张卡 → 「正文还没准备好」。

#### ⚠️ 有意留白

顶部栏「下滑隐藏」（spec 只给了四个字，无阈值/回弹规则，自行定数等于替设计做决定）·
单击中央唤出设置面板（面板本身是独立一批）· 划词/浮层/生词本 → **3.4b/c** ·
收藏清单 → **3.5**。

---

### 3.29 ✅ 记忆法槽位① 规则修正：交换 `etymology` 3 ↔ `collocation` 4（白哥批准 · 2026-09-27 14:08）

> 完整决策材料与执行记录：📄 `docs/review/mnemonic-slot-priority-conflict-2026-09-27.md`

**触因**：3.4b 实施「查词浮层」时，槽位①（记忆法）取哪一段无法定论 ——
设计稿 L1 §07 画 `vertical` 的槽位① = **词源故事**，而按 `mnemonic_type.priority` 会得到**搭配整记**。

#### 🔴 根因（实测推翻了「搭配不够强」这个原诊断）

`priority` 表**自相矛盾** —— `collocation` 的适用条件「有 ≥1 条高频固定搭配」实测 **99.3% 的词都满足（几乎恒真）**，
却排在 `etymology`（条件「**不可拆**」）之前 → **必然吃掉所有「不可拆词」的槽位①**。

| 实测 | 值 |
|---|---|
| **不可拆词**（`sections` 无 `root`） | **6,039 / 11,523 = 52.4%**（其中 **98.1%** 有 `etymology` 段） |
| `root`（**可拆**）与 `etymology`（**不可拆**） | 语义上**互补**的两条路（表自己的设计意图） |

**槽位① 分布对比**：

| 槽位① | 改前 | 改后 |
|---|---:|---:|
| `etymology` | **53（0.5%）** | **5,924（51.4%）** ✅ |
| `root` | 5,484（47.6%） | 5,484（47.6%） |
| `collocation` | **5,957（51.7%）** | **86（0.7%）** ✅ |

🔑 **改后 51.4% 与「不可拆词」52.4% 吻合** → 说明新顺序符合语言事实。
🔑 **交叉验证**：`word_mnemonic_profile.primary_code`（LLM 当年判定）里 `collocation` 仅 **0.9%** ——
与改后渲染层得到的 0.7% **高度吻合**，说明「搭配只在少数词上该当槽位①」是语言学习判断，不是我们的发明。
🔴 **「聚合页入口」的独立论据**：入口只在 `root`/`cognate`/`etymology` 段里（`collocation` 段 **0%**）
→ 槽位① 若是搭配，**浮层没地方挂聚合页入口**。

#### 🔴 执行中发现：`priority` 有**三处出处**（只改 DB 会静默回退）

| 出处 | 性质 | 处理 |
|---|---|---|
| `data/word.db` 的 `mnemonic_type` 表 | 运行时数据 | ✅ 改（一次 UPDATE 完成交换，影响 **2 行**） |
| `scripts/load_llm_results.py` 的 `MNEMONIC_TYPES` | 🔑 **真源**（重建词库时由它写入） | ✅ 改 —— **不改则下次重建回退** |
| `scripts/verify_card_structure.py` 的 `MNEMONIC_ORDER` | 副本（验收用） | ✅ 改名 `SECTION_STORAGE_ORDER` + 澄清注释 |

#### ⚠️ 有意**未做**：不重排 `card.sections` 的段顺序

段顺序是生成时按**当时**的 priority 写入的，现在与 priority 不再一致（存储仍是 `…collocation, etymology…`）。

**理由**：① `card.sections` 是**素材池**（「存全部素材、裁剪留渲染层」）
② 白哥 2026-09-26「**优先级是渲染层面的事**」→ **存储顺序不承载语义**
③ 重排要改写 **11,523 份 JSON**（含重序列化副作用风险）→ **为无意义的约束付大代价**

→ 渲染层按 `mnemonic_type.priority` 取，**不依赖段顺序**；验收脚本的存储顺序断言保留（仍 0 错误）但已改名澄清。

#### 🆕 新增：`scripts/query_verify/bin/verify_worddb_sync.dart`

**两份 `word.db` 的一致性断言**（`data/word.db` 源 ↔ `app/assets/word.db` 交付物）—— **防漂移**。

🔑 为什么允许两份：`git` 按**内容哈希**存 blob → 两份相同**复用同一 blob**（实测 `git add` 后对象数 **113 → 113**，`.git` 仍 87 MB）
→ 换来「clone 即完整、CI 无需前置复制步骤」。⚠️ 代价是漂移风险，**分叉后 App 用旧词库且无任何运行时症状** → 本断言是唯一守卫。

✅ 并**故意篡改 1 字节验证过它真会红**（精确报出偏移 1000）—— 断言必须能回答「改坏了会不会红」。

#### ✅ 验证（全过）

| 项 | 结果 |
|---|---|
| `PRAGMA integrity_check` | ✅ **ok**｜`word`/`card` 仍各 11,523 |
| 文件指纹 | ✅ `e7495c54…` → **`d76c3d22…`**（证明**真落盘**） |
| **`verify_worddb_sync`**（🆕） | ✅ **6 项** |
| `verify_card_structure.py` | ✅ **13 项**（改名后无回归） |
| `verify_word_query` / `review_list` / `bookmark` | ✅ **42 / 37 / 49 项** |
| `tokens_verify` / `trace_verify` / `fsrs_verify` | ✅ **300 / 97 / 19 项** |
| `analyze_inproc` | ✅ **error=3 / warning=13 / info=7**（前端本轮未改） |
| 目视核对 | ✅ `intercept`→词根词缀 · **`vertical`→词源故事**（= 设计稿 L1）· `traffic jam`→搭配整记 |

#### ⚠️ 仍未处理（仅记录）

① `AggregateLink.pageType` 恒空（`entry` 实际无 `page_type` 字段）｜② 验证脚本硬编码 `E:\CoEvo\data\word.db`
（换机器/CI 失败）｜③ `verify_card_structure.py` 用 `imagery` 而 DB 用 `image`（**永远匹配不到**，现无实害）
｜④ **「存储顺序」断言是否该保留**（待白哥定 —— 它约束的是素材池顺序，与「把渲染决策固化成库字段」同型）
｜⑤ `pubspec.yaml` 尚未声明 `assets/word.db`（属 3.4b 落盘机制，待确认）

---

---

### 3.30 ✅ Step 3.4b：`word.db` 落盘 + 查词浮层 + 词性归一化（白哥选 A · 2026-09-27 14:46）

> 完整执行记录：📄 `docs/review/step3-reader-plan-2026-09-27.md` **§十一**

#### 🔑 两项决定（白哥 14:36 / 14:40）

| 决定 | 内容 |
|---|---|
| **浮层定位** | 🔴 **浮层 = 查词（基础信息四要素）；词卡 = 学词（记忆法）** —— 修正 L1 §07（它把浮层画成「词卡的紧凑版」）｜**v1 未规定显示什么** → 不违反 L0 |
| **三层递进** | 浮层 →（点进）复习卡片 →（**唯一聚合页入口**）聚合页 → ∴ **浮层不放导航入口** · **聚合页顺延 3.7** |

#### 交付物（+768 行）

| 文件 | 动作 | 行数 |
|---|---|---|
| `services/word_db_bootstrap.dart` | 🆕 **落盘决策 · 纯 Dart** | 172 |
| `services/pos_display.dart` | 🆕 **词性归一化 · 纯 Dart** | 174 |
| `providers/word_db_provider.dart` | 🆕 | 98 |
| `widgets/lookup_sheet.dart` | 🆕 浮层（四要素） | 192 |
| `screens/reader_screen.dart` | 改（+`SelectionArea`） | 346 → 478 |
| `pubspec.yaml` | 改（🔴 **声明 `assets/word.db`**） | +6 |
| 🆕 `verify_worddb_bootstrap.dart` / `verify_pos_display.dart` | 🆕 | 149 / 185 |

#### 🔑 五处关键设计

1. **落盘决策与 IO 分离** → 判断可独立断言（22 项）。最有价值的一条：
   🔴 **资产异常（0 字节）+ 目标存在 → 不复制** —— 防「**用空文件盖掉好库**」（不可逆）。
   直觉会写成「不同就复制」，但那样一旦打包事故，用户的库就被毁了。
2. **`pos` 归一化 47 种 → 19 类**：同义（`[n]`/`n`/`noun`）· **可数性标记**（`[c,u]`/`[n pl]` → `n.`，
   **它们不是词性**）· 复合（`[adj/adv]`）· 全角括号注释 · 多词键**整串优先**（`modal verb`）· 未知**原样保留**（不猜）
3. 🔴 **而「原样保留」这条兜底差点骗过我**：首跑报 `[det./pron.]` 未识别，**但我手写样例断言过它且通过了** ——
   根因是清洗只剥「整串」尾点、没剥**每段**的 → `det.` 查不到表 → 走兜底 → **输出恰好等于期望** → **假通过**
   > 🔑 **凡有「兜底原样返回」的地方，必须另有一条断言独立判「是否命中」**
4. **长按选择三处处理**：① `onSelectionChanged` **只暂存**（拖动会反复触发 → 否则一次拖动打十几次库）
   ② 自定义工具栏**只有一个「查词」**（默认的「复制」在阅读场景没用）③ 遮罩用 **12%**（默认 54% 像「跳到另一个界面」）
5. **`ByteData` 的 offset 陷阱**：必须 `asUint8List(offsetInBytes, lengthInBytes)` ——
   否则写出文件头不对 → `file is not a database`，**只在真机/真打包下暴露**

#### ✅ 验证

| 脚本 | 结果 |
|---|---|
| 🆕 `verify_worddb_bootstrap` | ✅ **22 项**（含「资产异常不写盘」的编排验证） |
| 🆕 `verify_pos_display` | ✅ **31 项** · **真库全量 47 种全识别** → 19 类 |
| `verify_worddb_sync` | ✅ **6 项** |
| `query_verify` 三脚本 | ✅ **42 / 37 / 49 项** |
| `tokens_verify` | ✅ **304 项**（+5 条浮层零粘土断言） |
| `trace_verify` | ✅ **97 项** |
| `analyze_inproc` | ✅ **error=3 / warning=13 / info=7**（76 文件 / 22,285 行） |

⚠️ 过程中修了 **2 个我引入的 error**（一度 5）：`library_directive_not_first` · `undefined_getter`（token 字段名是 `type`）。

#### ⏳ 只能真机看

首次落盘耗时 · **`assets/word.db` 是否真被 `rootBundle` 找到**（本地脚本不过打包链路）·
长按手感 · 浮层遮挡 · 三档可读性 · `ByteData` 的 offset 假设。

**请 `flutter run`**：进阅读器 → 长按 `vertical` → 点「查词」→ 应弹含 **音标 / 词性（`n.` 非 `[n]`）/ 释义 / 例句** 的浮层。

#### ⚠️ 仍未做（各有归属）

浮层→复习卡片入口 & 聚合页 → **3.7**｜「＋ 加入生词本」→ **3.4c**｜浮层 🔊 朗读（四要素未提，且属 `flutter_tts` 另一端）→ 未放｜
`external_word_cache` → Phase 3｜阅读设置面板 → 独立批次｜`word.db` 排除 iCloud 备份 → 需平台通道，未做

---

---

### 3.31 ✅ 交互收敛：长按即弹浮层（白哥 2026-09-27 15:37）

> 完整记录：📄 `docs/review/step3-reader-plan-2026-09-27.md` **§十三 · §十四**

| 白哥反馈 | 处置 |
|---|---|
| `Ctrl+Shift+M` 弹出的是 Chrome 账号登录 | ✅ 查清＝**Chrome 浏览器级快捷键被抢**（DevTools 无焦点）→ 改「点手机图标」或 `Ctrl+Shift+P`；**并实测确认 Chrome 设备模拟能绕过「长按不认鼠标」**（引擎按 `pointerType` 映射） |
| 长按没有弹出 | ✅ 白哥换路径后**确认弹出正常** —— 前一版的代码本身是对的 |
| 「中间的『查词』是多余的」 | ✅ **删掉 `_LookupToolbar`**，长按即弹浮层（3 步 → 1 步）｜`reader_screen` 521 → **501 行** |

#### 🔑 三条本轮新增的认知

1. **防抖不是优化，是正确性** —— 查 SDK 源码确认 `_handleTouchLongPressMoveUpdate` 里**每次都调**
   `_updateSelectedContentIfNeeded()`（→ 触发 `onSelectionChanged`）→ 不防抖的话，
   一次「长按 + 拖动微调」会打**十几次 SQLite** + 弹**十几个浮层** → 加 **300ms 防抖**
2. 🔴 **「剥首尾标点」被实测否掉** —— 我第一版加了剥离首尾非字母数字的清洗，**然后去查了词库**：
   **`a.m.` / `dr.` 本就以句点结尾**（剥了反而查不到）· **`café` 会被 `[^A-Za-z0-9]` 毁成 `caf`**
   → 🔑 **分层结论：UI 层只做「去空白」；标点/宽松匹配属查询层**（它才知道词库里有什么）
3. **两个「关工具栏」的层次不能混** —— `main.dart` 关的是**浏览器原生菜单**，
   `contextMenuBuilder: (_, __) => SizedBox.shrink()` 关的是**Flutter 自己的工具栏**

#### ⚠️ 已知边界（未修 · 已记录）

拖动手柄会把标点带进来（`vertical,`）→ 会提示「词库里没有『vertical,』」。
修法＝查询层加「精确 → 剥标点」两段查（要同步 `verify_word_query`）→ **独立一批**。
📌 主路径不受影响（长按默认选中就是一个词）。

#### ✅ 验证

`analyze_inproc` **error=3/warning=13/info=7** ｜ `query_verify` **6/22/31/42/37/49** ｜
`tokens_verify` **304** ｜ `trace_verify` **97** ｜ 残留引用 `_LookupToolbar`/`ValueNotifier`/`_picked` **均 0**

🆕 **另备好更可靠的真机验证路径**：Android 环境实测齐备（WHPX 可用 · image `android-36.1` ·
licenses · JBR 21）→ **已创建 AVD `coeo_phone`** → `flutter run -d android`
（⚠️ 首次 Gradle 10–30 min，之后秒级；这是 **Windows 上唯一能产生真触摸事件的路径**）

---

---

### 3.32 ✅ 修「词库不可用」：预热的真 bug + 文案分层（白哥 2026-09-27 15:58）

> 完整报告：📄 `docs/review/word-db-readiness-gap-2026-09-27.md`

#### 🔴 白哥反馈「弹窗显示词库正在整备」→ 查出**三个独立成因**

| # | 成因 | 性质 |
|---|---|---|
| **A** | **web 上永久不可用** —— `sqflite 2.4.1` 只声明 `android/ios/macos` · `path_provider` 无 web · `dart:io` 在 web 是 stub | ⚠️ 平台限制（**非 bug**） |
| **B** | 🔴 **provider 从未预热** —— 全项目仅 `ref.read`，**无任何 `ref.watch`**（而两处注释**都声称**是 watch；`bookmarkProvider` 用的是 watch） | 🔴 **真 bug（我的）** |
| **C** | 「正在准备」把 A/B **混成一句** | 文案缺陷 |

🔑 **B 被 A 掩盖了** —— web 上 provider 本就必然失败，所以「第一次查词拿不到」在 web 上看不出来。
**这是「在错误的平台验证」的又一类形态：错误平台的错误，会掩盖真平台的错误。**

**B 的后果（真机同样发生）**：进阅读器**不启动**落盘 → 第一次长按那一刻 future 刚启动
→ `valueOrNull` 必然 null → **第一次查词 100% 失败**，而文案说「请稍候」，用户以为是自己点太快。

#### 修复（白哥选「修 B + C」）

- **B**：`reader_screen.build` 加 **`ref.watch(wordQueryProvider)`** → 进阅读器即开始落盘
- **C**：`WordDbLoad` 改 **sealed class**（`Ready` / `Unsupported` / `Failed`）→
  **类型层面消除「有结果但没 service」的非法状态**，且 `switch` **编译器强制穷尽**；
  **web 上提前返回 `Unsupported`**（不做注定失败的尝试）
- 四种「拿不到词卡」文案各自准确（含**能不能等**）：平台不支持 / 打开失败 / 正在准备 / 词库里没有

#### 🔒 新增 4 条断言（`tokens_verify` §12 · 304 → **308**）

含一条**防回归锁**：「阅读器 watch 了 wordQueryProvider（**不能只 read**）」——
🔑 **它极易回归**（有人为了省一次 rebuild 改回 `read`），而后果「第一次查词 100% 失败」
**在 web 上看不出来** → **凡「改坏了在开发环境看不出来」的约束，都该用断言锁住**。
✅ 并**故意把 watch 改回 read 验证过它真会红**（报「实现类失败 1 项」），恢复后全过。

#### ✅ 验证

`analyze_inproc` **error=3/warning=13/info=7** ｜ `tokens_verify` **308** ｜
`query_verify` **6/22/31/42/37/49** ｜ `trace_verify` **97** ｜ 旧 API（`serviceOrNull`）残留 **0**

#### 📌 Web 端限制的完整清单（都不是 bug，都是「产品不做 web」的后果）

| 层 | 限制 | 处置 |
|---|---|---|
| 手势 | 长按不认鼠标 | ✅ Chrome 设备模拟绕开 |
| 系统菜单 | web 显示浏览器原生菜单 | ✅ debug-only `disableContextMenu()` |
| **数据层** | **无本地 SQLite** | ✅ **本轮给准确提示**（不再谎称「请稍候」） |

→ **web 只能验证「UI 与手势链路」，验证不了「数据层」**。真实查词须用 **Android 模拟器**（AVD 已建）或 iPhone。

#### ⏳ 待真机验证
「进阅读器 → 立刻长按 → 应弹**词卡**（而非「正在准备」）」· 首次落盘耗时是否被预热吸收
（读正文的几秒是否够写 31.4 MB）· `assets/word.db` 是否真被 `rootBundle` 找到

---

---

### 3.33 🔴 Step 3 解阻：删掉阻断原生构建的 web 录音代码（白哥 2026-09-27 19:55）

> 完整报告：📄 `docs/review/android-build-blocker-web-only-2026-09-27.md`

#### 触发
白哥「`flutter build apk --debug` 运行超过 1 个小时，正常吗」→ **不正常，而且它不是慢，是已失败**：

```
lib/screens/chat/chat_input.dart:221:10: Error: Undefined name 'context'.
lib/widgets/review_card_widget.dart:181:25: Error: Undefined name 'JsFunction'.
FileSystemException(uri=org-dartlang-untranslatable-uri:dart%3Ajs ...)
Execution failed for task ':app:compileFlutterBuildDebug'.
BUILD FAILED in 1h 26m 4s
```

#### 根因：`dart:js` / `dart:html` 在非 web 平台**编译期**不可用
浏览器端**录音**代码（`MediaRecorder` + `ScriptProcessor` → WAV base64 → `/api/stt/transcribe`）。

#### 🔴🔴 最重要的教训：把 `error` 当「基线」= 把故障当正常
`analyze_inproc` **过去 5 轮都在报**这三条，规则文本里**就写着「→ iOS/Android 编不过」**，
而我每轮都写「error=3 —— **与基线逐项一致**」。

> 🔑 **「与基线一致」只是「和上次一样」。基线里装着 error 时，它等价于「故障依旧」。**
> → **基线必须分层**：`error` = 已知故障（❌ 不可接受）· `warning`/`info` = 噪音（✅ 可作基线）

**已按白哥批准改为：`error` 必须为 0，不为 0 就当场排查。**

#### 修复（净减 **−417 行**）

| 文件 | 改动 | 行数 |
|---|---|---|
| `lib/screens/chat/chat_input.dart` | **重写**：删 `dart:js` + 7 处调用 + 语音字段/方法/UI；→ **`StatelessWidget`**（删后无状态） | 348 → **85** |
| `lib/widgets/review_card_widget.dart` | 删 `dart:html`（**0 使用**）+ `dart:js` + `dart:async` + `http`（均仅语音用）+ 6 字段 + 4 方法 + build 语音 UI + `TickerProviderStateMixin`（**0 个 AnimationController**） | 846 → **692** |

🔑 **为什么这不是「删功能」而是「卸包袱」**：① 它在 **iOS 上原理上不可能工作**（依赖浏览器 MediaRecorder）
② 当前**用户不可达**（chat 入口已在 3.1 移除）③ 与已定案的 **`flutter_tts` 全量端侧**冲突 ④ 产品**只做 iOS**
→ ∴ 删除**不损失任何现有能力**，它在目标平台上**从未生效过**。
⚠️ 将来 AI 考核若需语音输入 → 用 **iOS 原生录音插件**实现，**不是恢复这段代码**。

#### 🔑 一条技术判据（本轮最容易走错的一步）

**`kIsWeb` 守卫解决不了这个问题** —— `import 'dart:js'` 是**编译期**错误：
```dart
if (kIsWeb) { js.context.callMethod('__coeStart'); }   // ❌ 一样编不过
```
> 🔑 **判据：「这个错误是编译期还是运行期？」**
> 编译期（缺符号 / 平台不支持的库）→ `if` 守卫**无效**，必须改**结构**（删 / 条件导入 / 换实现）

#### ✅ 验证

| 项 | 改前 | 改后 |
|---|---|---|
| **`analyze_inproc`** | error=**3** / info=7 | ✅ **error=0** / info=4 |
| 残留扫描 | — | `js.`·`html.`·`_voiceMode`·`Timer`·`http.` **全 0** |
| `tokens_verify` / `trace_verify` | 308 / 97 | ✅ **308 / 97** |
| `query_verify` 六脚本 | 6/22/31/42/37/49 | ✅ **6/22/31/42/37/49** |

#### ⏳ 下一步
重新 `flutter build apk --debug`（Gradle 缓存已就绪 → 预期**快得多**）→
**先 `unzip -l` 查 `word.db` 是否进包**（不需设备）→ 再装模拟器验证查词。

---

## 四、下一步建议（按依赖排序 · 已按白哥 2026-09-26「按计划进行」开始执行）

> **修订说明**：初版把 P0 写成「建 `codemagic.yaml`」——**已改为「扩展已有的 GitHub Actions」**
> （原因见 §3.3 更正：CI 已存在，且 GHA 自带 macos runner，无需引入第二个 CI 平台）。

| 优先级 | 事项 | 为什么现在做 | 依赖 | 状态 |
|---|---|---|---|---|
| ~~✅ P0~~ | ~~🔴 **修 `taiwan`/`tibet` 释义**~~ | — | — | ✅ **已完成 2026-09-26 23:24** —— **P0 2 → 0**（见 §3.10） |
| ~~✅~~ | ~~**Step 2 设计系统落地**（token → 代码）~~ | — | — | ✅✅ **完成（§3.12–§3.19）**：token 层 · A′ 字体 · **旧主题删除 + `buildTheme` 接线** · **粘土渲染层**（四态 + 真 inset + 接入设置页）· **280ms 动效 + token 插值** → **验收 307 项全过** ＋ ✅ **`flutter run -d chrome` 真编译通过**｜⏳ 仅剩真机目视（非代码工作） |
| **P1** | **Phase 4 #1 `user.db` 接入** | 表结构 + 查询层已就绪（79 项断言过），差**落库接线** | — | ⏳ |
| **P2** | **Phase 3 内容抓取**（服务端 RSS） | 无内容 = 端侧没东西可读；可与 P1 并行 | — | ⏳ |
| **P2** | **Step 3 核心界面**（信息流/阅读器/**划词**） | 🔴 **最大工作量项** | Step 2 | 🟠 **已完成：3.0 清退 · 3.1 导航/首页/tabbar · 3.2 痕迹 · 3.3 收藏 · 3.4a 阅读器骨架**（§3.20·§3.21·§3.25·§3.27·§3.28）→ 下一步 **3.4b `word.db` 落盘 + 划词查词**（**最大未知**）｜🔑 **「跑起来看还是旧界面」已定位**：不是审美问题，是**页面调的后端接口已随 3.0 删除**｜🔴 **3.4 的缺口在数据层**：4 张表不存在 + 32.9 MB 预制库从未落盘 |
| **P3** | 🟠 **清理待办**：`fsrs5.rs` 删除 · 轮换泄漏 key · `data/` git 状态 · `marketing` key | 见 §五 风险 5/9/10 | — | ⏳ |
| **最后** | **Phase 0 Apple 账号**（$99/年） | 🟠 **白哥 2026-09-26 决定置末** —— 不阻塞当前开发；但**上架前必须办**（且 810 号令填报依赖它） | — | ⏳ **按白哥指示放最后** |
| ~~✅~~ | ~~打通验证链路~~ | — | — | ✅ **已完成**（CI 5 job + 进程内 analyzer + 纯 Dart 验收三层） |
| ~~✅~~ | ~~Step 1 清障~~ | — | — | 🟢 **主体完成**（删 17,205 行 · web-only **13→2** 且余下 2 个属「待重写」→ 并入 Step 3/4） |
| ~~✅~~ | ~~Phase 1 #10 卡片结构重组~~ | — | — | ✅ **已完成**（例句 → `context` 99.72%） |
| ~~✅~~ | ~~**`content_hash` 全库回填**~~ | — | — | ✅ **已完成 2026-09-26 23:40** —— 28.4% → **100%**（见 §3.11 ①） |
| ~~✅~~ | ~~**扫描器 `autonomous region` 误报**~~ | — | — | ✅ **已完成** —— 固化为**铁律 5「官方行政区划名 ≠ 主权主张」**（见 §3.11 ②） |
| ~~✅~~ | ~~**验收断言改 P0 零容忍**~~ | — | — | ✅ **已完成** —— **31 项全过**，新增 2 条强化负例（见 §3.11 ③） |

---

## 五、已识别但未解决的风险

| # | 风险 | 影响 | 状态 |
|---|---|---|---|
| ~~1~~ | ~~`dart:html` 13 处~~ | ✅ **已清 90%** —— **13 文件 → 2 文件**（3 处）；剩 2 个文件**本身就在「待删/待重写」范围内** | ✅ 见 §3.5 |
| ~~2~~ | ~~admin 未删（≈14,946 行）~~ | ✅ **已删完** —— app 内 admin **0 行** + **`app_admin` 整项目已删**（9,224 行） | ✅ 已解决 |
| ~~3~~ | ~~例句 type 错（在 `sense` 里）~~ | ✅ **已修复（2026-09-26）** —— 例句独立成 `context`（99.72%），`sense` 归零 | ✅ 已解决 |
| ~~4~~ | ~~`codemagic.yaml` 不存在~~ | ✅ **已更正 + 已补强** —— CI 存在（GHA）；本地快反馈已用 **结构检查 + 🆕 进程内 analyzer** 两层补上（§3.3） | ✅ 已解决 |
| 5 | 🟠 **`backend/.../fsrs5.rs` 仍在且算错** | 双实现会分叉 | 🔴 **实测确认仍在**（`crates/card_engine/src/fsrs5.rs` + `fsrs_scheduler.rs` 两文件）—— 已定删除，待做 |
| ~~6~~ | ~~词库内容合规~~ | ✅ **已修复（2026-09-26 23:24）** | ✅ **P0 2 → 0** —— `taiwan`/`tibet` 释义已改为符合官方立场的表述（同时同步 `content_hash`）· 见 §3.10 |
| 7 | 🟠 **`word_form` 两代口径并存**（36,856 vs 22,829） | 覆盖率指标口径不明 | 见 §六 偏差 1 |
| 8 | 🟠 **iOS 构建额度** | macOS runner 私有仓库按 **10x** 计费（2,000 分钟/月 → 实际 200 macOS 分钟） | 已改为手动/tag 触发 |
| 9 | 🟠 **本地产物污染 git 状态** | `data/coevo.db` 显示 `M` + 新增 `-shm`/`-wal`；`data/word.db` 未跟踪；`data/curriculum/*.json` 一批未跟踪 | 🔴 **实测确认** —— 待明确是否入库/忽略 |
| 10 | ⚠️ **安全隐患** | `marketing/scripts/v3/demo_run.py:41` 明文硬编码 key，**已被 git 跟踪** | 🔴 **实测确认目录仍在** —— 未处理 |
| 11 | 🆕 ⚠️ **术语歧义：`lemma` vs `spelling`** | `word.db` **无 `lemma` 列**（词元字段叫 **`spelling`**）；`lemma` 只是**代码里的概念/变量名**（`analyzeForm` → `LemmaResult.base`） | 🔴 **实测发现** —— 文档/记忆里「按 `lemma` 唯一」「`UNIQUE(lemma)`」易让人去找不存在的列 → 应标注消歧 |

---

## 六、已知偏差（文档 vs 实测）

### 偏差 1：`word_form` 有两代产物，口径不同

| 产物 | 条数 | 结构 | 出处 |
|---|---:|---|---|
| 旧映射表 | **36,856** | `form/lemma/rule/in_vocab/word_id` | `data/curriculum/prebuilt/word_form.json`（v1 时代，清洗后） |
| **新链式表** | **22,829** | `form/base/rule/kind/anchor/anchor_id/depth/in_vocab/action` | **`data/word.db.word_form`**（2026-09-26 落库） |

**新表实测分布**：`in_vocab=0` 21,545 / `in_vocab=1` 1,284 · `distinct base` 7,530 · `distinct anchor` 7,931 · `rule` 以 plural 6,901 / ing 6,856 / past 6,846 为主

🟠 **差异原因未查明**（可能是新表只收 base 在词表内的映射，或去重规则不同）。
🔴 **覆盖率指标（原 99.5%）是旧表口径，新表覆盖率未重测** → **待核实**。

### 偏差 2：`sections` 的结构与 v1 不符 —— ✅ **已修复（2026-09-26）**

**修复前**：`card.content.sections` 只有 `sense`（24,491 条）+ `root`（5,484 条）两种类型，
而 v1 §4.2 定义了 **8 种**；`sense` 是实现自创的。

**修复后**（Phase 1 #10 卡片重组，见 §一）：`definition` 11,523 · `context` 11,491 · `collocation` 11,437 ·
`etymology` 11,407 · `root` 5,484 · `cognate` 2,988 —— **`sense` 归零**，段类型与 v1 §4.2 对齐。
验收：`scripts/verify_card_structure.py` **13 项断言全过**（退出码 0）。

### 偏差 3：主方案 §八「当前状态」已过期

主方案（L3 文档）§八 仍写着「上架区域待重新确认」「词形映射 34,724 条 / 覆盖 97.6%」等 ——
**这些已被后续决策与实测取代**。→ **以本文档为准**，§八 仅作历史参考。

### 偏差 4：🆕 本地构建目标被 `pub get` 切换（本轮副作用 · **需白哥知晓**）

为解析新增的 `fsrs` 依赖，在 `app/` 执行了 `dart pub get --offline`（`FLUTTER_ROOT=D:\flutter`），
产生两处副作用：

| 位置 | 变化 | 影响 |
|---|---|---|
| `app/.dart_tool/package_config.json` | `flutter` 指向：`D:\flutter_flutter`（鸿蒙版）→ **`D:\flutter`（官方 3.41.1）** | 🟠 **本地构建目标的 Flutter 变了** —— 若原先用鸿蒙版构建，需重新 `pub get` 切回 |
| `app/pubspec.lock`（**git 跟踪**） | **16 个依赖版本变化** + 新增 `fsrs` / `meta` | 🟠 需确认是否接受（`vector_math 2.1.4→2.2.0` 等由新 Flutter 约束驱动） |

**背景（一个此前的交付缺陷）**：`app/pubspec.yaml` 自 2026-09-26 起声明 `fsrs: ^2.0.1`，
但**从未在 `app/` 内真正解析过**（当时的「解析通过」是在 `/tmp` 独立包验证的）
→ **app 在该状态下无法编译通过**（进程内 analyzer 首跑即报 `uri_does_not_exist: package:fsrs/fsrs.dart`）。
本次 `pub get --offline` 把它补齐。

🔴 **待白哥裁决**：本地 Flutter 目标用官方版还是鸿蒙版？（按「仅 iOS」的定位，**官方版是正确方向**）

**🔄 2026-09-26 晚补充（本轮第二次 `pub get --offline`）**：为移除 `sherpa_onnx` 再次执行，

| 项 | 结果 |
|---|---|
| `package_config.json` 的 flutter 指向 | ✅ **未变**（仍 `D:\flutter` 官方版）→ **无新增副作用** |
| `pubspec.lock` 本轮变化 | ✅ **纯 sherpa 移除**（9 个包：主包 + 8 平台变体），**无其他包变动** |
| SDK 约束 | ⚠️ `dart >=3.6.0→3.10.0` / `flutter >=3.27.0→3.38.0` —— 属**上一轮**副作用（由官方 3.41.1 驱动，非本轮） |

---

### 偏差 5：🆕 术语歧义 —— `lemma`（概念）vs `spelling`（列名）

**实测（2026-09-26 核对）**：`data/word.db` **全部 19 张表都没有 `lemma` 列**（`PRAGMA table_info` 逐个扫过）。

| 名字 | 实际身份 | 出现位置 |
|---|---|---|
| **`spelling`** | 🔴 **数据库列名**（词元字段） | `word.spelling` · `card_review_state.spelling` · 索引 `idx_crs_spelling` |
| **`lemma`** | 🟠 **代码里的概念/变量名** | `word_query_service.dart`：`analyzeForm()` → `LemmaResult.base`（词形归并结果） |

🔴 **为什么必须写下来**：文档与记忆里多处说「**生词本按 `lemma` 唯一**」「`UNIQUE(lemma)`」，
后人若按字面去 `word.db` 找 `lemma` 列会**找不到**（我已踩过：查询直接报 `no such column: lemma`）。
> 🔑 **准确表述**：词元唯一性由 **`word.spelling`（`COLLATE NOCASE`）** 承载；
> 「按 lemma 唯一」是**概念描述**，落地列名是 **`spelling`**。

---

## 七、一句话总结

> **词库（Phase 1）收口** ✅（11/11 · 合规扫描器已建 · ✅ **`taiwan`/`tibet` 两处 P0 已修并验证** ——
> 本段曾记「未修」，属旧时点，**已过时**；现措辞为「台湾海峡 / 台湾人；台湾的 / 西藏自治区 / 青藏高原」）·
> **TTS 链路收口** ✅（全量端侧 `flutter_tts`，Phase 2 取消）· **端侧 MVP 只完成内核**（14 项完成 2 项）🟠 ·
> **~~语音包~~（已取消）/ 内容抓取 / 变现 / 资质都还没开始** ⏳
>
> **Step 1 清障主体已完成（§3.5）**，**Step 2（设计系统）与 Step 3 主体（核心界面）均已完成** ✅
> （本段曾写「堵点在 Step 2/3」「界面要从零写」「划词查词仍 0 命中」「界面层尚未开始」——
> 那些都是 **09-26 时点**的描述，**现已全部过时**：web-only 已归零 · 划词/信息流/阅读器/收藏清单均已建并**真机验证**）
>
> **Step 3 剩余**：`3.4c`（`user_word`/`lookup_event` 查词写入，**表尚未建**）→ `3.6 复习页` → `3.7 复习卡片 + 聚合页`
> → 之后是 **Phase 3 内容抓取** · **Phase 5 变现** · **Phase 0 Apple 账号**（放最后）
>
> （验证链路已在 §3.3 更正并补强：本地结构检查 + 纯 Dart 验收 + CI 三层，**不需要 Codemagic**。）
>
> **已做**：内核（FSRS 服务层 · 查询层 · 端侧 TTS · 词库）+ **界面层（Step 3 主体，已真机跑通）**。

---

**下一步见 §四**（单一来源，避免两处维护同一份信息）。

*本文档为进度快照，随工作推进会更新。所有状态均标注了实测证据；无证据的一律标 ⏳ 未开始。*
*🔍 **数字核对请以顶部「实测核对快照」为准**（该节含命令，可复现）。*

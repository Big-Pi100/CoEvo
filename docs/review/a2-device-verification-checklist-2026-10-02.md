# A2 真机验证清单（2026-10-02）

> **给白哥照着跑** · 目的：把「只有真机能回答」的问题一次问清。
> 代码侧已全绿（`resolution` 95 文件 0 error / `tokens_verify` 643 项 / `query_verify` 15 个脚本）。
> **本轮没有改任何与验证无关的代码**（只补了 `device_id`）。
>
> ⚠️ 本清单**只描述怎么验**。发现的问题分两类：能当场判定的写在 §5，需要你拍板的写在 §6。

---

## 〇、前置：构建时必须注入 API 地址

🔴 **不注入就会连 `localhost:8080`**（`api_config.dart` 的默认值）→ 表现为「划词后提示连不上服务」。

```bash
cd app
# 真机（USB 连接，Debug 即可 —— A2 的行为与 build mode 无关）
flutter run -d <你的设备 id> \
  --dart-define=API_HOST=api.keyievolution.fun
# 可选：分享链接用的域名（本清单用不到）
#   --dart-define=PUBLIC_BASE_URL=https://keyievolution.fun
```

**先验这一步成功**（否则后面全白跑）：

> 打开 App → 首页应有内容流。
> 若首页空 + 有报错 → API 地址没注入对，**先解决这个**。

📌 `api_config.dart` 的头注释里还写着 `flutter build web` 与旧 IP `<OLD_VPS_IP>`
—— 与「仅 iOS」「api 子域」矛盾，属**语义残留**。✅ **本轮已清**（见 §5-C）。

---

## 一、基线（跑之前先记下）

我实测了两端的当前状态 —— 跑完对照，就能**确证**数据真的走通了：

| 位置 | 查什么 | **当前值（基线）** |
|---|---|---|
| 服务端 `/opt/coevo/data/coevo.db` | `generated_card_cache` 行数 | **0** |
| 同上 | `generated_card_hit` 行数 | **0** |

查询命令（只读，可随时重跑）：

```bash
ssh -i ~/.ssh/coevo_key ubuntu@<VPS_IP> 'python3 -' <<'PY'
import sqlite3
c = sqlite3.connect('file:/opt/coevo/data/coevo.db?mode=ro', uri=True)
for t in ('generated_card_cache', 'generated_card_hit'):
    print(t, c.execute(f'SELECT COUNT(*) FROM {t}').fetchone()[0], '行')
print('明细:')
for r in c.execute('SELECT spelling, device_id, hit_count FROM generated_card_hit'):
    print('  ', r)
for r in c.execute('SELECT spelling, hit_count, distinct_user_count, contract_version FROM generated_card_cache'):
    print('  ', r)
PY
```

---

## 二、三个「只有真机能回答」的边界

### 边界 ① `rootBundle` 能否读到 `assets/word_db.version`

**为什么只有真机能答**：`rootBundle` 在真机走的是打包后的 asset bundle，
桌面 `/dart` 或 `flutter test` 的环境**不具代表性**。而**漏声明 asset 不报错**，
只会静默退化成「按文件大小判定」。

| 步骤 | 期望 |
|---|---|
| 1. 冷启动 App（杀进程后重开） | — |
| 2. 看日志里 `[word_db]` 那一行 | 应形如 `[word_db] 跳过：版本与大小都相同（11523+65cd2ea4 · 31.5 MB）` |
| 🔴 **失败的样子** | 日志出现 `[word_db] 读不到版本号资产（…）→ 退回按文件大小判定` ⇒ **asset 没打进包** |

**判定依据**：日志里**要么有版本号 `11523+65cd2ea4`，要么有那句「读不到」**。
两样都没有 = 这行日志没走到（另一回事，报我）。

### 边界 ② 转圈浮层的**关闭时序**

**为什么只有真机能答**：这是纯时序问题（`showDialog` 的 push 需要一帧，
而请求可能比一帧还快）—— **文本断言验不了**（项目已有教训：
文本断言的上限是「写了」，「会执行到」只能真跑）。

| # | 场景 | 期望 |
|---|---|---|
| 2a | **正常网**：划一个词库外的词（如 `brainstorm`） | 转圈出现 → 词卡浮层出现；**转圈消失** |
| 2b | 🔴 **断网**（开飞行模式）：划一个**没查过**的词库外词 | 转圈 → 提示「连不上服务…」；🔴 **转圈必须消失** |
| 2c | 同一词再划一次（走端侧缓存） | **不出现转圈**，直接弹词卡 |

🔴 **2b 是重点**（这一项**曾经会失败**，现已修）：见 §5-A ——
它触发过**转圈浮层永久卡住**的真 bug（**本轮已修**，见 §5-A）。
✅ 所以 2b 现在是一条**回归验证点**：**它必须过**；不过就是把 bug 改回来了。

### 边界 ③ 真实联网往返

| # | 场景 | 期望 |
|---|---|---|
| 3a | 划词库外的词，首次 | 转圈 → 词卡（含音标/释义/例句）→ 与词库内词的浮层**长得一样** |
| 3b | 立刻查**服务端**：`generated_card_cache` | 从 1 行开始有记录；`hit_count=1`、`distinct_user_count=1`、`contract_version='v6'` |
| 3c | 换一个词库外词，重复 3b | 又 +1 行 |
| 3d | 同一词**第二次**划（先用 2c 确认走缓存 → 见下） | 服务端 `hit_count` 应为 **2**（若第二次仍走网络的话） |

⚠️ **3d 的前提**：端侧缓存命中时**根本不发请求**（`_lookupExternalWord` 先读缓存）→
所以正常顺序下 `hit_count` 不会到 2。**要测 hit_count 递增**，
需要用**另一台设备**（或清掉 App 数据）查同一个词。

---

## 三、A2 端到端：词库外的词**真的进了生词本与复习队列**

这是 A2 的**验收标准**（不只是「能看到卡」）。

| # | 操作 | 期望 |
|---|---|---|
| 4a | 划 `brainstorm`（词库外）→ 看词卡 | 显示正常 |
| 4b | 打开「生词本」 | 🔑 有 `brainstorm` 这一条 |
| 4c | 进「复习」 | 🔑 队列里有它（说明 `card_review_state` 也写了） |
| 4d | 给它评一次级 | 不报错；卡片进入下一轮调度 |
| 4e | 杀掉 App → 重开 → 进复习 | 🔴 **它还在**（证明落盘成功，不是只存在于内存）|
| 4f | 划一个**词库里已有**的词（如 `absurd`）| 与 4a 的浮层**完全同款**（不应有「另一种卡」）|

---

## 四、device_id（本轮新增）

**为什么加它**：服务端靠它算 `distinct_user_count` —— 那是 **A3 回流门槛的真信号**
（`hit_count` 只累计，去重不了：「一人刷 100 次」与「100 人各 1 次」在它眼里一样）。

| # | 查什么 | 期望 |
|---|---|---|
| 5a | 跑完 3b 后，服务端 `generated_card_hit` 的 `device_id` | 🔑 **非空、形如 `dev_` + 32 位小写 hex** |
| 5b | 同一设备再查**另一个**词库外词 | `generated_card_hit` 出现第二行，且 `device_id` **与 5a 完全相同** |
| 5c | 端侧 `review_log.device_id`（跑完 4d 后） | 🔑 **不再是空串**（升级前写的是 `''`）|
| 5d | **退出登录 → 再查一次词库外词** | 🔴 `device_id` **必须不变**（证明退出登录没有连带清掉它）|

**5d 特别说明**：`auth_provider.logout()` 用的是 `prefs.remove('display_name')`
（精确删单键，**不是 `clear()`**）→ 目前安全。已加断言守这条（`tokens_verify` §20），
但**真机跑一次更硬**。

📌 **语义提醒**：它是**设备**标识，不是**用户**标识 —— 换设备/卸载重装会得到新 id
（服务端会算成另一个「用户」）。这对「去重」而言是**正确**语义，但回流门槛设计时要知道：
**门槛卡的是「不同设备数」，不是「不同人数」**。

---

## 五、曾当场判定的三项（**均已处理** · 2026-10-02）

### A. ✅ **已修**：转圈浮层的关闭时序 bug

**根因**（`reader_screen.dart` 的 `_showGenerating`）—— 原写法：

```dart
unawaited(showDialog(... builder: (c) { dialogCtx = c; ... }));   // builder 在**下一帧**才跑
return () async {
  await Future<void>.delayed(Duration.zero);   // ⚠️ 只让出事件循环 ≠ 过了一帧
  final c = dialogCtx;
  if (c != null && c.mounted) Navigator.of(c).pop();   // c == null 时**静默什么都不做**
};
```

**链条**：`showDialog` → `Navigator.push` → dialog 要**下一帧**才 build →
而 `Future.delayed(Duration.zero)` 是 `Timer(0)`（≈ 0 ms），**不保证渲染帧已跑**（~16 ms）→
若「请求比一帧还快返回」（断网/连接被拒/DNS 失败，HTTP 可能几毫秒就失败）
→ 关闭函数执行时 `dialogCtx` 仍是 `null` → **不 pop** → dialog 随后才出现 →
**永久留在屏幕上**。

**后果被两个设置放大到「必须杀 App」**：`barrierDismissible: false` + **仅 iOS**（无系统返回键）。

**✅ 修法**（已实施）：等「builder **真的执行过**」这个**条件**（`Completer`），
并用**有界超时**（3 s）兜底；`showDialog` 的 future 完成时也解除等待。
🔑 一般化：**`等一个猜的时长` ＜ `等一个条件成立`**（与 flaky test 的经典修法同一条：
**永远不要 sleep，要等状态**）。

**断言**：`tokens_verify` §21（7 项）—— 禁止 `Duration.zero` · 必须有 `Completer` ·
`complete` 必须在 `builder` 里（**紧跟记录 context 之后**）· 必须有有界超时 · 必须有兜底解除。
**证伪**：退回 `Duration.zero` → 红 3 项；把 `complete` 挪出 builder → 红 1 项（其余 650 项仍绿）。

📌 **但这一类的最终防线是 §2b（真机断网真跑）** —— 文本断言只能证明
「不再用猜的时长、且用了条件等待」，证不了「那条路径真的不会卡」。
**§2b 请务必跑**。

### B. ✅ **已删**：`assets/` 下两个 32 MB 冗余备份

删前核实（删之前三问）：
| 问 | 答 |
|---|---|
| 会不会被当作交付物？ | ❌ 未在 `pubspec.yaml` 声明 → 从不进包 |
| 有没有脚本引用？ | ❌ 穷尽 grep：无任何代码/配置引用 |
| 删了能不能恢复？ | ✅ **能** —— `data/` 下有**同名且 md5 完全相同**的副本（`d76c3d22…` / `81f5da72…`）|
| 有没有「只在此备份里」的内容？ | ❌ 词集合与当前库**完全一致**（各 11,523），**无独有词** |

⇒ 确认是**纯冗余副本**后删除。`app/assets/` 现在正好只剩 pubspec 声明的 4 项。

### C. ✅ **已清**：`api_config.dart` 的过时注释

原写着 `flutter build web`（项目**仅 iOS**）+ 旧 VPS IP `<OLD_VPS_IP>`
+ 主域（现在 API 走 `api.` 子域）。已改写为当前实况（含真机连生产后端的命令），
并把旧写法标为**已作废**（保留一小段说明，防后人照抄）。
⚠️ `docs/` 下仍有 **108 处**旧 IP（多数在 Web 时代的部署文档里）——
那是**历史文档**，未擅自改，见 §八。

---

## 六、失败时的排查顺序

| 现象 | 先看哪 |
|---|---|
| 首页空 / 划词提示「连不上服务」 | `--dart-define=API_HOST` 有没有生效（§〇）|
| 划词后**什么都不发生** | 日志有无 `[user_word]` / `[generate_card]`；`_hint` 是否被浮层遮住 |
| 🔴 **转圈一直转、退不掉** | 若已含本次修复仍复现 → 把现象/机型/网络状态报回来（这是 §5-A 的兜底验证失败）|
| 提示「该词暂不支持生成」 | 服务端**合规闸门**拒了 —— 换一个常见词再试（这不是 bug）|
| 提示「正在生成中，请稍后重试」 | 正常（别人正在生成同一个词）→ **过几秒重试应成功** |
| 词卡显示但生词本没有 | 查 `[lookup]` 日志；`_writeBackLookup` 是 `unawaited`（**有意**：不阻塞展示）|
| 服务端两张表都是 0 | 请求**没到服务端** → 先确认 §〇 与 §3b |

---

## 七、本轮为了「能验」而做的改动（都在代码里）

| 项 | 内容 |
|---|---|
| 🆕 `device_id` | `services/device_id.dart`（纯逻辑 + 单飞）+ `providers/device_id_provider.dart`；接入**制卡请求**与**复习日志** |
| 🔴 修时序 bug | `reader_screen.dart` 的 `_showGenerating`：「等零时长」→「等条件（`Completer`）+ 有界超时」（§5-A）|
| 断言 | `verify_device_id.dart`（**47 项**）· `tokens_verify` §20（**17 项**接线与边界，含「logout 不许 `clear()`」）· §21（**7 项**时序）|
| 修过时引用 | `fsrs_service.dart:220` 原指 `verify_review_log.dart`（**该文件不存在**）→ 改为 `verify_review_list.dart`【13】|
| 🔧 修断言工具 | `_braceBody` 的返回类型正则不认 `Future<void> Function()` → 切错区间（**切片函数本身漏了**，它注释里警告过的同类坑）→ 补「返回函数类型」形态 |

**证伪记录**（证明断言不是假的）：
- 把 `isDeviceId` 当「已存值是否可用」的门槛 → 红 2 项（会**换掉用户身份**）
- 破坏单飞 → 红 3 项（同机留下多个 id）
- 读失败时静默生成新的 → 红 2 项（偶发故障即换身份）
- 去掉 `deviceId: deviceId` 实参 + `logout` 改用 `prefs.clear()` → 恰好 2 项红、其余 641 项仍绿
- 时序退回 `Future.delayed(Duration.zero)` → 红 3 项；把 `complete` 挪出 `builder` → 红 1 项

---

## 八、顺带发现、**未处理**（等你的决定）

| # | 发现 | 说明 |
|---|---|---|
| 1 | 🔴 **`data/backups/` 已堆积 ~498 MB** | 其中 20+ 个 word.db 历史快照（09-25 ~ 09-29 的各阶段中间态，单个 17–33 MB）。多数已**被当前库覆盖**（当前库含全部 11,523 词）。**要不要清理**？我建议保留最近 2–3 个 + 删掉更早的，但**不擅自动** |
| 2 | `docs/` 下 **108 处**旧 IP `<OLD_VPS_IP>` | 集中在 `docs/deploy/`（`web-deploy-guide.md` 53 处 · `maintenance-spec.md` 17 处 · `deployment-guide.md` 12 处）。⚠️ **「web-deploy-guide」整篇都已过时**（项目不做 Web）→ 建议整篇标作废而不是逐行改 IP |
| 3 | `tts_service.dart:111` 的 100 ms 延时 | `stop()` 后等 100 ms 再 `speak()` —— 绕第三方库竞态，是**同类判据**（用猜的时长）的另一个实例。**不同之处**：`flutter_tts` 没给就绪回调，且有 `myGen` 代检查兜底 → 属**不得已**。改它需要真机测 TTS，**未动** |
| 4 | `app/build/` 下有构建产物 | 正常（构建输出），但 `flutter clean` 可回收。未动 |

**§八-1 与 §八-2 都是「存量不清理」的同族** —— 旧东西留着会持续吸引新用途
（部署文档的旧 IP 会被人照抄、旧备份会被误当权威）。建议排一次专门的清理，
但**不在本轮**。

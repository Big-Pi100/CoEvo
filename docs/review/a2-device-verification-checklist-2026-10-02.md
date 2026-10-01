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
—— 与「仅 iOS」「api 子域」矛盾，属**语义残留**（清单 §5 已列，待你定是否本轮清）。

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

🔴 **2b 是重点**：见 §5-A —— 我判定这里有**真 bug**，很可能就是这个场景触发。

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

## 五、我能当场判定的（附实测依据）

### A. 🔴 **转圈浮层可能永久卡住**（我判定是真 bug，建议先修再验 2b）

**根因**（`reader_screen.dart:697` 的 `_showGenerating`）：

```dart
unawaited(showDialog(... builder: (c) { dialogCtx = c; ... }));   // builder 在**下一帧**才跑
return () async {
  await Future<void>.delayed(Duration.zero);   // ⚠️ 只让出事件循环 ≠ 过了一帧
  final c = dialogCtx;
  if (c != null && c.mounted) Navigator.of(c).pop();   // c == null 时**静默什么都不做**
};
```

**链条**：`showDialog` → `Navigator.push` → dialog 要**下一帧**才 build →
而 `Future.delayed(Duration.zero)` 只让出事件循环（≈ 0 ms），**不等渲染帧**（~16 ms）→
若「请求耗时 < 一帧」，关闭函数跑时 `dialogCtx` 仍是 `null` → **不 pop** →
随后 dialog 才 build 出来 → **永久留在屏幕上**。

**触发条件**：`barrierDismissible: false`（配置里就是这么设的）+ **iOS**
（无系统返回键可退）→ 用户**只能杀 App**
⇒ 项目**仅 iOS**，所以这个后果是实打实的。

**最可能的触发场景**：**断网/连接被拒/DNS 失败**（HTTP 可能几毫秒就失败）→ 正好是 §2b。

**修法**（我建议的，最小改动）：把「等零延时」换成**等 dialog 真的挂载**
（`Completer` + 有界超时），而不是「等一个事件循环」：

```dart
final mounted = Completer<void>();
... builder: (c) { dialogCtx = c; if (!mounted.isCompleted) mounted.complete(); return ...; }
... showDialog(...).whenComplete(() { if (!mounted.isCompleted) mounted.complete(); });
return () async {
  await mounted.future.timeout(const Duration(seconds: 3), onTimeout: () {});
  final c = dialogCtx;
  if (c != null && c.mounted) Navigator.of(c).pop();
};
```

📌 **状态**：**未改**（按规矩先报后动）。**建议先修再跑 §2b** ——
否则验证会卡在那个场景上。除此外它不影响其它项。

### B. `assets/` 下有两个 32 MB 的本地垃圾

`word.db.bak-priority-redo-20260928-182159` 与 `-194116`（各 ~32 MB）。
**未在 `pubspec.yaml` 声明** → **不会进包**（所以不影响交付物体积），
但白占 ~64 MB 磁盘。**要不要删**（属你的决定，我不动）。

### C. `api_config.dart` 的头注释已过时

写着 `flutter build web`（项目**仅 iOS**）+ 旧 VPS IP `<OLD_VPS_IP>`
+ 主域 `keyievolution.fun`（现在是 `api.` 子域）。同「文档与代码漂移」那一类。

---

## 六、失败时的排查顺序

| 现象 | 先看哪 |
|---|---|
| 首页空 / 划词提示「连不上服务」 | `--dart-define=API_HOST` 有没有生效（§〇）|
| 划词后**什么都不发生** | 日志有无 `[user_word]` / `[generate_card]`；`_hint` 是否被浮层遮住 |
| 提示「该词暂不支持生成」 | 服务端**合规闸门**拒了 —— 换一个常见词再试（这不是 bug）|
| 提示「正在生成中，请稍后重试」 | 正常（别人正在生成同一个词）→ **过几秒重试应成功** |
| 词卡显示但生词本没有 | 查 `[lookup]` 日志；`_writeBackLookup` 是 `unawaited`（**有意**：不阻塞展示）|
| 服务端两张表都是 0 | 请求**没到服务端** → 先确认 §〇 与 §3b |

---

## 七、本轮为了「能验」而做的改动（都在代码里）

| 项 | 内容 |
|---|---|
| 🆕 `device_id` | `services/device_id.dart`（纯逻辑 + 单飞）+ `providers/device_id_provider.dart`；接入**制卡请求**与**复习日志** |
| 断言 | `verify_device_id.dart`（**47 项**）+ `tokens_verify` §20（**17 项**接线与边界，含「logout 不许 `clear()`」）|
| 修过时引用 | `fsrs_service.dart:220` 原指 `verify_review_log.dart`（**该文件不存在**）→ 改为 `verify_review_list.dart`【13】|

**证伪记录**（证明断言不是假的）：
- 把 `isDeviceId` 当「已存值是否可用」的门槛 → 红 2 项（会**换掉用户身份**）
- 破坏单飞 → 红 3 项（同机留下多个 id）
- 读失败时静默生成新的 → 红 2 项（偶发故障即换身份）
- 去掉 `deviceId: deviceId` 实参 + `logout` 改用 `prefs.clear()` → 恰好 2 项红、其余 641 项仍绿

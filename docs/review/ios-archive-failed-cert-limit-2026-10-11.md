# iOS 出包失败：Apple 账号证书达上限（2026-10-11 12:11）

> 触发：白哥「IOS 可以出包了」→ run **38110797295** → `Archive` 步骤 **exit 65**。
> **结论：不是代码问题**，是 **Apple 开发者账号侧的证书上限**。
> ⚠️ 仓库**已立刻改回 private**（复核 `isPrivate: true` ✅）。

---

## 一、失败现象（CI 原文）

```
Archive & Export IPA   Archive   ** ARCHIVE FAILED **

app/ios/Runner.xcodeproj: error: Choose a certificate to revoke.
    Your account has reached the maximum number of certificates.
    To create a new one, you must choose a certificate to revoke.
    (in target 'Runner' from project 'Runner')

app/ios/Runner.xcodeproj: error: No profiles for 'com.coevo.coevoApp' were found:
    Xcode couldn't find any iOS App Development provisioning profiles
    matching 'com.coevo.coevoApp'. (in target 'Runner' from project 'Runner')

The following build commands failed:
    Archiving workspace Runner with scheme Runner
(1 failure)
##[error]Process completed with exit code 65.
```

## 二、为什么可以断定**与代码无关**（三条独立证据）

| # | 证据 |
|---|---|
| 1 | 失败发生在 **`Archive` 的签名阶段**（`Choose a certificate to revoke`），**不是编译阶段** |
| 2 | **同一 run 里 `Build Flutter artifacts` ✓ 通过** ⇒ Dart 编译没问题；本机 `analyze_inproc` 也 **error = 0** |
| 3 | **前 4 次出包（09:54 / 21:13 / 22:40 / 00:20）走的是同一条 workflow、同样的密钥** —— 这条路径本身是通的 |

> 🔑 判据：**「失败在签名/部署阶段」优先怀疑环境与凭据，而不是被测代码** ——
>    否则会去改一个根本没错的文件。

## 三、🔴 根因（硬证据：一行 `pbxproj` 配置）

```
app/ios/Runner.xcodeproj/project.pbxproj:
    "CODE_SIGN_IDENTITY[sdk=iphoneos*]" = "iPhone Developer";   ← 🔴 Development 证书
    CODE_SIGN_STYLE = Automatic;
```

**`CODE_SIGN_IDENTITY = "iPhone Developer"` ⇒ Archive 阶段用的是 Development 签名**
⇒ Xcode 去找 **`iOS App Development` provisioning profile**
⇒ 这正是 CI 报的 `No profiles for 'com.coevo.coevoApp' ... iOS App Development`。
（这一行是 **Flutter 模板的默认值**，从未改过 ⇒ 一直是 Development 签名。）

### 完整根因链

| # | 环节 |
|---|---|
| 1 | `pbxproj` 的 `CODE_SIGN_IDENTITY = iPhone Developer` ⇒ archive 需要 **Development 证书 + Development profile** |
| 2 | workflow 开着 **`-allowProvisioningUpdates`** ⇒ Xcode 会自动**查找/创建**证书与 profile |
| 3 | 而 workflow **没有任何清理账号证书的步骤**（`✓ 清理私钥` 只删**本地** `~/private_keys/*.p8`）|
| 4 | ⇒ 每次 CI 归档都可能**新增一张 Development 证书** ⇒ **只增不减** |
| 5 | ⇒ 攒到 Apple 账号上限 ⇒ **既不能新建、又找不到可用 profile** ⇒ **本轮 archive 失败** |

> ⚠️ 白哥贴的列表印证了这一点：**`Development` 类型（Created via API）一大堆**，
> 而 **`Distribution Managed` 只有 1 张**（`xu bai` 创建）。
> 🔑 而 Release 归档**本来就应该用 Distribution 签名** —— 现在这行是模板默认值，属于**未修的历史遗留**。

### 顺带核实的（这些**没问题**）

| 项 | 结论 |
|---|---|
| `export-options.plist` 位置 | ✅ 在 `app/.github/`（workflow 的 working-directory 是 `app`）|
| `method` 是否被 input 覆盖 | ✅ **会覆盖**（`PlistBuddy -c "Set :method $METHOD"`）⇒ `-f method=ad-hoc` 生效 |
| `destination` | ✅ 按 `upload` 切换 |
| 本机 `analyze_inproc` | ✅ **error = 0**（Dart 层无问题）|


## 四、怎么办（A 你操作 · B/C 我来改，等你批）

### 🔴 方案 A（立刻解眼前 · 你操作 · 约 3 分钟）

⚠️ **要撤销的是 `Development` 类型那一堆**（不是 `Distribution`）——
因为失败发生在 **archive 阶段的 Development 签名**（见 §三）。

1. 打开 <https://developer.apple.com/account/resources/certificates/list>
2. 把 **Type = `Development`** 的那些（Created via API）**撤销/删除** ——
   **留 1 张**即可（或者全删，Xcode 下次会自动建 1 张新的）
3. 🔴 **务必保留** `xu bai` 那张 **`Distribution Managed`** —— 出包要用它
4. （可选）<https://developer.apple.com/account/resources/profiles/list>
   删掉 `com.coevo.coevoApp` 的**旧 profile**
5. **回来说一声，我立刻重跑**（改公开 → CI → 下载 → 改回私有，全流程我自动做）

> ✅ 撤销 Development 证书**不影响已上架版本**，也不影响 Distribution 出包。
> ⚠️ 只会影响「本机 Xcode 真机调试」—— 而 Xcode 下次会自动重建一张，无需担心。

### 🟢 方案 B（根治 · 我改 workflow · 等你批）

在 `.github/workflows/ios-archive.yml` 的 `xcodebuild archive` 里**加一行**：

```yaml
CODE_SIGN_IDENTITY="Apple Distribution"
```

**理由**：Release 归档**本来就该用 Distribution 签名** —— 现在 `pbxproj` 里那行
`"CODE_SIGN_IDENTITY[sdk=iphoneos*]" = "iPhone Developer"` 是 **Flutter 模板的默认值，从未改过**。
⇒ 改完之后 **archive 不再需要 Development 证书** ⇒ **不再堆积** ⇒ 上限问题消失。
**前提**：账号里有可用的 Distribution 证书（你有 1 张 ✅）。

> 📌 我不擅自改 workflow（等你点头）。

### 🔵 方案 C（一劳永逸 · 更彻底）

**固定证书 + 手动签名**：导出 1 份 `.p12` + 1 份 `.mobileprovision` 存成 GitHub Secrets，
workflow 里 `security import` + 指定 `CODE_SIGN_IDENTITY` / `PROVISIONING_PROFILE_SPECIFIER`，
**去掉** `-allowProvisioningUpdates` ⇒ 完全不依赖自动管理。

---

## 五、我的建议顺序

| 顺序 | 动作 | 谁做 | 结果 |
|---|---|---|---|
| 1 | **撤销多余的 Development 证书**（方案 A）| **你** | ✅ 已完成（现仅 1 张 Development + 1 张 Distribution）|
| 2 | ~~改 workflow 加 `CODE_SIGN_IDENTITY="Apple Distribution"`（方案 B）~~ | 我 | ❌ **已试，行不通 —— 见 §七** |
| 3 | **用原配置 + 清理后的证书重跑** | 我 | ⏳ run 38112115154 |
| 4 | 排进下次迭代：**固定证书 + 手动签名**（方案 C）| 我 + 你导出证书 | ⏳ |

---

## 七、⚠️ 方案 B 的尝试失败 —— **错在我**（2026-10-11 12:29）

你同意方案 B 后，我在 archive 命令里加了：

```yaml
CODE_SIGN_IDENTITY="Apple Distribution" \
"CODE_SIGN_IDENTITY[sdk=iphoneos*]"="Apple Distribution" \
```

run **38111750123** → **仍失败**（exit 65），而错误**是我引入的**：

```
CODE_SIGN_IDENTITY = iphoneos*]=Apple Distribution        ← key 被截断了！
error: Runner is automatically signed, but code signing identity
       iphoneos*]=Apple Distribution has been manually specified.
```

### 两个错，都很典型

| # | 错 | 原因 |
|---|---|---|
| 1 | `"CODE_SIGN_IDENTITY[sdk=iphoneos*]"=...` **没被当成赋值**，而是普通参数 ⇒ key 被截断 | POSIX shell 的**赋值词**要求 name 是**合法标识符**，且**引号不能包住 name**（只能写成 `name="value"`）。`[` `]` `*` 都不是标识符字符 |
| 2 | `Automatic` + **手动指定 identity** 本身**冲突** | `pbxproj` 是 `CODE_SIGN_STYLE = Automatic`；Xcode 明确拒绝这个组合（报 `conflicting provisioning settings`）|

### 🔑 三条教训（已写入判据库）

1. **命令行覆盖 `[sdk=…]` 条件键这条路是错的** —— Xcode 的 build setting 覆盖只对**简单键名**可靠。
2. **「Automatic + 手动指定 identity」是自相矛盾** —— 要指定 identity 必须同时
   `CODE_SIGN_STYLE=Manual`，而那又要求先有 profile 名。
3. **最重要**：**「推理出来的修法」必须先小成本验证** —— 我基于「命令行优先级最高」的推断
   直接改了 CI 并触发，**白白浪费一次出包**。
   而**原配置在证书充足时已被实测证明能成功 4 次** ⇒ 当时正确的动作是
   **先回滚、用清理后的证书重跑**，而不是引入一个没验证过的改动。
   📌 判据：**当「原路径已知可通、只差一个前提」时，先补前提、别改路径**。

### 已处置

- ✅ **`git revert`**（`d12b414` → `097464b`）：与改动前**逐字一致**（`git diff` 为空）
- ✅ 用**原配置 + 你清理后的证书**重跑：run **38112115154**
- ⛔ 方案 B 作废；根治改走**方案 C（固定证书 + 手动签名）**

---

## 八、✅ 最终结果：回滚后**一次通过**（2026-10-11 12:43）

| 项 | 值 |
|---|---|
| run | **38112115154** · 全步骤 ✓ · **6m5s** |
| 出包 commit | **`097464b`**（= 回滚后的 HEAD）|
| 产物 | `E:\CoEvo_backups\ios-20261011-card-backfill\coevo_app.ipa` · **36045998 B** · `sha256=a09f6b2ceab5d12d…` |
| 可见性 | 已复核 **`isPrivate: true`** ✅ |

### 🔑 这次「一次通过」本身就是一个结论

**原配置（`CODE_SIGN_IDENTITY = iPhone Developer` + Automatic）在证书充足时完全可用** ——
前面 4 次成功 + 这次成功后，共 **5 次**。

⇒ **§三 的诊断成立**：失败的原因**只是证书被 Development 那堆占满了**，
**不是**签名配置本身有错。（白哥清理证书后，**一个字都没改**就直接通过了。）

⇒ 这也反证了 §七 的方案 B：**那是一个不必要的改动** ——
当时正确的动作就是**补上「证书」这个前提**，而不是改路径。

### ⏳ 根治（下次迭代 · 方案 C）

「Development 证书会随每次 CI 归档堆积」这个**机制**仍在（`-allowProvisioningUpdates` 未变）。
⇒ 若不加处理，**出几次包之后还会再撞上限**。
⇒ 真正根治 = **固定证书 + 手动签名**（导出 `.p12` + `.mobileprovision` 存 Secrets，
   指定 `CODE_SIGN_STYLE=Manual` + `CODE_SIGN_IDENTITY` + `PROVISIONING_PROFILE_SPECIFIER`，
   去掉 `-allowProvisioningUpdates`）。**⚠️ 注意 Manual 必须三者齐备**（§七 的教训 2）。

---

## 九、✅ 根治完成 —— 换了条**不需要导出证书**的路（2026-10-11 12:54）

白哥：「现在就可以，根治」。我选了**成本更低**的做法 —— 因为失败发生在 **Archive 阶段的
Development 签名**（§三 已证），而 **Archive 其实不需要签名**：

### 改法：Archive 不签名，签名全交给 Export

```yaml
xcodebuild -workspace ios/Runner.xcworkspace \
  -scheme Runner -configuration Release \
  -archivePath build/ios/archive/Runner.xcarchive -sdk iphoneos \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  archive
```
（并**去掉** archive 的 `-allowProvisioningUpdates` + API Key 参数 ——
 它们只在「归档时签名」这条路上有用，留着反而可能触发证书创建。）

### 为什么这样能根治（四步）

| # | 环节 |
|---|---|
| 1 | 失败发生在 **Archive 阶段的 Development 签名** ⇒ 它需要 Development 证书/profile |
| 2 | **Archive 本身不需要签名** —— 归档只要产物，签名可以晚一步做 |
| 3 | `CODE_SIGNING_ALLOWED=NO`（配合 `REQUIRED=NO`）⇒ 跳过签名 ⇒ **不再需要 Development 证书** ⇒ **不再堆积** |
| 4 | 签名交给 **Export 阶段** —— 那里本来就有 `signingStyle=automatic` + API Key + `-allowProvisioningUpdates`；<br>而它用的是 **Distribution** 证书/profile ⇒ **每个 bundle id 一套、长期复用**，不会每次新建 |

> 🔑 对比起来，§五 的**方案 C（固定证书）就不必做了** ——
> 那条路要导出 `.p12` / `.mobileprovision`（对没有 Mac 的环境还挺麻烦），
> 而本方案**零凭据改动**。方案 C 留作**万一**的退路。

### 结果

| 项 | 值 |
|---|---|
| run | **38112765397** · 全步骤 ✓ · **5m40s** |
| 出包 commit | **`6575f35`** = 本地 HEAD ✅ |
| 产物 | `E:\CoEvo_backups\ios-20261011-rootfix\coevo_app.ipa` |
| 可见性 | 已复核 **`isPrivate: true`** ✅ |

### ⚠️ 这个改动的验证强度（如实标注）

| | 状态 |
|---|---|
| **改后能否正常出包** | ✅ **已证**（run 38112765397 全绿）|
| **「Development 证书不再堆积」** | ✅ **已证**（2026-10-11 13:0x，用 CI 日志直接证实，见 §十）|

> 📌 判据：**「改完 CI 绿了」≠「根因被消除了」** ——
> 前者只证明「这条路能走通」，后者要看**那个会增长的动作有没有停止发生**。
>
> 🔑 **而验证方式本身也要选对**：**看「有没有发起那个动作」（行为日志）强于「看数量变没变」** ——
> 数量不变也可能是「复用了旧的」；而「压根没做那个动作」是**逻辑上的不可能**。

---

## 十、🔍 根治验证：那张新证书来自**根治之前**（2026-10-11 13:0x）

白哥复查 Apple 账号证书页，发现 **2 张 `Development`**（`2027/10/10` + **`2027/10/11`**）。
需要判断：**新增那张到底是谁造成的？**

### 排他性证据（按 run 逐一核对 CI 日志）

| run | 北京时间 | commit | 是否走到「签名」这一步 | 能否创建证书 |
|---|---|---|---|---|
| 38110797295 | 12:11 | `14cfac3` | ❌ 未走到（已达上限即失败）| 否 |
| 38111750123 | 12:29 | `d12b414` | ❌ 未走到（conflicting settings）| 否 |
| **38112115154** | **12:36** | **`097464b`（根治前 · 原配置）** | ✅ **走到** | **✅ 是** |
| 38112765397 | 12:48 | `6575f35`（**根治后**）| ❌ **不签名** | 否 |

12:36 那次的日志原文（证据）：

```
export CODE_SIGNING_ALLOWED=YES
/usr/bin/codesign --force --sign 8BE2B1B475E0C204252C75F9B0D1DACFCA389CF0 … \
    .../Runner.app/Frameworks/audioplayers_darwin.framework
Provisioning Profile: "iOS Team Provisioning Profile: com.coevo.coevoApp"
```

⇒ 四次 run 里**只有 12:36 那一次**有能力创建证书
⇒ **`2027/10/11` 那张 = 根治之前造成的** ✅（**不是**根治那次）

### 根治后的 Archive 日志（同一位置的对照）

```
xcodebuild … -sdk iphoneos DEVELOPMENT_TEAM=*** \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive
    CODE_SIGNING_ALLOWED = NO
    export CODE_SIGNING_ALLOWED\=NO
```

**全程没有任何 `codesign` 调用，也没有 provisioning profile 安装**
⇒ archive **根本不签名** ⇒ 它连「用哪张证书」都不需要知道 ⇒ **不可能创建/消耗证书**。

### 结论与后续

- ✅ **根治有效**：archive 不再签名 ⇒ 不再消耗 Development 证书（机制已断，不只是「这次没撞上」）
- ⚠️ 现有 2 张 Development **已达 Apple 的 Development 证书上限** —— 虽然 CI 已不受影响，
  但**建议删掉多余的 1 张**（保留 1 张供本机真机调试），留出缓冲
- 🔑 判据保留：若将来**又出现**新的 Development 证书 ⇒ 说明 archive 仍在签
  ⇒ 回退到方案 C（固定证书 + 手动签名）。**这个反例仍然有效**。





## 六、本轮已做的（agent 侧）

| 动作 | 结果 |
|---|---|
| 改公开前置审计 | ✅ 工作区干净 · HEAD == origin/main · 密钥检查通过 |
| 临时改 public → 触发 run 38110797295 | ✅ |
| **失败后立刻改回 private** | ✅ 复核 `isPrivate: true` |
| 判定「非代码问题」 | ✅ 三条证据（见 §二）|
| 未产出 IPA | ⛔ 本次**无产物**（`Export IPA` 步骤被跳过）|

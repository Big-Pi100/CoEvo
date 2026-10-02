# 部署 v0.1.0（2026-10-03 00:26）

> **给白哥** · 白哥指令：「部署吧」。
>
> ✅ **部署成功**。但过程中挖出一个 **CI 配置的长期 bug** ——
> **推 tag 从未触发过 workflow**，即这条「自动化部署链路」**从建立起就没工作过**。
>
> 🔑 附带结论：**从二轮起的所有源扩展（8 + 2 + 10 个源）此前从未进过生产**，
> 本次一次性全部生效。

---

## 一、部署结果（全部实测，非推断）

| 项 | 部署前 | 部署后 |
|---|---|---|
| 二进制 `/opt/coevo/bin/coevo_backend` | `Oct 2 12:59` | **`Oct 3 00:26`** ✅ |
| `content_source` 行数 | 5 | **24**（23 启用 + 1 禁用 Ars）✅ |
| `category` 类数（有源） | 2（news/tech） | **12 类全覆盖** ✅ |
| `content_source` 的 CHECK | **无** | ✅ **有**（含 `education`/`family`）|
| `content_pool` 条数 | 415 | **853**（+438）✅ |
| 产出内容的新源 | — | **23 个启用源全部有产出** ✅ |

### 1.1 CHECK 是真生效（不是「DDL 里有字样」）

**实测插入非法分类**：

```
INSERT INTO content_source (..., category='bogus', ...)
→ ✅ CHECK constraint failed: category IN ('news','tech','business',...
```

这才是「重建表」的目的达成 —— 与 `schema.rs` 里那条断言（读 DDL 比对词表）互为表里。

### 1.2 12 类全部有源、且都有内容

| 类 | 源数 | 内容条数 |
|---|---|---|
| tech | 3 | 317 |
| science | 3 | 284 |
| news | 5 | 155 |
| culture | 3 | 27 |
| health | 2 | 16 |
| family | 1 | 10 |
| history | 1 | 10 |
| sports | 1 | 10 |
| entertainment | 1 | 9 |
| education | 1 | 7 |
| law | 1 | 5 |
| business | 1 | 3 |

### 1.3 保留期 30 天：已生效，但**当前不删任何数据**

启动日志明写：

```
content_fetch: 内容保留期 30 天（`COEVO_CONTENT_RETENTION_DAYS=0` 可关闭清理）
```

实测：`content_pool` 最老 `2026-10-01T09:13:30Z`，**早于 30 天前的条数 = 0**
⇒ **没有删任何东西**（全部存量都是最近两天抓的）。以后按 30 天正常轮转。

### 1.4 抓取已跑起来（新源在产出）

```
16:29:28  启动（首轮 30s 后，之后每 21600s）
16:29:59  NPR News 拿到 10 条 · 新增 4 条
16:30:42  NPR World 国际 拿到 10 条 · 新增 4 条    ← 新源
16:30:43  NPR Business 商业 拿到 10 条 · 新增 3 条
16:30:44  NPR Science 科学 拿到 10 条 · 新增 6 条
16:30:45  NPR Culture 文化 拿到 10 条 · 新增 7 条
16:30:46  NPR Technology 拿到 10 条 · 新增 6 条
16:30:47  NPR Health 健康 拿到 10 条 · 新增 6 条
…
```

23 个启用源**全部**有产出；新接入的 10 个源（id 15–24）合计 **91 条**。

---

## 二、🔴 根因：CI 的 `on.push` 缺 `tags` —— 推 tag **从未触发过 workflow**

### 2.1 问题

```yaml
on:
  push:
    branches: [main, master]     # ← 只有 branches，没有 tags
  workflow_dispatch:
```

而三个 job 上写着：

```yaml
if: ${{ github.event_name == 'workflow_dispatch' || startsWith(github.ref, 'refs/tags/v') }}
#    ↑ backend-release / backend-deploy / ios-build
```

意图明显是「**推 `v*` tag 即构建 + 部署**」，但 `on` 段从未声明 `tags`
⇒ **那三处 `if` 永远不会为真**（死条件）。

**GitHub 官方规则**（Events that trigger workflows → `push`）：

> If you define **only `tags` or only `branches`**, the workflow **won't run**
> for events affecting the undefined Git ref.

⇒ 只写 `branches` 时，**推 tag 完全不触发 workflow** ——
不是「触发了但 job 被 `if` 跳过」，而是**根本没有 run**。

### 2.2 排查中被引到错误方向（如实记录）

我一开始的判断依次是：
1. CI 构建失败？（本地 release 构建验证 → **成功**，8m49s）
2. runner 连不上国内 IP:22？（CI 注释里自己就写着「此前未实测」的疑虑）
3. GitHub Actions 额度耗尽？

**直到我查了 `auth.log`** —— 里面**只有我自己的连接**（124.23.134.x）
和一个海外扫描 IP（51.89.42.211 在反复猜 root 密码），
**没有任何来自 GitHub runner 的连接** ⇒ 说明 deploy job **从未尝试过连接**。

那一刻才回头查「**触发条件成立吗**」，而不是继续在「执行失败」里找原因。

📌 **判据**：**「没反应」时先查「触发条件成立吗」，再查「执行成功吗」** ——
   两者是完全不同的失败，而后者更容易被怀疑（也更容易白查一轮）。

### 2.3 修复

`on.push` 加 `tags: ["v*"]`（commit `6058bd6`），并在注释里写明这段来由。
修复后删旧 tag、重建、重推 ⇒ **立刻触发**，约 8 分钟后部署完成。

### 2.4 影响面（比「这次部署失败」更大）

这条链路**从建立起就没工作过** ⇒ 之前的部署**全是手动**（WSL 构建 + scp）。
⇒ 连带确认：**二轮（8 源）与三轮（10 源）的改动从未进生产**，
本次一次性全部生效（`content_source` 5 → 24 行是直接证据）。

---

## 三、附带发现：**本地 SSH 到生产一直是通的**

`ssh -i ~/.ssh/coevo_key ubuntu@<VPS_IP>` ✅

⚠️ 我之前试 `ssh root@<VPS_IP>`（**没指定 key**）→ `Permission denied`，
就以为「SSH 不可用」，转而依赖 CI。
⇒ 实际是 **`~/.ssh/coevo_key` + `ubuntu` 用户**的组合可用（CI 用的也是 `ubuntu`）。

📌 判据：**「我没找到」≠「不存在」** —— 换参数再试一次的成本，远低于绕路重建一条链路。

**价值**：这条通道让「部署后验证」变成**直查**（DB / 日志 / 二进制时间戳），
而不是靠外部 HTTP 旁路猜。本次全部结论都来自直查。

---

## 四、🆕 本轮判据

| # | 判据 | 触发它的事实 |
|---|---|---|
| ① | 🔴🔴 **「没反应」先查「触发条件成立吗」，再查「执行成功吗」** | 推 tag 零 CI 运行，排查方向全错 |
| ② | 🔴 **`on.push` 只写 `branches` 时，push tag 不触发 workflow** | GitHub 官方规则；三个 job 的 `if` 因此全是死条件 |
| ③ | 🔴 **配置要与意图一起读** —— job 上的 `if` 期待 tag，`on` 却不声明 tags ⇒ 矛盾 | 「配置与意图矛盾」类 bug |
| ④ | 🔑 **iOS/权重 job 的 `continue-on-error` 只影响该 job**，不阻塞 deploy | 确认 tag 触发是安全路径 |
| ⑤ | 🔑 **验证要直查（SSH），不要只靠外部旁路** | 旁路 curl 只能看到「有没有新内容」，看不到「二进制/DB/CHECK」 |
| ⑥ | 🔑 **「我没找到」≠「不存在」** —— 换参数再试一次 | `root@` 失败 ⇒ 以为 SSH 不可用；换 `ubuntu@`+key 后一通百通 |
| ⑦ | 🔴 **保留期类改动要看「实际会删几条」**，不能只说「机制已生效」 | 实测 0 条（存量都在 30 天内）—— 这是「有没有副作用」的答案 |

---

## 五、复现 / 后续

```bash
# 查部署后状态（直查比旁路准）
ssh -i ~/.ssh/coevo_key ubuntu@<VPS_IP>

# 以后部署（CI 已修好）
git tag -a v0.1.x -m "..." && git push origin v0.1.x
```

⚠️ **`v0.1.0` 是首个 tag** —— 之前无任何 tag，也从无 tag 触发过 CI。

### 待办（供白哥定）

1. 🟡 **iOS 构建 job 也依赖 tag** —— 现在 tag 会**同时**触发 `ios-build`（macOS runner）。
   它有 `continue-on-error`，不会阻塞部署，但会**消耗 macOS 额度**（10 倍计费）。
   若不需要每次 tag 都跑，可考虑加 `paths`/条件限定。
2. ⏳ 上轮遗留：ESPN NFL / NPR Pop Culture 备选 · 存量许可复核（Dev.to / HN）
3. ⏳ 文章朗读 · 支付/恢复购买（提审前）· A3 回流 · 真机验 A2

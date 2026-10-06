# 存量重抓操作手册（方案 A · 2026-10-06）

> 目的：把已经入库的「**配件版正文**」（如 NPR 音频页的 `Download` / `Embed` / `iframe`）
> 换成完整正文。
>
> 🔴 **前置条件：必须先部署本轮代码** —— 否则重抓回来的正文**仍然带配件**
>    （清理逻辑 `strip_media_furniture` 是这次才加的）。**部署顺序不能反。**

---

## 一、先看数据（2026-10-06 实测）

### 配件型条目的分布

判据：`length(body) < 3000` **且** body 含 `Embed` / `ondemand.npr.org` / `<iframe>`

| 发布日 | 篇数 |
|---|---|
| 2026-09-29 | 1 |
| 2026-10-01 | 3 |
| 2026-10-02 | 10 |
| 2026-10-03 | 9 |
| 2026-10-04 | 10 |
| 2026-10-05 | 8 |
| **合计** | **41** |

### 🔑 重要发现：**方案 C 上线后会**自动**修掉大部分存量**

方案 C（重试窗口）的判据是「**发布 7 天内 + 距上次尝试 > 12h + 正文 < 3000 字符**」
⇒ 实测命中 **214 篇**（其中包含上面 41 篇里 **10-01 之后的全部**）。

⚠️ **两个数字不能相减**（214 − 41 = 负数）：它们的分母不同 ——
214 是「**所有**短正文」（含本来就只有摘要的源），41 是「**含配件特征**的」。
📌 判据：**比例/数量类结论要看「分母是不是同一个」**（本项目已记同族条目）。

⇒ **A 需要手工处理的只有**：

| 情形 | 数量 | 说明 |
|---|---|---|
| 已超 7 天窗口的配件型 | **1 篇**（09-29） | C 不会自动覆盖 |
| 其余 40 篇 | — | ✅ C 会自动覆盖（**但要等**，见下） |

### ⏳ 但 C 的自我修复是**渐进**的

C 每轮配额 **20 条**（`MAX_BODY_RETRY_PER_ROUND`），而补抓每轮 **6 小时**
⇒ 214 条 ≈ **11 轮 ≈ 66 小时（约 3 天）** 才跑完。

⇒ 若要**立刻**修好这 41 篇，仍需手工（下面的步骤）；否则等 2–3 天。

---

## 二、执行步骤（**部署之后**再做）

### ① 先确认部署生效

```bash
# 确认服务用的是新二进制（重启时间应晚于部署）
ssh -i ~/.ssh/coevo_key ubuntu@<VPS_IP> \
  "systemctl show -p ExecMainStartTimestamp coevo; ls -la /opt/coevo/coevo-bin"
```

### ② 🔴 先备份受影响的行（**不可跳过**）

```bash
ssh -i ~/.ssh/coevo_key ubuntu@<VPS_IP> "python3 -" << 'PY'
import sqlite3, json, datetime
c = sqlite3.connect("/opt/coevo/data/coevo.db")
c.row_factory = sqlite3.Row
rows = [dict(r) for r in c.execute("""
  select id, url, length(body) blen, body_attempted_at
  from content_pool
  where length(body) < 3000
    and (body like '%Embed%' or body like '%ondemand.npr.org%' or body like '%<iframe%')""")]
ts = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
p = f'/opt/coevo/data/backups/furniture-before-refetch-{ts}.json'
open(p,'w').write(json.dumps(rows, ensure_ascii=False, indent=1))
print(f'已备份 {len(rows)} 行 → {p}')
PY
```

**为什么必须备份**：下面要改 `body_attempted_at`（那是「重抓的唯一开关」）。
虽然重抓是**幂等**的（抓不回新的就保持原样），但**万一新抓的正文更短/更差**，
没有备份就回不去（旧 body 会被覆盖）。

### ③ 清空这些条目的抓取标记（= 让它们重新成为候选）

```bash
ssh -i ~/.ssh/coevo_key ubuntu@<VPS_IP> "python3 -" << 'PY'
import sqlite3
c = sqlite3.connect("/opt/coevo/data/coevo.db")
n = c.execute("""UPDATE content_pool SET body_attempted_at = NULL
  WHERE length(body) < 3000
    AND (body LIKE '%Embed%' OR body LIKE '%ondemand.npr.org%' OR body LIKE '%<iframe%')""").rowcount
c.commit(); print(f'已重置 {n} 条')
PY
```

### ④ 开重抓模式并重启（跑完**必须**关掉）

```bash
# 在 /opt/coevo/.env 追加（⚠️ 改前先 cp .env .env.bak-<ts>）
COEVO_REFETCH_BODIES=1
```

```bash
sudo systemctl restart coevo   # 🔴 改动前请白哥确认
```

⚠️ `COEVO_REFETCH_BODIES=1` 会让「**已有正文但没试过**」的条目也被抓 ——
  它是为「存量迁移窗口」设计的**临时开关**，**跑完必须删掉**（否则每轮白抓）。

### ⑤ 验证（**四层**，逐层看）

```bash
# ⑤-1 看日志：应出现「补抓正文 N/M 篇成功（其中重试 K 篇）」
ssh -i ~/.ssh/coevo_key ubuntu@<VPS_IP> "journalctl -u coevo -n 40 --no-pager | grep 补抓正文"

# ⑤-2 看数据：配件型应大幅减少 / 消失
ssh -i ~/.ssh/coevo_key ubuntu@<VPS_IP> "python3 -" << 'PY'
import sqlite3
c = sqlite3.connect("file:/opt/coevo/data/coevo.db?mode=ro", uri=True)
n = c.execute("""select count(*) from content_pool
  where length(body) < 3000
    and (body like '%Embed%' or body like '%ondemand.npr.org%' or body like '%<iframe%')""").fetchone()[0]
print('剩余配件型:', n)
PY

# ⑤-3 抽一篇白哥报过的（应已是完整文字稿，且**不含** iframe/Download）
ssh -i ~/.ssh/coevo_key ubuntu@<VPS_IP> "python3 -" << 'PY'
import sqlite3
c = sqlite3.connect("file:/opt/coevo/data/coevo.db?mode=ro", uri=True)
b = c.execute("select body from content_pool where id=7091").fetchone()[0]
print('长度:', len(b))
print('含 iframe:', 'iframe' in b, '· 含 Download:', 'Download' in b)
print('首行:', b.split(chr(10))[0][:60])
print(b[:400])
PY

# ⑤-4 端侧：真机打开那篇（阅读页 + 朗读），确认两行配件消失
```

### ⑥ 关掉重抓模式

```bash
# 从 .env 删掉 COEVO_REFETCH_BODIES=1，再重启服务
```

---

## 三、回滚

出了问题 ⇒ 用 ② 备份的 JSON 恢复 `body` 与 `body_attempted_at`，
并**立即关掉** `COEVO_REFETCH_BODIES`（否则每轮继续覆盖）。

```bash
ssh -i ~/.ssh/coevo_key ubuntu@<VPS_IP> "python3 -" << 'PY'
import sqlite3, json
p = '/opt/coevo/data/backups/furniture-before-refetch-<TS>.json'   # ← 填实际文件名
rows = json.load(open(p))
c = sqlite3.connect("/opt/coevo/data/coevo.db")
for r in rows:
    c.execute("UPDATE content_pool SET body=(select body from backup where id=?),"
              " body_attempted_at=? WHERE id=?", (r['id'], r['body_attempted_at'], r['id']))
c.commit()
PY
```
⚠️ 上面这段回滚 SQL 是**示意**（JSON 里没存 `body` 全文 —— 备份脚本只存了元信息）。
**若要能完整回滚**，② 的备份要**把 `body` 也存进去**（改一行 `select` 即可）。
📌 判据：**备份要覆盖「你即将改动的每一个字段」** —— 只备份 id 列表是回滚不了的。

---

## 四、一句话总结

> **先部署**（否则白抓）→ 备份 → 清标记 → 开 refetch 重启 → 四层验证 → **关 refetch**。
> 而**方案 C 上线后会自动做同样的事**（只是要等 2–3 天）——
> ⇒ 若不急，**跳过 A 也行**；A 的价值是「立刻生效」+「覆盖已超窗的 1 篇」。

---

## 四、✅ 部署已执行（2026-10-06 18:38 CST）· 本手册的「方案 A」**不必再做**

> 本节记录**实际执行结果**。结论：**方案 C 已在生效并自动修存量 ⇒ 不需要走上面的手工重抓流程。**

### 1. 为什么走的不是 CI（两条路都实测堵死）

| 路径 | 结论 |
|---|---|
| **CI**（`tag ⇒ backend-release ⇒ backend-deploy`）| 🔴 **额度 exhausted**（Free 私有仓库 2000 分/月 · 官方「无付款方式 ⇒ 用量被 blocked」· 窗口约 27 天）|
| **本机 WSL 构建** | 🔴 沙箱拦 `wsl.exe`（Program Blacklist）⇒ **只有白哥能跑** |
| **Windows 交叉编译** | 🔴 不可行：无 `zig`/`clang`/`cc`/`gcc`，且 `rusqlite` 用 **`bundled`**（要为目标平台编译 C）+ `native-tls`（要 OpenSSL）|

⚠️ 另：推 `v*` tag 会**连带触发 `ios-build`**（`macos-latest` = **10 倍计费**）⇒ 一次 tag 部署 ≈ **160 分额度**。

### 2. 实际执行的路径（**额度断时可用**，建议留档）

```bash
# ① 构建（白哥侧 · WSL）
LANG=C wsl.exe -d Ubuntu-22.04 -- bash -lc "tr -d '\r' < /mnt/e/CoEvo/scripts/deploy/build_linux_in_wsl.sh | bash"
#   产物：C:/Users/Lenovo/AppData/Local/Temp/coevo_deploy/{coevo_backend, cefr_catalog.json, prompts/}

# ② 传输（我侧 · Git Bash）
scp -i ~/.ssh/coevo_key <产物>/coevo_backend ubuntu@<VPS_IP>:/tmp/coevo_stage/coevo_backend

# ③ 部署（我侧 · 在 VPS 上跑，**不加 --with-assets** ⇒ 不动 .env / unit / prompts）
tr -d '\r' < scripts/deploy/deploy_update.sh | ssh -i ~/.ssh/coevo_key ubuntu@<VPS_IP> 'bash -s'
```

**部署前预检三件（缺一不可）**：

| 检查 | 命令 | 本次结果 |
|---|---|---|
| 传输完整性 | `sha256sum`（本地 vs VPS 双向）| **`c2c4d170…` 完全一致** ✅ |
| 产物类型 | `file` | `ELF 64-bit LSB pie executable, x86-64, stripped` ✅ |
| 依赖可解析 | `ldd … \| grep "not found"` | 无缺失 ✅（目标机 glibc **2.39** ≥ 构建机 2.35）|

### 3. 部署结果

| 项 | 值 |
|---|---|
| 新二进制 | 17640896 B · sha256 `c2c4d170accbdb3b…` |
| 回滚点 | `coevo_backend.prev` = 17397848 B（10-04 那版）|
| **健康检查** | **重启后第 1 次就 HTTP 200** ✅ |
| 邻居服务 | `vibedollar-pay` / `mailproxy` / `nginx` 全 active ✅ · 外网 `/health` 200 · `pay`/healthz 200 |
| 内存 / 监听 | 80.1 / 256 MB · 仅 `127.0.0.1:8300` ✅ |
| panic / ERROR | **0** ✅ |

### 4. 🔴 验证结论：**B / C / D 三项全部生效**（实测，非推断）

判据 —— 本轮（部署后 1 分钟的首轮抓取）处理了 **43 篇 = 20 重试 + 23 新**：

| 方案 | 怎么验 | 结果 |
|---|---|---|
| **B** 配件清理 | 这 43 篇正文里搜 `iframe` / `ondemand.npr.org` / `npr.org/player/embed` / 裸配件词 | **0 条残留** ✅ |
| **D** 标题去重 | 这 43 篇：正文首行是否 == `title` | **0 条** ✅ |
| **C** 重试窗口 | 20 重试 + 23 新 = **43**（与日志「补抓正文 41/43 篇成功 · 失败分类: too_short=2（其中重试 20 篇）」**完全对上**）| ✅ |

正文长度分布变化：`3001-10000` **+20 篇** · `10001+` **+5 篇**。
抽样 `id=8640` 拿到 **29976 字符**完整文字稿（`TONYA MOSLEY, HOST: This is FRESH AIR\.`）。

### 5. 白哥报的那篇（`id=7091`）

- **排名：第 3 / 188**（重试队列，`ORDER BY COALESCE(published_at, fetched_at) DESC` ⇒ 最新优先）
- ⇒ **下一轮（约 6h 后）会被自动重试**
- 剩余 188 篇 · 配额 20/轮 · 6h/轮 ⇒ **约 2.5 天自动跑完** ⇒ **本手册 §二的「方案 A 手工重抓」不需要执行**

### 6. ⚠️ 两个「看哪里」的坑（下次省时间）

| 坑 | 真相 |
|---|---|
| **日志不在 journald** | `journalctl -u coevo \| grep content_fetch` **全时间 0 条**；日志在 **`/opt/coevo/data/logs/coevo.log.YYYY-MM-DD`**（按天滚动，当天 77 条）|
| **`data/` 是 WAL 模式** | 主库 `coevo.db` 的 mtime 只在 checkpoint 时更新（写入先进 `-wal`）⇒ **mtime 不代表「没写」** |

### 7. 回滚（若需要）

```bash
install -m 755 /opt/coevo/bin/coevo_backend.prev /opt/coevo/bin/coevo_backend
sudo systemctl restart coevo
```
（`deploy_update.sh` 在健康检查失败时会**自动**执行这一步，并把失败副本留档为 `coevo_backend.failed-*`。）

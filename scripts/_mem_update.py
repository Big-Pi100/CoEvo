# -*- coding: utf-8 -*-
"""临时：压缩 MEMORY.md 腾空间 + 加新判据索引 + 追加今日日志。

（用编辑器写而不是 heredoc —— 本项目的 heredoc 会破坏 `X:\\s` 形态的转义。）
"""
import io

MEM = '.workbuddy/memory/MEMORY.md'
LOG = '.workbuddy/memory/2026-10-02.md'

s = io.open(MEM, encoding='utf-8', newline='').read()
before = len(s.encode())

# ── ① 压缩（等义、只减不增）──
REPS = [
    ('（微信·无 IAP·提审前必处理）', '（提审前必处理）'),
    ('（✅三项·✅转义⏳真机·📄 `s4-device-*`）', '（✅P0·✅转义·📄 `s4-*`）'),
    ('· 🔴 **内容管线**（🔴重抓受阻·🟡hl 2MB·📄 `content-*`·Ars片段）',
     '· **内容管线**（✅重抓已修·🟡hl 2MB·📄 `content-*`）'),
    ('（已犯 4 次）', '(×4)'),
    ('（「零影响」≠「可删」）', '（零影响≠可删）'),
    ('（抽出的 widget 会漏 = **假绿**；重构后必重跑）', '（抽出的 widget 会漏=假绿；重构后必重跑）'),
]
for old, new in REPS:
    assert old in s, f'未命中: {old[:30]}'
    s = s.replace(old, new)

# ── ② 加新判据索引（挂在「工具/写法错→假结论」那条的计数上，并新增一条）──
old_cnt = '/**R8改名**·**重置状态≠下游接住** 等 **16 条**'
assert old_cnt in s, '计数行未命中'
s = s.replace(old_cnt, '/**R8改名**/**重置状态≠下游接住**/**证伪须指名断言** 等 **17 条**')

# 在「静默失效」那条后面补「还原文件后构建可能不重编」
old_sil = '· 🆕🔴 **`cargo check` 不编译 `#[cfg(test)]`**）'
assert old_sil in s, '静默失效行未命中'
s = s.replace(
    old_sil,
    '· 🆕🔴 **`cargo check` 不编译 `#[cfg(test)]`** · 🆕🔴 **还原文件不刷 mtime→构建跳过重编**（用注入版二进制跑出「假红」））',
)

io.open(MEM, 'w', encoding='utf-8', newline='').write(s)
after = len(io.open(MEM, 'rb').read())
print(f'MEMORY.md: {before} → {after} 字节 · 限额 16384 → '
      + ('✅ 余 %d' % (16384 - after) if after <= 16384 else '🔴 超 %d' % (after - 16384)))

# ── ③ 追加今日日志 ──
BLOCK = r'''

---

## ✅ 修「片段当全文」+ 打通存量重抓（白哥「同意」）· `e3bec8c`

📄 完整报告 → `docs/review/excerpt-and-refetch-fix-2026-10-02.md`

### 两个缺陷（叠加）

| # | 缺陷 | 位置 | 后果 |
|---|---|---|---|
| A | 相对判据 `None => true` **恒真** | `content_rss.rs` | Ars 的 **161 词片段被当全文**（用户看到 `Read full article`）|
| B | `body` 非空 ⇒ **永不重抓** | `content_fetch.rs` | 清标记也白做（148 看着能重抓，实际只有 11–12 条）|

### 修法

**A**：`extract_body` → `classify_encoded`（**三重判据 + 三态**）
· ① 强标记按**子串** ② **绝对闸** <300 词（摘要缺失时唯一防线）③ 相对闸（**缺基准时弃权**）
· 三态：`Full`→body · **`Excerpt`→body 留空 + 归入 summary** · `Absent`→都不填
· 新增 `better_summary()`：源摘要 vs 片段**取更有用的**（≥2 倍且多 ≥50 词才换）

**B**：`pick_body_candidates(conn, limit, refetch_existing)` + `COEVO_REFETCH_BODIES=1`
· 默认 **false ⇒ 行为与改动前逐字相同**；启动打 **WARN** 提醒「用完要关」

**存量**：脚本新增 `--demote-excerpt-bodies`（64 行）
· 把片段迁 summary + 置空 body + **清 body_attempted_at**（三个动作缺一不可）

### 🔴 被真实数据推翻三次（都值得记）

| 我最初判断 | 真实数据 | 影响 |
|---|---|---|
| 片段标记**独立成行** | **紧跟正文最后一句**（20/20）| 整行匹配**一条都认不出来** ⇒ 改子串 |
| Ars 的 description 是**空的** | 是 **14 词导读**（CDATA 包裹）| 🔴 **我的测量脚本把 CDATA 内容一起剥了**（工具错，不是数据错）|
| 片段归 summary「不用改别的」| 优先 description 会让 Ars 掉到 **14 词** | 加 `better_summary` |

📌 判据：**判据的「理想化样本」与「真实数据」可能完全不同** ——
三个错都只有拿真 fixture/真库跑才暴露（合成样本上我全绿）。

### 验证

`cargo test --workspace` **174 项全过**（api_server 154）· 新增 9 条断言
· 证伪 **5/5 目标断言如期报红** · 生产库 dry-run 识别 **34 篇**片段

🔑 **替换掉一条「把 bug 锁死」的断言**：旧断言 `assert!(body.is_some())`
+ 注释「Ars feed **自带全文**（实测 20/20）」—— **那个前提是错的**，
它因此**保护了错误行为**（修好它反而让断言报红）。
📌 判据：**注释里的「实测如此」也要能失败** —— 写进注释后没人再回头核对。

### 🔴 证伪过程两次自我纠错（比结论更有价值）

① **「有测试红了」≠「我指的那条红了」**
   我给注入 0 挂的目标断言（`..._must_not_be_vacuous_without_summary`）**没红**。
   原因：那条测试的样本**同时带片段标记** ⇒ **标记闸先兜住** ⇒ 任何一条闸失效它都还绿。
   真正敏感的是「**无标记 + 够长 + 无摘要**」的样本。
   ⇒ 判据：**证伪的目标必须是具体断言名**；**多条闸指向同一结论时，要单独为每条闸准备样本**。

② **证伪工具用 `shutil.copy2` 还原 ⇒ 保留旧 mtime ⇒ cargo 不重编** ⇒
   复跑用的是**注入版**二进制 ⇒ 表现为「还原后仍然报红」（假红）。
   修：还原后 `os.utime(path, None)`。
   ⇒ 判据：**「以为重跑了」≠「真的重跑了」**（同族：`cargo test` 不重编 bin）。

### ⏭️ 待白哥

1. **构建**（WSL 被安全策略禁，我跑不了）
2. 部署（**未批准，生产未动**）
3. 存量迁移（按脚本 `--plan` 的输出顺序：demote → 开重抓模式 → reset → 关重抓模式）
4. 🔴 **Ars 抓不到全文**（文章页对两种 UA 都 **405**）⇒ 只能停在「摘要」态，需产品决定
'''

t = io.open(LOG, encoding='utf-8', newline='').read()
if not t.endswith('\n'):
    t += '\n'
io.open(LOG, 'w', encoding='utf-8', newline='').write(t + BLOCK)
d = io.open(LOG, 'rb').read()
print('日志已追加 · 行数 =', d.count(b'\n'), '· CRLF =', d.count(b'\r\n'))

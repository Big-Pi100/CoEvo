#!/usr/bin/env python3
"""部署后验证（**只读**）—— 覆盖 v0.1.6 书架上云 + 整段翻译，以及 2026-10-10 两批改动：
① 4 类同步表（`lookup_event` / `book_marker` / `achievement_unlock` / `setting`）
② **多端登录（最多 3 台）** —— 「单端登录」的解耦，见
   `docs/review/device-sync-and-profile-failure-2026-10-10.md`

跑法（在 VPS 上执行）：
    ssh -i ~/.ssh/coevo_key ubuntu@<vps> "python3 -" < scripts/trace_verify/bin/verify_v016_deploy.py

# 🔑 核心判据：**「401 ≠ 404」**

本轮新增的端点都是「要登录」的 —— 无 token 时**正确**返回 **401**（认证失败），
而**没部署**时返回 **404**（路由不存在）。
⇒ **401 就是「这条路由确实注册上了」的证据**，且它**不需要任何账号**就能测。

⚠️ 反面：若「所有请求都返回 401」（中间件把兜底也拦了），那 401 就不是证据。
   ⇒ 本脚本配一条**阴性对照**：请求一个**确定不存在**的 /api 路径，必须 **404**。
      📌 判据：**「检测器能报出差异」本身要先被证明**，否则「全 401」和「全过」长得一样。

# ⚠️ 未覆盖（如实标注，不假装）

带**有效登录态**的深层行为 —— 「翻译真能翻出句子」「书真能上传下载」—— **未验证**：
需要生产账号，而本脚本**不创建**（不往生产库写数据）。那部分留给真机。
本脚本覆盖的是：**路由已注册 · 表已建 · 列已加 · 二进制含新代码 · prompt 已就位**。
"""
import json
import os
import sqlite3
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8300"
BIN = "/opt/coevo/bin/coevo_backend"
DB = "/opt/coevo/data/coevo.db"
PROMPT = "/opt/coevo/prompts/translate.md"

_pass = 0
_fail = 0
_failures = []


def check(label, ok, detail=""):
    global _pass, _fail
    if ok:
        _pass += 1
        print(f"  ✅ {label}{'' if not detail else '  (' + detail + ')'}")
    else:
        _fail += 1
        _failures.append(f"{label}  {detail}")
        print(f"  🔴 {label}{'' if not detail else '  (' + detail + ')'}")


def http_code(path, method="GET", data=None, headers=None):
    """返回状态码；网络层失败返回 -1（与任何 HTTP 状态码都不相等）。"""
    req = urllib.request.Request(BASE + path, method=method, data=data,
                                 headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception as e:  # noqa: BLE001
        print(f"    （{method} {path} 网络层失败：{e}）")
        return -1


def bin_count(needle: bytes) -> int:
    """二进制里的出现次数。⚠️ 用 `bytes.count`（`grep -a` 等价）——
    `strings` 会漏多字节，且 Rust 字面量在 `.rodata` **连续拼接** ⇒ 别搜整句。"""
    with open(BIN, "rb") as f:
        return f.read().count(needle)


print("")
print("① 基础")
h = http_code("/health")
check("①-1 /health 返回 200", h == 200, f"实际 {h}")

# ══════════════════════════════════════════════════════════════
print("")
print("② 新端点已注册（判据：**非 404** —— 404 才代表路径不存在；401/415/422/400 都说明路由在）")

# ⚠️ 每个请求**只发一次**，判定与 detail 用**同一个**返回值 ——
#    写成 `check(..., http_code()==401, f"实际 {http_code()}")` 会发两次，
#    而两次结果理论上可以不同（detail 显示的就不是被判定的那一次）。
#
# 🔴 **判据口径（2026-10-08 两次实测修正）**：本组唯一的**强判据是「不是 404」**，
#    因为 axum 的**提取器在鉴权之前执行**，缺失/不合法的 body 会在到达 handler 前就失败：
#      · 端点**不读 body**（GET / DELETE）⇒ 直接进鉴权 ⇒ 无 token 得 **401**
#      · 端点**读 body**（POST + Json / Multipart）⇒ 按提取阶段依次得到：
#          无 `Content-Type`              → **415**
#          有 `Content-Type` 但缺必填字段  → **422**
#          body 合法                      → 才进 handler → **401**
#    ⇒ 对后者，**只要不是 404 就说明路由注册了**（404 才代表路径不存在）。
#    ⚠️ 为什么不索性发一个合法 body 去换 401：那要求这里**维护一份请求 schema 的副本**，
#       它会随后端字段变动而漂 ⇒ 判据自己变成新的故障源。📌 **机械判据只做到「路由存在」这一层。**
c_tr = http_code("/api/translate", "POST", data=b"{}",
                 headers={"Content-Type": "application/json"})
check("②-1 POST /api/translate → 非 404（Json 端点 · 不合法 body 时提取器先于鉴权失败）",
      c_tr != 404, f"实际 {c_tr}")

c_dl = http_code("/api/books/blob/deadbeef", "GET")
check("②-2 GET /api/books/blob/<hash> → 401", c_dl == 401, f"实际 {c_dl}")

c_del = http_code("/api/books/blob/deadbeef", "DELETE")
check("②-3 DELETE /api/books/blob/<hash> → 401", c_del == 401, f"实际 {c_del}")

c_up = http_code("/api/books/blob", "POST")
check("②-4 POST /api/books/blob → 非 404（multipart 端点 · 同上）",
      c_up != 404, f"实际 {c_up}")

# 🔴 阴性对照：证明「401」这个判据**真的能区分**存在与不存在
#    （否则「所有 401」和「全部通过」在输出上长得一样）
neg = http_code("/api/definitely-not-a-real-route-xyz")
check("②-5 阴性对照：不存在的 /api 路由 → 404"
      "（证明 ②-1~②-4 的 401 是「存在」而非「一律拦截」）",
      neg == 404, f"实际 {neg}")

# ══════════════════════════════════════════════════════════════
print("")
print("③ 旧行为未坏（对照）")

feed = http_code("/api/feed?limit=1")
check("③-1 GET /api/feed?limit=1 → 200", feed == 200, f"实际 {feed}")

try:
    with urllib.request.urlopen(BASE + "/api/feed?limit=1", timeout=10) as r:
        d = json.loads(r.read().decode("utf-8"))
    check("③-2 feed 仍有数据（total > 0）", (d.get("total") or 0) > 0,
          f"total={d.get('total')}")
except Exception as e:  # noqa: BLE001
    check("③-2 feed 仍有数据（total > 0）", False, str(e))

# ══════════════════════════════════════════════════════════════
print("")
print("④ 二进制含新代码（交付物级证据）")

F = os.path.getsize(BIN)
print(f"    二进制 {BIN} · {F / 1048576:.1f} MiB")
for label, needle in [
    ("④-1 含 `translate.md`（翻译 prompt 文件名）", b"translate.md"),
    ("④-2 含 `translation_usage`（翻译额度表）", b"translation_usage"),
    # 🔴 这里**必须带 `IF NOT EXISTS ` 与结尾空格**，不能只搜 `sync_book`：
    #    实测「部署前」的**旧**二进制里 `sync_book` 就有 **16 次** ——
    #    因为 `sync_book_progress` / `sync_bookmark` 都含这个子串。
    #    ⇒ 只搜 `sync_book` 是一个**太松**的判据（部署前就绿 ⇒ 它证明不了任何事）。
    #    📌 判据：**子串判据要检查「同族名是否会误命中」**，别让判据在**该红的时候也是绿的**。
    ("④-3 含 `IF NOT EXISTS sync_book (`（书单表 · 带括号避免与 sync_book_progress 混淆）",
     b"IF NOT EXISTS sync_book ("),
    ("④-4 含 `blob_size`（云端文件大小的权威列）", b"blob_size"),
    ("④-5 阳性对照：含 `wordlib_contract.md`（旧代码也有 ⇒ 证明检测器能报 ≥1）",
     b"wordlib_contract.md"),
    # ── 2026-10-10 本批新增：4 类同步表 ──
    #    🔴 子串必须带 `IF NOT EXISTS ` 前缀 + ` (` 后缀：只搜 `sync_setting` 会在
    #       `sync_setting_xx` 之类的同族名上**假绿**；带括号则唯一指向这张表的建表语句。
    ("④-6 含 `IF NOT EXISTS sync_lookup_event (`（本批 · 划词历史）",
     b"IF NOT EXISTS sync_lookup_event ("),
    ("④-7 含 `IF NOT EXISTS sync_book_marker (`（本批 · 书内书签）",
     b"IF NOT EXISTS sync_book_marker ("),
    ("④-8 含 `IF NOT EXISTS sync_achievement_unlock (`（本批 · 成就解锁时间）",
     b"IF NOT EXISTS sync_achievement_unlock ("),
    ("④-9 含 `IF NOT EXISTS sync_setting (`（本批 · 应用设置键值）",
     b"IF NOT EXISTS sync_setting ("),
    # ── 2026-10-10 第二批：多端登录（最多 3 台）──
    #    🔑 用**日志字面量**而不是函数名：第 3 步 `strip` 会删符号表 ⇒ 函数名不在二进制里，
    #       而 `tracing::warn!` 的格式串留在 `.rodata`（这是本脚本既有的取串原则）。
    #    ⚠️ tracing 宏会把字面量**在 `{...}` 占位符处切开** ⇒ 只能搜占位符**之前**那一段。
    #       这里 `enforce_token_limit 失败（user_id=…）` 的 `（user_id=` 之前正是所搜的子串。
    ("④-10 含 `enforce_token_limit 失败`（本批 · 多端登录的限额清理）",
     "enforce_token_limit 失败".encode("utf-8")),
]:
    n = bin_count(needle)
    check(label, n >= 1, f"{n} 次")

# 🔴 **反向判据**（单列 —— 上面那个循环的语义是「必须有」，表达不了「必须归零」）。
#
# 为什么要**双向**：单向「新增串命中」可能只是历史批次的巧合（本项目踩过：
# 「字符串字面量会一直命中」⇒ 证明不了是本批的包）。而「**旧实现的串归零**」
# 是本批**特有**的判别 —— 它同时证明「新逻辑在」+「旧的被真正替换掉」。
_old_cleanup = bin_count(b"Failed to clean old tokens")
check("④-11 旧「登录删全部 token」的日志串**已归零**（部署前实测为 1）",
      _old_cleanup == 0,
      f"{_old_cleanup} 次" + ("（🔴 仍在新版里 ⇒ 包不对，或旧函数没删净）" if _old_cleanup else ""))

# ══════════════════════════════════════════════════════════════
print("")
print("⑤ prompt 已就位")

check(f"⑤-1 {PROMPT} 存在", os.path.isfile(PROMPT))
if os.path.isfile(PROMPT):
    with open(PROMPT, "rb") as f:
        b = f.read()
    # 🔑 不比对整份 md5（换行符/编码差异会造成**假红**）——
    #    只确认「是这份 prompt」（含它的特征要求「逐字」与 JSON 约定）
    check("⑤-2 内容是翻译 prompt（含 segments 契约）",
          b"segments" in b and len(b) > 300, f"{len(b)} B")

# ══════════════════════════════════════════════════════════════
print("")
print("⑥ 建表已生效（老库走 ALTER/CREATE，不是只有新库才有）")

try:
    conn = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    names = {r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'")}
    # 🔴 老库靠 `init_database` 的 `CREATE TABLE IF NOT EXISTS` 补建 —— 若这批漏进
    #    `init_database`，则「新库有、老库没有」⇒ 这条断言正是抓这种半成品的。
    for t in ("sync_book", "translation_usage",
              "sync_lookup_event", "sync_book_marker",
              "sync_achievement_unlock", "sync_setting"):
        check(f"⑥ 表 `{t}` 存在", t in names)
    if "sync_book" in names:
        cols = {r[1] for r in conn.execute("PRAGMA table_info(sync_book)")}
        # 🔴 「表建了但列没加」是这类迁移最典型的半成品状态
        check("⑥-3 `sync_book` 含 `blob_size` 列", "blob_size" in cols,
              f"列：{','.join(sorted(cols))}")
        check("⑥-4 `sync_book` 含 `deleted` 列（软删；配额要排除已删书）",
              "deleted" in cols)
    conn.close()
except Exception as e:  # noqa: BLE001
    check("⑥ 能只读打开 coevo.db 并查表", False, str(e))

# ══════════════════════════════════════════════════════════════
print("")
print("⑧ 多端登录「最多 3 台」的**行为现状**（🟠 信息性，**不计入成败**）")
#
# 🔴 为什么是「信息性」而不是断言：
#    `enforce_token_limit` 只在 **登录时** 收敛 ⇒ 部署完的那一刻，
#    库里仍是「每用户 1 行」（**这是正常的**）。要看到 3 行，必须
#    **各设备各登录一次** —— 那是真机的动作，脚本不代为创建/登录账号。
# 判据（部署后人工确认）：真机上第二台、第三台登录后，本处应显示 ≥2。
MAX_TOKENS_PER_USER = 3  # 与 backend `auth.rs` 的 `MAX_TOKENS_PER_USER` 保持一致
try:
    conn2 = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    rows = list(conn2.execute(
        "SELECT user_id, COUNT(*) AS n FROM tokens GROUP BY user_id ORDER BY n DESC"))
    mx = max((r[1] for r in rows), default=0)
    print(f"    tokens 表 {len(rows)} 个用户 · 单用户最多 {mx} 个 token"
          f"（上限 {MAX_TOKENS_PER_USER}）")
    print("    ⚠️ 已存在的「1 用户 1 行」**不会自动**变成 3 行 —— 需各设备各登录一次。")
    if mx > MAX_TOKENS_PER_USER:
        print(f"    🔴 已超过上限 {MAX_TOKENS_PER_USER}：限额逻辑没生效？")
    conn2.close()
except Exception as e:  # noqa: BLE001
    print(f"    （跳过：{e}）")

# ══════════════════════════════════════════════════════════════
print("")
print("⑦ 重启窗口内无 ERROR（应用日志 · 不在 journald）")

# 🔑 只看**最近 10 分钟**的行 —— 全文件扫描会把**历史**错误也算进来（假红）。
#    ⚠️ 并**打印窗口内的行数**：若为 0，说明这一条可能是**空过**
#       （服务重启后没写任何日志），人一眼能看出来，而不是被「✅」盖住。
import datetime  # noqa: E402
import glob  # noqa: E402

try:
    logs = sorted(glob.glob("/opt/coevo/data/logs/coevo.log.*"),
                  key=os.path.getmtime)
    check("⑦-0 找到应用日志文件", bool(logs), f"{len(logs)} 个")
    if logs:
        latest = logs[-1]
        with open(latest, "r", errors="replace") as f:
            lines = f.read().splitlines()
        cutoff = (datetime.datetime.now(datetime.timezone.utc)
                  - datetime.timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M")
        recent = [ln for ln in lines if ln[:16] >= cutoff]
        errs = [ln for ln in recent if " ERROR " in ln]
        print(f"    最新日志 {os.path.basename(latest)} · 窗口内 {len(recent)} 行")
        check("⑦-1 重启窗口内无 ERROR 级日志", not errs,
              f"{len(errs)} 条" + (f"：{errs[0][:110]}" if errs else ""))
except Exception as e:  # noqa: BLE001
    check("⑦ 能读取应用日志", False, str(e))

# ══════════════════════════════════════════════════════════════
print("")
print("═" * 74)
if not _failures:
    print(f"✅ 全部通过：{_pass} 项")
else:
    print(f"🔴 失败 {_fail} 项 / 通过 {_pass} 项：")
    for f in _failures:
        print(f"    · {f}")
    print("")
    print("🔑 最可能的原因：")
    print("    · ② 组红 ⇒ 二进制没换成新版（部署那步没跑 / 跑在别的机器上）")
    print("    · ②-5 红 ⇒ 兜底路由把未知路径也拦成 401/200 ⇒ ②-1~②-4 的证据力下降")
    print("    · ④ 组红 ⇒ 构建产物不是这个 commit 编的")
    print("    · ⑥ 组红 ⇒ 新表没进 init_database（新库有、老库没有）")
print("═" * 74)
sys.exit(1 if _failures else 0)

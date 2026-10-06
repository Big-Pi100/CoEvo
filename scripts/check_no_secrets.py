#!/usr/bin/env python3
"""明文凭据门禁 —— 扫「**会被提交**」的文件里有没有真密钥。

# 🔴 为什么需要它（2026-10-06 实测踩到）

为绕开 GitHub Actions 额度耗尽，白哥定了「出包时临时把仓库改公开」——
动手前审计发现：**git 历史 + 当前版本里都有真实 API Key**。
根因不是「忘了 gitignore」（`.env` 早就屏蔽了），而是：
**密钥被写进了 `.md` 文档与 `.py` 脚本** —— `.gitignore` 管不到那种情况。

⇒ 所以门禁要**按内容扫**，不能只靠 `.gitignore` 按文件名挡。

# 🔑 口径设计：只扫「git 跟踪的文件」

这是本脚本最重要的一个决定。
**风险 = 「进了仓库」**，不是「存在于磁盘」：
  · `backend/.env` 是**本地密钥文件的正当位置**，且已 gitignore ⇒ **不该报**（报了就是假红）
  · 而「未跟踪文件里的硬编码」虽然不会公开，仍是**卫生问题** ⇒ **单独作附注提示，不导致失败**

📌 判据：**门禁的口径要与「风险」对齐** —— 否则假红会训练人忽略红灯。

# 🔑 为什么用「精确长度」的正则

各家凭据的格式是固定的（长度 + 字符集），精确匹配 ⇒ **误报率极低**：
  · DeepSeek / OpenAI : `sk-` + 32 位十六进制
  · 腾讯云 SecretId    : `AKID` + 32 位字母数字（共 36）
  · GitHub PAT         : `ghp_` + 36 位
  · AWS Access Key ID  : `AKIA` + 16 位大写
  · 私钥块             : `-----BEGIN ... PRIVATE KEY-----`

⚠️ 宽松模式（如 `sk-.{20,}`）会把 `sk-xxx`、`sk-your-api-key` 这类**占位符**全报出来 ⇒ 噪音。
   本项目的实测先例：`AKIDfake_fake_fake`（文档里的**假**密钥示例）如果按 `AKID[a-zA-Z0-9]{16,}`
   就会被误报 —— 精确长度（+32）刚好避开。

用法：
    python scripts/check_no_secrets.py            # 扫跟踪文件（作为门禁）
    python scripts/check_no_secrets.py --verbose  # 附注也详细打印
退出码：0 = 干净；1 = 跟踪文件里有明文凭据；2 = 用法/环境错误
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

# ── 精确模式（格式固定 ⇒ 低误报）────────────────────────────────────
PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("DeepSeek/OpenAI Key", re.compile(r"\bsk-[0-9a-f]{32}\b")),
    ("腾讯云 SecretId", re.compile(r"\bAKID[A-Za-z0-9]{32}\b")),
    ("GitHub PAT", re.compile(r"\bghp_[A-Za-z0-9]{36}\b")),
    ("AWS Access Key ID", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    # 🔴 私钥块**必须**要求「BEGIN 行后面真的跟着 base64 内容」——
    #    只匹配 `-----BEGIN ... PRIVATE KEY-----` 会出现大量**假红**（实测踩到 5 处）：
    #      · `iap_handlers.rs` 的**文档注释**（说明 PEM 里含这一行）
    #      · `iap_handlers.rs` 的**测试代码**（`format!("-----BEGIN…\n{}\n…")`，后面是 `{}`）
    #      · `owner-action-checklist` 的**配置说明**（告诉白哥 .p8 文件长什么样）
    #    ⇒ 加 `[A-Za-z0-9+/=]{64,}` 后，上面三种都不匹配（{ } ` 都不是 base64 字符），
    #      而真 .p8 的第一行 base64 就有 64 字符 ⇒ 能抓到。
    #    📌 判据：**门禁的假红会训练人忽略红灯** ⇒ 第一版就要修掉，不能留着。
    ("私钥块", re.compile(
        r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\\n]*[A-Za-z0-9+/=]{64,}"
    )),
]

# ── 允许清单（确有正当理由出现这些模式的文件）──────────────────────
# ⚠️ 加进这里必须写清理由，否则等于把门禁关掉。
ALLOWLIST: set[str] = set()
# 例：("tests/fixtures/fake_keys.txt")  ← 纯测试夹具，且值本身是假的

# ── 跳过（二进制 / 体积过大 / 生成物）──────────────────────────────
SKIP_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".webp", ".pdf", ".zip", ".gz",
    ".woff", ".woff2", ".ttf", ".otf", ".so", ".dylib", ".dll", ".exe", ".bin",
    ".o", ".a", ".rlib", ".rmeta", ".mp3", ".mp4", ".wav", ".db", ".sqlite",
    ".lock",  # lock 文件里是包哈希，不是凭据（且体积大）
}
MAX_BYTES = 2_000_000  # 单文件上限 2 MB


def looks_like_placeholder(val: str) -> bool:
    """判断命中的串是不是**占位符**而非真凭据。

    🔴 为什么需要它（实测）：`AKID` + 32 个 `x`（文档里极常见的占位符写法）
        **完全符合**腾讯云 SecretId 的格式（长度 + 字符集）⇒ 精确正则也挡不住。
    判据：看**主体部分的字符种类数**。真 key 是随机的（几十种字符），
       占位符是靠重复填充的（1~2 种，如 `xxx…` / `000…` / `AAA…`）。
    """
    body = re.sub(r"^(sk-|AKID|ghp_|AKIA)", "", val)
    # 私钥块（含 BEGIN/END 与换行）不适用这个判据 —— 它本来就有大量重复
    if "PRIVATE KEY" in val:
        return False
    return len(set(body)) <= 2


def repo_root(start: Path) -> Path:
    """靠特征文件找仓库根 —— cwd 无关（CI 与本地都能跑）。"""
    cur = start.resolve()
    for cand in [cur, *cur.parents]:
        if (cand / "app" / "pubspec.yaml").exists() or (cand / ".git").exists():
            return cand
    return cur


def tracked_files(root: Path) -> list[str]:
    r = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=root, capture_output=True, text=True, errors="replace",
    )
    if r.returncode != 0:
        print("🔴 无法执行 git ls-files（需要 git 仓库）", file=sys.stderr)
        sys.exit(2)
    return [f for f in r.stdout.split("\0") if f]


def scan(path: Path) -> list[tuple[str, str, int, str]]:
    """返回 [(模式名, 相对路径, 行号, 掩码片段)]。"""
    hits: list[tuple[str, str, int, str]] = []
    try:
        raw = path.read_bytes()
    except OSError:
        return hits
    if len(raw) > MAX_BYTES or b"\0" in raw[:4096]:   # 太大 / 二进制
        return hits
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("utf-8", errors="replace")
    for label, pat in PATTERNS:
        for m in pat.finditer(text):
            val = m.group(0)
            if looks_like_placeholder(val):
                continue
            line = text.count("\n", 0, m.start()) + 1
            masked = val[:8] + "…" + val[-4:] if len(val) > 14 else val
            hits.append((label, str(path), line, masked))
    return hits


def main() -> int:
    ap = argparse.ArgumentParser(description="明文凭据门禁")
    ap.add_argument("--verbose", action="store_true", help="附注（未跟踪文件）也详细打印")
    args = ap.parse_args()

    root = repo_root(Path(__file__).parent)
    files = tracked_files(root)
    if not files:
        print("🔴 git ls-files 返回 0 个文件 —— 门禁不能假绿，显式报错", file=sys.stderr)
        return 2

    print("═" * 74)
    print("明文凭据扫描（只扫 **git 跟踪** 的文件 —— 那才是会被提交的）")
    print("═" * 74)
    print(f"跟踪文件数：{len(files)}")

    bad: list[tuple[str, str, int, str]] = []
    for rel in files:
        if rel in ALLOWLIST:
            continue
        if Path(rel).suffix.lower() in SKIP_SUFFIXES:
            continue
        bad.extend(scan(root / rel))

    # ── 附注：未跟踪文件里的命中（不参与判定，但会提示）──
    notes: list[str] = []
    for pat_name, pat in PATTERNS:
        r = subprocess.run(
            ["git", "grep", "--untracked", "-l", "-E", pat.pattern],
            cwd=root, capture_output=True, text=True, errors="replace",
        )
        for line in r.stdout.splitlines():
            if line and line not in files and line not in notes:
                notes.append(line)

    if bad:
        print(f"\n🔴 跟踪文件里发现 {len(bad)} 处明文凭据：\n")
        for label, f, line, masked in bad:
            print(f"   · {f}:{line}   [{label}]  {masked}")
        print("\n修复方式：")
        print("   · 文档  → 换成占位符 + 指向真实位置（如服务器 /opt/coevo/.env）")
        print("   · 代码  → 改为读环境变量（os.environ.get(\"…\")）")
        print("   🔴 若该凭证仍有效 ⇒ **先去平台吊销**，再改文件（顺序不能反）")
        print("   🔴 若它已进过**历史** ⇒ 光改文件不够，还要清历史（见 skill git-history-purge）")
        return 1

    print("\n✅ 跟踪文件里没有明文凭据")

    if notes:
        print(f"\n附注：未跟踪文件里有 {len(notes)} 个含疑似凭据（不会提交，但建议清理）：")
        for n in notes[:10]:
            print(f"   · {n}")
        if len(notes) > 10:
            print(f"   … 另有 {len(notes) - 10} 个")
        # ⚠️ 附注**不导致失败** —— 未跟踪文件不会被公开（判据见文件头）

    print("\n" + "═" * 74)
    return 0


if __name__ == "__main__":
    sys.exit(main())

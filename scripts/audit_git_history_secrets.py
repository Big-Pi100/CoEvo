#!/usr/bin/env python3
"""历史 blob 全量扫描 + 体积诊断（不打印任何敏感值，只输出哈希）。

用于「仓库改公开」前的审计复核（2026-10-06）。
判据来源：docs/review/git-history-secret-audit-2026-10-05.md
  · 「出现过某字符串」≠「它是真值」→ 必须看实际内容（本脚本按内容特征判定）
  · 安全手法：只输出值的 sha256 前 12 位，绝不打印明文
"""
import hashlib
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(sys.argv[1] if len(sys.argv) > 1 else ".")

# 文本类扩展名（只扫这些，避开 PDF/DB/图片二进制）
TEXT_EXT = {
    ".md", ".py", ".rs", ".sh", ".yaml", ".yml", ".json", ".txt", ".dart",
    ".toml", ".env", ".example", ".sql", ".cfg", ".ini", ".conf", ".gitignore",
}

# 敏感模式（名称 → 正则）
#
# 🔴 2026-10-07 扩充：原版**只覆盖「密钥」一类**，导致「仓库改公开」后
#    才发现 IP / 邮箱同样暴露（SOUL.md 明确要求「无密钥、无 IP、无域名」）。
#    ⇒ 判据：**审计要按「隐私类别」逐类扫，不能只扫密钥。**
#
# ⚠️ IP / 邮箱用**通用正则**而非具体值 —— 两个原因：
#    ① 覆盖面全（不会因"清单不全"漏掉某个 IP）
#    ② 脚本自身不含敏感字面量（否则 filter-repo --replace-text 会把它自己替换掉）
PATTERNS = {
    "deepseek_key": re.compile(rb"sk-[A-Za-z0-9]{20,}"),
    "tencent_akid": re.compile(rb"AKID[A-Za-z0-9]{10,}"),
    "github_pat": re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"),
    "private_key": re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "aws_key": re.compile(rb"AKIA[0-9A-Z]{16}"),
    "slack_token": re.compile(rb"xox[baprs]-[A-Za-z0-9-]{10,}"),
    "password_assign": re.compile(rb"(?i)(password|passwd|pwd)\s*[:=]\s*[\"']?[^\s\"']{8,}"),
    # 🆕 基础设施 / 联系信息（2026-10-07 加）
    "public_ipv4": re.compile(rb"\b(?!0\.|10\.|127\.|169\.254\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.|255\.)(?:\d{1,3}\.){3}\d{1,3}\b"),
    "email_addr": re.compile(rb"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),
}

# 已知的「假值 / 示例」标记 —— 命中这些词的一律判为示例（报告 §四 判据）
FAKE_MARKERS = (b"fake", b"example", b"placeholder", b"your_", b"xxx", b"***", b"REDACTED", b"<", b"test")


def load_blobs():
    """从 git 直接取 (size, path) 列表 —— 不依赖外部临时文件（跨平台路径坑）。"""
    out = subprocess.run(
        ["git", "rev-list", "--objects", "--all"],
        cwd=REPO, capture_output=True, text=True, errors="replace",
    ).stdout.splitlines()
    shas = [line.split(" ", 1)[0] for line in out if " " in line]
    if not shas:
        return []
    proc = subprocess.run(
        ["git", "cat-file", "--batch-check=%(objecttype) %(objectsize) %(rest)"],
        cwd=REPO, input="\n".join(shas).encode(),
        capture_output=True,
    )
    rows = []
    for line in proc.stdout.decode(errors="replace").splitlines():
        parts = line.split(" ", 2)
        if len(parts) != 3 or parts[0] != "blob":
            continue
        try:
            rows.append((int(parts[1]), parts[2]))
        except ValueError:
            continue
    return rows


def main():
    rows = load_blobs()
    print(f"历史 blob 总数: {len(rows)}")

    # ── ① 体积分组（按顶层目录 + 扩展名）──
    by_ext = defaultdict(int)
    by_top = defaultdict(int)
    for size, path in rows:
        ext = Path(path).suffix.lower() or "(无扩展名)"
        by_ext[ext] += size
        top = path.split("/")[0] if "/" in path else "(根)"
        by_top[top] += size

    print("\n═══ ① 体积 Top 10（按扩展名，未压缩）═══")
    for ext, size in sorted(by_ext.items(), key=lambda x: -x[1])[:10]:
        print(f"  {size/1048576:9.1f} MB  {ext}")
    print("\n═══ ① 体积 Top 10（按顶层目录，未压缩）═══")
    for top, size in sorted(by_top.items(), key=lambda x: -x[1])[:10]:
        print(f"  {size/1048576:9.1f} MB  {top}/")

    # ── ② 敏感模式扫描（只扫文本类）──
    print("\n═══ ② 敏感模式扫描（文本类 blob，只输出哈希）═══")
    # 建 path → blob hash 映射（需要 rev-list 的 hash）
    raw = subprocess.run(
        ["git", "rev-list", "--objects", "--all"],
        cwd=REPO, capture_output=True, text=True, errors="replace",
    ).stdout.splitlines()
    hash_to_paths = defaultdict(set)
    for line in raw:
        parts = line.split(" ", 1)
        if len(parts) == 2:
            hash_to_paths[parts[0]].add(parts[1])

    targets = []
    for h, paths in hash_to_paths.items():
        for p in paths:
            if Path(p).suffix.lower() in TEXT_EXT or p.endswith(".env.example"):
                targets.append((h, p))
                break
    print(f"  待扫文本 blob: {len(targets)}")

    hits = defaultdict(list)
    # 用 git cat-file --batch 批量读，避免逐次 spawn
    proc = subprocess.Popen(
        ["git", "cat-file", "--batch"],
        cwd=REPO, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    )
    for h, p in targets:
        proc.stdin.write((h + "\n").encode())
        proc.stdin.flush()
        header = proc.stdout.readline().decode(errors="replace").strip()
        if not header or header.endswith("missing"):
            continue
        try:
            size = int(header.split()[2])
        except (IndexError, ValueError):
            continue
        data = proc.stdout.read(size)
        proc.stdout.read(1)  # 结尾换行
        for name, pat in PATTERNS.items():
            for m in pat.finditer(data):
                val = m.group(0)
                low = val.lower()
                kind = "示例/占位" if any(k in low for k in FAKE_MARKERS) else "真值?"
                digest = hashlib.sha256(val).hexdigest()[:12]
                hits[name].append((kind, digest, p))
    proc.stdin.close()
    proc.wait()

    if not hits:
        print("  ✅ 无命中")
    for name, items in hits.items():
        real = [i for i in items if i[0] == "真值?"]
        print(f"\n  ── {name} ──  命中 {len(items)} 处（其中**非示例** {len(real)} 处）")
        seen = set()
        for kind, digest, p in items:
            key = (kind, digest, p)
            if key in seen:
                continue
            seen.add(key)
            mark = "🔴" if kind == "真值?" else "  "
            print(f"    {mark} {digest}  {p}   [{kind}]")


if __name__ == "__main__":
    main()

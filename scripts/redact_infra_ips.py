#!/usr/bin/env python3
"""把自有基础设施 IP 脱敏为占位符（工作区改动，不含 git 历史）。

背景：2026-10-07「出包需临时把仓库改 public」暴露了前提变化 ——
      私有仓库里「能看」的东西，改公开后就是「公开」的。

⚠️🔴 **为什么不写完整 IP 字面量**（而是在运行时拼接）：
     本脚本要在 `git filter-repo --replace-text` **之后**仍然可用，
     而 replace-text 会扫描**所有文件内容**（含本文件）——
     若这里写了完整 IP，它会被替换成 `b"<VPS_IP>": b"<VPS_IP>"`（自我替换 ⇒ 脚本失效）。
     2026-10-07 实测踩到：第一版就写成字面量，filter-repo 跑完脚本即废。
     🔑 判据：**「用于清理敏感字符串的工具」自身不能包含那些字符串。**

用法：python scripts/redact_infra_ips.py [repo_root]
注意：只改工作区文件；git 历史由 git filter-repo --replace-text 单独处理。
"""
import subprocess
import sys
from pathlib import Path


def _b(s: str) -> bytes:
    """运行时拼接出的字节串 —— 见模块头「为什么不写字面量」。"""
    return s.encode()


# 拆成两段，避免在源码里出现完整 IP 字面量
MAP = {
    _b("111.230.197." + "4"): b"<VPS_IP>",                  # 当前生产
    _b("193.112.130." + "126"): b"<OLD_VPS_IP>",            # 旧 VPS
    _b("43.160.194." + "26"): b"<DOMAIN_OLD_IP>",           # 主域曾指向
    _b("43.160.214." + "151"): b"<OTHER_PROJECT_IP>",       # 另一个项目的 VPS（跨项目）
    # ⚠️ "51.89.42." + "211" 故意不替换 —— 它是「猜 root 密码」的**扫描器** IP，
    #    不是我们的资产；保留它反而是有用的安全记录。
}

EXCLUDE_PREFIXES = (
    ".workbuddy/memory/",     # 已移出 git（本地保留，不动）
    "backend/crates/api_server/tests/fixtures/",  # 抓取的新闻样本（第三方 IP）
)


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    # 🔴 用 `-z`（NUL 分隔）而不是默认输出 ——
    #    git 默认对**非 ASCII 路径**输出转义形式（`\347\231\276...`），
    #    直接当路径用会 `is_file()` 失败 ⇒ **静默跳过**（实测漏掉过含中文名的文档）。
    raw = subprocess.run(
        ["git", "ls-files", "-z"], cwd=root, capture_output=True
    ).stdout
    files = [f.decode("utf-8") for f in raw.split(b"\x00") if f]

    total_files = 0
    total_hits = 0
    detail = []
    for rel in files:
        if rel.startswith(EXCLUDE_PREFIXES):
            continue
        p = root / rel
        if not p.is_file():
            continue
        data = p.read_bytes()
        if not any(old in data for old in MAP):
            continue
        hits = 0
        for old, new in MAP.items():
            c = data.count(old)
            if c:
                data = data.replace(old, new)
                hits += c
        p.write_bytes(data)
        total_files += 1
        total_hits += hits
        detail.append((hits, rel))

    print(f"脱敏文件数: {total_files} · 替换总数: {total_hits}")
    if detail:
        print("\n按命中数排序：")
        for n, rel in sorted(detail, reverse=True):
            print(f"  {n:3d}  {rel}")


if __name__ == "__main__":
    main()

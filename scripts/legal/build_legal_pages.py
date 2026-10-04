#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CoEvo 法律文本 → 可部署 HTML

把 `docs/legal/privacy-policy.md` / `terms-of-service.md` 渲染成**可公开访问的
HTML 页面**（Apple 上架硬要求 + 订阅页法定必填）。

# 为什么需要它（而不是「手工转一次」）

法律文本会**长期修订**（新增收集项、改联系方式、改价格）。每次修订都要：
替换占位符 → 转 HTML → 部署。**手工做三次就会漂**（漏填某个占位符、改了一处忘了另一处）。
⇒ 固化成脚本，且**生成后校验「无残留占位符」**（漏填直接失败，而不是把
「【待填：联系邮箱】」发布到公网 —— 那等于公开承认法律文本不完整）。

# 🔴 隐私：为什么不直接把姓名/邮箱写进 md

`docs/legal/*.md` 是**模板**（含占位符）⇒ 进 git 的只有模板。
真实姓名/邮箱通过**命令行参数**注入 ⇒ **不进 git 历史**。
📌 判据：**能公开的进源文件，只有你知道的走参数**。

# 用法

    # 预览（用示例值，输出到 build/ —— 仅供查看效果，不可部署）
    python scripts/legal/build_legal_pages.py --dry-run

    # 正式生成
    python scripts/legal/build_legal_pages.py \\
        --operator "张三" --email "support@example.com" \\
        --base-url "https://api.keyievolution.fun" \\
        --out build/legal

# 依赖：pandoc（成熟工具，不自建 md→html 转换）

# 退出码：0 = 成功 · 1 = 有残留占位符或转换失败 · 2 = 用法错误
"""

from __future__ import annotations

import argparse
import datetime
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
LEGAL_DIR = REPO_ROOT / "docs" / "legal"
TEMPLATE = LEGAL_DIR / "templates" / "legal-page.html"

# (源 md, 输出文件名, 页面标题, 需要的额外替换)
PAGES = [
    ("privacy-policy.md", "privacy.html", "CoEvo 隐私政策"),
    ("terms-of-service.md", "terms.html", "CoEvo 用户协议"),
]

# 🔴 占位符 → 替换值的映射（`{operator}` / `{email}` / `{privacy_url}` 由参数填充）
#
# ⚠️ **顺序有意义**（Python dict 保序）：**整段替换必须排在单 token 之前** ——
#    否则单 token 先被吃掉，整段就匹配不上了。
#
# ⚠️ 每加一个占位符都必须在这里登记 —— 否则会被下面的「残留检查」拦下
#    （这正是我们要的：宁可生成失败，也不要发布残缺的法律文本）。
PLACEHOLDER_MAP = {
    # ── 🔴 整段替换（不是换占位符，是修**两个渲染 bug**）──────────────
    #
    # 源 md 写的是：
    #     `[《隐私政策》](./privacy-policy.md)（【待填：链接】）`
    #
    # 直接渲染会出两个问题（2026-10-04 实测产物时发现）：
    #   ① `./privacy-policy.md` 在 md 语境下是「同目录文件引用」，但**渲染成 HTML 后
    #      就是死链** —— 服务器上根本没有 `.md` 文件（点了 404）。
    #   ② `（https://...privacy）` 里的**中文右括号被 pandoc 吞进 URL** ⇒
    #      产出 `href="https://.../privacy）"`（含非法字符），链接照样坏，
    #      而且显示文本里括号重复。
    #
    # ⇒ 整段替换成**一个正确的 markdown 链接**：两个问题一并解决，
    #    且不在括号里重复显示 URL（链接本身就是 URL，重复是冗余）。
    #
    # 📌 教训：**「占了位」不等于「渲染对了」** ——
    #    占位符替换是字符串层面的事，**链接能不能点是渲染层面的事**。
    #    所以本脚本除了查占位符残留，还必须查**产物里的链接**（见 `find_bad_links`）。
    "[《隐私政策》](./privacy-policy.md)（【待填：链接】）":
        "[《隐私政策》]({privacy_url})",

    "【待填：开发者/运营者姓名】": "{operator}",

    # ── 🔴 邮箱替换成 **markdown 链接**（不是裸邮箱）────────────────────
    #
    # 直接替换成裸邮箱会出问题（2026-10-04 实测，被 `find_bad_links` 抓到）：
    #     md 里是 `发送邮件至【待填：联系邮箱】`
    #              → 替换后 `发送邮件至support@keyievolution.fun`
    #              → pandoc 把**「发送邮件至」也当成邮箱的一部分**
    #                （RFC 允许 UTF-8 local part）⇒ 产出
    #                `href="mailto:发送邮件至support@keyievolution.fun"` —— **坏链接**。
    #
    # ✅ 用 `[邮箱](mailto:邮箱)`：pandoc **优先解析 link 语法**，
    #    中文不会被吞；同时链接**可点**（法律文本里的联系方式应当能点）。
    #    ⚠️ 不要试图用「禁用 autolink」绕开 —— 那会让裸邮箱**不可点**，
    #       而「联系邮箱」正是最该可点的一处。
    "【待填：联系邮箱】": "[{email}](mailto:{email})",
    # 🔑 「注销入口或联系邮箱」短期填**邮箱**（邮件申请也是合法渠道）。
    #    ⏳ 长期应改为 App 内注销入口 —— 那是 Apple 5.1.1(v) 的要求，
    #       目前前后端零实现（见 docs/operations/owner-action-checklist-2026-10-04.md §7.2）。
    "【待填：注销入口或联系邮箱】": "[{email}](mailto:{email})",
}

# 🔴 还有一类**不是 `【待填】` 格式**的占位符：**日期**。
#
# 文档里写的是「2026 年 10 月 __ 日」（生效日期 / 最近更新）——
# `__` 看起来像「下划线填空」，但**长得不像占位符标记** ⇒ 第一版替换表**漏了它**，
# 生成出来是「2026 年 10 月 __ 日」，而且**残留检查也查不到**
# （我原来只搜 `【...】`）。
# 📌 教训：**「占位符」的识别口径要覆盖所有形态** —— 只按一种格式搜，
#    就会有「检查通过、实际残缺」的假绿。
#
# 🔑 用正则匹配**整个日期**（年/月/日 都换掉），而不是只替换 `__` ——
#    否则跨月发布时月份会留着旧值（如 10 月里发布 11 月的文本）。
DATE_RE = re.compile(r"\d{4} 年 \d{1,2} 月 __ 日")

# 整行删除的规则（这些行对应的内容**当前不存在**，留着反而误导）
#
# 当前仅一条：「历史版本链接」—— 我们没有历史版本 ⇒ 删掉整行，
# 而不是填一个指向不存在页面的链接（放死链比不放进糟糕）。
DROP_LINE_PREFIXES = [
    "> 📌 **本政策的历史版本**",
]


def find_pandoc() -> str:
    """定位 pandoc —— 找不到就**明确报错**，不要静默降级到自建转换。"""
    p = shutil.which("pandoc")
    if p:
        return p
    # Windows 常见安装位（PATH 可能没刷新）
    for cand in [
        r"C:\Program Files\Pandoc\pandoc.exe",
        r"C:\Program Files (x86)\Pandoc\pandoc.exe",
    ]:
        if Path(cand).exists():
            return cand
    raise SystemExit(
        "🔴 未找到 pandoc。\n"
        "   安装：https://pandoc.org/installing.html\n"
        "   （本项目判据：md→html 用成熟工具，不自建转换器）"
    )


def render_md(md_text: str, values: dict[str, str]) -> str:
    """替换占位符 + 删除不存在的条目。"""
    out_lines: list[str] = []
    for line in md_text.splitlines():
        if any(line.lstrip().startswith(p) for p in DROP_LINE_PREFIXES):
            continue
        out_lines.append(line)
    text = "\n".join(out_lines)

    # ① 日期占位（`2026 年 10 月 __ 日`）→ 实际生效日期
    text = DATE_RE.sub(values["date"], text)

    # ② `【待填：...】` 一类
    for token, tmpl in PLACEHOLDER_MAP.items():
        if token not in text:
            continue
        text = text.replace(token, tmpl.format(**values))
    return text


def find_leftover_placeholders(text: str) -> list[str]:
    """🔴 关键校验：找出所有残留的占位符。

    有残留 ⇒ **必须失败**。因为它的后果是「把未填完的法律文本发布到公网」——
    比构建失败严重得多（用户/审核员会直接看到「【待填：联系邮箱】」）。

    ⚠️ 覆盖**两种形态**（只查一种就会假绿 —— 第一版就漏了日期）：
      · `【待填：...】` —— 方括号标记
      · `__ 日`         —— 日期填空（不是方括号格式，但同样不能发布）
    """
    found = set(re.findall(r"【[^】]*】", text))
    if "__ 日" in text:
        found.add("__ 日（生效日期未填）")
    return sorted(found)


def find_bad_links(html: str) -> list[str]:
    """🔴 查**产物 HTML** 里的坏链接（只在字符串层查占位符是抓不到的）。

    # 为什么必须单独做这一步（2026-10-04 实测踩到）

    占位符替换是**字符串**层面的事；而「链接能不能点」是**渲染**层面的事。
    源 md 写 `[《隐私政策》](./privacy-policy.md)` 在 md 语境下完全正常
    （同目录文件引用），**渲染成 HTML 后却成了死链**（服务器上没有 .md 文件）。
    这类问题**残留检查看不见** —— 它没有占位符。
    📌 判据：**「占了位」≠「渲染对了」**；**产物要按它自己的形态去验**。

    检查两类：
      ① `href` 指向 **`.md`** —— 源文档的相对路径，上线后必然 404
      ② `href` 含**非 ASCII**（如被吞进 URL 的中文右括号 `）`）—— 非法 URL
    """
    problems: list[str] = []
    for m in re.finditer(r'href="([^"]*)"', html):
        href = m.group(1)
        if href.endswith(".md"):
            problems.append(f"指向 .md 的死链：{href}")
        bad = [c for c in href if ord(c) > 127]
        if bad:
            problems.append(f"href 含非 ASCII 字符 {''.join(bad)!r}：{href}")
    return sorted(set(problems))


def main() -> int:
    ap = argparse.ArgumentParser(description="法律文本 → HTML")
    ap.add_argument("--operator", help="运营者姓名（须与 App Store 主体一致）")
    ap.add_argument("--email", help="对外联系邮箱")
    ap.add_argument(
        "--base-url",
        default="https://api.keyievolution.fun",
        help="法律页所在基址（用于「用户协议 → 隐私政策」的绝对链接）",
    )
    ap.add_argument("--out", default="build/legal", help="输出目录（相对仓库根）")
    ap.add_argument(
        "--effective-date",
        help="生效日期（默认=今天）。格式随意，推荐 `2026 年 10 月 4 日`",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="用示例值生成（仅供预览，**不可部署**）",
    )
    args = ap.parse_args()

    dry = args.dry_run
    operator = args.operator or ("（示例）运营者姓名" if dry else None)
    email = args.email or ("（示例）support@example.com" if dry else None)
    if not operator or not email:
        print("🔴 缺少 --operator / --email（或用 --dry-run 预览）", file=sys.stderr)
        return 2

    base = args.base_url.rstrip("/")

    # 🔑 生效日期默认 = **今天**，而不是写死在模板里：
    #    「生效日期」的语义就是「这份文本开始生效的日子」= 发布日。
    #    ⚠️ 但**允许覆盖** —— 若先备好文本、几天后才发布，应填实际发布日。
    #    ⚠️ 不补零（`10 月 4 日` 而非 `10 月 04 日`）—— 与文档既有写法一致。
    eff = args.effective_date or (
        f"{datetime.date.today().year} 年 "
        f"{datetime.date.today().month} 月 "
        f"{datetime.date.today().day} 日"
    )

    values = {
        "operator": operator,
        "email": email,
        "date": eff,
        # 🔑 绝对 URL：用户协议里指向隐私政策。用绝对地址（而非相对路径），
        #    因为两份文档可能被分开分享/打印。
        "privacy_url": f"{base}/privacy",
    }

    out_dir = (REPO_ROOT / args.out).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    if not TEMPLATE.exists():
        print(f"🔴 模板缺失：{TEMPLATE}", file=sys.stderr)
        return 1

    pandoc = find_pandoc()
    print(f"pandoc: {pandoc}")
    print(f"输出:   {out_dir}")
    if dry:
        print("⚠️  --dry-run：使用**示例值**，仅供预览，**不可部署**")
    print()

    failed = False
    for md_name, html_name, title in PAGES:
        src = LEGAL_DIR / md_name
        if not src.exists():
            print(f"🔴 缺源文件：{src}")
            failed = True
            continue

        raw = src.read_text(encoding="utf-8")
        rendered = render_md(raw, values)

        leftover = find_leftover_placeholders(rendered)
        if leftover:
            # ⚠️ 这里**不抛异常就继续**是故意的：一次把两份文档的问题都报出来，
            #    而不是修一个再跑一次（减少往返）。但最终会返回 1。
            print(f"🔴 {md_name} 仍有未替换的占位符：{leftover}")
            failed = True
            continue

        # 临时 md → pandoc 渲染
        tmp_md = out_dir / f".{md_name}"
        tmp_md.write_text(rendered, encoding="utf-8")
        dst = out_dir / html_name
        try:
            subprocess.run(
                [
                    pandoc,
                    str(tmp_md),
                    "-o",
                    str(dst),
                    f"--template={TEMPLATE}",
                    "--from=gfm",          # gfm：支持表格（本文档大量使用）
                    "--standalone",
                    f"--metadata=title={title}",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
        except subprocess.CalledProcessError as e:
            print(f"🔴 pandoc 渲染 {md_name} 失败：\n{e.stderr}")
            failed = True
            continue
        finally:
            tmp_md.unlink(missing_ok=True)

        # 🔴 查**产物**里的坏链接 —— 字符串层的占位符检查抓不到这类问题
        #    （死链没有占位符可查）。见 `find_bad_links` 的说明。
        bad = find_bad_links(dst.read_text(encoding="utf-8"))
        if bad:
            print(f"🔴 {html_name} 有 {len(bad)} 处坏链接：")
            for b in bad:
                print(f"     · {b}")
            failed = True
            continue

        size = dst.stat().st_size
        print(f"✅ {md_name} → {html_name}  ({size:,} 字节)")

    print()
    if failed:
        print("🔴 生成未完成 —— 见上面的错误")
        return 1

    print("✅ 全部生成成功")
    if dry:
        print("\n📌 预览用：直接在浏览器打开上面两个 .html 即可看效果。")
    else:
        print("\n下一步（部署）：scripts/legal/publish_legal_pages.sh")
    return 0


if __name__ == "__main__":
    sys.exit(main())

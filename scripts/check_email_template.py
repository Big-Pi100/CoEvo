#!/usr/bin/env python3
"""CoEvo · 邮件模板规范自查（腾讯云 SES + 邮件客户端兼容性）

用法：
    python scripts/check_email_template.py                              # 查默认目录全部模板
    python scripts/check_email_template.py docs/operations/email-templates/password-reset.html
    python scripts/check_email_template.py <目录>

# 为什么需要它

邮件模板有**三套约束**，而且**错了不会报错**（腾讯云模板要审核，但审核不通过时
只给一句笼统的「模板内容错误」；而兼容性问题要等用户真的收到邮件才暴露）：

| 约束来源 | 典型错法 | 后果 |
|---|---|---|
| 腾讯云规范 | 用了 `<style>` 标签 / 外部 CSS | 审核不通过 |
| 腾讯云规范 | 出现「加群 / 二维码 / 加微信」 | 🔴 **直接被拒**（硬性禁项）|
| 腾讯云规范 | 变量写成 `{code}` 而非 `{{code}}` | 用户收到字面的 `{code}` |
| 邮件客户端兼容 | 用 flex/grid 布局 | Outlook（Word 引擎）**错版** |
| 邮件客户端兼容 | 用了图片 | 客户端默认不加载 ⇒ 一块空白 |
| 内容质量 | 图片/链接指向第三方 | **数据出境**风险 |

⇒ 这些都能**程序化检查**，就不该靠人肉看。

⚠️ 本脚本**不能**替代：
    · 真的发一封到自己邮箱看渲染（客户端差异只有真机能验）
    · 腾讯云的复核（它是最终裁判）
"""

import pathlib
import re
import sys

# 🔴 腾讯云审核的硬性禁项（出现即大概率被拒）
BANNED_TERMS = [
    "二维码", "加群", "微信群", "QQ群", "加微信", "扫码", "关注公众号",
    "加qq", "加微信", "引流",
]

# 邮件客户端不认的现代布局（Outlook 用 Word 渲染引擎）
MODERN_LAYOUT = ["display:flex", "display: grid", "display:grid", "flex-direction", "grid-template"]


def check_html(path: pathlib.Path) -> list[str]:
    s = path.read_text(encoding="utf-8")
    low = s.lower()
    fails: list[str] = []

    # ── 1. 腾讯云硬性规范 ──
    if "<link" in low:
        fails.append("含 <link>（外部 CSS）⇒ 腾讯云明确禁止")
    if "@import" in s:
        fails.append("含 @import ⇒ 外部 CSS")
    if "<style" in low:
        fails.append("含 <style> 标签 ⇒ 与「全部内联」冲突（且 Gmail 会剥离部分规则）")
    if "<script" in low:
        fails.append("含 <script> ⇒ 邮件客户端一律不执行，且会触发审核疑问")

    # 变量：必须是 {{双花括号}}
    vars_found = re.findall(r"\{\{([^}]+)\}\}", s)
    single = re.findall(r"(?<!\{)\{([a-zA-Z_][a-zA-Z0-9_]*)\}(?!\})", s)
    if single:
        fails.append(
            f"发现**单花括号**写法 {single} ⇒ 腾讯云只认 {{{{双花括号}}}}，"
            f"否则用户会看到字面的 {single[0]} 而不是验证码"
        )
    if not vars_found:
        fails.append("没有任何 {{变量}} —— 确认这是否是故意（无变量的模板也合法，但要清楚）")

    # ── 2. 审核禁项 ──
    hits = [t for t in BANNED_TERMS if t in s]
    if hits:
        fails.append(f"🔴 命中审核禁项 {hits} ⇒ 腾讯云模板禁止「加群 / 二维码 / 加微信」类内容")

    # ── 3. 可渲染性 ──
    if "charset" not in low:
        fails.append("缺 charset 声明 ⇒ 中文可能乱码")
    if "<img" in low:
        fails.append("含 <img> ⇒ ① 多客户端默认不加载（露白）② 图片需外链（可用性/出境风险）")
    if "background-image" in low:
        fails.append("用了 background-image ⇒ Outlook 不支持；关键信息绝不能放背景图")
    for m in MODERN_LAYOUT:
        if m in low.replace(" ", "").replace("display:flex", "display:flex"):
            if m.replace(" ", "") in low.replace(" ", ""):
                fails.append(f"用了 `{m}` ⇒ Outlook（Word 引擎）不认，会错版")
                break
    if "<table" in low and 'role="presentation"' not in low:
        fails.append('table 缺 role="presentation" ⇒ 屏幕阅读器会把它当数据表朗读（无障碍）')
    if "<table" in low and not ('cellpadding="0"' in low and 'cellspacing="0"' in low):
        fails.append('table 缺 cellpadding="0" cellspacing="0" ⇒ 部分客户端出现单元格间隙')

    # ── 4. 变量:文字 比例（腾讯云要求 ≤ 1:5）──
    text_only = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", s)).strip()
    var_len = sum(len(v) + 4 for v in vars_found) or 1
    if len(text_only) < var_len * 5:
        fails.append(
            f"变量:文字 比例不足 1:5（实测 1:{len(text_only)/var_len:.1f}）—— 腾讯云可能判定为「模板化程度过高」"
        )

    # ── 5. 体积 ──
    nbytes = len(s.encode("utf-8"))
    if nbytes > 20480:
        fails.append(f"体积 {nbytes} 字节偏大（>20 KB）⇒ 建议精简")

    # ── 报告 ──
    print(f"\n{'=' * 70}\n{path}\n{'=' * 70}")
    print(f"  体积 {nbytes} 字节 · 变量 {vars_found} · 纯文本 {len(text_only)} 字符"
          f" · 变量:文字 1:{len(text_only)/var_len:.1f}")
    print(f"  内联 style 标签数：{len(re.findall(r'<[a-zA-Z][^>]*\sstyle=', s))}")
    if fails:
        for f in fails:
            print(f"  🔴 {f}")
    else:
        print("  ✅ 全部检查通过")
    return fails


def main() -> int:
    args = sys.argv[1:]
    targets: list[pathlib.Path] = []
    if args:
        for a in args:
            p = pathlib.Path(a)
            targets.extend(sorted(p.rglob("*.html")) if p.is_dir() else [p])
    else:
        d = pathlib.Path("docs/operations/email-templates")
        targets = sorted(d.rglob("*.html")) if d.is_dir() else []

    if not targets:
        print("🔴 没找到任何 .html 模板 —— 检查路径")
        return 2

    all_fails: list[str] = []
    for t in targets:
        all_fails += check_html(t)

    print(f"\n{'=' * 70}")
    if all_fails:
        print(f"🔴 共 {len(all_fails)} 项问题")
    else:
        print(f"✅ 全部通过（{len(targets)} 个模板）")
    print("⚠️ 提醒：本脚本查的是「规范与兼容性」，**不能**替代真机收信看渲染。")
    print(f"{'=' * 70}")
    return 1 if all_fails else 0


if __name__ == "__main__":
    sys.exit(main())

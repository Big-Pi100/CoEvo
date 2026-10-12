#!/usr/bin/env python3
"""检查候选 App 名称在 App Store（中国区）是否已被占用 + 是否踩备案字眼。

用法：
    python scripts/check_app_store_name.py 拾忆 忆读 词忆 ...

## 原理
Apple 的 App 名称**必须全 App Store 唯一**（ASC 里改名重复会直接报错）。
上架后的名称可通过 **iTunes Search API**（公开、免鉴权）查到：
    https://itunes.apple.com/search?term=<名>&country=cn&entity=software&limit=200

**判据（精确匹配，不是模糊）**：
把返回项的 `trackName` 按副标题分隔（` - ` / `：`）取主名，
**恰好等于**候选名 ⇒ 视为**已占用**。
（`trackName` 常形如 `主名 - 副标题`；只做主名比较，避免「XX笔记」误伤「笔记」。）

## 🔴 本脚本的局限（必须知道）
1. 只能查到**已上架**的 App —— 别人在 ASC 里建好但**未上架**的名称**查不到**。
   ⇒ 「未占用」是**必要条件**，不是保证。
2. 只看**中国区**（我们只在中国区上架）。其他国家区的同名 App 不影响我们。
3. 结果里会附**该名下的实际 App**，供人工再判（同名不同类目时尤其要看）。

## 备案字眼（内置检查）
腾讯云官方：「App 名称若包含 **新闻、出版、教育**、医疗保健、药品/医疗器械、
电子公告，广播影视，**文化**、论坛等**字眼或明显属于此类字眼**的，需提供前置审批文件。」
⇒ 按**字眼**判定，不看实际业务。本脚本对每个候选名做字面扫描并给出警示。
"""

import json
import subprocess
import sys
import time
import urllib.parse

# 备案官方列出的字眼（+ 几个保守补充，标注了）
FILING_WORDS = [
    "新闻", "出版", "教育", "医疗保健", "药品", "医疗器械",
    "电子公告", "广播影视", "影视", "文化", "论坛", "宗教",
    # 保守补充：官方未列，但同族联想，建议避开
    "图书", "杂志", "报纸", "教学", "培训", "课程", "学院", "学校",
]

API = "https://itunes.apple.com/search"


def fetch(term: str, country: str = "cn") -> list:
    """调 iTunes Search API，返回 trackName 列表。"""
    q = urllib.parse.urlencode({
        "term": term, "country": country, "entity": "software", "limit": 200,
    })
    url = f"{API}?{q}"
    # 用 curl（python 的 urllib 在本项目沙箱里可能被拦）
    out = subprocess.run(
        ["curl", "-s", "-m", "25", url],
        capture_output=True, text=True, encoding="utf-8",
    ).stdout
    try:
        return json.loads(out).get("results", [])
    except Exception:
        return []


def main_name(track_name: str) -> str:
    """剥掉副标题（` - ` / `：` / `:` 之后的部分）。"""
    for sep in (" - ", "：", ":"):
        if sep in track_name:
            return track_name.split(sep, 1)[0].strip()
    return track_name.strip()


def filing_warnings(name: str) -> list:
    return [w for w in FILING_WORDS if w in name]


def main() -> None:
    cands = sys.argv[1:]
    if not cands:
        print(__doc__)
        return

    print("=" * 74)
    print("候选 App 名称检查（App Store 中国区占用 + 备案字眼）")
    print("=" * 74)

    ok_names, taken_names = [], []

    for cand in cands:
        results = fetch(cand)
        exact = [r for r in results
                 if main_name(r.get("trackName", "")) == cand]
        words = filing_warnings(cand)

        flag = "✅ 未占用" if not exact else "🔴 已占用"
        warn = "" if not words else "  ⚠️ 备案字眼：" + "/".join(words)
        print(f"\n  {flag}  「{cand}」  （模糊结果 {len(results)} 条）{warn}")

        if exact:
            for r in exact[:3]:
                print(f"        · 占用者：{r.get('trackName')}"
                      f"  | {r.get('sellerName')}"
                      f"  | {r.get('primaryGenreName')}")
            taken_names.append(cand)
        elif words:
            pass
        else:
            ok_names.append(cand)

        time.sleep(0.4)  # 温和限流

    print("\n" + "=" * 74)
    print(f"✅ 未占用且无备案字眼（{len(ok_names)}）：{' · '.join(ok_names) or '（无）'}")
    print(f"🔴 已占用（{len(taken_names)}）：{' · '.join(taken_names) or '（无）'}")
    print("=" * 74)
    print("⚠️ 局限：只覆盖**已上架**的 App —— 别人建好未上架的名称查不到。")
    print("   「未占用」是必要条件，不是保证；填 ASC 时仍可能报重复。")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""CoEvo · Python 脚本语法门禁（`scripts/**/*.py`）

用法：
    python scripts/check_python_syntax.py            # 扫仓库的 scripts/
    python scripts/check_python_syntax.py <目录/文件>  # 扫指定位置
    python scripts/check_python_syntax.py --quiet     # 只输出结论（CI 用）

# 🔴 为什么需要它（2026-10-05 的真实教训）

我改一个脚本的文档字符串时，`Edit` 的 `new` 内容**漏掉了结尾的 `\"\"\"`** ——
于是整个文件的 docstring **没有闭合**，后面的代码全被当成字符串的一部分。
`import` 时报 `SyntaxError: invalid character '（' (U+FF08)`，而报错行号指向**别处**
（第 59 行），完全看不出真凶在第 41 行。

而当时：
* Rust 侧有 `cargo check`（CI 里跑）
* Dart 侧有 `codestatic` / `flutter analyze`（CI 里跑）
* 🐍 **Python 侧什么都没有** —— 120 个 `.py` 文件，改了没人验语法

📌 判据：**「写了没人跑 = 迟早失效」** —— 没有门禁的语言，出错只能等它真的被运行时撞上。
   本次是**在提交前手工跑了一次 `py_compile`** 才发现的；手工步骤不叫门禁。

⇒ 本脚本把「120 个 Python 文件语法检查」变成**秒级、可重复、进 CI** 的一步。

# 与其他门禁的分工

| 语言 | 有编译检查吗 | 谁在跑 |
|---|---|---|
| Rust | ✅ `cargo check` / `clippy` | CI `backend` job |
| Dart/Flutter | ✅ `flutter analyze` / `codestatic` | CI `frontend` job |
| 🐍 Python | 🆕 **本脚本** | CI `query-verify` job（与 `verify_script_portability.dart` 同属「守 scripts/ 自身」）|

# ⚠️ 它能做什么、不能做什么

* ✅ **语法**（`SyntaxError`）—— 这正是本次漏掉的那类
* ❌ **不能**发现「变量名写错」「import 不存在」「逻辑错」——
    那些要运行才知道。本脚本**只**保证「能编译」。
* ⚠️ 也不检查「未使用的 import」「风格」等 —— 那需要 ruff/flake8 之类的额外依赖，
    而本仓库的 Python 工具是**零依赖**的（不引入新依赖是刻意取舍）。
"""

import argparse
import pathlib
import py_compile
import sys
import tempfile


def repo_root(start: pathlib.Path) -> pathlib.Path:
    """从 `start` 向上找仓库根（靠**特征文件**，不靠层数）。

    🔑 与 `scripts/query_verify/bin/_repo_paths.dart` 同一口径：
       「靠特征文件定位」比「靠相对层数」稳 —— 后者在 cwd 变化时就错了。
    """
    d = start.resolve()
    for _ in range(8):
        if (d / "app" / "pubspec.yaml").is_file():
            return d
        if d.parent == d:
            break
        d = d.parent
    return start.resolve()


def check_one(path: pathlib.Path, cfile: str) -> str | None:
    """返回 None = 通过；否则返回错误摘要。"""
    try:
        py_compile.compile(str(path), cfile=cfile, doraise=True)
        return None
    except py_compile.PyCompileError as e:
        # 只取第一行（含文件名与行号），避免刷屏
        first = str(e).strip().split("\n")
        return first[1].strip() if len(first) > 1 else first[0].strip()
    except Exception as e:  # noqa: BLE001 —— 读文件失败等也要报，不能静默跳过
        return f"{type(e).__name__}: {e}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="*", help="要检查的目录或文件（默认为仓库 scripts/）")
    ap.add_argument("--quiet", action="store_true", help="只输出结论")
    args = ap.parse_args()

    targets: list[pathlib.Path] = []
    if args.paths:
        for p in args.paths:
            pp = pathlib.Path(p)
            targets.extend(sorted(pp.rglob("*.py")) if pp.is_dir() else [pp])
    else:
        root = repo_root(pathlib.Path.cwd())
        sd = root / "scripts"
        if not sd.is_dir():
            print(f"🔴 找不到 scripts/ 目录（仓库根={root}）⇒ 路径判断错了会让下面**假绿**")
            return 2
        targets = sorted(sd.rglob("*.py"))

    # 🔑 「扫到 0 个文件」必须能与「真的没有」区分 —— 否则路径写错会让门禁静默通过
    if not targets:
        print("🔴 扫到 0 个 .py 文件 ⇒ 路径很可能写错了（门禁会假绿）")
        return 2

    # 排除虚拟环境/缓存目录（若有）
    targets = [
        t for t in targets
        if not any(part in (".venv", "venv", "__pycache__", ".dart_tool") for part in t.parts)
    ]

    failures: list[tuple[pathlib.Path, str]] = []
    with tempfile.TemporaryDirectory() as td:
        cfile = str(pathlib.Path(td) / "out.pyc")
        for t in targets:
            err = check_one(t, cfile)
            if err:
                failures.append((t, err))

    if not args.quiet:
        print(f"扫描 {len(targets)} 个 .py")
    if failures:
        print(f"🔴 {len(failures)} 个文件有语法错误：")
        for f, err in failures:
            print(f"   · {f}")
            print(f"     {err}")
        print()
        print("🔑 常见成因（本项目实踩）：")
        print("   · `Edit` 时**漏掉了字符串/代码块的闭合符号**（如 `\\\"\\\"\\\"`、`}`、`)`）")
        print("     ⇒ 报错行号常常**不在**真正的错误位置，往上找最近的字符串开头")
        print("   · 中英文标点混用（中文全角括号出现在**代码**位置）")
        print("   · 缩进不一致（同一块里混用 Tab 与空格）")
    else:
        print(f"✅ 全部通过（{len(targets)} 个 .py）")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

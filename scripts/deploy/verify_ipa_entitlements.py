#!/usr/bin/env python3
"""校验出包产物里**真的带上了**自定义 entitlements。

# 🔴 为什么需要它（2026-10-13 的真实事故）

`ios-archive.yml` 在 2026-10-11（提交 `6575f35`）为了解决「Development 证书被 CI 刷爆」，
把归档改成 `CODE_SIGNING_ALLOWED=NO`（**完全不签名**）。
当时只验了「CI 成功 = 包出来了」，**没验「包带对了能力」**。

后果：Apple 官方原话 —— *entitlements are carried by the code signature,
so if the app in the archive isn't signed then there's nothing to preserve.*
⇒ **所有自定义 entitlements 在导出阶段静默丢失**，
`com.apple.developer.applesignin` 首当其冲 ⇒ 真机上点「通过 Apple 继续」**毫无反应**。

📌 判据：**「构建成功」≠「产物可用」**。这一步把「可用」变成一条**可红**的断言。

# 它查什么 / 怎么查

查**代码签名 blob 里实际携带的 entitlements**（运行时生效的就是这一份），
而不是描述文件里「被授予」的那份 —— 两者差一层，而事故恰恰出在这一层。

要求哪些 key：**直接读 `Runner.entitlements`**（唯一权威）。
🔑 好处：将来新增能力（推送 / 关联域 / App Groups…）**不必改本脚本、也不必改 workflow**。

# 🔴 阳性对照（防「检测器失效 ⇒ 假绿」）

若扫描器本身坏了（例如字节序写错），它会报「什么都没找到」——
看起来和「真的没有」一模一样。所以先断言 **SuperBlob magic 命中 ≥1**
（`0xfade0cc0`，**大端**存储）⇒ 证明「这个包确实签过名」。
没有这一步，本脚本可能把「没签名」误报成「签了但没 entitlements」，也可能反过来。

> 实测教训：本脚本第一版按**小端**扫 `0xfade7171`（`71 71 de fa`）⇒ 扫不到任何东西
> ⇒ 差点把「有」判成「没有」。Apple 的 code-signing blob **一律大端**。

跑法：
    python3 scripts/deploy/verify_ipa_entitlements.py <产物> [--entitlements <Runner.entitlements>]

`<产物>` 支持三种：`.ipa` / `.app`（目录）/ `.xcarchive`
"""

from __future__ import annotations

import argparse
import plistlib
import re
import struct
import sys
import zipfile
from pathlib import Path

# Apple code-signing blob 的 magic（**大端**存储）
MAGIC_SUPERBLOB = b"\xfa\xde\x0c\xc0"  # 0xfade0cc0 —— 整个签名容器
MAGIC_ENTITLEMENTS = b"\xfa\xde\x71\x71"  # 0xfade7171 —— entitlements 本体

# 系统会**改写值**的 key（值不该逐字比对，只断言「存在」）
#   · application-identifier / keychain-access-groups 会被加上 Team 前缀
VALUE_REWRITTEN_KEYS = {
    "application-identifier",
    "com.apple.developer.team-identifier",
    "keychain-access-groups",
}

_fail: list[str] = []
_warn: list[str] = []


def _fail_with(msg: str) -> None:
    _fail.append(msg)
    print(f"  🔴 {msg}")


def _warn_with(msg: str) -> None:
    _warn.append(msg)
    print(f"  🟠 {msg}")


def parse_signed_entitlements(exe: bytes) -> list[dict] | None:
    """从 Mach-O 可执行文件里取出**签名携带**的 entitlements。

    返回 `None` 表示「连签名的 SuperBlob 都没有」（= 根本没签名）；
    返回 `[]` 表示「签过名，但没有 entitlements blob」。
    """
    if not exe.count(MAGIC_SUPERBLOB):
        return None
    out: list[dict] = []
    for m in re.finditer(re.escape(MAGIC_ENTITLEMENTS), exe):
        off = m.start()
        if off + 8 > len(exe):
            continue
        length = struct.unpack(">I", exe[off + 4 : off + 8])[0]
        chunk = exe[off + 8 : off + 8 + length]
        pm = re.search(rb"<\?xml.*?</plist>", chunk, re.S)
        if not pm:
            continue
        try:
            out.append(plistlib.loads(pm.group(0)))
        except Exception as e:  # noqa: BLE001
            _warn_with(f"entitlements blob 解析失败：{e}")
    return out


def find_app(path: Path) -> tuple[Path, Path]:
    """把任意产物定位到 `(App 目录, 可执行文件)`。"""
    if path.suffix == ".ipa":
        with zipfile.ZipFile(path) as z:
            app_dir = next(
                n for n in z.namelist() if n.startswith("Payload/") and n.endswith(".app/")
            )
            exe_name = app_dir.rstrip("/").split("/")[-1]
            # 可执行文件名 = .app 去掉后缀
            exe_name = exe_name[:-4] if exe_name.endswith(".app") else exe_name
            target = app_dir + exe_name
            if target not in z.namelist():
                cands = [
                    n
                    for n in z.namelist()
                    if n.startswith(app_dir) and n.count("/") == app_dir.count("/")
                ]
                if not cands:
                    raise SystemExit(f"🔴 在 IPA 里找不到可执行文件（候选：{cands[:5]}）")
                target = cands[0]
            tmp = path.parent / f"._verify_{exe_name}"
            tmp.write_bytes(z.read(target))
            return Path(app_dir), tmp

    if path.suffix == ".xcarchive":
        apps = list((path / "Products" / "Applications").glob("*.app"))
        if not apps:
            raise SystemExit(f"🔴 {path} 里没有 Products/Applications/*.app")
        app = apps[0]
    else:
        app = path

    exe = app / app.stem
    if not exe.exists():
        cands = [p for p in app.iterdir() if p.is_file()]
        if not cands:
            raise SystemExit(f"🔴 {app} 里没有可执行文件")
        exe = cands[0]
    return app, exe


def declared_requirements(ent_path: Path) -> dict:
    if not ent_path.exists():
        raise SystemExit(f"🔴 找不到 entitlements 文件：{ent_path}")
    return plistlib.loads(ent_path.read_bytes())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("artifact", help=".ipa / .app / .xcarchive")
    ap.add_argument(
        "--entitlements",
        default=None,
        help="权威的 entitlements 文件（默认 app/ios/Runner/Runner.entitlements）",
    )
    args = ap.parse_args()

    repo_root = Path(__file__).resolve().parents[2]
    ent_path = Path(args.entitlements) if args.entitlements else (
        repo_root / "app" / "ios" / "Runner" / "Runner.entitlements"
    )
    required = declared_requirements(ent_path)

    print("═" * 74)
    print("出包产物 entitlements 校验 —— 「构建成功」≠「产物可用」")
    print("═" * 74)
    print(f"产物      ：{args.artifact}")
    print(f"应带（权威）：{ent_path}")
    for k, v in required.items():
        print(f"    · {k} = {v}")

    app, exe = find_app(Path(args.artifact))
    print(f"App 目录  ：{app}")
    print(f"可执行文件：{exe}（{exe.stat().st_size} 字节）")
    print("─" * 74)

    data = exe.read_bytes()

    # ── ① 阳性对照 ──
    n_super = data.count(MAGIC_SUPERBLOB)
    print(f"① 阳性对照：SuperBlob(0xfade0cc0) 命中 {n_super} 次")
    if n_super == 0:
        _fail_with("产物**根本没有签名** ⇒ 无 entitlements 可保留（这正是 10-11 事故的形状）")
        print("   （停止：无法继续判定）")
        _report()
        return 1
    print("   ✅ 包确实签过名 ⇒ 下面的扫描结果可信")

    # ── ② 取签名携带的 entitlements ──
    blobs = parse_signed_entitlements(data)
    if blobs is None:
        _fail_with("签名容器里没有 entitlements blob")
        _report()
        return 1
    if not blobs:
        _fail_with("解析不到任何 entitlements（签名容器存在，但内容取不出）")
        _report()
        return 1

    signed: dict = {}
    for b in blobs:
        signed.update(b)
    print(f"② 签名实际携带 {len(signed)} 项：{sorted(signed)}")

    # ── ③ 逐项断言 ──
    print("③ 逐项断言（要求来自 entitlements 文件，而非硬编码）")
    for k, want in required.items():
        if k not in signed:
            _fail_with(f"**缺** {k} —— 产物不带这个能力（真机上会静默失效）")
            continue
        got = signed[k]
        if k in VALUE_REWRITTEN_KEYS:
            print(f"   ✅ {k} 存在（值由系统改写，不逐字比对）：{got}")
        elif got != want:
            _fail_with(f"{k} 值不符：期望 {want!r}，实际 {got!r}")
        else:
            print(f"   ✅ {k} = {got}")

    _report()
    return 1 if _fail else 0


def _report() -> None:
    print("═" * 74)
    if not _fail:
        print("✅ 全部通过：产物带上了 entitlements 文件里声明的全部能力")
    else:
        print(f"🔴 失败 {len(_fail)} 项：")
        for f in _fail:
            print(f"    · {f}")
        print()
        print("🔑 最可能的原因：归档阶段没有真正签名 ⇒ 导出时无 entitlements 可保留。")
        print("    详见 docs/review/ios-archive-entitlements-lost-2026-10-13.md")
    if _warn:
        print(f"🟠 另有 {len(_warn)} 条提示（不计入成败）")
    print("═" * 74)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从已构建的 iOS IPA 里提取「APP 备案（工信部）」所需的证书特征信息。

为什么要有这个脚本
------------------
腾讯云 APP 备案的「APP 特征信息」要填三样：**Bundle ID / 公钥 / 签名MD5值**。

🔴 两个坑（都踩过/核实过）：
  1. 字段名叫「签名MD5值」，但**苹果平台实际要填的是证书的 SHA-1**
     （腾讯云官方 `document/product/243/97789`：
      「苹果版 APP，请填写证书的 SHA-1 值（以16进制形式填写）」）
     —— 安卓才填 MD5。照着字段名填必错。
  2. 常规做法要在 **macOS 钥匙串**里看证书详情 —— 我们**没有 Mac**。
     ⇒ 但证书**就嵌在 IPA 的 `embedded.mobileprovision` 里**（DeveloperCertificates），
       所以只要有 IPA，用 OpenSSL 就能解出来，**完全不需要 Mac / 钥匙串 / Apple 后台**。

⚠️ 必须用 **Apple Distribution** 证书（上架用），不能用 Apple Development。
   ad-hoc 与 app-store 导出用的都是 Distribution 证书，Xcode 自动签名会复用同一张
   ⇒ 拿 ad-hoc IPA 提的值通常就等于将来上架包的值；
     出 app-store 包后**再跑一次本脚本比对 SHA-1** 即可确认。

用法
----
    python scripts/app_filing_cert_info.py /path/to/xxx.ipa

依赖：openssl 在 PATH 里（Windows 的 Git Bash 自带）。
"""

import base64
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile


def fail(msg):
    print(f"🔴 {msg}")
    sys.exit(1)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, **kw)


def extract_profile(ipa_path):
    """从 IPA 里取出 embedded.mobileprovision 的原始字节。"""
    with zipfile.ZipFile(ipa_path) as z:
        names = [n for n in z.namelist() if n.endswith("embedded.mobileprovision")]
        if not names:
            fail("IPA 里找不到 embedded.mobileprovision（不是合法 IPA？）")
        if len(names) > 1:
            print(f"  ⚠️ 有 {len(names)} 个 profile，取第一个：{names[0]}")
        return names[0], z.read(names[0])


def profile_to_plist(mp_bytes):
    """mobileprovision 是 CMS 签名数据；用 openssl 解出内层 plist XML。"""
    with tempfile.TemporaryDirectory() as td:
        src = os.path.join(td, "in.mobileprovision")
        dst = os.path.join(td, "out.plist")
        with open(src, "wb") as f:
            f.write(mp_bytes)
        # OpenSSL 3.x 里 smime 仍可用；失败则退回 cms
        for sub in ("smime", "cms"):
            r = run(["openssl", sub, "-inform", "DER", "-verify", "-noverify",
                     "-in", src, "-out", dst])
            if r.returncode == 0 and os.path.exists(dst):
                with open(dst, "rb") as f:
                    return plistlib.load(f)
        fail("openssl 解析 mobileprovision 失败：" + r.stderr.decode(errors="replace")[:200])


def cert_facts(der_bytes):
    """给定证书 DER，返回 (subject, sha1, sha256, spki_hex)。"""
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "cert.der")
        with open(p, "wb") as f:
            f.write(der_bytes)

        def out(args):
            r = run(["openssl", "x509", "-inform", "DER", "-in", p, "-noout"] + args)
            if r.returncode != 0:
                fail("openssl x509 失败：" + r.stderr.decode(errors="replace")[:200])
            return r.stdout.decode(errors="replace").strip()

        # openssl 会带 "subject=..." / "sha1 Fingerprint=..." 前缀，剥掉
        subject = out(["-subject"]).split("=", 1)[-1].strip()
        sha1 = out(["-fingerprint", "-sha1"]).split("=", 1)[-1].strip()
        sha256 = out(["-fingerprint", "-sha256"]).split("=", 1)[-1].strip()

        # 公钥 → SPKI DER → 十六进制（钥匙串里「公共密钥」那一串）
        r = run(["openssl", "x509", "-inform", "DER", "-in", p, "-noout", "-pubkey"])
        if r.returncode != 0:
            fail("导出公钥失败")
        r2 = run(["openssl", "pkey", "-pubin", "-outform", "DER"], input=r.stdout)
        if r2.returncode != 0:
            fail("公钥转 DER 失败")
        spki_hex = r2.stdout.hex().upper()

        return subject, sha1, sha256, spki_hex


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    ipa = sys.argv[1]
    if not os.path.isfile(ipa):
        fail(f"找不到文件：{ipa}")

    name, mp = extract_profile(ipa)
    print(f"=== 1. profile ===\n  {name}")
    info = profile_to_plist(mp)

    ent = info.get("Entitlements", {})
    app_id = ent.get("application-identifier", "")
    team = ent.get("com.apple.developer.team-identifier", "")
    bundle_id = app_id.split(".", 1)[1] if "." in app_id else app_id

    pname = info.get("Name", "")
    kind = ("Ad Hoc" if "Ad Hoc" in pname
            else "App Store" if "AppStore" in pname.replace(" ", "")
            else "Development" if "Development" in pname
            else "?")
    print(f"\n=== 2. 标识 ===")
    print(f"  Team ID      : {team}")
    print(f"  Bundle ID    : {bundle_id}")
    print(f"  profile 类型 : {kind}")
    print(f"  有效期       : {info.get('CreationDate')} → {info.get('ExpirationDate')}")

    certs = info.get("DeveloperCertificates") or []
    if not certs:
        fail("profile 里没有 DeveloperCertificates")
    if len(certs) > 1:
        print(f"  ⚠️ 有 {len(certs)} 张证书，取第 0 张（叶子证书）")

    subject, sha1, sha256, spki_hex = cert_facts(certs[0])

    print(f"\n=== 3. 证书 ===")
    print(f"  {subject}")
    if "Apple Distribution" not in subject and "iPhone Distribution" not in subject:
        print("  🔴 警告：这不是 Distribution 证书！备案要求用 Distribution（不能用 Development）")
    elif "Apple Development" in subject or "iPhone Developer" in subject:
        print("  🔴 警告：这是 Development 证书，不能用于备案/上架")

    print(f"\n=== 4. 填进腾讯云 APP 备案「APP 特征信息」的值 ===")
    print(f"  Bundle ID    : {bundle_id}")
    print(f"  公钥         : {spki_hex}")
    print(f"  签名MD5值    : {sha1}")
    print(f"                 ↑ 苹果平台**填这个 SHA-1**（不是 MD5）；")
    print(f"                   若系统不认带冒号格式，去掉冒号即可。")
    print(f"\n  （备用）SHA-256 : {sha256}")
    print(f"  （备用）公钥，纯 RSA 部分：见脚本注释 —— 通常用不到")


if __name__ == "__main__":
    main()

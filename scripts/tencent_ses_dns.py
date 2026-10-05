#!/usr/bin/env python3
"""CoEvo · 用腾讯云 API 拉出发信域名需要的 DNS 记录（免手抄）。

用法
----
    # 方式 A：读环境变量（推荐，密钥不落在命令行历史里）
    export TENCENT_SES_SECRET_ID=...
    export TENCENT_SES_SECRET_KEY=...
    python scripts/tencent_ses_dns.py

    # 方式 B：显式传（⚠️ 会进 shell 历史）
    python scripts/tencent_ses_dns.py <SecretId> <SecretKey> [发信域名]

⚠️ 说明
-------
TC3 签名来自**共享模块** `_tencent_api.py`（与后端 Rust `tencent_sign.rs` 同一套算法）。
已验证：用假密钥跑会返回 `AuthFailure.SecretIdNotFound`（**不是** `SignatureFailure`）
⇒ 签名格式被腾讯云接受、网络可达（详见 `_tencent_api.py` 文件头）。
若报错，`_tencent_api.py` 里的「错误码 → 人话」表会直接给出归因。

📌 实际上：**更简单的路**是在腾讯云「发信域名」页点「验证」——
   记录会弹在窗里，直接复制即可（见 `docs/operations/tencent-ses-onboarding-*.md` §1.3）。
   本脚本是**不想手抄 / 想脚本化**时的备选。
"""

import sys

from _tencent_api import TencentApiError, call, credentials_from_args

DEFAULT_DOMAIN = "mail.keyievolution.fun"


def main() -> int:
    domain = None
    if len(sys.argv) >= 4:
        domain = sys.argv[3].strip()
    sid, skey, region = credentials_from_args(sys.argv, domain_args_start=1)
    if domain is None:
        import os

        domain = os.environ.get("TENCENT_SES_DOMAIN", DEFAULT_DOMAIN).strip()

    print("=" * 78)
    print(f"腾讯云 SES · GetEmailIdentity  ({domain} · {region})")
    print("=" * 78)

    try:
        r = call("GetEmailIdentity", {"EmailIdentity": domain}, sid, skey, region)
    except TencentApiError as e:
        print(f"🔴 API 错误：{e}")
        from _tencent_api import hint_for

        h = hint_for(e.code)
        if h:
            print(f"   💡 {h}")
        return 1
    except Exception as e:
        print(f"🔴 调用失败：{e}")
        return 1

    verified = r.get("VerifiedForSendingStatus")
    print(f"\n验证状态：{'✅ 已通过' if verified else '⏳ 未通过（待验证）'}")
    print(f"验证类型：{r.get('IdentityType', '?')}")

    attrs = r.get("Attributes") or []
    if not attrs:
        print("\n⚠️ 该 API 未返回 Attributes（可能版本差异）⇒ 回控制台点「验证」看弹窗。")
        return 0

    print(f"\n需要配置的 DNS 记录（{len(attrs)} 条）：\n")
    for i, a in enumerate(attrs, 1):
        print(f"【{i}】{a.get('Type', '?')}")
        print(f"    主机记录 : {a.get('Name', '?')}")
        print(f"    记录值   : {a.get('Value', '?')}")
        for k in ("Status", "ReceiverDomain", "RecordType", "DkimSelector"):
            if a.get(k) not in (None, ""):
                print(f"    {k:9}: {a[k]}")
        print()

    print("=" * 78)
    print("🔑 填 Cloudflare 时注意：")
    print("   · Name 填**相对名**（Cloudflare 自动补域名）：如 `mail`、`xxxx._domainkey.mail`")
    print("     ⚠️ 上面给的 `主机记录` 可能是**完整 FQDN** ⇒ 填 Cloudflare 时要**去掉域名后缀**")
    print("   · 🔴 若 DKIM 是 **CNAME**，**必须把代理点成灰色**（Cloudflare 默认给 CNAME 开代理）")
    print("   · MX 记录值末尾可带点，Cloudflare 不带更稳；Priority 填 10")
    print("=" * 78)
    return 0


if __name__ == "__main__":
    sys.exit(main())

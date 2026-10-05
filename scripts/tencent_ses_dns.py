#!/usr/bin/env python3
"""CoEvo · 用腾讯云 API 拉出发信域名需要的 DNS 记录（免手抄）。

用途
----
腾讯云 SES 的「发信域名」页点「验证」会弹出要配的记录清单 —— 但有时找不到/不方便抄。
本脚本直接调 `GetEmailIdentity`（Version `2020-10-02`），把记录列出来并格式化。

用法
----
    # 方式 A：读环境变量（推荐，密钥不落在命令行历史里）
    export TENCENT_SES_SECRET_ID=...
    export TENCENT_SES_SECRET_KEY=...
    python scripts/tencent_ses_dns.py

    # 方式 B：显式传（⚠️ 会进 shell 历史）
    python scripts/tencent_ses_dns.py <SecretId> <SecretKey> [发信域名]

环境变量
--------
    TENCENT_SES_SECRET_ID / TENCENT_SES_SECRET_KEY   —— 子账号密钥（**不要**贴聊天里）
    TENCENT_SES_REGION（默认 ap-guangzhou）
    发信域名默认 mail.keyievolution.fun

⚠️ 未实测标注
-------------
本脚本的 TC3 签名逻辑与本项目 `backend/crates/api_server/src/tencent_sign.rs`
**同一套算法**（那道实现已在 ASR 上跑过），但**本脚本自身没有对真实 API 跑通过**
（写它的时候还没有可用密钥）。若报错：
    · `AuthFailure.SignatureFailure` ⇒ 签名/时钟问题（先对一下服务器时间）
    · `AuthFailure.SecretIdNotFound`  ⇒ 密钥不对
    · `ResourceNotFound`              ⇒ 发信域名还没建 / 名字拼错
    · 超时/SSL 错                      ⇒ 网络（把脚本放到服务器上跑，走国内网络）
"""

import hashlib
import hmac
import json
import os
import sys
import time
import urllib.request
from datetime import datetime, timezone

HOST = "ses.tencentcloudapi.com"
SERVICE = "ses"
VERSION = "2020-10-02"
DEFAULT_DOMAIN = "mail.keyievolution.fun"


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def call(action: str, payload: dict, secret_id: str, secret_key: str, region: str) -> dict:
    """调一次腾讯云 API 3.0（TC3-HMAC-SHA256）。

    🔑 与 Rust `tencent_sign.rs` **逐字同源**：canonical 串只签 `content-type;host`，
       且签名的那个 body 字符串与**实际发出的 body 必须是同一个**。
    """
    ts = int(time.time())
    date = datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d")

    # 🔴 紧凑 JSON（无空格）—— 与签名用的 payload 必须完全一致
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
    content_type = "application/json"

    canonical_headers = f"content-type:{content_type}\nhost:{HOST}\n"
    signed_headers = "content-type;host"
    hashed_payload = hashlib.sha256(body.encode("utf-8")).hexdigest()
    canonical_request = (
        f"POST\n/\n\n{canonical_headers}\n{signed_headers}\n{hashed_payload}"
    )

    credential_scope = f"{date}/{SERVICE}/tc3_request"
    string_to_sign = (
        f"TC3-HMAC-SHA256\n{ts}\n{credential_scope}\n"
        + hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()
    )

    k_date = _sign(f"TC3{secret_key}".encode("utf-8"), date)
    k_service = _sign(k_date, SERVICE)
    k_signing = _sign(k_service, "tc3_request")
    signature = hmac.new(
        k_signing, string_to_sign.encode("utf-8"), hashlib.sha256
    ).hexdigest()

    authorization = (
        f"TC3-HMAC-SHA256 Credential={secret_id}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )

    req = urllib.request.Request(
        f"https://{HOST}/",
        data=body.encode("utf-8"),
        headers={
            "Authorization": authorization,
            "Content-Type": content_type,
            "Host": HOST,
            "X-TC-Action": action,
            "X-TC-Timestamp": str(ts),
            "X-TC-Version": VERSION,
            "X-TC-Region": region,
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def main() -> int:
    sid = os.environ.get("TENCENT_SES_SECRET_ID", "").strip()
    skey = os.environ.get("TENCENT_SES_SECRET_KEY", "").strip()
    domain = DEFAULT_DOMAIN

    if len(sys.argv) >= 3:
        sid, skey = sys.argv[1].strip(), sys.argv[2].strip()
        domain = sys.argv[3].strip() if len(sys.argv) > 3 else DEFAULT_DOMAIN
    else:
        domain = os.environ.get("TENCENT_SES_DOMAIN", DEFAULT_DOMAIN).strip()

    region = os.environ.get("TENCENT_SES_REGION", "ap-guangzhou").strip()

    if not sid or not skey:
        print("🔴 缺密钥。用环境变量 TENCENT_SES_SECRET_ID / TENCENT_SES_SECRET_KEY，")
        print("   或：python scripts/tencent_ses_dns.py <SecretId> <SecretKey>")
        print("   ⚠️ 别把密钥贴在聊天里；在服务器上跑最安全。")
        return 2

    print("=" * 78)
    print(f"腾讯云 SES · GetEmailIdentity  ({domain} · {region})")
    print("=" * 78)

    try:
        resp = call("GetEmailIdentity", {"EmailIdentity": domain}, sid, skey, region)
    except Exception as e:
        print(f"🔴 调用失败：{e}")
        print("   排查见本文件头部「未实测标注」的对照表。")
        return 1

    r = resp.get("Response", {})
    if "Error" in r:
        err = r["Error"]
        print(f"🔴 API 返回错误：{err.get('Code')} —— {err.get('Message')}")
        print("   （RequestId: %s）" % r.get("RequestId", "?"))
        return 1

    verified = r.get("VerifiedForSendingStatus")
    print(f"\n验证状态：{'✅ 已通过' if verified else '⏳ 未通过（待验证）'}")
    print(f"验证类型：{r.get('IdentityType', '?')}")

    attrs = r.get("Attributes") or []
    if not attrs:
        print("\n⚠️ API 没返回 Attributes（可能这个 API 版本不含 DNS 详情）。")
        print("   ⇒ 回控制台点「验证」看弹窗。")
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
    print("     ⚠️ 上面 API 给的 `主机记录` 可能是**完整 FQDN**（带 .keyievolution.fun）")
    print("        ⇒ 填 Cloudflare 时要把域名后缀去掉")
    print("   · 🔴 **CNAME 那条必须把代理点成灰色**（Cloudflare 默认给 CNAME 开代理）")
    print("   · MX 记录值**末尾要有点 `.`**；优先级填 10")
    print("=" * 78)
    return 0


if __name__ == "__main__":
    sys.exit(main())

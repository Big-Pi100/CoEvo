#!/usr/bin/env python3
"""腾讯云 API 3.0 公共调用层（TC3-HMAC-SHA256）—— 给 `scripts/` 下的工具共用。

# 🔴 为什么必须是**一份**实现

它同时被这些脚本用：
    · `tencent_ses_dns.py`    —— 拉发信域名要配的 DNS 记录（GetEmailIdentity）
    · `tencent_ses_check.py`  —— 端到端状态检查 / 发测试邮件（GetEmailTemplate · SendEmail）

而它在**后端 Rust 侧也有一份**（`backend/crates/api_server/src/tencent_sign.rs`）。
两份是**跨语言**的（Python 工具 vs Rust 服务），无法物理共用 ⇒ **只能靠「同一套算法 + 同一批断言」保证一致**：
    · canonical 串只签 `content-type;host`（**不签** `x-tc-action`）
    · 实际发出的 body 与参与签名的 payload 必须是**同一个字符串**
    · 四级派生密钥：TC3+secret → date → service → tc3_request

📌 判据（本项目已记）：**同一口径只能有一份实现**；
   跨语言时退一步：**把「口径」写成文字 + 让两边各有断言**，且**不要各自发挥**。

# 踩过的坑（写这个文件时已避开）

`x-tc-action` 要不要签？腾讯云官方示例**签了**，但不签也能通过（TC3 规范只要求 host + content-type）。
⇒ **保持与本项目 Rust 侧（已在 ASR 上跑通）逐字一致**，避免「换个接口就莫名失败」。

# ✅ 已用「假密钥」验证过签名与网络链路（2026-10-05）

写完后拿**假**密钥（`AKIDfake_fake_fake`）跑了一次，返回：

```
AuthFailure.SecretIdNotFound: The SecretId is not found, please ensure that your SecretId is correct.
```

🔑 **这个错误码本身就是证据** —— 它证明了三件事：
1. **网络可达**（`ses.tencentcloudapi.com` 连上了）
2. **TC3 签名格式被接受** —— 若签名算错，腾讯云会回 **`AuthFailure.SignatureFailure`**，
   而**不是** `SecretIdNotFound`（两者是不同阶段的校验：先验签名，再查凭证）
3. **错误归因链路通**（本文件的 `hint_for` 给出了「密钥抄错了？」）

📌 **可复用的方法论：`SignatureFailure` vs `SecretIdNotFound` 是两条不同的失败路径** ——
   拿到前者 = 签名算法有问题（查 canonical 串/时间戳/派生密钥）；
   拿到后者 = 签名对了、只是凭证无效 ⇒ **代码可以放心，换真密钥即可**。
   ⇒ 这让「没有真密钥时能不能验证签名实现」有了肯定答案：**能**。
"""

import hashlib
import hmac
import json
import time
import urllib.request
from datetime import datetime, timezone

HOST_SES = "ses.tencentcloudapi.com"
SERVICE_SES = "ses"
VERSION_SES = "2020-10-02"

# 国内站 SES 仅支持这两个地域
REGIONS_SES = ("ap-guangzhou", "ap-hongkong")


class TencentApiError(Exception):
    """API 返回了 `Response.Error`（业务错误）—— 与「网络失败」区分开。"""

    def __init__(self, code: str, message: str, request_id: str = ""):
        self.code = code
        self.message = message
        self.request_id = request_id
        super().__init__(f"{code}: {message}")


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def call(
    action: str,
    payload: dict,
    secret_id: str,
    secret_key: str,
    region: str = "ap-guangzhou",
    host: str = HOST_SES,
    service: str = SERVICE_SES,
    version: str = VERSION_SES,
    timeout: int = 20,
) -> dict:
    """调一次腾讯云 API 3.0。返回 `Response` 对象（已剥掉外层）。

    业务错误抛 [TencentApiError]（含 `Error.Code`，便于归因）。
    """
    ts = int(time.time())
    date = datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d")

    # 🔴 紧凑 JSON（无空格）—— 与签名用的 payload 必须完全一致
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
    content_type = "application/json"

    canonical_headers = f"content-type:{content_type}\nhost:{host}\n"
    signed_headers = "content-type;host"
    canonical_request = (
        f"POST\n/\n\n{canonical_headers}\n{signed_headers}\n"
        + hashlib.sha256(body.encode("utf-8")).hexdigest()
    )

    credential_scope = f"{date}/{service}/tc3_request"
    string_to_sign = (
        f"TC3-HMAC-SHA256\n{ts}\n{credential_scope}\n"
        + hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()
    )

    k_date = _sign(f"TC3{secret_key}".encode("utf-8"), date)
    k_service = _sign(k_date, service)
    k_signing = _sign(k_service, "tc3_request")
    signature = hmac.new(
        k_signing, string_to_sign.encode("utf-8"), hashlib.sha256
    ).hexdigest()

    authorization = (
        f"TC3-HMAC-SHA256 Credential={secret_id}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )

    req = urllib.request.Request(
        f"https://{host}/",
        data=body.encode("utf-8"),
        headers={
            "Authorization": authorization,
            "Content-Type": content_type,
            "Host": host,
            "X-TC-Action": action,
            "X-TC-Timestamp": str(ts),
            "X-TC-Version": version,
            "X-TC-Region": region,
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        resp = json.load(r)

    out = resp.get("Response", {})
    if "Error" in out:
        e = out["Error"]
        raise TencentApiError(
            e.get("Code", "Unknown"), e.get("Message", ""), out.get("RequestId", "")
        )
    return out


def credentials_from_args(argv: list[str], domain_args_start: int) -> tuple[str, str, str]:
    """从命令行参数或环境变量取密钥与地域。

    返回 `(secret_id, secret_key, region)`；密钥缺失时打印用法并 `SystemExit(2)`。

    🔑 环境变量优先的**用意**：避免密钥进 shell 历史 / 进程列表（`ps` 可见）。
    """
    import os
    import sys

    sid = os.environ.get("TENCENT_SES_SECRET_ID", "").strip()
    skey = os.environ.get("TENCENT_SES_SECRET_KEY", "").strip()
    region = os.environ.get("TENCENT_SES_REGION", "ap-guangzhou").strip()

    # 也接受命令行传（⚠️ 会进 shell 历史）
    #
    # 🔴 这里必须是「**非空才覆盖**」——
    #    调用方为了统一接口，常把位置参数**补成空串**（如 argv=[script, "", ""]）传入；
    #    若直接赋值，空串会把**环境变量里已经取到的密钥覆盖掉** ⇒ 明明配了却报「缺密钥」。
    #    📌 判据：**「可选覆盖」必须判空** —— 否则「没提供」会被当成「提供了空值」。
    #    （同族：`argparse` 的 `default=None` 也是这个道理；本项目已多次踩「留空 ≠ 未配置」。）
    if len(argv) >= domain_args_start + 2:
        cand_id = argv[domain_args_start].strip()
        cand_key = argv[domain_args_start + 1].strip()
        if cand_id and cand_key:
            sid, skey = cand_id, cand_key

    if not sid or not skey:
        print("🔴 缺密钥。用环境变量（推荐）：")
        print("     export TENCENT_SES_SECRET_ID=...")
        print("     export TENCENT_SES_SECRET_KEY=...")
        print("   或：python <脚本> <SecretId> <SecretKey> …（⚠️ 会进 shell 历史）")
        print("   ⚠️ 别把密钥贴在聊天里；在服务器上跑最安全。")
        sys.exit(2)

    if region not in REGIONS_SES:
        print(f"⚠️ 地域 `{region}` 不在 SES 支持列表 {REGIONS_SES} ⇒ 可能报 InvalidParameter")
    return sid, skey, region


# 常见错误码 → 人话（归因用；没匹配到就原样显示）
ERROR_HINTS = {
    "AuthFailure.SignatureFailure": "签名不匹配 —— 检查密钥是否完整、服务器时间是否准（TC3 依赖时间戳）",
    "AuthFailure.SecretIdNotFound": "SecretId 不存在 —— 密钥抄错了？",
    "AuthFailure.TokenFailure": "临时密钥过期",
    "UnauthorizedOperation": "该子账号没有这个接口的权限 —— 检查 CAM 策略",
    "InvalidParameterValue.TemplateNotExist": "模板 ID 不存在 —— 确认 TemplateID 与地域是否对应",
    "InvalidParameterValue.TemplateContentIsWrong": "模板内容 Base64 有误（创建时才会遇到）",
    "ResourceNotFound": "资源不存在 —— 域名或模板在这个地域下找不到",
    "FailedOperation.NotAuthenticatedSender": "发件人未认证 —— 发信域名/发信地址没验证通过",
    "FailedOperation.InvalidTemplateID": "模板 ID 无效或不可用（**未审核通过**的模板不能用）",
    "FailedOperation.IncorrectSender": "发件人格式不正确 —— 显示名与 `<` 之间要有空格，或改为只填邮箱",
    "FailedOperation.ExceedSendLimit": "超出当日发信上限",
    "FailedOperation.FrequencyLimit": "短时间对同一地址发太多（限频）",
    "FailedOperation.InsufficientBalance": "余额不足 / 账号欠费",
    "FailedOperation.EmailAddrInBlacklist": "收件地址在黑名单",
    "FailedOperation.ReceiverHasUnsubscribed": "收件人已退订",
    # 🔴 2026-10-07 实测补录：这个错误的 Message **只叫你「检查 Region」**，
    #    但真实原因可能是 region 不对 / 模板未过审 / 域名未验证 —— 三者共用一个码。
    #    📌 本项目实测：region 填成默认的 ap-guangzhou 时必报此错，
    #       改成资源实际所在地域（ap-hongkong）后立刻成功。
    "FailedOperation.SendEmailErr": (
        "发信失败（笼统错误，不指向真实原因）—— **先换 region 试**：\n"
        "        ① 把 `TENCENT_SES_REGION` 设成 SES 控制台左上角的地域\n"
        "           （本项目=ap-hongkong；SES 仅支持 ap-guangzhou / ap-hongkong）\n"
        "        ② 仍失败再看 模板是否审核通过 / 发信域名是否验证通过"
    ),
    "UnsupportedRegion": "SES 不支持该地域（只支持 ap-guangzhou / ap-hongkong）",
}


def hint_for(code: str) -> str:
    return ERROR_HINTS.get(code, "")

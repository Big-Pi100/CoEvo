#!/usr/bin/env python3
"""CoEvo · SES 端到端状态检查（域名验证 + 模板审核 + 可选真发一封）。

用法
----
    # 只查状态（不发信，安全）
    export TENCENT_SES_SECRET_ID=...
    export TENCENT_SES_SECRET_KEY=...
    python scripts/tencent_ses_check.py

    # 查状态 + 真发一封测试邮件到自己邮箱
    python scripts/tencent_ses_check.py --send you@qq.com

    # 覆盖默认值
    python scripts/tencent_ses_check.py --domain mail.keyievolution.fun --template 221378

# 为什么需要它

「忘记密码」跑不通时，可能卡在**四个不同的地方**，而现象都是「收不到验证码」：

| 卡点 | 本脚本怎么区分 |
|---|---|
| 发信域名没验证通过 | `GetEmailIdentity.VerifiedForSendingStatus` |
| 模板还在审核 / 被拒 | `GetEmailTemplate.TemplateStatus`（0/1/2）|
| 密钥/权限不对 | 调用直接抛 `AuthFailure.*` / `UnauthorizedOperation` |
| 发信本身失败 | `SendEmail` 的 `Error.Code`（模板无效 / 发件人未认证 / 限频 …）|

⇒ 它把「收不到邮件」这个笼统现象，**拆成四个可判定的检查项**。
比在 App 里点「忘记密码」再看不出所以然强得多。

# 🔴 `--send` 会**真发一封**（消耗免费额度 1 封）

所以默认**不发**，必须显式传 `--send <收件人>`。
首次验证建议发到**自己掌握的两个不同邮箱**（如 QQ + Gmail）——
不同收件商的显示与反垃圾策略不同，一封正常不代表另一封正常（腾讯云官方也这么建议）。

# ✅ 已用「假密钥」验证过（2026-10-05）

拿假密钥跑，返回 `AuthFailure.SecretIdNotFound`（而**不是** `SignatureFailure`）
⇒ 证明**网络 + TC3 签名 + 错误归因**三环都通，只差真凭证。
详见 `_tencent_api.py` 文件头。

⚠️ 但**业务层未验证**（域名状态 / 模板状态 / 真发一封）—— 那需要真密钥，
   且模板还在审核中。⇒ 首次拿真密钥跑时，重点看 ① 域名是否已验证 ② 模板状态。
"""

import argparse
import os
import sys

from _tencent_api import (
    TencentApiError,
    call,
    credentials_from_args,
    hint_for,
)

DEFAULT_DOMAIN = "mail.keyievolution.fun"
# 我们的密码重置模板（白哥 2026-10-05 提交，ID 从控制台抄录）
DEFAULT_TEMPLATE_ID = 221378
SUBJECT = "CoEvo 密码重置验证码"


def _line(ok: bool | None, label: str, detail: str = "") -> None:
    icon = "✅" if ok is True else ("🔴" if ok is False else "⚠️")
    print(f"  {icon} {label}" + (f"  —— {detail}" if detail else ""))


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--domain", default=os.environ.get("TENCENT_SES_DOMAIN", DEFAULT_DOMAIN))
    ap.add_argument(
        "--template",
        type=int,
        default=int(os.environ.get("TENCENT_SES_TEMPLATE_ID", DEFAULT_TEMPLATE_ID)),
    )
    ap.add_argument(
        "--send",
        metavar="收件邮箱",
        default=None,
        help="真发一封测试邮件到这个地址（默认不发）",
    )
    # 密钥也允许从位置参数传（与其它脚本一致）
    ap.add_argument("secret_id_pos", nargs="?", default=None)
    ap.add_argument("secret_key_pos", nargs="?", default=None)
    args = ap.parse_args()

    argv = [sys.argv[0], args.secret_id_pos or "", args.secret_key_pos or ""]
    sid, skey, region = credentials_from_args(argv, domain_args_start=1)

    print("=" * 78)
    print(f"CoEvo · SES 端到端检查  地域={region}")
    print("=" * 78)

    problems: list[str] = []

    # ── ① 发信域名 ──
    print(f"\n【①】发信域名验证：{args.domain}")
    try:
        ident = call("GetEmailIdentity", {"EmailIdentity": args.domain}, sid, skey, region)
        verified = bool(ident.get("VerifiedForSendingStatus"))
        _line(verified, "域名验证", "已通过" if verified else "**未通过** ⇒ 回控制台点「验证」")
        if not verified:
            problems.append("域名未验证通过")
            attrs = ident.get("Attributes") or []
            if attrs:
                print("     待配/未通过的记录：")
                for a in attrs:
                    print(f"       · {a.get('Type')} {a.get('Name')}  状态={a.get('Status')}")
    except TencentApiError as e:
        _line(False, "域名查询失败", str(e))
        if hint_for(e.code):
            print(f"     💡 {hint_for(e.code)}")
        problems.append("域名查询失败")
    except Exception as e:
        _line(None, "域名查询异常（网络？）", str(e))
        problems.append("域名查询异常")

    # ── ② 模板 ──
    print(f"\n【②】邮件模板：TemplateID={args.template}")
    STATUS = {0: ("✅", "审核通过"), 1: ("⏳", "待审核"), 2: ("🔴", "审核拒绝")}
    try:
        tpl = call("GetEmailTemplate", {"TemplateID": args.template}, sid, skey, region)
        st = tpl.get("TemplateStatus")
        icon, text = STATUS.get(st, ("⚠️", f"未知状态 {st}"))
        print(f"  {icon} 模板状态：{text}")
        print(f"     模板名：{tpl.get('TemplateName', '?')}")
        if st == 1:
            problems.append("模板待审核（审核通过前**不能发信**）")
            print("     ⚠️ 腾讯云：模板需**审核通过**才能用于发信 ⇒ 发信会报 FailedOperation.InvalidTemplateID")
            print("     ℹ️ 审核时长：工作日提交通常 1 个工作日内完成；休息日提交顺延到下一工作日")
        elif st == 2:
            problems.append("模板被拒")
            print("     🔴 拒绝原因在控制台：**邮件配置 > 发信模板** 页面的**红色感叹号**处")
        elif st == 0:
            # 顺手检查模板内容里是否还有变量（防「审核后被人改掉变量」）
            content = tpl.get("TemplateContent") or {}
            import base64

            for kind in ("Html", "Text"):
                raw = content.get(kind)
                if not raw:
                    continue
                try:
                    decoded = base64.b64decode(raw).decode("utf-8", errors="replace")
                except Exception:
                    continue
                if "{{code}}" not in decoded:
                    print(f"     🔴 {kind} 里**没有 `{{{{code}}}}` 变量** —— 用户收到的会是固定文案，不是验证码！")
                    problems.append(f"模板 {kind} 缺 {{{{code}}}} 变量")
                else:
                    print(f"     ✅ {kind} 含 `{{{{code}}}}` 变量")
    except TencentApiError as e:
        _line(False, "模板查询失败", str(e))
        if hint_for(e.code):
            print(f"     💡 {hint_for(e.code)}")
        problems.append("模板查询失败")
    except Exception as e:
        _line(None, "模板查询异常（网络？）", str(e))
        problems.append("模板查询异常")

    # ── ③ 可选：真发一封 ──
    if args.send:
        print(f"\n【③】真发一封测试邮件 → {args.send}")
        print("  ⚠️ 这会消耗免费额度 1 封（共 1000 封）")
        payload = {
            "FromEmailAddress": os.environ.get(
                "TENCENT_SES_FROM", "CoEvo <noreply@mail.keyievolution.fun>"
            ),
            "Destination": [args.send],
            "Subject": SUBJECT,
            "Template": {
                "TemplateID": args.template,
                # 🔴 TemplateData 必须是 **JSON 字符串**（不是嵌套对象）
                "TemplateData": '{"code":"123456"}',
            },
        }
        try:
            r = call("SendEmail", payload, sid, skey, region)
            mid = r.get("MessageId", "?")
            _line(True, "已提交发送", f"MessageId={mid}")
            print("     ℹ️ `MessageId` 只代表**腾讯云已受理**，不等于已送达。")
            print("        真送达状态可查 `GetSendEmailStatus`（本脚本暂未覆盖）。")
            print("     📌 建议：发到**两个不同收件商**（如 QQ + Gmail）各一封 ——")
            print("        不同收件商的显示与反垃圾策略不同（腾讯云官方也这么建议）。")
        except TencentApiError as e:
            _line(False, "发信失败", str(e))
            if hint_for(e.code):
                print(f"     💡 {hint_for(e.code)}")
            problems.append("发信失败")
        except Exception as e:
            _line(None, "发信异常（网络？）", str(e))
            problems.append("发信异常")
    else:
        print("\n【③】跳过发信（未传 --send）")
        print("     想真发一封：python scripts/tencent_ses_check.py --send you@qq.com")

    # ── 总结 ──
    print("\n" + "=" * 78)
    if not problems:
        print("✅ 全部就绪 —— 可以把密钥 + 模板 ID 配到服务器了")
        print("   （命令见 docs/operations/tencent-ses-onboarding-2026-10-05.md §4.2）")
    else:
        print(f"⏳ 未就绪 {len(problems)} 项：")
        for p in problems:
            print(f"   · {p}")
        if any("待审核" in p or "被拒" in p for p in problems):
            print("\n   🔑 模板审核是**日历天**瓶颈（1 个工作日）—— 先做别的，审核过了再回来跑本脚本。")
    print("=" * 78)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

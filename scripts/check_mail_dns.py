#!/usr/bin/env python3
"""CoEvo · 发信域名 DNS 体检 —— 查 `mail.keyievolution.fun` 的 SES 四类记录是否就位。

用法：
    python scripts/check_mail_dns.py                      # 默认查 mail.keyievolution.fun
    python scripts/check_mail_dns.py mail.example.com     # 查别的发信域名
    python scripts/check_mail_dns.py mail.keyievolution.fun abc123._domainkey
                                                          # 第 2 个参数 = DKIM selector

# 为什么要有这个脚本（而不是靠人肉 nslookup）

腾讯云 SES 的验证要四项（MX / SPF / DKIM / DMARC）**各自**通过，
而「配了没生效」和「配错了」在控制台上**长得一样**（都是一句「未通过」）。
⇒ 本脚本把四项**逐条**查出来 + 明确说「缺哪个」，
   这样在点腾讯云的「验证」按钮**之前**就能知道会不会过。

# 🔴 为什么用 DoH（DNS over HTTPS）而不是 `nslookup`

实测（2026-10-05）：`nslookup -type=TXT mail.x host` 在 Windows 上行为不稳定
（返回 SOA 却看不出是 NODATA 还是失败）。
而 DoH 的 JSON 接口给出**明确的 Status 码**（NOERROR / NXDOMAIN），
能区分「名字不存在」与「名字存在但没有该类型」——这两者对排查的含义完全不同：
    · NXDOMAIN  ⇒ 这个名字**一条记录都没有**（连 A 都没有）
    · NODATA    ⇒ 名字存在（有别的类型，如 A），但**缺**这一类

⚠️ 国内网络到 Cloudflare 的 DoH 会被中断（实测 SSL UNEXPECTED_EOF）⇒ 默认用**阿里 DoH**，
   回退腾讯 DoH（腾讯云验证时用的正是腾讯这一侧，所以两个都查更有参考价值）。

# ⚠️ 缓存说明（容易误判）

公共 DNS 会按 SOA 的 minimum TTL 缓存**负结果**。
若你刚在 Cloudflare 加完记录、本脚本仍说「缺」，
**先等 1–2 分钟再跑一次**（Cloudflare 自身是秒级生效，但公共解析器可能有残留缓存）。
"""

import json
import sys
import urllib.parse
import urllib.request

DOH_ENDPOINTS = [
    ("阿里", "https://dns.alidns.com/resolve"),
    ("腾讯", "https://doh.pub/dns-query"),
]

TYPE_NAMES = {1: "A", 2: "NS", 5: "CNAME", 6: "SOA", 15: "MX", 16: "TXT", 28: "AAAA"}


def query(name: str, rtype: str, endpoint: str) -> tuple[int | None, list[dict]]:
    """返回 (Status, answers)。Status: 0=NOERROR · 3=NXDOMAIN · None=查询失败。"""
    url = endpoint + "?" + urllib.parse.urlencode({"name": name, "type": rtype})
    req = urllib.request.Request(url, headers={"accept": "application/dns-json"})
    try:
        with urllib.request.urlopen(req, timeout=12) as r:
            d = json.load(r)
    except Exception:
        return None, []
    return d.get("Status"), d.get("Answer", [])


def query_multi(name: str, rtype: str) -> tuple[int | None, list[dict], str]:
    """多源查询；返回第一个成功的来源结果。"""
    last_status, last_ans = None, []
    for label, ep in DOH_ENDPOINTS:
        st, ans = query(name, rtype, ep)
        if st is None:
            continue
        last_status, last_ans = st, ans
        if ans:  # 有结果就立刻用（比"没结果"更可信）
            return st, ans, label
    # 全都没结果：返回最后一个"成功但为空"的（而不是"查询失败"）
    return last_status, last_ans, "阿里/腾讯"


def fmt(answers: list[dict]) -> list[str]:
    return [f"{TYPE_NAMES.get(a.get('type'), a.get('type'))}  {a.get('data')}" for a in answers]


# ──────────────────────────────────────────────────────────────────────
# DKIM 深度校验
#
# 为什么 DKIM 需要单独深查（另外三项不需要）：
#   · MX / SPF / DMARC 都是**短值**，肉眼一看就知道对不对
#   · DKIM 是 400+ 字符的 RSA 公钥 ⇒ **两个特有风险**：
#       ① DNS 层会把超长 TXT **分片**（单段上限 255 字节）⇒ 显示成 `"段1" "段2"`
#          按 RFC 1035，多段是**直接连接**（不加空格）—— 若误加空格，公钥就坏了
#       ② base64 长度必须是 4 的倍数；错一个字符（多/少/换行）就解不出来
#   ⇒ 肉眼看不出坏没坏，只能程序校验。
# ──────────────────────────────────────────────────────────────────────

def split_txt_segments(data: str) -> list[str]:
    """把 DoH 返回的 TXT data（形如 `"段1" "段2"`）拆成**段列表**。"""
    segs, cur, inq = [], [], False
    for ch in data:
        if ch == '"':
            if inq:
                segs.append("".join(cur))
                cur = []
            inq = not inq
        elif inq:
            cur.append(ch)
    if cur:
        segs.append("".join(cur))
    return segs if segs else [data]


def check_dkim_value(data: str) -> tuple[bool, str]:
    """校验一条 DKIM TXT 的值：分片拼接 + base64 合法性 + RSA 位长。

    返回 (是否通过, 逐行报告字符串)。
    """
    import base64

    lines: list[str] = []
    segs = split_txt_segments(data)
    joined = "".join(segs)  # 🔑 RFC 1035：多段直接连接，**不加空格**

    lines.append(f"  分片：{len(segs)} 段" + (f"（{', '.join(str(len(s)) for s in segs)} 字符）" if len(segs) > 1 else ""))
    lines.append(f"  拼接后总长：{len(joined)}")

    if not joined.startswith("v=DKIM1"):
        return False, "\n".join(lines + ["  🔴 不以 v=DKIM1 开头"])
    if "k=rsa" not in joined:
        return False, "\n".join(lines + ["  🔴 缺 k=rsa"])
    if "p=" not in joined:
        return False, "\n".join(lines + ["  🔴 缺 p=（公钥）"])

    b64 = joined.split("p=", 1)[1].strip()
    # 🔑 只看 **p= 之后** 有没有空格 —— 别检查整个字符串
    #    （`v=DKIM1; k=rsa;` 本身就含空格 ⇒ 检查全体必然假红。本脚本第一版就误报过。）
    if " " in b64 or "\t" in b64:
        return False, "\n".join(lines + ["  🔴 p= 部分含空白字符（公钥已损坏 —— 多半是分片拼接时混入了空格）"])

    if len(b64) % 4 != 0:
        return False, "\n".join(lines + [f"  🔴 base64 长度 {len(b64)} 不是 4 的倍数 ⇒ 值不完整或多了字符"])

    allowed = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    bad = sorted(set(b64) - allowed)
    if bad:
        return False, "\n".join(lines + [f"  🔴 含非法字符：{bad}"])

    try:
        der = base64.b64decode(b64, validate=True)
    except Exception as e:
        return False, "\n".join(lines + [f"  🔴 base64 解码失败：{e}"])

    lines.append(f"  ✅ base64 合法：{len(b64)} 字符 → {len(der)} 字节")
    if der[:1] != b"\x30":
        return False, "\n".join(lines + [f"  🔴 DER 首字节 {der[0]:#x}（应为 0x30 SEQUENCE）"])

    # RSAPublicKey 的 modulus：INTEGER, length=0x0101（257 字节）⇒ 2048 位
    if der.find(b"\x02\x82\x01\x01") > 0:
        lines.append("  ✅ DER 合法，公钥为 **2048 位 RSA**")
    elif der.find(b"\x02\x81\x81") > 0:
        lines.append("  ⚠️ DER 合法，但公钥是 **1024 位**（腾讯云另有 1024 位记录，确认选对了没）")
    else:
        lines.append("  ⚠️ DER 合法，但未能识别密钥位长")
    return True, "\n".join(lines)


def main() -> int:
    mail_domain = sys.argv[1] if len(sys.argv) > 1 else "mail.keyievolution.fun"
    dkim_selector = sys.argv[2] if len(sys.argv) > 2 else None

    print("=" * 78)
    print(f"发信域名 DNS 体检：{mail_domain}")
    print("=" * 78)

    problems: list[str] = []

    # ── 0. 先看这个子域名到底有没有东西（决定后面「NXDOMAIN vs NODATA」怎么解读）──
    print("\n【0】该子域名的现有记录（决定「完全没建」还是「建了但缺项」）")
    any_record = False
    for t in ("A", "AAAA", "CNAME", "MX", "TXT"):
        st, ans, _ = query_multi(mail_domain, t)
        if st is None:
            print(f"  {t:6} → （查询失败，网络问题？）")
            continue
        if ans:
            any_record = True
            print(f"  {t:6} → ✅ " + " ; ".join(fmt(ans)))
        else:
            tag = "NXDOMAIN(名字不存在)" if st == 3 else "NODATA(无此类型)"
            print(f"  {t:6} → —  {tag}")
    if not any_record:
        print("  ⚠️ 该子域名完全没有任何记录 —— 若你「已经配过」，很可能配到了别处。")

    # ── 1. MX ──
    print("\n【1】MX（收退信 · 腾讯云要求发信域名必须有）")
    st, ans, src = query_multi(mail_domain, "MX")
    if ans:
        for line in fmt(ans):
            print(f"  ✅ {line}")
    else:
        print(f"  ❌ 缺 MX 记录（{src} 回报：{'NXDOMAIN' if st == 3 else 'NODATA'}）")
        problems.append("MX")

    # ── 2. SPF ──
    print("\n【2】SPF（TXT · v=spf1 …）")
    st, ans, src = query_multi(mail_domain, "TXT")
    txts = [a.get("data", "") for a in ans]
    spf = [t for t in txts if "v=spf1" in t]
    if spf:
        for line in spf:
            print(f"  ✅ {line}")
        if len(spf) > 1:
            print("  🔴 发现**多条** SPF —— 一个域名只能有一条，多条会被判 permerror ⇒ 邮件全进垃圾箱")
            problems.append("SPF(多条)")
    else:
        if txts:
            print("  查到 TXT 但没有 SPF：" + " ; ".join(txts))
        else:
            print(f"  ❌ 缺 SPF（{src} 回报：{'NXDOMAIN' if st == 3 else 'NODATA'}）")
        problems.append("SPF")

    # ── 3. DKIM ──
    print("\n【3】DKIM（TXT 或 CNAME · 记录名 = <selector>._domainkey.<发信域名>）")
    if dkim_selector:
        dkim_name = f"{dkim_selector}._domainkey.{mail_domain}"
        st, ans, src = query_multi(dkim_name, "TXT")
        if not ans:
            st2, ans2, _ = query_multi(dkim_name, "CNAME")
            if ans2:
                print(f"  ✅ {dkim_name} → CNAME")
                for line in fmt(ans2):
                    print(f"     {line}")
                print("     🔴 是 CNAME ⇒ **务必确认代理是「仅 DNS」（灰云朵）**，")
                print("        否则 Cloudflare 会代理它 ⇒ 腾讯云验证永远不通过")
                ans = ans2
        else:
            print(f"  ✅ {dkim_name} → TXT")
            # 🔑 只做深度校验，**不打印 400+ 字符的原文**（打印了也看不出对不对，
            #    还会把终端刷满）。
            ok_dkim, report = check_dkim_value(ans[0].get("data", ""))
            print(report)
            if not ok_dkim:
                problems.append("DKIM(值非法)")
        if not ans:
            print(f"  ❌ 缺 DKIM（查了 {dkim_name}）")
            problems.append("DKIM")
    else:
        print("  ⏭ 跳过 —— 需要你知道 selector（腾讯云控制台显示的那个前缀）")
        print("     用法：python scripts/check_mail_dns.py <发信域名> <selector>")
        print("     ⚠️ DKIM 是四项里**最容易配错**的（若给的是 CNAME，Cloudflare 默认会开代理 ⇒ 必须点成灰云朵）")

    # ── 4. DMARC ──
    print("\n【4】DMARC（TXT · 配在 _dmarc.<发信域名>）")
    dmarc_name = f"_dmarc.{mail_domain}"
    st, ans, src = query_multi(dmarc_name, "TXT")
    dmarc = [a.get("data", "") for a in ans if "v=DMARC1" in a.get("data", "")]
    if dmarc:
        for line in dmarc:
            print(f"  ✅ {dmarc_name} → {line}")
    else:
        print(f"  ❌ 缺 DMARC（{src} 回报：{'NXDOMAIN' if st == 3 else 'NODATA'}）")
        problems.append("DMARC")

    # ── 总结 ──
    print("\n" + "=" * 78)
    if not problems:
        print("✅ 四项都查到了 —— 可以回腾讯云点「验证」了")
    else:
        print(f"❌ 缺 {len(problems)} 项：{' / '.join(problems)}")
        print()
        print("🔑 排查顺序（按最常见的错法）：")
        print("   1. Cloudflare 里记录的 **Name 填成了完整域名** ⇒")
        print("      填 `mail` 才对（Cloudflare 会自动补 .keyievolution.fun）")
        print("      ❌ 填 `mail.keyievolution.fun` → 变成 mail.keyievolution.fun.keyievolution.fun")
        print("   2. **只加了 A 记录**（把子域名指向服务器）—— 那不是发信验证记录！")
        print("      腾讯云要的是 MX / TXT(SPF) / TXT或CNAME(DKIM) / TXT(DMARC)")
        print("   3. DKIM 给的是 **CNAME 且开了代理**（橙色云朵）⇒ 必须点成灰色 ☁️")
        print("   4. 刚加完 ⇒ 等 1–2 分钟（公共解析器有负缓存）")
    print("=" * 78)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

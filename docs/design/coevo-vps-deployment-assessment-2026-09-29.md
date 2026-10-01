# CoEvo 后端部署评估 —— 国内支付/邮件机（<VPS_IP>）

> 2026-09-29 11:3x ｜ 触发：白哥「您看看部署到这台 VPS，上边还有其他东西，**别动其他东西**」
> **本轮只做只读侦察 + 方案，未改动服务器上任何东西。**
> 口径：全部来自 `ssh -i coevo_key ubuntu@<VPS_IP>` 的**本机实测**（无 sudo 或仅 `sudo -n` 探测，未执行任何写操作）

---

## 一、🔴 先说最要紧的：这台机器上在跑什么（**绝不碰**）

| 服务 | 路径 | 体积 | 端口 | 已运行 | 说明 |
|---|---|---|---|---|---|
| **`vibedollar-pay.service`** | `/opt/vibedollar-pay` | 112 M | `127.0.0.1:8100` | **18 天** | vibedollar 支付网关（FastAPI） |
| **`mailproxy.service`** | `/opt/mailproxy` | 56 M | `127.0.0.1:8200` | **48 天** | vibedollar 发信代理（QQ SMTP · 国内 IP 绕风控） |
| **nginx** | `/etc/nginx/` | — | `0.0.0.0:80/443` | — | 反代 → 站点 `pay.keyievolution.fun` |

**nginx 站点现状**（`/etc/nginx/sites-available/vibedollar-pay`，**唯一站点**）：

```
server_name pay.keyievolution.fun          # 80: certbot webroot（/var/www/certbot）
                                           # 443: TLS（/etc/letsencrypt/live/pay.keyievolution.fun/）
location = /healthz   → 127.0.0.1:8100/healthz
location /api/pay/    → 127.0.0.1:8100
location /api/mail/   → 127.0.0.1:8200
location /            → 404                ← 🔑 「其余一律 404」：加 CoEvo **不影响任何现有路径**
```

### 🔴 我的「绝不碰」承诺（逐条可核验）

| # | 承诺 |
|---|---|
| 1 | **不修改** `/etc/nginx/sites-available/vibedollar-pay`（只**新增**一个文件） |
| 2 | **不动** `/opt/vibedollar-pay` · `/opt/mailproxy`（含其 `.venv` · 代码 · 数据） |
| 3 | **不动** `vibedollar-pay.service` · `mailproxy.service`（不 stop/restart/disable/改 unit） |
| 4 | **不碰**现有证书 `pay.keyievolution.fun`（新证书单独申请） |
| 5 | **不改**系统级配置（不装系统 rust/docker、不改 sysctl、不改 limits） |
| 6 | **不动**任何现有端口（8100 / 8200 / 80 / 443 的现有行为） |
| 7 | 只做**新增**：`/opt/coevo/` + `/etc/systemd/system/coevo.service`（+ 后期一个 nginx 站点文件） |

---

## 二、资源评估

| 项 | 实测 | 评估 |
|---|---|---|
| CPU | **2 核** · load average **0.10 / 0.06 / 0.02** | ✅ **很闲**（基本没负载） |
| 内存 | **961 MiB 总量** · used **411 MiB** · **available 550 MiB** | 🟠 **偏紧** —— 见 §五风险 |
| Swap | 1.9 GiB（已用 182 MiB） | ✅ 有余量 |
| 磁盘 | 40 G · 已用 6.5 G（18%）· **剩 32 G** | ✅ 充裕 |
| inode | 剩 **2,494,094**（5%） | ✅ 充裕 |
| 系统 | Ubuntu **24.04.4 LTS** · kernel 6.8 · 已跑 **49 天** | ✅ 稳定 |
| 权限 | ✅ **有 NOPASSWD sudo** | ✅ **我可自行部署**（但严格遵守 §一 承诺） |
| 运行时 | Python 3.12.3 · certbot 2.9.0 · **无 rust/cargo/docker** | 🔴 **无 Rust** → 见 §四 |
| 残留 | ✅ **无 `/opt/coevo*` 或 `coevo*.service`** | ✅ 干净起点 |

---

## 三、部署架构（最小侵入）

```
                    Internet
                       │
        ┌──────────────┴──────────────┐
        │  nginx (0.0.0.0:80/443)     │   ← 现有 nginx，**只加一个新 server 块**
        └──┬───────────┬───────────┬──┘
           │           │           │
  pay.keyievolution.fun      api.keyievolution.fun  ← 🆕 新站点（独立文件）
           │           │           │
    ┌──────┴─────┬─────┴────┐     │
    │            │          │     │
  :8100        :8200      :8300 ──┘   ← 🆕 CoEvo（**新端口，不与现役冲突**）
vibedollar-pay mailproxy  coevo
  (不动)        (不动)     (新增)
```

| 项 | 新建 | 说明 |
|---|---|---|
| 目录 | `/opt/coevo/`（`bin/` · `data/` · `prompts/`） | 与现有 `/opt/*` 同级，互不干扰 |
| 二进制 | `/opt/coevo/bin/coevo-backend` | §四 构建 |
| 服务 | `/etc/systemd/system/coevo.service`（**新文件**） | 照 `mailproxy.service` 模板 |
| 端口 | **`127.0.0.1:8300`** | 只监听本机（nginx 反代），**不对外暴露** |
| 数据 | `/opt/coevo/data/coevo.db`（**空骨架**，0.59 MB） | 全新库，不碰任何现有数据 |
| nginx | `/etc/nginx/sites-available/coevo`（**新文件**）+ 软链 | ⚠️ 需 `nginx -s reload`（见 §六） |
| 证书 | `api.keyievolution.fun`（certbot 新申请） | 现有证书**不受影响** |

---

## 四、🔴 Rust 二进制怎么出（服务器无 rust/cargo）

**不能在服务器上编译**：① 无 rust ② **内存 961 MiB 不够 `cargo build --release`**（易 OOM）③ 装 rust 属「动系统」→ 违 §一 承诺 5。

| 方案 | 评价 |
|---|---|
| **甲 ⭐ GitHub Actions 构建** | ✅ **推荐** —— 仓库**已有 CI**（`.github/workflows/ci.yml` 的 `backend` job 已在 ubuntu-latest 跑 clippy/test）→ **只加一个「build release + upload-artifact」job**。ubuntu runner 不受私有仓库 10× 计费（那是 macOS 才翻倍）。产出 artifact → 本地下载 → `scp` |
| 乙 本地交叉编译 | 🟠 本地**已装** `x86_64-unknown-linux-gnu` target，但**缺 Linux linker** → 需装 `cargo-zigbuild`/`cross`（新工具链） |
| 丙 服务器上装 rust 编译 | 🔴 **不可取** —— 违「别动其他东西」+ 内存不足 |
| 丁 租一台构建机 | 🔴 多余 |

**→ 建议甲。** 且它**可复用**：以后每次后端改动的部署都走同一条路（而不是每次手工折腾）。

### 部署包内容（实测体积）

| 项 | 体积 | 备注 |
|---|---:|---|
| release 二进制 | ≈ 30–60 MB | 待 CI 实测（Rust 静态链接偏大） |
| `cefr_catalog.json` | **11.55 MB** | 后端启动时 `word_bank::init` 要读 |
| `prompts/`（10 文件） | 361 KB | `prompt_loader::init` 要读 |
| `data/coevo.db` | 0.59 MB | 空骨架（建表靠 `schema.rs`，见下） |
| `.env` | 1,090 B | 🔴 **含密钥，必须单独传、不进 git、权限 600** |
| **合计** | **≈ 45–75 MB** | ✅ 可接受 |

🔴 ~~**注意：不要传 `backend/schema.sql`**~~ —— **该文件已于 2026-09-29 删除**（过时死文件：45 表，其中 16 张是已退役旧学习链，0 处代码引用；删除是清理「存量吸引新依赖」）。
真正建表由 **`schema.rs`（18 表 + 2 张制卡缓存 = 20 表，编译进二进制）** 在启动时执行
（入口是 `db_pool::init()` → `schema::init_database()`，见 `db_pool.rs`）。
→ 现在「改 sql 就能加表」这个误导源本身已不存在；**加表只改 `schema.rs`**。

---

## 五、🔴 风险评估（内存是唯一真风险）

| # | 风险 | 分析 | 缓解 |
|---|---|---|---|
| 1 | **内存不足拖垮支付/邮件** | 961 MiB 总量，现 available **550 MiB**。CoEvo 是 Rust（RSS 预估 30–60 MB）+ SQLite → **够，但没有余量挥霍**。且 CoEvo 有 LLM 调用（**并发时瞬时占用上升**） | 🔴 **systemd 加 `MemoryMax=256M`** —— 超限只杀 CoEvo，**保支付/邮件**（这是必须的） |
| 2 | **改 nginx 影响现网站点** | 加**新文件**不改旧文件；但 `reload` 是全局动作 | ✅ 先 `nginx -t` 验证语法 → 再 `reload`（毫秒级，不断连接）· **保留 `.bak` 可秒回滚** |
| 3 | **证书申请触发限流** | 新域名证书要 certbot | ✅ 用现有 webroot（`/var/www/certbot`）· 注意 letsencrypt 每周 50 张/域名上限（远没到） |
| 4 | **域名/备案** | `keyievolution.fun` **已备案**（粤ICP备2026061557号-1）→ 子域可用 ✅ | 需**白哥加 DNS A 记录**（见 §七） |
| 5 | **误操作波及生产** | 我有 sudo | ✅ §一 七条承诺 · 每步操作前报告 · 只新增不修改 |

---

## 六、分步计划（**步骤 1 完全不碰 nginx，风险为零**）

| 步 | 内容 | 碰 nginx? | 谁能做 | 前置 |
|---|---|---|---|---|
| **1** | 上传二进制 + `cefr_catalog.json` + `prompts/` + `.env` 到 `/opt/coevo/` · 建 `coevo.service`（`127.0.0.1:8300` + `MemoryMax=256M`）· `systemctl start` · **服务器本机 `curl 127.0.0.1:8300/health` 验证** | ❌ **完全不碰** | ✅ **我**（有 NOPASSWD sudo） | ① A1 代码写完 ② CI 出二进制 |
| **2** | nginx 加新站点（新文件 + `nginx -t` + `reload`）+ certbot 申请 `api.keyievolution.fun` | ⚠️ **要 reload** | ✅ 我（**执行前单独报告**） | ① 步骤 1 通过 ② **白哥加 DNS** |
| **3** | 端侧接（A2）· 真机端到端 | — | 🟠 我写 + 白哥编译 | 步骤 2 通 |

🔑 **为什么这样切**：步骤 1 能**在零风险下回答「能不能在这台机器上跑起来」** —— 不碰 nginx、不碰证书、不碰 DNS、不新增对外暴露。

---

## 七、🔴 需要白哥做的（只有一件）

**加一条 DNS A 记录**：

| 主机记录 | 类型 | 记录值 |
|---|---|---|
| `api`（即 `api.keyievolution.fun`） | A | **`<VPS_IP>`** |

（如果你更想用别的子域，告诉我；或想**先不做对外暴露**，步骤 1 也能独立跑完验证。）

---

## 八、请示

| # | 事项 | 我的建议 |
|---|---|---|
| 1 | **确认 §一 的「绝不碰」清单**（这是你要求的核心） | ⭐ 请确认 —— 特别是「**唯一需要 reload nginx**」这一条 |
| 2 | **部署包构建走 GitHub Actions（甲）？** | ⭐ **是**（加一个 build job，产出 artifact） |
| 3 | **先做步骤 1（不碰 nginx）？** | ⭐ **是** —— 零风险验证「能不能跑」 |
| 4 | **DNS**：`api` **A** → `<VPS_IP>` · 🔴 **Proxy = DNS only（灰云）** | ⭐ 你操作（步骤 2 前给我即可）· 详见 **§九**（含「为什么不能开橙云」） |
| 5 | 内存护栏 `MemoryMax=256M` | ⭐ **必须**（超限只杀 CoEvo，保支付/邮件） |

---

*本轮**未改动服务器上任何东西**（无 sudo 写操作 · 无 nginx 改动 · 无服务重启 · 无文件上传）。
改动前会逐步报告并请示。*
---

## 九、DNS 现状核实（2026-09-29 12:1x）—— Cloudflare 托管

> 白哥：「当前设置的 DNS 服务器 `aitana.ns.cloudflare.com` / `weston.ns.cloudflare.com`」

### 9.1 实测：`pay` 已经是一条**可照搬的模板**

| 项 | 实测 | 含义 |
|---|---|---|
| NS | `aitana` / `weston`.ns.cloudflare.com | ✅ Cloudflare 托管 |
| `pay.keyievolution.fun` | **`<VPS_IP>`**（用 8.8.8.8 公共 DNS 复核一致） | 🔑 **灰云「仅 DNS」**（解析直出源站 IP） |
| 响应头 `Server:` | **`nginx/1.24.0 (Ubuntu)`** | 🔑 **源站直接回应** —— 再次证明没走 CF 代理（走代理会显示 `cloudflare`） |
| 证书 issuer | **`Let's Encrypt CN=YE2`** · subject `pay.keyievolution.fun` · 2026-08-10 → **11-08** | ✅ 源站 certbot 签发（**不是** CF 边缘证书） |
| `http://pay.../healthz` | **HTTP 301** → https | ✅ **80 端口对外可达** → **certbot HTTP-01 可行** |
| `https://pay.../healthz` | **HTTP 200** | ✅ |
| `api.keyievolution.fun` | **NXDOMAIN（不存在）** | 还没加 ✅ |
| `keyievolution.fun` / `www` | `<DOMAIN_OLD_IP>`（探测超时） | ⚠️ 另一处目标，**与本次无关，不动** |

> #### 🔄 2026-10-01 复测：**上表两行的状态已变**（白哥后续操作）
>
> | 项 | 09-29（上表） | **10-01 实测** |
> |---|---|---|
> | `api.keyievolution.fun` | NXDOMAIN | ✅ **`<VPS_IP>`** —— **A 记录已加**（灰云「仅 DNS」） |
> | `keyievolution.fun` / `www` | `<DOMAIN_OLD_IP>` | ✅ **`<VPS_IP>`** —— 🔑 **主域已改指向 CoEvo VPS**（原指向的是另一台） |
> | `http://api.../health` | — | **301**（`Server: nginx/1.24.0`）⇒ **nginx 已能处理该 Host**，**80 端口通**（certbot HTTP-01 前提满足） |
> | `https://api.../health` | — | 🔴 **000（连不上）** ⇒ **443 尚无证书/server block** → **步骤 2 只差这一项** |
>
> 🔑 **结论**：**「白哥加 DNS」这个前置条件已完全满足** —— 步骤 2 的剩余工作**全在当前可控范围内**。
> ⚠️ 复测方法（可重跑）：`nslookup <域>` + `curl -s -o /dev/null -w '%{http_code}' http(s)://<域>/health`，
>   **并用已知有证书的 `pay` 域做对照**（它的 `https` 返 **404** 而非 `000` ⇒ 证明本机 443 出网正常，
>   `api` 的 `000` 是**真实的服务未配**，不是网络限制）。

🔑 **一句话**：`pay` 的形态 = **灰云 + 源站 certbot 签的 LE 证书 + 80 端口通** ——
**这正是 CoEvo 要复制的模板**，且它已在生产验证过。

### 9.2 🔴 加 `api` 记录：**必须选「仅 DNS」（灰云）**

> ✅ **白哥已于 2026-10-01 前完成**（实测解析到 `<VPS_IP>`）—— 本节保留为**操作依据与理由存档**，
> 不再是待办。⚠️ 但理由仍有意义：**若将来有人把 `api` 改成橙云（Proxied）**，下面的论证说明为什么不行。

| 项 | 值 |
|---|---|
| Type | **A** |
| Name | `api`（即 `api.keyievolution.fun`） |
| IPv4 | **`<VPS_IP>`** |
| **Proxy status** | 🔴 **DNS only（灰云）** —— 与 `pay` 一致 |
| TTL | Auto |

**为什么不能开橙云（Proxied）**：

| # | 后果 |
|---|---|
| 1 | DNS 会解析到 **CF 的 anycast IP**，而不是 `<VPS_IP>` → 与 `pay` 不一致 |
| 2 | Let's Encrypt 的 HTTP-01 验证会先到 CF 边缘，需 CF 回源才能拿到 token → **引入不确定性** |
| 3 | 源站看到的客户端 IP 会变成 **CF 的 IP** → 现有 nginx 的 `X-Real-IP $remote_addr` 语义被改变 |
| 4 | 证书会变成 **CF 边缘证书**（issuer 变 Cloudflare），与 `pay` 的 LE 证书不一致 |

*（橙云 + HTTP-01 实践中常能过，但**没有任何理由在这引入不确定性** —— `pay` 已验证的路径就是灰云。）*

### 9.3 ✅ 顺带核实：现有 certbot 自动续期**健康**

| 项 | 实测 |
|---|---|
| `certbot.timer` | **enabled** · 上次 6h 前 · 下次 **20:46** |
| `pay` 证书 | **VALID: 40 days**（到 2026-11-08） |

→ ✅ 自动续期在工作，**不需要我干预**（这也说明源站 80 端口的 acme-challenge 路径长期可用）。

### 9.4 🔴🔴 一个必须注意的 nginx 细节（新发现，会写进步骤 2）

现有 80 端口配置（`vibedollar-pay`，**唯一** server block）：

```nginx
server {
    listen 80;  listen [::]:80;
    server_name pay.keyievolution.fun;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }   # ← certbot 用
    location / { return 301 https://$host$request_uri; }
}
```

**实测：`grep default_server` → 无命中** → nginx **用「第一个** server block」当默认 server，
而 `include /etc/nginx/sites-enabled/*` 按 **字典序**加载。

🔴 **风险**：若把新文件命名为 `coevo`，它**排在 `vibedollar-pay` 之前** → **抢走默认 server**
→ 「未匹配 Host」的请求（含 IP 直连 80）行为被改变 —— **这违反「不碰」承诺 6**。

✅ **两条应对**（都会做）：
1. **命名 `zz-coevo`**（字典序在 `vibedollar-pay` 之后）→ **默认 server 不变**
2. 🔑 **先申请证书、再改 nginx**：certbot 走 HTTP-01 时 `Host=api.keyievolution.fun` 无匹配 block
   → fallback 到默认 server（**pay 的 block**）→ 它**已有** `/.well-known/acme-challenge/` →
   **证书可以在「完全不改 nginx」的情况下拿到** ✅

### 9.5 ✅ 修正后的步骤 2（比 §六 更精确）

| 顺序 | 动作 | 改 nginx? |
|---|---|---|
| 2.1 | **白哥加 DNS**：`api` A → `<VPS_IP>` · **仅 DNS** | ❌ |
| 2.2 | `certbot certonly --webroot -w /var/www/certbot -d api.keyievolution.fun` | ❌ **不改**（靠默认 server 的 acme-challenge） |
| 2.3 | 写 `/etc/nginx/sites-available/zz-coevo`（80 跳转 + 443 反代 → 8300）+ 软链 | ✅ 新增文件 |
| 2.4 | **`nginx -t` 先验** → `nginx -s reload` | ⚠️ reload |
| 2.5 | 备份原配置（可秒回滚）+ 复验 `pay` 仍 200 | — |

> 2.2 与 2.3 的顺序**不可颠倒** —— 颠倒了就要依赖「新 block 也配 acme-challenge」，
> 且若新 block 排在前还会抢默认 server。
### 9.6 🔴 12:2x 复核：白哥已改 DNS —— 实测发现两件事

**白哥给的表**：`keyievolution.fun` / `pay` / **`pi`** / `www` → 全部 **A** → `<VPS_IP>` · **仅 DNS** ✅

**实测（用 8.8.8.8 复核，排除本地缓存）**：

| 域名 | 解析 | 备注 |
|---|---|---|
| `keyievolution.fun` | `<VPS_IP>` | 🆕 **改过**（原 `<DOMAIN_OLD_IP>`） |
| `pay.keyievolution.fun` | `<VPS_IP>` | 不变 |
| **`api.keyievolution.fun`** | ❌ **NXDOMAIN（不存在）** | ⚠️ 我方案里要的是这个 |
| **`pi.keyievolution.fun`** | `<VPS_IP>` | 🆕 **加的是 `pi`，不是 `api`** |
| `www.keyievolution.fun` | `<VPS_IP>` | 🆕 **改过**（原 `<DOMAIN_OLD_IP>`） |

#### 🔴 第二件事：主域 / `www` / `pi` 现在 HTTPS 会「**证书不匹配 + 404**」

因为它们指向本机，但本机 nginx **只有 `pay` 的 server block** → 请求 fallback 到**默认 server（`pay` 的）**：

| 探测 | 结果 |
|---|---|
| `http://keyievolution.fun/` | **301** → `https://keyievolution.fun/`（80 默认 server 的 `return 301`） |
| `https://keyievolution.fun/`（**不加 `-k`**） | 🔴 **证书错误**：`SEC_E_WRONG_PRINCIPAL`（目标主要名称不正确） |
| 同上（**加 `-k`** 跳过验证） | **404**（命中 `pay` 的 `location / { return 404; }`） |
| 证书 subject | **`CN=pay.keyievolution.fun`** → 与这三个域名**都不匹配** |
| `pay` 自己 | ✅ **HTTP 200**（正常，未受影响） |

🔑 **状态变化**：主域从「**不通**」（`<DOMAIN_OLD_IP>` 超时）变成「**HTTPS 证书警告 + 404**」——
**对访客而言比之前更糟**（浏览器会弹安全警告）。
这是**改 DNS 的连带结果**（本机没有对应 server block，也无对应证书）。

**⏳ 待白哥澄清**（两个歧义，见请示）：
1. `pi` 是笔误还是有意？（我方案里写的是 `api`）
2. 主域 / `www` 指向本机的**意图**是什么？
---

## 十、域名规划（2026-09-29 12:2x · 白哥答复后定稿）

### 10.1 白哥的答复

| 问 | 答 |
|---|---|
| `pi` 还是 `api`？ | **「pi 是其他的功能，你如果要用 api 可以加一个」** → 🔴 **`pi` 属别的用途，我不碰**；CoEvo 用 **`api`**（白哥将新增该记录） |
| 主域 / `www` 做什么？ | **「给 CoEvo 用」** |

### 10.2 域名分工（定稿）

| 域名 | 归属 | 处理 |
|---|---|---|
| **`keyievolution.fun`** | ✅ CoEvo 门面 | 配 server block + 证书（**当前是证书错误 + 404**，见 §9.6） |
| **`www.keyievolution.fun`** | ✅ CoEvo 门面（同上） | 同上（建议 301 到主域，或同站） |
| **`api.keyievolution.fun`** | ✅ CoEvo 后端 API | 反代 → `127.0.0.1:8300` · ✅ **DNS 已加**（2026-10-01 实测：解析到 `<VPS_IP>`；`http` 返 **301** 证明 nginx 已能处理该 Host，而 `https` 仍 **000** ⇒ **只差证书 + server block**）· ⏳ **步骤 2 待执行** |
| `pay.keyievolution.fun` | 🔴 vibedollar 支付 | **不碰**（现有） |
| **`pi.keyievolution.fun`** | 🔴 **别的功能** | **不碰** |
| `mailproxy`（无独立域名） | 🔴 vibedollar 邮件 | **不碰** |

### 10.3 🔴 主域「当前状态」比改之前更差 —— 建议优先修

实测（§9.6）：主域 + `www` 现在是 **HTTPS 证书错误（`CN=pay...` 不匹配）+ 404**，
而改 DNS 之前是「不通」。**对访客而言：从"打不开"变成"安全警告"**。

→ **建议优先做**（不依赖 `api` 记录）：给主域 + `www` 配 server block + 证书
→ 证书可**一次覆盖全部**（将来 `api` 加好后再 `--expand`）：
```bash
certbot certonly --webroot -w /var/www/certbot \
  -d keyievolution.fun -d www.keyievolution.fun -d api.keyievolution.fun
```

### 10.4 🔴 主域放什么内容？—— 旧设计稿**已过时**，需产品决策

仓库里有 landing 相关素材，但**全部早于当前方向**：

| 文件 | 日期 | 问题 |
|---|---|---|
| `docs/features/landing-page-design.md` | **5 月 13 日** | 「单页官网 + **APK 下载**入口」→ 🔴 与现定「**仅 iOS**」**矛盾** |
| `docs/marketing/landing-redesign-plan.md` | 7 月 11 日 | 同期 |
| `docs/deliverables/landing-growth-audit.md` | 7 月 11 日 | 同期 |
| `docs/deploy/web-deploy-guide.md` | 7 月 13 日 | 同期（45 KB） |
| `marketing/`（**1,655 个文件**） | — | 含 remotion 视频 / discovery / v3-demo，同样陈旧 |

🔑 **记忆里明确**：「**仅 iOS**」+「**不做**：Web · 微信 · 词表分级 · plan · 跟读评测 · UGC」
（此处「Web」按上下文指 **Web 版应用**；官网/落地页属另一维度，但**旧稿的 APK 定位已不成立**）。

**三个选项（需白哥定）**：

| # | 主域放什么 | 工作量 | 评价 |
|---|---|---|---|
| **甲** ⭐ | **最简占位页**（一页静态 HTML：产品名 + 一句介绍 + 备案号） | 极小 | ✅ **先解决「证书错误 + 404」**；内容待上架前再充实 |
| 乙 | 更新旧落地页设计稿（改为 iOS / App Store 定位）再上线 | 中 | 🟠 但**尚未上架**，下载入口无处可指 |
| 丙 | 主域也反代到后端（:8300） | 极小 | ❌ 后端无根路由 → 仍 404（只修证书不修内容） |

**我的建议：甲** —— 用最小代价把「证书错误」这个**活跃不良状态**消掉；
落地页作为**独立任务**（属营销/上架准备，需产品决策，不该阻塞本次部署）。

### 10.5 修正后的执行顺序

| 步 | 内容 | 谁 | 依赖 |
|---|---|---|---|
| **0** | 白哥加 `api` 记录（A · `<VPS_IP>` · **仅 DNS**） | 白哥 | — |
| **1** | 服务端起（`/opt/coevo` + service 8300 + `MemoryMax=256M`）· 本机 `curl` 验 | 我 | A1 代码 |
| **2** | nginx 三域名 server block（主域/www/api）+ 一张多域名证书 + `reload` | 我（**先报告**） | 步 0 + 步 1 |
| **3** | 端侧接（A2）+ 真机端到端 | 我 + 白哥编译 | 步 2 |

> 🔑 步 2 也可**拆成 2a（主域+www）+ 2b（api）** —— 2a 不依赖 `api` 记录，
> 可以先修掉主域的证书问题。**推荐先 2a**（把活跃不良状态尽快消掉）。
---

## 十一、主域规划（2026-09-29 12:3x · 白哥授权我定）

> 白哥：「主域名方式吗你自己看，大概率是落地页吧，不过如果暂时不用就留着，等你规划」

### 11.1 现状：主域处于「**不良状态**」，且有明确的处理窗口

| 项 | 状态 |
|---|---|
| `keyievolution.fun` / `www` | 🔴 **HTTPS 证书错误（`CN=pay...` 不匹配）+ 404**（§9.6 实测） |
| 改 DNS 之前 | 不通（旧 IP `<DOMAIN_OLD_IP>`） |
| **处理窗口** | 🔑 **配 `api` 时本来就要动 nginx** → 顺手加主域**边际成本趋近 0** |

### 11.2 🔴 所有现成 landing 素材**全部过时**（不能直接用）

我逐个查了仓库里的落地页资产，**没有一份能用** —— 它们说的是**另一个产品**：

| 文件 | 它说什么 | 与现产品的冲突 |
|---|---|---|
| `docs/features/landing-page-design.md`（**5/13**） | HERO：「如果不想被 AI 取代，你需要刻意进化」+ **[下载 APK]** + 「支持 Android 8.0+」 | 🔴 定位是**早期 AI 对话产品**；且**APK / Android** 与「仅 iOS」直接矛盾 |
| `backend/data/crawler.html`（200 行，**最完整的一份**） | 标题「**CoEvo AI特级教师**」· keywords「**K12教育**」· 「无需下载，浏览器打开即用」·「支持电脑/手机/平板」·「免费试用 3 天」 | 🔴 **另一套完全不同的定位**：AI 特级教师 / K12 / **Web 应用** —— 与现在「**英语学习 iOS App · RSS 阅读 + 划词查词 + FSRS 复习 · 订阅制**」全不符 |
| `docs/marketing/landing-redesign-plan.md`（7/11）· `landing-growth-audit.md`（7/11）· `docs/deploy/web-deploy-guide.md`（7/13） | 同期规划 | 🔴 同期 |
| `marketing/`（**1,655 文件**） | remotion-videos / discovery / v3-demo | 🔴 同期 |

🔑 **结论**：落地页要**从零写**（或大改），**不能复用旧稿** —— 否则会把「AI 特级教师 / K12 / Web」这些已废弃的定位重新发布出去。

### 11.3 ✅ 有用的资产：备案信息（实测已确认）

| 项 | 值 | 用途 |
|---|---|---|
| **网站备案** | **`粤ICP备2026061557号-1`** | 🔑 **主域网站用这个**（`-1` = 网站） |
| **APP 备案** | `粤ICP备2026061557号-**2**` | App 内展示用（**不是**网站） |
| 公安备案 | `粤公网安备44060602003333号`（📄 见 `memory/2026-06-17.md`） | 页脚可一并挂（⚠️ 待白哥确认是否仍有效） |

### 11.4 三阶段规划

| 阶段 | 时机 | 内容 | 成本 |
|---|---|---|---|
| **① 占位页** | **并入本次（配 `api` 时）** | 主域 + `www` 的 server block + 多域名证书 + **一页最简静态 HTML** | 🟢 **趋近 0**（与 `api` 同一批 nginx 操作） |
| **② 正式落地页** | **iOS 上架前** | 重写文案（英语学习 App 定位）+ **App Store 下载入口** | 🟠 中（需产品文案） |
| **③ SEO / 内容站** | 上线后（可选） | 博客 / 词表索引页（旧 SEO 方案可参考，但需重做定位） | 🟠 持续 |

🔑 **为什么阶段 ① 值得现在做**（三条）：
1. **顺手** —— 配 `api` 必须动 nginx，加主域是同一批操作（多一个 server block + 证书多一个域名）
2. **消除不良状态** —— 「证书警告 + 404」对任何访客（含**备案核查**）都是负面印象
3. **不阻塞** —— 占位页可 1 个文件、几十行 HTML，**不打乱主线**（A1）

🔑 **为什么阶段 ② 必须等到上架前**：
**没有 App Store 链接** → 落地页最关键的「下载入口」**无处可指** →
现在做也只是空壳，且**文案/设计到那时多半要重来**。

### 11.5 占位页内容草案（阶段 ①，供白哥过目）

```html
<title>刻意进化 · CoEvo</title>
<h1>刻意进化 · CoEvo</h1>
<p>英语学习 App —— 读真实内容，划词即查，科学复习。</p>
<p>即将上线 App Store</p>
<footer>
  粤ICP备2026061557号-1
  （+ 公安备案，若确认有效）
</footer>
```

🔑 **要点**：
- ✅ **不提 Android / APK / Web / K12 / AI 特级教师**（都是废弃定位）
- ✅ **不提下载按钮**（还没上架）
- ✅ 挂**网站**备案号（`-1`）
- ✅ 一个文件、无 JS、无外链 —— 最小攻击面、最快加载

### 11.6 请示（二选一，一句话即可）

| 选项 | 内容 |
|---|---|
| **甲** ⭐ | **阶段 ① 现在做**（并入配 `api` 那批 nginx 操作）→ 主域立刻脱离「证书错误 + 404」 |
| **乙** | **主域先不动** —— 只配 `api`；主域保持现状（证书错误 + 404），等上架前一起做 |

**我建议甲** —— 边际成本几乎为 0，且能消掉一个**活跃的**不良状态。

---

## 十二、🟢 步骤 1 实施记录（2026-10-01 17:13 · 已完成）

> 白哥「1→2」的第 2 步。**本轮只新增 `/opt/coevo` 与 `coevo.service`** —— 未碰 nginx / 证书 / DNS / 任何现役服务。

### 12.1 🔴 方案调整：二进制不走 GitHub Actions（原计划「甲」被实测否决）

原计划（§四 方案甲）：加 CI build job → 产出 artifact → 本地下载 → `scp`。

**实测卡点**：

| 项 | 实测 |
|---|---|
| 仓库 `Big-Pi100/CoEvo` | 🔴 **私有**（`api.github.com` 返回 404） |
| `gh` CLI | 已装 2.65.0，但 **未登录** |
| `GH_TOKEN` / `GITHUB_TOKEN` / `GH_ENTERPRISE_TOKEN` / `GITHUB_PAT` | 🔴 **全部未设置** |

→ **私有仓库的 artifact 必须带 token 才能下载**，而本机没有任何可用凭据 →
这条路**当前走不通**（不是配置问题，是缺凭据）。

**改用方案乙（本地构建）的变体 —— WSL 原生构建**：

| 探项 | 实测 |
|---|---|
| 本机有 WSL | ✅ `Ubuntu-22.04`（7.8 GB 内存 · 898 GB 可用） |
| rust | ✅ 已有 cargo/rustc **1.94.0**（在 `~/.cargo/env`；**非登录 shell 需先 source** —— 这是我第一次探测误判「无 rust」的原因） |
| C 工具链 | ✅ `gcc` / `cc` / `make` 齐全（`rusqlite bundled` 要编 SQLite C 源码） |
| crates 镜像 | ✅ `rsproxy.cn` 200（已配 `~/.cargo/config.toml`） |
| glibc | 22.04 = **2.35** → 部署机 24.04（2.39）**可运行**（向后兼容） |

🔑 **为什么它比 CI 更合适**：不依赖任何外部凭据 · 不占 CI 额度 · 构建机与部署机同为 x86_64 Linux。
⚠️ **CI job 仍然加了**（`.github/workflows/ci.yml` 的 `backend-release`，手动 / tag 触发）——
   它是**长期正确**的路子，将来有 token 或换公开仓库即可直接用；本轮只是**没拿它当交付通道**。

**构建结果**：
```
ELF 64-bit LSB pie executable, x86-64   ·   strip 后 16.7 MB（原 20.6 MB）
依赖：libssl.so.3 / libcrypto.so.3 / libgcc_s / libm / libc   ← 24.04 均有（实测确认）
部署包合计 28 MB = 二进制 + cefr_catalog.json(12.1 MB) + prompts/(393 KB)
```

📄 构建脚本已入仓库：`scripts/deploy/build_linux_in_wsl.sh`（可复用）

### 12.2 🔴 实测修正：§四「部署包内容」有三处与现状不符

| # | §四 原说法 | 实测 | 影响 |
|---|---|---|---|
| 1 | 要传 `data/coevo.db`（空骨架 0.59 MB） | ❌ **不需要** —— `main.rs` → `db_pool::init()` **自动建库建表**（20 表）；实测首启即生成 `coevo.db` + WAL | 少传一个文件、少一处漂移源 |
| 2 | `prompts/`（10 文件 361 KB）·「`prompt_loader::init` 要读」 | 🟠 实际 **110 文件 393 KB**；且 `prompt_loader::init` **完全容错**（读不到 → 空注册表，**不 panic**） | 该模块**不是**硬依赖 |
| 3 | （未提） | 🔴 `prompts/` 里 **212 KB 是 K12 退役遗留**（`chat/` 16 科目 + `concept/` `plan/` `quiz/` `verify/` `routing/`） | ⏳ 建议后续清理（§12.5） |

**② 的核实方法**（不读注释，读代码）：`prompt_loader::read_file` 用 `unwrap_or_default()`；
`scan_subject_dirs` 用 `if let Ok(entries) = read_dir` → **目录整个缺失也只是空注册表**。

**真正「运行时必读」的只有 2 个**：

| 文件 | 谁读 | 读不到会怎样 |
|---|---|---|
| `wordlib_contract.md` | `llm_card.rs`（LLM 制卡契约） | 制卡 prompt 为空 → 制卡坏 |
| `compliance_terms.json` | `compliance.rs`（合规闸门） | 🔴 **返回 Err，不降级** → 制卡被拦 |

（`compliance_cases.json` 是 `include_str!` **编译期嵌入**，运行时不需要 —— 但仍一并传，保持目录完整。）

→ **最终仍传整个 `prompts/`**（393 KB 很小）：避免漏，也让 `config_admin` 的目录列举完整。

### 12.3 `.env`：只传「启动 + 现役」所需

**实测依据**：`WECHAT_*`（9 个）与 `TENCENT_*`（3 个）在代码里**全是 `.ok()?` 惰性读取**
（`wechat_pay.rs` / `tencent_asr.rs` / `tencent_tts.rs`）→ **不在启动路径上** →
不传只是「该功能不可用」，**服务照常起**。

| 传入 | 用途 |
|---|---|
| `COEVO_HOST=127.0.0.1` | 🔴 **必须显式设** —— 默认 `0.0.0.0` 会**对外暴露** |
| `COEVO_PORT=8300` | 新端口，不与现役冲突 |
| `DEEPSEEK_API_KEY` | LLM 制卡（实测 warmup OK） |
| `COEVO_ADMIN_KEY` · `COEVO_PII_KEY` | 管理后台 · PII 加密 |

**未传**：微信支付 9 项 + 腾讯云 3 项（**惰性**，待支付批再补）· `COEVO_K12_DATA_DIR`（退役）
· `COEVO_BASE_URL` / `PUBLIC_BASE_URL`（步骤 1 无对外地址）。

权限 `600`（照 `/opt/mailproxy/.env` 惯例）。🔴 上传用的 `/tmp/coevo_stage` **已删除**（含明文 `.env`）。

### 12.4 ✅ 实测结果

| 项 | 结果 |
|---|---|
| `coevo.service` | ✅ **active (running)** · **enabled**（开机自启） |
| `curl 127.0.0.1:8300/health` | ✅ `CoEvo API — OK`（**首次尝试即 200**） |
| 监听 | ✅ **仅 `127.0.0.1:8300`** —— `ss -ltn` 确认**未新增任何对外监听** |
| 启动链 | ✅ DB 建表 · 词库 **41,574 词 / 4 档** · `LLM warmup: OK` · `ready on 127.0.0.1:8300` |
| 🔴 内容抓取 | ✅ **首轮 5/5 源成功 · 新增 201 条**（NPR 10 · ECNS 100 · Ars 20 · Dev.to 12 · HN 59） |
| `/api/feed` | ✅ 返回真实条目（字段齐：`source` / `published_at` / `score` / `comments` / `has_body` / `word_count`…） |
| 内存 | ✅ **82 MB / 256 MB**（护栏未触发） |
| 🔴 vibedollar | ✅ `vibedollar-pay` · `mailproxy` · `nginx` **全部 active**（未受影响） |

**新增物（仅新增，未改任何现有文件）**：
```
/opt/coevo/{bin/coevo_backend, cefr_catalog.json, prompts/, .env(600), data/}
/etc/systemd/system/coevo.service
```

**回滚（一条命令）**：
```bash
sudo systemctl disable --now coevo && sudo rm -f /etc/systemd/system/coevo.service \
  && sudo systemctl daemon-reload && sudo rm -rf /opt/coevo
```

### 12.5 ✅ 已完成（2026-10-02）：步骤 2 —— nginx 反代 + `api` 证书

**✅ 端到端已通**：`https://api.keyievolution.fun/health` → **200** · TLS 证书校验通过 ·
`/api/feed` 返回**真实数据**。

#### 实施记录（照 §9.5 的顺序，**未改任何现有站点文件**）

| 步骤 | 动作 | 结果 |
|---|---|---|
| 1 | 备份 nginx 配置 | `/home/ubuntu/nginx-backup-20261002-002519/`（sites-available + sites-enabled + nginx.conf）|
| 2 | `certbot certonly --webroot -w /var/www/certbot -d api.keyievolution.fun` | ✅ 签发成功（**此时未改 nginx** —— 靠 `pay` 的默认 server block 兜 acme-challenge）· `CN=api.keyievolution.fun` · 到期 **2026-12-30** · 自动续期已挂 |
| 3 | 写 `/etc/nginx/sites-available/zz-coevo` + 软链 | ✅ **命名 `zz-`** ⇒ 字典序在 `vibedollar-pay` 之后 |
| 4 | `nginx -t`（**通过才 reload**）| ✅ `SYNTAX_OK` |
| 5 | `systemctl reload nginx` | ✅ `RELOAD_OK` |

#### 🔬 三条「未影响邻居」的**证据**（这是本步最重要的验收）

| 证据 | 实测 |
|---|---|
| **默认 server 未变** | `nginx -T` 里 `vibedollar-pay`(L189) **仍在** `zz-coevo`(L262) 之前；且 **443 IP 直连（不匹配 Host）拿到的证书仍是 `CN=pay.keyievolution.fun`** ✅ |
| **邻居服务仍 200** | `https://pay.keyievolution.fun/healthz` → **200**（内外网各验一次）|
| **进程未被重启** | `coevo.service` 的 `ActiveEnterTimestamp` 仍是 **2026-10-01 20:46:37**（早于本次部署）⇒ **只 reload 了 nginx，没动任何后端进程** |

#### 🔴 新增发现：后端带着一组 `/api/admin/*` 端点 → **已在 nginx 层挡住**

后端（沿用 vibedollar 商业代码）路由里有完整的 `/api/admin/*`：
`users/export`（**导出用户**）· `users/{id}/hard-delete`（**硬删除用户**）· `dashboard` · `audit-log` …

- ✅ **App 侧对它们零调用**（2026-10-02 穷尽 grep：App 用的是 feed / generate-card / auth /
  user / notifications / referral / campaign / pay / public-qrcode —— **不含 admin**）
- ⇒ 配置里 `location /api/admin/ { return 404; }`（**最小暴露面**，不指望后端鉴权）
- ⚠️ **需要 admin 后台时**：删掉那一行即可，其余不动（已在配置文件里写明）
- 📌 顺带的事实：这个后端**不只是 CoEvo 内容源** —— 它含支付/分销/营销/通知端点，
  说明它复用了 vibedollar 的完整商业后端。**是否要精简**属独立决策（见「仍未做」）。

### 12.6 ⏳ 仍未做（边界）

| 项 | 状态 |
|---|---|
| ~~**nginx 反代 + `api` 证书**（步骤 2）~~ | ✅ **已完成 2026-10-02**（见 §12.5）|
| **主域 / www 占位页** | ⏳ 未定 —— 🔴 但**现状是「证书不匹配 + 404」**（DNS 已指向本机，nginx 无对应 block → fallback 到 `pay` 的默认 server）⇒ 访客看到**安全警告**。修法：加一个 `zz-` 前缀的占位 block（与 `api` 同做法）。**待白哥定放什么内容** |
| 🔴 **后端是否精简**（去掉 `/api/admin/*` 等商业端点）| ⏳ **新发现，待决策** —— 这些端点在代码里仍存在，目前只在 nginx 层挡住。是否要从**代码层**删掉（CoEvo 是个人项目、零用户，用不到支付/分销/营销/后台）属独立评估 |
| `prompts/` 的 K12 退役遗留 | ⏳ 建议独立清理（同「删功能要清语义残留」原则） |

---

*§十二 为步骤 1 的实施记录。步骤 1 **完全不碰 nginx**，故对现网零影响。*

---

## 十三、🟢 路径 B：CI 自动部署（2026-10-01 · 已配置，待首次触发验证）

> 白哥问「gh CLI 需要登录吗 / GH_TOKEN 那些是什么」→ 核实后发现**我上轮的结论片面了**，
> 于是补上这条**更省事**的部署路径。

### 13.1 🔴 先更正一个我自己的错误结论

上轮我写「CI 出二进制**这条路走不通**」—— **片面的**。

走不通的只是「**下载 artifact**」这一个**环节**。**部署**本身完全能通，而且**不需要下载任何东西**：

```yaml
# E:\vibedollar\.github\workflows\deploy.yml（本机已在跑，验证过的模式）
- name: Deploy to VPS (rsync)
  uses: easingthemes/ssh-deploy@v5.1.0
  with:
    SSH_PRIVATE_KEY: ${{ secrets.VPS_SSH_KEY }}
    REMOTE_HOST: <OTHER_PROJECT_IP>
    ...
```
→ CI 跑完**直接 rsync 到 VPS**，全程不需要 token。

🔑 **判据**：下「这条路走不通」前先问 —— 我说的是**目标**还是**手段**？
还有别的实现方式吗？**本仓库/本机有没有人已经这么干过**？
（这次正是靠 `~/.ssh/vibedollar_ci_deploy` 这个名字发现的。）

### 13.2 🔑 为什么 artifact 在 workflow 内部流转**不需要任何凭据**

| 场景 | 用什么认证 | 本机需要 token 吗 |
|---|---|---|
| **同一次 workflow 内** upload → download artifact | GitHub **自动注入**的 `GITHUB_TOKEN` | ❌ **不需要** |
| 在**本地/外部**下载 artifact | 必须带 PAT（`repo` 或 `Actions: read`） | ✅ 需要 |

📄 官方文档逐节不同（实测核对）：
- `List/Get an artifact` → 明写「can be used **without authentication** … if only public resources are requested」
- **`Download an artifact`** → ⚠️ **没有这句豁免** → 一律要认证
- 私有仓库 → 以上全部需要认证

→ 所以 B 的设计是「**release job 产出 → 同 workflow 内 deploy job 消费**」，**完全绕开凭据问题**。

### 13.3 🔴 密钥：专用 CI key（**没有**复用 `coevo_key`）

| 项 | 值 |
|---|---|
| 指纹 | `SHA256:cVihJXzdDMLe6pYu/zSjEPy+VGjqisYpTm/YJITghiY` |
| 注释 | `coevo-ci-deploy-20261001` |
| 类型 | ed25519（无 passphrase —— CI 无法交互输入） |
| 私钥（本地） | `~/.ssh/coevo_ci_deploy`（600） |
| 公钥（服务器） | `~/.ssh/authorized_keys` 第 3 行 |

**为什么不复用 `coevo_key`**：那把权限大、日常运维在用 → 一旦泄漏或需撤销，会连累日常。
专用 key 可**单独撤销**（删 authorized_keys 里那一行即可）。

🔴 **必须知道的事实**：服务器 `passwordauthentication no` → **SSH 只有 key 一条入口**，
所以这把 CI key 就是**全权访问**（能登录 + 能 `sudo`）。
`authorized_keys` 备份：`~/.ssh/authorized_keys.bak-20261001180600`。

**撤销步骤**：
```bash
ssh -i ~/.ssh/coevo_key ubuntu@<VPS_IP> \
  "grep -v 'coevo-ci-deploy-20261001' ~/.ssh/authorized_keys > /tmp/ak && mv /tmp/ak ~/.ssh/authorized_keys"
# 然后去 GitHub 删掉 secret COEVO_VPS_SSH_KEY，并停用 workflow
```

### 13.4 顺带修正的**属主问题**（否则 CI 的 rsync 覆盖不了）

首次部署用的是 `sudo install` / `sudo cp` → 这 3 个变成 `root:root`：
`bin/coevo_backend` · `cefr_catalog.json` · `prompts/`

→ CI 以 `ubuntu` 身份 rsync → **无法覆盖 root 的文件**。
→ 已 `chown ubuntu:ubuntu` 这 3 处（与 `/opt/coevo` 目录一致）。
🔴 **`.env` 保持 `root:root 600` 不动** —— systemd 以 root 读 `EnvironmentFile` 再注入给进程，
`ubuntu` 用户**不需要**直接读它。别顺手改成 ubuntu。

### 13.5 workflow 设计（`.github/workflows/ci.yml`）

```
backend-release  ──(artifact: coevo-backend-linux-x86_64)──▶  backend-deploy
   构建 + strip + 打包(dist/bin/…)                             下载 → rsync → 重启 → 验健康
```

| 步骤 | 关键点 |
|---|---|
| 打包结构 | **`dist/` 内部结构与 `/opt/coevo/` 一一对应**（`bin/` + `cefr_catalog.json` + `prompts/`）→ 部署就是一句 rsync，无需搬运 |
| 🔴 rsync | **不带 `--delete`**，且 `--exclude=data/ --exclude=.env` |
| 回滚点 | 部署前 `cp -a … coevo_backend.prev`；健康检查失败 → **自动回滚 + 重启 + 复验** |
| 可达性预检 | 单独一步先探 runner→VPS:22，失败时**给出明确结论与降级方案**，而不是让 rsync 报天书 |
| 邻居复验 | 部署后确认 `vibedollar-pay` / `mailproxy` / `nginx` 仍 active |

**为什么必须不带 `--delete`**：`/opt/coevo/data/`（运行时 DB + WAL）与 `.env`（密钥）
**只存在于服务器** —— 带 `--delete` 会把它们清掉。
📌 同类事故先例：vibedollar 2026-08-31（首页被覆盖）/ 09-11（CF 缓存）——
都是「部署把服务器侧独有的东西弄没了」。

**触发方式**：`workflow_dispatch`（手动）或 `v*` tag。**日常 push 不触发**（省额度 · 不误发布）。

### 13.6 白哥需要做的（一次）

1. 私钥已复制到剪贴板（或从 `C:\Users\Lenovo\.ssh\coevo_ci_deploy` 取）
2. 打开 `https://github.com/Big-Pi100/CoEvo/settings/secrets/actions`
3. **New repository secret** → Name = **`COEVO_VPS_SSH_KEY`** → Secret = 粘贴私钥全文（含首尾 `-----BEGIN/END-----` 行）
4. Actions → **CI** → **Run workflow**（选 main）

### 13.7 ⚠️ 一条未实测的风险（首次触发才能回答）

**GitHub runner 在海外，目标是国内 IP（`<VPS_IP>`）** —— 这条 SSH 链**此前未验证**。

| 证据 | 方向 |
|---|---|
| ✅ 80/443 端口被 **Let's Encrypt 海外节点**做过 HTTP-01 验证并成功签发证书 | 说明**无整体阻断**，海外能到这台机器 |
| ❓ **22 端口** | **未实测** |

→ 所以 workflow 里加了 **Preflight** 步：第一次触发就会明确告诉我们「能不能通」。
**若不通**：降级走本地 —— `scripts/deploy/build_linux_in_wsl.sh`（本次已用过，实测可行）。

### 13.8 三条路对比（定稿）

| | 路径 | 前置 | 适合 |
|---|---|---|---|
| **A** | 本地 WSL 构建 + `scp` | 无 | 手动控制、首次部署 |
| **B** ⭐ | **CI 直接 SSH 部署** | 1 个 secret（网页配） | 改完点一下就上 |
| C | artifact 下载到本地再传 | 需 PAT | 想本地先验产物 |

---

*§十三 为 CI 自动部署的配置记录。**密钥与 workflow 已就位，尚未首次触发** ——
首次触发的结果（尤其 13.7 的可达性）需另行记录。*

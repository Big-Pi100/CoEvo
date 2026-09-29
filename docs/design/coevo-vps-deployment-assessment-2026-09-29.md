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

🔴 **注意：不要传 `backend/schema.sql`** —— 它是**过时死文件**（45 表，含已退役旧学习链，0 处代码引用）。
真正建表由 **`schema.rs`（18 表，编译进二进制）** 在启动时执行。
→ 传过去会误导后人以为「改 sql 就能加表」（实际改了没用）。

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

🔑 **一句话**：`pay` 的形态 = **灰云 + 源站 certbot 签的 LE 证书 + 80 端口通** ——
**这正是 CoEvo 要复制的模板**，且它已在生产验证过。

### 9.2 🔴 加 `api` 记录：**必须选「仅 DNS」（灰云）**

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

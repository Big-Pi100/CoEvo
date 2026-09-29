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
| 4 | **DNS**：`api.keyievolution.fun` → `<VPS_IP>` | ⭐ 你操作（步骤 2 前给我即可） |
| 5 | 内存护栏 `MemoryMax=256M` | ⭐ **必须**（超限只杀 CoEvo，保支付/邮件） |

---

*本轮**未改动服务器上任何东西**（无 sudo 写操作 · 无 nginx 改动 · 无服务重启 · 无文件上传）。
改动前会逐步报告并请示。*

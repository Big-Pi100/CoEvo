# CoEvo 部署与出包 —— **单一权威**

> **2026-10-08 依据实测重写。** 本目录旧文档（`web-deploy-guide` / `deployment-guide` /
> `deployment-checklist` / `deployment-monetization-plan`）**已全部删除** ——
> 它们描述的是旧产品形态（Web）或已变的链路，**其中没有一份能用**。
> 需要历史请查 `git log -- docs/deploy/`。

---

## 0. 我要做什么 → 走哪条路

| 目的 | 路径 | 需要仓库公开？ | 谁执行 |
|---|---|---|---|
| **后端上线** | **A · WSL 构建 + scp**（§2.1）⭐ | ❌ 不需要 | 白哥构建 + agent 上传/重启/验证 |
| **安卓包**（真机测试） | 本地 `flutter build apk`（§3）| ❌ | 白哥 |
| **iOS 包**（TestFlight / 真机） | CI `ios-archive.yml` **手动触发**（§4）| 🔴 **需要** | 白哥触发 + agent 看结果 |
| iOS 能否编过（快速） | CI `ios-build`（tag 触发）（§5）| 🔴 需要 | agent 推 tag |

🔴 **默认顺序（2026-10-08 白哥定）**：

```
① 后端（路径 A，不公开）→ ② 安卓包 + 真机功能验证
→ ③ 功能完整后才公开仓库 → 跑 iOS → ④ 白哥立刻改回私有
```

📌 **「公开」是一次性、有明确目的的时间窗**（为了 macOS runner 的额度）。
**别让「部署后端」这种本来可离线完成的事占用它。**

---

## 1. 🔴 三个大前提（每个都真实踩过）

### 1.1 私有仓库的 Actions 额度会耗尽 ⇒ **CI 根本不跑**

额度耗尽后**连 run 都不会创建**。症状极具误导性：

| 你看到的 | 你以为 | 真相 |
|---|---|---|
| tag 推成功、`git push` 返回 OK | 「CI 在跑，等着」| 🔴 **没有 run** |
| VPS 毫无变化 | 「runner 在国外，连不上国内 VPS:22」| 🔴 同上 |
| Actions 页面没有新记录 | 「workflow 的 `if` 写错了」| 🔴 同上 |

📌 **判据：「没反应」先查「有没有 run」，再查「run 为什么失败」。**
两种情况下**在 VPS 侧看到的现象完全一样**（都是什么都没有）。

✅ 处置：**改 public**（公开仓库 Actions 免费无限）。
🔴 改前先跑历史审计：`python scripts/audit_git_history_secrets.py .`
⚠️ 改公开**不会重跑**已失败的 run ⇒ 要**删 tag 重推**（或界面 re-run）才触发。

### 1.2 提交才有得部署

CI 部署的是 **GitHub 上的代码**，不是本地工作区。⇒ **先 commit + push，再触发**。
⚠️ 只 `push main` **不部署**（见 §5 对照表）。

### 1.3 `prompts/` 不随二进制编译 ⇒ 必须单独同步

改了 prompt 而没同步到 `/opt/coevo/prompts/`，**运行时会读不到文件**。
核对方式：`md5sum` 两侧对比（**不是**「文件存在就算过」）。

---

## 2. 后端部署

### 2.1 路径 A（⭐ 默认）：WSL 构建 + scp —— **不需要公开仓库**

```bash
# ① 构建（⚠️ 必须由白哥的终端跑 —— WSL 在 agent 沙箱里被安全策略封禁）
LANG=C wsl.exe -d Ubuntu-22.04 -- bash -lc "tr -d '\r' < /mnt/e/CoEvo/scripts/deploy/build_linux_in_wsl.sh | bash"
#   产出：%TEMP%\coevo_deploy\  （coevo_backend + cefr_catalog.json + prompts/）

# ② 上传（打包成 tar 一次传，比逐个 scp 稳）
cd "/c/Users/Lenovo/AppData/Local/Temp/coevo_deploy" && tar czf /tmp/coevo_deploy.tar.gz coevo_backend cefr_catalog.json prompts
scp -i ~/.ssh/coevo_key /tmp/coevo_deploy.tar.gz ubuntu@111.230.197.4:/tmp/

# ③ 替换 + 同步 + 预检 + 重启（agent 执行）
ssh -i ~/.ssh/coevo_key ubuntu@111.230.197.4 '
set -e
rm -rf /tmp/coevo_new && mkdir -p /tmp/coevo_new
tar xzf /tmp/coevo_deploy.tar.gz -C /tmp/coevo_new

cp -a /opt/coevo/bin/coevo_backend /opt/coevo/bin/coevo_backend.prev     # 回滚点

# 🔴 不能直接 cp 覆盖运行中的二进制 —— 报 `Text file busy`（EXT4 拒写正在执行的文件）。
#    同分区 mv 是**原子 rename**（运行中的进程继续持旧 inode）⇒ 零停机、无需先停服。
cp /tmp/coevo_new/coevo_backend /tmp/coevo_backend.staged
chmod 755 /tmp/coevo_backend.staged
mv /tmp/coevo_backend.staged /opt/coevo/bin/coevo_backend

# ⚠️ 用 cp -a src/. dst/ 而不是 rsync —— VPS 上**没装 rsync**。
#    它与「rsync 不带 --delete」等价：覆盖同名、保留服务器独有的文件。
cp -a /tmp/coevo_new/prompts/. /opt/coevo/prompts/
cp /tmp/coevo_new/cefr_catalog.json /opt/coevo/cefr_catalog.json

test -x /opt/coevo/bin/coevo_backend || { echo "🔴 无执行位"; exit 1; }
ldd /opt/coevo/bin/coevo_backend 2>&1 | grep -q "not found" && { echo "🔴 缺动态库"; exit 1; }
sudo systemctl restart coevo && sleep 3 && curl -s http://127.0.0.1:8300/health'
```

⚠️ **前置**：WSL 里要有 Rust 工具链。报 `cargo: command not found` ⇒
`curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y`

⚠️ **回滚也要用 `mv`**（同样会 `Text file busy`）：

```bash
ssh -i ~/.ssh/coevo_key ubuntu@111.230.197.4 '
  cp -a /opt/coevo/bin/coevo_backend /opt/coevo/bin/coevo_backend.failed.$(date +%s)  # 先留现场
  cp -a /opt/coevo/bin/coevo_backend.prev /tmp/rollback.bin
  mv /tmp/rollback.bin /opt/coevo/bin/coevo_backend
  sudo systemctl restart coevo && sleep 3 && curl -s http://127.0.0.1:8300/health'
```

### 2.2 路径 B：推 `v*` tag 走 CI（仅在仓库**已公开**时用）

```bash
git add backend/ && git commit -m "feat(backend): ..."
git push origin main
git tag -a v0.1.7 -m "说明这次部署了什么"
git push origin v0.1.7          # ← 这一下才真正触发部署
```

CI 两个 job 的实际动作：

| job | 做了什么 |
|---|---|
| `backend-release` | `ubuntu-24.04` + Rust **1.98.0** → `cargo build --release --bin coevo_backend` → `strip` → 打包 `dist/{bin/coevo_backend, cefr_catalog.json, prompts/}`（**结构与 `/opt/coevo/` 一致**）→ upload-artifact |
| `backend-deploy` | download-artifact → SSH → **可达性预检** → 备份 `.prev` → **`rsync -avz --exclude='data/' --exclude='.env'`（🔴 不带 `--delete`）** → **权限修复 + `test -x` + `ldd`** → 重启 → **health 探测 10 次** → 失败**自动回滚** |

**两个必须知道的点**
- 🔴 **`rsync` 不带 `--delete`** —— `/opt/coevo/data/`（运行时 DB/WAL）与 `.env` 只存在于服务器，带 `--delete` 会被清掉。
- 🔴 **artifact 不保留执行位**（官方文档明写）⇒ 二进制落地是 `644` ⇒ `execve` 报 `EACCES` ⇒ systemd **203/EXEC**。
  所以有那步「显式 `chmod` + `test -x`」。
- ⚠️ `backend-deploy` **不依赖**门禁 job ⇒ **门禁红也照样部署**。「门禁绿」不能当「部署已就绪」的证明。

### 2.3 服务器侧设施（实测现状）

| 项 | 值 |
|---|---|
| VPS | **`111.230.197.4`**（旧 `193.112.130.126` **已废弃不可达**）|
| SSH | `ubuntu@…` + `~/.ssh/coevo_key`（⚠️ `root@` 被拒）|
| 系统 | Ubuntu **24.04.4** · glibc **2.39** · 2C / 961 MiB / 2 GB swap / 40 GB（31 G 可用）|
| 服务 | `coevo.service`（systemd · `User=ubuntu` · `MemoryMax=256M` · `EnvironmentFile=/opt/coevo/.env`）|
| 监听 | **`127.0.0.1:8300`**（不对外，走 nginx）|
| 二进制 | **`/opt/coevo/bin/coevo_backend`**（回滚点 = `.prev`）|
| 工作目录 | `/opt/coevo` |
| prompts | `/opt/coevo/prompts/`（`COEVO_PROMPTS_DIR` **未设** ⇒ 取工作目录下的 `prompts/`）|
| DB | `/opt/coevo/data/coevo.db` |
| 日志 | **`/opt/coevo/data/logs/coevo.log.YYYY-MM-DD`**（🔴 **不在 journald**）|
| 书籍文件 | `/opt/coevo/data/book_blobs`（`COEVO_BLOB_DIR` 未设 ⇒ 此默认值）|
| nginx | `/etc/nginx/sites-available/zz-coevo`（enabled）· 443 → `proxy_pass http://127.0.0.1:8300` · 另有 `location = /privacy` `/terms` → `root /var/www/coevo-legal` |
| 证书 | certbot：`/etc/letsencrypt/live/api.keyievolution.fun/`（续期 `certbot certonly --webroot -w /var/www/certbot`）|
| 域名 | `api.keyievolution.fun` → `111.230.197.4` ✅ |
| 🔴 **同机** | **vibedollar**（`vibedollar-pay` 站点 / `:8100` / `:8200`）—— **一律不碰** |

### 2.4 部署后验证（**别只看 health**）

```bash
ssh -i ~/.ssh/coevo_key ubuntu@111.230.197.4 "tr -d '\r' | python3 -" \
  < scripts/trace_verify/bin/verify_v016_deploy.py
```

| 判据 | 为什么 |
|---|---|
| 新端点 **不是 404** | **404 才代表路径不存在**。🔴 配**阴性对照**：不存在的 `/api` 路径必须 **404**。<br>⚠️ **不要断言「必须 401」** —— axum 的**提取器在鉴权之前**执行：<br>· 不读 body 的端点（GET/DELETE）⇒ 无 token 得 **401** ✅<br>· 读 body 的端点 ⇒ 无 `Content-Type` **415** · 有但字段不全 **422** · multipart 无 body **400**<br>· 只有 body 合法才会进 handler 拿 401<br>📌 2026-10-08 首次跑就因「断言必须 401」**误报 ②-1 / ②-4 两条**。<br>想拿到 401 就得在这里维护一份请求 schema 副本 —— 它会漂 ⇒ **判据停在「路由存在」这一层** |
| 二进制 grep 特征串 | 交付物级证据。⚠️ **子串要独特**：`sync_book` 在**旧**二进制里就有 16 次（`sync_book_progress`/`sync_bookmark` 含它）⇒ 得搜 `IF NOT EXISTS sync_book (` |
| DB 新表 + 新列存在 | 老库靠 `init_database` 的 `CREATE TABLE IF NOT EXISTS`；**「表建了但列没加」**是这类迁移最典型的半成品 |
| 重启窗口内无 ERROR | 日志在 `data/logs/`，**不在 journald** |

**本机侧**（`backend/` 有改动时必须先全绿）：

```bash
cd backend && cargo test -p api_server --offline    # 期望 0 failed
cargo fmt --check && cargo clippy -p api_server --offline --lib --tests
```

### 2.5 回滚

```bash
ssh -i ~/.ssh/coevo_key ubuntu@111.230.197.4 '
  cp -a /opt/coevo/bin/coevo_backend /opt/coevo/bin/coevo_backend.failed.$(date +%s)  # 先留现场
  cp -a /opt/coevo/bin/coevo_backend.prev /opt/coevo/bin/coevo_backend
  sudo systemctl restart coevo && sleep 3 && curl -s http://127.0.0.1:8300/health'
```

⚠️ 回滚用 `cp -a` 会**覆盖现场**（CI 因此踩过：事后看权限是「正常」的）⇒ **先留失败副本**。

---

## 3. 安卓包（真机测试）—— **不需要 CI**

```bash
D:\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --dart-define=API_HOST=api.keyievolution.fun
```

产物：`app/build/app/outputs/flutter-apk/app-release.apk`

- 🔑 `--dart-define=API_HOST=…` 决定打到哪个后端（生产 = `api.keyievolution.fun`，已实测 `/health` **200**）。
- 🔑 **不依赖 CI、不依赖仓库公开** ⇒ 它是「功能验证」的主力载体。
- ⚠️ 本机（agent 沙箱）**跑不了 Flutter**（spawn 子进程被拒）⇒ 必须白哥跑。

---

## 4. iOS 包

**两条路，别混**：

| | `ios-archive.yml`（**出包**）| `ci.yml` 的 `ios-build`（**只验证能否编过**）|
|---|---|---|
| 触发 | `workflow_dispatch`（**白哥在网页点**）| `v*` tag / `workflow_dispatch` |
| 签名 | ✅ 有（API Key + Team ID）| ❌ `--no-codesign` |
| 产出 | **IPA**（+ 可选上传 ASC / TestFlight）| 无产物 |
| 用途 | 上架 / TestFlight / 真机 | 「iOS 代码还编得过吗」|

`ios-archive.yml` 的两个 input：

| input | 含义 |
|---|---|
| `upload` | 勾上 ⇒ 直接上传 App Store Connect；不勾 ⇒ 只产出 IPA artifact |
| `method` | `app-store`（上架/TestFlight）· `ad-hoc` / `development`（装指定 UDID 的真机验证）|
| ⚠️ | `upload` 只对 `app-store` 有意义 —— ad-hoc/development **不能**上传 ASC |

🔴 **iOS 只能走 CI**（没有 Mac；Windows 上 Flutter 出不了 iOS 包）⇒ **必须公开仓库**（§1.1 额度）。

---

## 5. CI 触发方式对照（`ci.yml`）

| 触发 | 跑什么 | 部署？ |
|---|---|---|
| `push main` | **8 个门禁 job**（`backend` / `frontend` / `fsrs-verify` / `trace-verify` / `query-verify` / `iap-verify` / `ebook-verify` / `native-readiness`）| ❌ **不部署** |
| `v*` tag | 上述 8 个 **+** `backend-release` + `backend-deploy` + `ios-build` | ✅ **部署** |
| `workflow_dispatch` | 同 `v*` tag（**同一个 `if`**）| ✅ 部署 |

📌 ⇒ **没有「只部署后端、不跑 iOS」的触发方式**（三者共用一个 `if`）。
所以想省 macOS 额度就只能**根本不推 tag** ⇒ 走路径 A。

---

## 6. ❌ 已否决 / 不可行（每条都实测过，别重复试）

| 路径 | 为什么不行 |
|---|---|
| **VPS 就地编译** | 无 Rust 工具链；961 MiB 内存 + `cargo build` 会**挤占同机的 vibedollar 生产服务**；装 rust 属「动系统」|
| **Windows 交叉编译** | 有 `x86_64-unknown-linux-gnu` target 但**无 Linux 链接器**；产物动态依赖 `libssl.so.3` ⇒ 交叉编译 OpenSSL 不现实 |
| **Docker 构建** | 本机**未安装**（PATH 里的 Docker Desktop 目录不存在）|
| **`gh` CLI 查 CI / 下 artifact** | 未认证；且**私有**仓库下载 artifact 必须带 PAT |
| **agent 里跑 WSL** | `wsl.exe` 在安全策略的 Program Blacklist 里，直接 `Permission denied` |
| **只看 health 就算部署成功** | health 200 只说明「进程起来了」，不说明「新代码在库里」 |

---

## 7. 故障对照表

| 症状 | 先查 | 常见根因 |
|---|---|---|
| 推了 tag，VPS 无变化 | **有没有 run**（Actions 页面）| 🔴 **私有仓额度耗尽** ⇒ 改 public |
| `203/EXEC`，health 全 000 | `ls -la /opt/coevo/bin/coevo_backend` | artifact 丢了执行位 ⇒ `chmod 755` |
| `Preflight — reachability` 失败 | runner 能否连 VPS:22 | 网络可达性 ⇒ 改走路径 A |
| 起不来、日志报缺库 | `ldd /opt/coevo/bin/coevo_backend` | 动态库缺失 |
| 服务起来但功能 404 | §2.4 的 ② 组 | 二进制不是这个 commit 编的 |
| 新表查不到 | §2.4 的 ⑥ 组 | 表没进 `init_database` ⇒ 新库有、老库没有 |
| 运行时「读不到 prompt」| `ls /opt/coevo/prompts/` + md5 对比 | `prompts/` 没同步（§1.3）|

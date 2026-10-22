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
| **iOS 包**（TestFlight / 真机） | CI `ios-archive.yml` **手动触发**（§4）| 🔴 **需要** | **agent**（`gh workflow run` · 2026-10-12 起 gh 已认证）|
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

🆕 **2026-10-12 起，这一步 agent 可全自动** —— `gh` 已认证
（账号 `Big-Pi100` · token scope 含 `repo`）⇒ 可见性切换与 workflow 触发都不需要人工：

```bash
gh repo edit Big-Pi100/CoEvo --visibility public  --accept-visibility-change-consequences
git push origin main
gh workflow run ios-archive.yml -f upload=true -f method=app-store
gh repo edit Big-Pi100/CoEvo --visibility private --accept-visibility-change-consequences
```

🔴🔴 **顺序不可颠倒：`改公开` 必须排在 `push` 之前**。
2026-10-12 实测踩到：写成 `push → 改公开` 时，`push` 那一刻仓库还是私有
⇒ `ci.yml` 虽然起来了，但 **job 起不来（`steps=0`）**，看起来是「绿色的空跑」。
⚠️ 那次代价很大：本轮新增的依赖**只有 CI 能解析**（本机跑不了 `flutter pub get`），
而它**从没被真跑过** —— 直到收尾核对才发现。

🔑 **恢复私有不需要等 run 结束**（实测两次：run 照常跑完并 success）。

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
#
# 🔑 脚本末尾会跑 **5/5 自检**，分两段（2026-10-09 重做）：
#    ① **新鲜度**（通用）：产物必须比 `backend/` 下所有 `.rs` / `Cargo.toml` 都新
#       —— 这是**唯一不依赖「本批改了什么」**的判据。
#       也可单独调用：`bash scripts/deploy/verify_artifact_fresh.sh <产物> <源码目录>`
#       （退出码 0=新鲜 / 1=过期 / 2=用法错，Windows 侧与服务器侧都能跑）。
#    ② **常驻功能标记**：几个字符串字面量（含一条阳性对照）。
#       ⚠️ 它证明的是「这些老功能还在」，**不是**「这是本批的包」——
#          字符集是**历史批次**的，会一直命中 ⇒ 别再往里堆，也别拿它当新鲜度依据。
#    任一段不过 ⇒ `exit 1` 并打印「请不要上传这个包」。
#
#    📌 为什么第 ① 段才是关键（2026-10-09 实测）：那天部署包的 `sha256` 与上一版
#       **完全相同**，而它已经准备上传 —— 真因是命令路径少了一层、**脚本根本没跑**。
#       当时第 ② 段**照样全绿**（那些字符串是上一批的，本来就命中）。
#       ⇒ 判据要**跟意图走**（「这次构建到底跑过没有」），不跟**当批内容**走。
#    ⚠️ 路径别写错：是 `scripts/**deploy**/build_linux_in_wsl.sh`
#       —— 写成 `scripts/build_…` 会 `No such file or directory`，而**没有任何产物生成**
#       （此时 `%TEMP%\coevo_deploy\` 里留着的是**上一次**的包，极易被误传）。

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

### 2.2.1 🔴🔴 第三处体积上限：nginx 的 `client_max_body_size`

**2026-10-22 真机事故（代价：排查一整晚）**：

| 层 | 上限 | 当时的值 |
|---|---|---|
| 端侧 `kMaxBookBytes` | 50 MB | 50 MB ✅ |
| 后端 `MAX_BOOK_BYTES` | 50 MB | 50 MB ✅ |
| **nginx `client_max_body_size`** | —— | **2 m** ❌ |

⇒ 一本 **5.5 MB** 的书被 **nginx 直接 413**，请求**根本到不了后端**
（后端日志零条上传记录 —— 排查方向被彻底带偏），
而端侧把 413 归成「超过单本上限」，于是提示「**超过 50 MB**」。

📌 判据：**「上限」在部署链路上有几处，就要对齐几处**。
   代码里两处对了，不代表线上能通 —— 中间还隔着反向代理。

**当前值：`client_max_body_size 51m;`**
（= `MAX_BOOK_BYTES` 50MB + 1MB multipart 开销，与后端 `DefaultBodyLimit` 同口径）

⚠️ **改上限的正确动作（三处一起）**：
1. `app/lib/services/ebook/book_blob_parse.dart::kMaxBookBytes`
2. `backend/crates/api_server/src/book_storage.rs::MAX_BOOK_BYTES`
3. `/etc/nginx/sites-available/zz-coevo` 的 `client_max_body_size`（**+1m 余量**）
   ⇒ `sudo nginx -t && sudo systemctl reload nginx`

🔍 **验证方法（不用真书）**：
```bash
head -c 5500000 /dev/urandom > /tmp/t.bin
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://api.<domain>/api/books/blob \
  -F "content_hash=0123456789abcdef0123456789abcdef" -F "ext=epub" -F "file=@/tmp/t.bin"
# 期望 401（未登录，说明请求已穿透 nginx 到后端）；
# 若是 413 ⇒ nginx 还在挡。
```

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

### 4.1 🔴 上传成功 ≠ TestFlight 可见（2026-10-12 实测踩到）

`xcodebuild` 打印 `Upload succeeded` **只说明「传输完成」**，之后还有两段**异步**流程：

| 阶段 | 谁在做 | 典型耗时 | 卡住时的表现 |
|---|---|---|---|
| ① ASC **处理**（Processing） | Apple | **10 分钟 – 1 小时** | ASC 的「构建版本」里显示「**正在处理**」 |
| ② **分发到测试组** | **你**（除非该组开了自动分发） | — | 处理完成、但测试者仍看不到 ⇒ 要去「测试组」里**把这个 build 加进去** |

**判断顺序**（都在 ASC 网页 → 该 App → **TestFlight** → 「构建版本」tab）：

| ASC 显示 | 含义 | 处置 |
|---|---|---|
| 「正在处理」 | ① 还没跑完 | **等**（本项目 build 3 / 5 / 6 均在上传后 1 小时内可见）|
| 「缺少出口合规信息」 | 没回答加密问题 | 本项目**已声明** `ITSAppUsesNonExemptEncryption=false`（`app/ios/Runner/Info.plist:135`）⇒ **不应出现**；真出现说明该声明丢了 |
| 「已准备好提交」但测试者还是看不到 | ② 没分发 | 去 **测试组** 添加该 build |
| 「无效 / Invalid Binary」 | 处理被拒 | ASC 会**发邮件**给 Apple ID 邮箱，看邮件里的原因 |

🔑 **怎么确认「真上传了、号也对」**（比看 ASC 更早可得的证据）：

```bash
gh run view <run-id> --log | grep -aE "Uploaded |FLUTTER_BUILD_NUMBER"
# 期望两行：export FLUTTER_BUILD_NUMBER=<N>   +   Uploaded <AppName>
```

⚠️ `CFBundleVersion` 在 `Info.plist` 里写的是 `$(FLUTTER_BUILD_NUMBER)` ⇒ 它**跟随 `pubspec.yaml` 的 `+N`**
⇒ 忘了 bump `+N` 会导致 **ASC 拒收重复的 build 号**（ITMS-4238 Redundant Binary Upload）。

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
| 🔴 **部署脚本跑一半就停了，但输出看着「正常」** | 脚本里有没有 `grep -c` / `grep -q` 之类**无匹配即非零退出**的命令 | **`grep` 无匹配的退出码是 1** ⇒ 在 `set -e` 下**静默中断**（2026-10-09 实测踩到）。<br>✅ 处置：改用 `grep -ac … \|\| true`，或**别在部署脚本里用 `set -e`**；<br>⚠️ 中断后**先查状态再重跑** —— 中断点可能在「已经替换了二进制、还没重启」之间 |
| 🔴 **产物看着是新的、其实是旧件** | **跑 `scripts/deploy/verify_artifact_fresh.sh <产物> backend/`**（0 = 新鲜）| 时间戳会骗人：cargo 命中缓存 / 复制保留 mtime / 终端贴了历史输出 / **命令路径写错以致根本没构建**（2026-10-09 实测：部署包 `sha256` 与上一版**完全相同**，而它已准备上传）。<br>✅ 通用判据 = **产物比源码新**（已做进 §2.1 的 5/5 自检，不通过 `exit 1`）<br>🟠 辅助：字符串字面量（**只用日志/错误消息，别用函数名** —— 脚本会 `strip`，符号表被删后函数名不在二进制里）。⚠️ 历史批次的字符串**会一直命中**，不能当新鲜度依据 |

### 7.1 🔑 一个值得抄的做法：**部署前后各记一次探针**

「部署成功」最容易自欺（health 200 只说明进程起来了）。**可证伪**的做法是
部署**前**先把基线记下来，部署后逐条对上：

| 探针 | 为什么 |
|---|---|
| 本次**删掉**的路由（POST/PUT 无 body）| 部署前 **415**（路由在、提取器先跑）→ 部署后 **404** |
| **阴性对照**：一个确定不存在的路径 | 必须**一直 404** ⇒ 证明「404 判据」本身有效 |
| **阳性对照**：一个确定存在的 POST 路由 | 必须**一直是 415** ⇒ 证明探针没被中间件统一改写 |
| 二进制特征串（`grep -a`）| 交付物级证据；⚠️ **阴性必须配阳性对照**，否则「0」可能是「grep 根本没读进去」|

📌 2026-10-09 按此表实测：trial 两条 415→404、两个特征串 1→0、对照不变 ⇒ 一次就过关。

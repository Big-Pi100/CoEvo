# AOCI 反馈：全局配置型 host（以 WorkBuddy 为例）的四个实测问题

> 可直接作为 issue / 反馈正文转发。
> 环境：`aoci 0.1.0-rc21 (cfa8e93, built 2026-10-14)` · Windows 11 · Git Bash / PowerShell
> 宿主：WorkBuddy —— MCP 配在**全局** `~/.workbuddy/mcp.json`，不是项目级文件
> 场景：两个仓库（`E:/CoEvo`、`E:/vibedollar`）需要并存

**先说：skill §〇 的「全局配置型 host」这一类写得对**，三个连带事实（`init` 不写 MCP /
`doctor` 不认 / 工具名带前缀）全部实测成立。

下面是实测补充的四个问题，按影响排序。

---

## 🔴 P0：`repo` 建议从**启动参数**提升为**工具参数**

**现状**

```console
$ aoci mcp --help
Flags:
  -h, --help   Show help for mcp
Global Flags:
      --repo string   Explicit repository root (overrides automatic discovery)
```

`repo` 只有**全局 flag**（启动时定死）。⇒ 全局配置型 host 只能配一条 MCP，
**多项目必须改配置文件 + 重启宿主**。

**实测：自动发现确实按 cwd**

```console
$ cd E:/CoEvo && aoci doctor          # 不传 --repo
[✓] Repository-root discovery: E:\CoEvo
```

自动发现本身是好的。问题是 **MCP 进程的 cwd 由宿主决定**（不是用户当前打开的项目），
所以全局 host 下这条自动发现**靠不住**。

**建议（首选）：参照 gitnexus，把 `repo` 做成工具参数**

gitnexus 的每个工具都带 `repo`：

```json
impact({ repo: "CoEvo", target: "...", direction: "upstream" })
```

一条 MCP 服务多仓，不需要并存多条 server，也就绕开了「工具名带前缀」那一整类问题。

AOCI 的 `aoci_maintain` / `aoci_overview` / `aoci_update_entry` 若支持**可选** `repo` 参数
（缺省回落到启动时 `--repo` / 自动发现），全局 host 就能真正"多项目并存"。

**建议（次选）**：给一条运行时切换命令（如 `aoci repo use <path>`，把当前作用仓写进
`.aoci/` 状态），至少避免"改配置 + 重启宿主"。

---

## 🟠 P1：`init` 对未知 host 的**正确用法**没写进 skill

**实测**

```console
# ① 传未知 agent
$ aoci --repo <tmp> init --agent workbuddy
Error: unknown Agent "workbuddy" (available: claude, codex, cursor, opencode, qoder, all;
       ...; omit it to create the skeleton and detect Agents only)
真实 exit=3

# ② 省略 --agent（正确路径）
$ aoci --repo <tmp> init
AOCI initialization complete @ ...
  - .aoci/.gitignore created
  - aoci.txt, aoci.meta.txt, aoci.code.txt skeleton created (no project Entries were fabricated)
  - config.json is ready
  - AGENTS.md created with the aoci managed block
exit=0

# ③ 幂等（再跑一次）
  - .aoci/.gitignore already exists (skipped; never overwritten)
```

⇒ 对全局配置型 host，**正确路径是省略 `--agent`**：只建骨架，不写任何 host 配置。

**问题**：skill 现在只说「host 不在列表 → 手工加 stdio MCP」，**没说 `init` 该传什么**。
用户照列表猜着传 `claude`，会得到一份**没人读的 `.mcp.json`**（还被 init 加进 `.gitignore`），
**看起来配好了、实际不生效** —— 正是 skill 自己警告过的那类"静默出错"。

**建议 skill 加一句**：

> 全局配置型 host 应**省略 `--agent`**（`aoci init` 无参）——只建 `.aoci/` 与 `AGENTS.md`，
> 不写任何 host 配置；MCP 由用户手工加到宿主的全局配置。

---

## 🟠 P2：`doctor` 对未知 host 一律报 `not configured`，会误导

**实测输出**

```
== Agent integrations ==
[·] Detected Agent environments: [claude codex]
[·] AGENTS.md policy block: not configured
[·] Claude MCP (.mcp.json): not configured
[·] Codex MCP (.codex/config.toml): not configured
[·] OpenCode MCP (opencode.json V1): not configured
[·] Qoder CLI MCP (.mcp.json ...): not configured
```

**没有任何一行提示"当前宿主不是上面这五类"**。用户即使已经把 MCP 配在全局文件里、
而且实际能用，`doctor` 仍然只报五类环境 `not configured` ⇒ 会以为没配好，反复折腾。

**建议**：
- 检测到非上述五类时，输出一行中性提示，例如
  「未识别的 host：MCP 可能配在宿主自己的全局配置中，doctor 无法核验」
- 或支持 `aoci doctor --agent <name>` 让用户显式声明当前宿主

（不是要它去读任意宿主配置，只是**别把"我看不见"说成"你没配"**。）

---

## 🟡 P3：`init --agent claude` 的副作用范围偏大

实测 `init --agent claude` 写入：

```
.aoci/  aoci.txt  aoci.meta.txt  aoci.code.txt  AGENTS.md  .mcp.json  .gitattributes  .gitignore
```

- **`.gitattributes`（钉 LF）是**仓库级全局配置**，对"只是想接一个 agent"的初始化来说副作用偏大。
  我这次是空仓，**测不出已有 `.gitattributes` 时是追加还是覆盖** —— 如果覆盖，对有自己行尾策略的仓库是破坏性的。
- 建议：`init` 末尾明确列出"新增/修改了哪些项目级文件"，或给 `--gitattributes=auto|skip`。

---

## 附：本次实测确认**正常**、不用改的几件事

| 项 | 结果 |
|---|---|
| 退出码可靠 | `init` 未知 agent → **3**；`guide` 未初始化 → **3**（与 skill §九 记载一致）|
| `init` 幂等 | 已存在的资产 `skipped; never overwritten` ✅ |
| 自动发现按 cwd | ✅ 不带 `--repo` 也能正确识别仓库根 |
| `init` 不编造条目 | ✅ 输出明写 `no project Entries were fabricated` |
| `doctor` 不做漂移比对 | ✅ 如实写"详情运行 `aoci verify`"，没有假装 |

---

## 一句话总结

**「全局配置型 host」这一类的抽象是对的，skill 也把三个连带事实写全了；
剩下最值得改的是 P0 —— 把 `repo` 从启动参数变成工具参数，这才是多项目并存的根本解。**
在它落地之前，skill 至少应补 P1 那一句（省略 `--agent`），否则用户会配出一份"看着像配好了"的无效配置。

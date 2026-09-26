# Social Marketing 项目迁移计划

## 目标
将 CoEvo 项目中的社交媒体内容管线（V1/V2/V3 脚本 + 产出）独立到 `E:\social_marketing\`，与 CoEvo 本体解耦。

## 新目录结构

```
E:\social_marketing\
├── scripts\
│   ├── v3\                  # V3 管线 Python + Node.js 脚本
│   │   ├── *.py             # 11 个 Python 源文件
│   │   ├── *.cjs            # 3 个 Node.js 渲染脚本 (render_cover, render_quotes, render_xiaohongshu)
│   │   ├── emotion_lexicon.json
│   │   ├── article_knowledge_base.json
│   │   ├── package.json / package-lock.json
│   │   └── node_modules/    # npm install 重建
│   ├── social-image-gen\    # V1/V2 渲染器
│   │   ├── full-render.cjs
│   │   ├── full-render-v2.cjs
│   │   ├── package.json / package-lock.json
│   │   └── node_modules/    # npm install 重建
│   └── common\              # 共享工具
│       ├── smart-paginate-pretext.js
│       ├── package.json / package-lock.json
│       └── node_modules/    # npm install 重建
│
├── output\
│   ├── v1\                  # ← 原 marketing/2026-07-* (V1 产出)
│   ├── v2\                  # ← 原 marketing/v2/
│   └── v3\                  # ← 原 marketing/v3-demo/
│
├── blog-html\               # ← 原 docs/blog/drafts/ 的 HTML 文件
│
├── .env                     # API 密钥 (从 CoEvo backend/.env 复制)
│
└── docs\                    # 设计文档、管线文档
    ├── content-pipeline-v2.md
    ├── content-pipeline-v3.md (如有)
    └── dynamic-page-split-design.md
```

## 执行步骤

### 阶段 1：建目录 + 拷脚本 (+ node_modules 重建)

**步骤 1.1** — 创建骨架目录
```bash
mkdir -p E:\social_marketing\scripts\v3
mkdir -p E:\social_marketing\scripts\social-image-gen
mkdir -p E:\social_marketing\scripts\common
mkdir -p E:\social_marketing\output\v1
mkdir -p E:\social_marketing\output\v2
mkdir -p E:\social_marketing\output\v3
mkdir -p E:\social_marketing\blog-html
mkdir -p E:\social_marketing\docs
```

**步骤 1.2** — 拷贝 Python 源文件
从 `E:\CoEvo\marketing\scripts\v3\*.py` → `E:\social_marketing\scripts\v3\`
（不拷 `__pycache__/`）

**步骤 1.3** — 拷贝 Node.js 源文件
- `render_cover.cjs` / `render_quotes.cjs` / `render_xiaohongshu.cjs` → `scripts\v3\`
- `full-render.cjs` / `full-render-v2.cjs` → `scripts\social-image-gen\`
- `smart-paginate-pretext.js` → `scripts\common\`

**步骤 1.4** — 拷贝 JSON 数据
- `emotion_lexicon.json` / `article_knowledge_base.json` → `scripts\v3\`
- `package.json` 文件（3 个 `scripts/` 下各一）

**步骤 1.5** — 重建 node_modules
```bash
cd E:\social_marketing\scripts\v3 && npm install
cd E:\social_marketing\scripts\social-image-gen && npm install
cd E:\social_marketing\scripts\common && npm install
```

### 阶段 2：拷贝产出

**步骤 2.1** — V2 产出
`E:\CoEvo\marketing\v2\*` → `E:\social_marketing\output\v2\`

**步骤 2.2** — V3 产出
`E:\CoEvo\marketing\v3-demo\*` → `E:\social_marketing\output\v3\`

**步骤 2.3** — V1 旧产出
`E:\CoEvo\marketing\2026-07-*` → `E:\social_marketing\output\v1\`

**步骤 2.4** — 博客草稿
`E:\CoEvo\docs\blog\drafts\*.html` → `E:\social_marketing\blog-html\`

### 阶段 3：改脚本内部路径引用

#### 3a. `render_xiaohongshu.cjs` 和 `render_cover.cjs`

当前问题：这两个脚本通过 `getEnv()` 从 `backend/.env` 读 API key。

```
旧: const envPath = path.join(__dirname, "..", "..", "..", "backend", ".env");
新: const envPath = path.join(__dirname, "..", "..", ".env");
        或者: process.env.DEEPSEEK_API_KEY 即可
```

#### 3b. 所有 CJS 脚本的 Pretext 引用

```
旧: require('../common/smart-paginate-pretext')
新: require('../../common/smart-paginate-pretext')   (如果脚本在 scripts/v3/)
```

脚本位置决定相对路径长度：
- `scripts/v3/*.cjs` 引用 `scripts/common/` → `../common/` → `../../common/`（因为 v3/ → scripts/ → common/）
  - 不对——`../common/smart-paginate-pretext` 这个路径从 `scripts/v3/` 出发，`..` 是 `scripts/`，`common/` 在 `scripts/` 下，所以就是 `../common/` —— 这个路径本身是对的！不需要改。

等等，让我确认一下。当前路径方案：
- `scripts/v3/render_xiaohongshu.cjs` → `require('../common/smart-paginate-pretext')`
  - `__dirname` = `E:/CoEvo/marketing/scripts/v3/`
  - `..` = `E:/CoEvo/marketing/scripts/`
  - `../common/` = `E:/CoEvo/marketing/scripts/common/` ✅

新项目会变成：
- `scripts/v3/render_xiaohongshu.cjs` → `require('../common/smart-paginate-pretext')`
  - `__dirname` = `E:/social_marketing/scripts/v3/`
  - `..` = `E:/social_marketing/scripts/`
  - `../common/` = `E:/social_marketing/scripts/common/` ✅

所以这个相对路径不需要改！同样，`full-render-v2.cjs` 在 `social-image-gen/` 下引用 `common/` 也是 `../common/`。

#### 3c. V2 renderer 的 blog HTML 路径

`full-render-v2.cjs` 接受 blog HTML 路径作为命令行参数，所以运行时传入正确的路径即可。但自动化 prompt 里的调用路径需要更新。

#### 3d. `.env` API 密钥

创建一个新的 `E:\social_marketing\.env`，从 `E:\CoEvo\backend\.env` 复制 `DEEPSEEK_API_KEY=` 行。

### 阶段 4：改 WorkBuddy 自动化 prompt

V2 自动化 prompt 中涉及的路径：
- `E:\\CoEvo\\marketing\\content-pipeline-v2.md` → `E:\\social_marketing\\docs\\content-pipeline-v2.md`
- `marketing/v2/{DATE}/` → `social_marketing/output/v2/{DATE}/`
- 渲染命令中 `docs/blog/{slug}/index.html` → `../social_marketing/blog-html/{slug}.html`
- `full-render-v2.cjs` 调用路径更新

### 阶段 5：VPS 部署调整

现状：V1 管线负责将 `docs/blog/` 下的文章部署到 VPS。

调整后：
- 博客 HTML 文件在 `E:\social_marketing\blog-html\` 下
- VPS 上博客目录路径不变（仍为 `/opt/coevo/admin-web/blog/`）
- 部署脚本需要从 `social_marketing/blog-html/` 取文件
- 或者保持博客 HTML 在 CoEvo 项目中的一份拷贝（推荐：先保留 CoEvo 中的 blog HTML，迁移稳定后再移除）

### 阶段 6：验证

- Python 脚本运行：`cd scripts/v3 && python demo_run.py --mock`
- Node.js 渲染测试：渲染一个已有文章验证路径正确
- 自动化路径测试：确认所有引用路径正确

### 阶段 7：清理（可选）

确认一切工作正常后，删除 CoEvo 项目中的原文件：
- `E:\CoEvo\marketing\scripts\v3\` (保留 `__pycache__`)
- `E:\CoEvo\marketing\scripts\social-image-gen\`
- `E:\CoEvo\marketing\scripts\common\`
- `E:\CoEvo\marketing\v2\`
- `E:\CoEvo\marketing\v3-demo\`
- `E:\CoEvo\marketing\2026-07-*`
- `E:\CoEvo\docs\blog\drafts\`
- `E:\CoEvo\marketing\content-pipeline*.md`
- `E:\CoEvo\marketing\docs\` 中 pipeline 相关文档

## 关键路径变更清单

| 文件 | 变更类型 | 旧引用 | 新引用 |
|------|---------|--------|--------|
| `render_xiaohongshu.cjs` | .env 路径 | `../../backend/.env` | `../../.env` (或删除, 用环境变量) |
| `render_cover.cjs` | .env 路径 | 同上 | 同上 |
| 自动化 prompt | 输出路径 | `marketing/v2/{DATE}/` | `social_marketing/output/v2/{DATE}/` |
| 自动化 prompt | 渲染 input | `docs/blog/{slug}/index.html` | `social_marketing/blog-html/{slug}.html` |
| 自动化 prompt | 管线文档 | `E:\\CoEvo\\marketing\\content-pipeline-v2.md` | `E:\\social_marketing\\docs\\content-pipeline-v2.md` |
| 部署脚本 | 源路径 | `docs/blog/` | `social_marketing/blog-html/` + 保留博客主页部署 |

## 风险点

1. **博客主页** — CoEvo 的博客首页 (`docs/blog/index.html`) 留在原地还是迁移？建议：首页跟 CoEvo 走，文章 HTML 跟 social_marketing 走。部署时从 social_marketing/blog-html/ 推送文章到 VPS 博客目录
2. **V3 历史文章链接** — 已部署到 VPS 的文章不受影响（URL 不变）。新文章的部署路径需要确认
3. **知识库去重** — v3-demo 中的 `article_knowledge_base.json` 需要跟脚本一起迁移，避免去重信息丢失

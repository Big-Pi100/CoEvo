# CoEvo·刻意进化学习 — 双引擎SEO整体优化策略 v2.0

> **文档版本**：v2.0  
> **适用搜索平台**：百度（中国）+ Google（全球）  
> **创建日期**：2026-07-11  
> **负责**：SEO 专家

---

## 目录

1. [现状盘点与诊断](#1-现状盘点与诊断)
2. [双引擎策略总览](#2-双引擎策略总览)
3. [Phase 0 · 快速修复（本周）](#3-phase-0--快速修复本周)
4. [Phase 1 · 技术SEO加固（第1-2周）](#4-phase-1--技术seo加固第1-2周)
5. [Phase 2 · 内容矩阵建设（第2-4周）](#5-phase-2--内容矩阵建设第2-4周)
6. [Phase 3 · 关键词与搜索意图策略（第3-6周）](#6-phase-3--关键词与搜索意图策略第3-6周)
7. [Phase 4 · 权威与链接建设（第4-12周）](#7-phase-4--权威与链接建设第4-12周)
8. [Phase 5 · Flutter SPA SEO 深度优化](#8-phase-5--flutter-spa-seo-深度优化)
9. [Phase 6 · 监测体系搭建](#9-phase-6--监测体系搭建)
10. [执行路线图与里程碑](#10-执行路线图与里程碑)
11. [附录：关键词矩阵](#11-附录关键词矩阵)
12. [附录：执行检查清单](#12-附录执行检查清单)

---

## 1. 现状盘点与诊断

### 1.1 站点基础信息

| 项目 | 状态 |
|:----|:-----|
| 域名 | `keyievolution.fun` + `www.keyievolution.fun` |
| ICP备案 | ✅ 粤ICP备2026061557号-1 |
| SSL证书 | ✅ Let's Encrypt，2026-09-13到期，自动续期 |
| 服务器 | 腾讯云 2C1G / Ubuntu 22.04 |
| 技术栈 | Flutter Web SPA + Rust (axum) 后端 |
| 域名后缀 | ⚠️ `.fun` 非百度偏好后缀，Google 无显著偏好 |

### 1.2 已完成（正面）

| 项目 | 详情 |
|:----|:-----|
| ✅ Baidu站长验证 | `baidu_verify_codeva-k3gx3YOTTR.html` 已部署 |
| ✅ robots.txt | 已部署 `/var/www/coevo-landing/` |
| ✅ sitemap.xml | 已部署，但百度主体资质验证未通过，主动提交暂不可用 |
| ✅ SSL双域名 | `keyievolution.fun` + `www` 均已覆盖 |
| ✅ 百度统计 | `hm.baidu.com` 已嵌入 |
| ✅ 百度自动推送 | `zz.bdstatic.com/linksubmit/push.js` 已嵌入 |
| ✅ 结构化数据（百度/Google 通用） | WebApplication、FAQPage（8问）、BreadcrumbList、WebSite+SearchAction |
| ✅ Title / Meta Description | 已优化，含核心关键词 |
| ✅ Canonical URL | `https://www.keyievolution.fun/app/` |
| ✅ Open Graph | og:title/description/url/type/site_name/locale/image 完整 |
| ✅ FAQ Schema | 8个问答覆盖常见用户问题 |
| ✅ 落地页→Flutter Web 迁移 | 落地页已废弃，SEO 元数据迁移到 `app/web/index.html` |
| ✅ crawler.html | 爬虫预渲染页面，供百度读取结构化数据 |
| ✅ Favicon / PWA Manifest | 已配置 |
| ✅ 移动端 Web App | `mobile-web-app-capable` `apple-mobile-web-app` 已设 |

### 1.3 未完成/需优化（按优先级）

| 优先级 | 项目 | 当前状态 | 影响 |
|:------|:-----|:---------|:-----|
| **P0** | Google Search Console 验证 | ❌ 未设置 | Google 无法监控收录，无法提交 sitemap |
| **P0** | Google Analytics 4 | ❌ 未安装 | 无法追踪 Google 搜索流量和用户行为 |
| ~~P0~~ | ~~Google Fonts 未部署到 VPS~~ | ✅ **已完成** | Flutter Web 已使用本地打包的 AlibabaPuHuiTi 字体，无外部加载 |
| **P0** | Flutter SPA 可索引性 | ⚠️ 只有 crawler.html 兜底 | 百度/Google 爬虫无法抓取 SPA 内部内容 |
| **P1** | 内容矩阵空白 | ❌ 无博客/内容页面 | 无法建立主题权威，核心词无排名机会 |
| **P1** | 无外链/品牌权威 | ❌ Domain Authority 接近 0 | 新站无信任背书，排名困难 |
| **P1** | Hreflang 标签 | ❌ 未设置 | 多语言场景下 Google 可能索引错误页面 |
| **P1** | Google 结构化数据测试 | ❌ 未验证 | 不确定 Google Rich Results 是否正常 |
| **P2** | 图片优化 | ❌ 缺 alt 属性、命名 | 图片搜索流量丢失 |
| **P2** | nginx gzip 压缩 | ❌ 未确认开启 | 传输体积增大，影响加载速度 |
| **P2** | CDN 配置 | ❌ 未接入 | 全国延迟偏高，Core Web Vitals 不过关 |
| **P2** | 缓存策略 | ❌ 静态文件未设强缓存 | 重复下载，浪费带宽 |
| **P2** | 百度百科 | ❌ 未创建 | 品牌词搜索结果缺失权威条目 |
| **P2** | 百度知道/文库/贴吧 | ❌ 未布局 | 百度生态流量缺失 |
| **P2** | PageSpeed 优化 | ❌ 未测量 | 移动端速度评分未知 |

---

## 2. 双引擎策略总览

### 2.1 战略选择

CoEvo 是面向**中国市场 K12 学生和家长**的产品。但不应放弃 Google：

| 维度 | 百度策略 | Google 策略 |
|:----|:---------|:------------|
| **目标用户** | 中国大陆家长/K12学生 | 海外华人、港澳台、留学家庭 |
| **搜索份额** | 中国搜索市场 ~60%+ | 全球搜索市场 ~90%+ |
| **内容语言** | 简体中文 | 简体中文为主，辅助英文 |
| **生态布局** | 百度百科/知道/文库/贴吧 | Google Business Profile / YouTube / Medium |
| **投放** | 百度推广（SEM） | Google Ads（海外推广） |
| **SEO 技术栈** | 百度资源平台 / 百度统计 | Search Console / GA4 / PageSpeed Insights |
| **加分项** | ICP备案、国内服务器、MIP | Core Web Vitals、HTTPS、移动优先 |

**核心原则**：技术 SEO 双平台通用（结构化数据、速度、移动优先等），内容和外链建设按平台侧重。

### 2.2 双平台技术 SEO 交集

```
┌─────────────────────────────────────┐
│         双平台通用（80%精力）          │
│                                     │
│  • HTTPS + 移动优先                 │
│  • Core Web Vitals / 页面速度       │
│  • 结构化数据（JSON-LD）            │
│  • Sitemap / robots.txt            │
│  • 清晰的信息架构/内链              │
│  • 原创高质量内容                    │
│  • 语义化 HTML                      │
└─────────────────────────────────────┘
         ↗                    ↖
  ┌──────────┐          ┌──────────┐
  │   百度    │          │  Google  │
  │ (20%精力) │          │ (20%精力) │
  │          │          │          │
  │• 百度生态 │          │• Search  │
  │• 主体备案 │          │ Console  │
  │• MIP     │          │• GA4     │
  │• 百度统计 │          │• Pagespd │
  └──────────┘          └──────────┘
```

---

## 3. Phase 0 · 快速修复（本周）

> **影响/投入比极高，立即执行。**

### 3.1 ✅ 注册 Google Search Console

1. 访问 [search.google.com/search-console](https://search.google.com/search-console)
2. 添加属性：`https://keyievolution.fun`
3. 推荐验证方式：**DNS TXT 记录验证**（无需修改网站文件，DNSPod 操作简单）
   - 替代方案：HTML 文件上传到 VPS `/var/www/coevo-landing/googleXXXX.html`
4. 提交 sitemap：`https://keyievolution.fun/sitemap.xml`
5. 配置首选域名：`https://keyievolution.fun`
6. 添加第二个属性：`https://www.keyievolution.fun`（或设置域名重定向）

### 3.2 ✅ 安装 Google Analytics 4（GA4）

1. 创建 GA4 媒体资源
2. 获取测量 ID（`G-XXXXXXXXXX`）
3. 在 `app/web/index.html` `<head>` 中添加 GA4 代码：

```html
<!-- Google Analytics -->
<script async src="https://www.googletagmanager.com/gtag/js?id=G-XXXXXXXXXX"></script>
<script>
  window.dataLayer = window.dataLayer || [];
  function gtag(){dataLayer.push(arguments);}
  gtag('js', new Date());
  gtag('config', 'G-XXXXXXXXXX');
</script>
```

4. 配置转化事件：
   - `sign_up`（用户注册）
   - `start_trial`（开始试用）
   - `purchase`（付费购买）
   - `card_created`（创建学习卡片）
   - `review_completed`（完成复习）

### 3.3 ✅ 运行 PageSpeed Insights 基准测试

1. 分别在 `https://keyievolution.fun/` 和 `https://keyievolution.fun/app/` 运行
2. 记录移动端和桌面端得分（作为基线）
3. 记录作为基准线，后续 CDN/cache 优化后做对比

### 3.4 ✅ Google 结构化数据测试

1. 访问 [search.google.com/test/rich-results](https://search.google.com/test/rich-results)
2. 测试 `https://keyievolution.fun/` 的现有 JSON-LD
3. 修复发现的任何错误或警告

---

## 4. Phase 1 · 技术SEO加固（第1-2周）

### 4.1 统一主域名（301 重定向）

**现状**：`keyievolution.fun` 和 `www.keyievolution.fun` 都可能被访问。

**方案**：
- 选择 **`https://keyievolution.fun`** 作为主域名（更短、SEO 权重集中）
- Nginx 配置：`www.keyievolution.fun` → 301 → `keyievolution.fun`

```nginx
server {
    listen 443 ssl;
    server_name www.keyievolution.fun;
    return 301 https://keyievolution.fun$request_uri;
}
```

- 更新 `app/web/index.html` 中 canonical URL 为 `https://keyievolution.fun/`
- 更新 sitemap.xml 中所有 URL 为无 `www` 版本
- 在百度站长平台设置主域名

### 4.2 确认 nginx Gzip 开启

```bash
# 检查当前 gzip 状态
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> "
  grep -E 'gzip|gzip_' /etc/nginx/sites-available/coevo
"

# 如未开启，添加：
# gzip on;
# gzip_vary on;
# gzip_proxied any;
# gzip_comp_level 6;
# gzip_types text/plain text/css text/xml application/json application/javascript image/svg+xml;
```

**预期效果**：JS/CSS/JSON 传输体积减少 60-70%。

### 4.3 配置静态文件强缓存

```nginx
location /app/ {
    rewrite ^/app/(.*)$ /$1 break;
    try_files $uri $uri/ /index.html;
    
    # 静态资源强缓存（JS/CSS/字体/图片）
    location ~* \.(js|css|woff2?|ttf|png|jpg|webp|svg)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
```

**预期效果**：首次加载后，静态资源不再重复请求，页面性能大幅提升。

### 4.4 配置腾讯云 CDN

**操作步骤**：
1. 登录腾讯云控制台 → CDN → 添加加速域名 `keyievolution.fun`
2. 源站配置：`<OLD_VPS_IP>:80`
3. 缓存规则：
   - 静态文件（`*.js, *.css, *.png, *.woff2`）→ 30 天强缓存
   - HTML（`/`）→ 不缓存（确保内容实时更新）
4. 回源配置：开启 HTTPS（源站已是 HTTPS）
5. DNS 配置：CNAME 解析到 CDN 域名

**注意事项**：
- 开启 CDN 后，百度爬虫 IP 可能变化，需要在 CDN 控制台配置回源 Host
- 确保 CDN 不会缓存需要登录验证的动态内容

### 4.5 图片优化

**现状**：Flutter Web 构建的 `icons/` 目录下有图片，但全部缺 SEO 标注。

**操作**（以下在 Flutter 代码中实现）：
1. 为每个图片资源添加语义化命名（`Icon-192.png` → `coevo-logo-192x192.png`）
2. 在 `app/web/index.html` 中添加图片优化：
   - `<link rel="preload" as="image" href="icons/coevo-logo-512x512.png">`
   - 确保 favicon 使用 `.ico` + `.png` 双格式
3. 确认应用内所有 `<img>` 标签有 `alt` 属性（Flutter Web 渲染后由框架控制）

### 4.6 优化 Title / Meta Description

**当前**（已不错，但可微调）：

```
Title: CoEvo AI特级教师 — 主动式一对一学习，不遗忘不跑偏
       (35字符，百度截断30字符，Google截断约55字符)
```

**优化建议**：

```html
<!-- 首页（FLutter SPA） -->
<title>CoEvo AI特级教师 — 不遗忘不跑偏的一对一学习 | 刻意进化</title>
<meta name="description" content="CoEvo基于FSRS记忆算法的AI一对一辅导。AI对话自动提取概念，FSRS科学复习，客观验证效果。免费试用中。">
```

**规则**：
- Title：百度限制 **30字符**，Google 限制 **~55字符**
- 关键前置：核心关键词放在开头前 15 字符
- Description：百度 78 字符，Google ~160 字符
- 每个页面独立（未来如果增加内容页）

### 4.7 结构化数据增强

**已有**：WebApplication、FAQPage、BreadcrumbList、WebSite+SearchAction

**新增建议**：

```json
<!-- 缺少 Organization Schema（E-E-A-T 信号） -->
{
  "@context": "https://schema.org",
  "@type": "Organization",
  "name": "刻意进化学习",
  "alternateName": "CoEvo",
  "url": "https://keyievolution.fun/",
  "logo": "https://keyievolution.fun/icons/Icon-512.png",
  "description": "基于FSRS记忆算法的AI特级教师平台",
  "foundingDate": "2026",
  "contactPoint": {
    "@type": "ContactPoint",
    "contactType": "customer support",
    "email": "admin@keyievolution.fun"
  },
  "sameAs": [
    "https://keyievolution.fun/"
  ]
}
```

**Organization Schema 的作用**：
- Google 知识图谱收录信号
- 搜索结果中可能显示 Logo 和品牌信息
- 百度百家号/百科关联的基础信息
- E-E-A-T 权威性信号

---

## 5. Phase 2 · 内容矩阵建设（第2-4周）

> **这是当前最大的 SEO 缺口**。单页应用 + 零内容页面 = 零主题权威 = 零长尾词流量。

### 5.1 内容策略总纲

**核心矛盾**：Flutter SPA 不适合承载大量内容页面。解决方案：

```
Option A: 独立内容站（推荐 ✅）
  blog.keyievolution.fun  或  keyievolution.fun/blog/
  └── 独立静态站（Hugo / Astro / Jekyll）
  └── Nginx 反向代理到同一域名下
  └── 共享品牌权重，内链互跳

Option B: 放在 Flutter Web 内（不推荐 ❌）
  所有内容放在 /app/blog/ 路由下
  但 SPA 爬虫可索引性硬伤，SEO 效果差

推荐：Option A
  独立静态博客，快速上线，能积累独立 SEO 权重
  与主站共享域名，将 blog/ 路由指向静态站
```

### 5.2 内容主题架构（Topic Cluster）

采用**支柱内容（Pillar） + 集群内容（Cluster）** 结构：

#### 主题一：AI教育与学习方法（核心主题）

| 类型 | 内容 | 目标关键词 | 字数 |
|:----|:-----|:----------|:----:|
| **Pillar** | AI 到底能不能帮孩子提分？——2026 K12 AI 学习全面评测 | AI教育怎么样 / AI辅导效果 | 3000+ |
| Cluster 1 | FSRS 记忆算法 vs 艾宾浩斯遗忘曲线：哪个更科学？ | FSRS记忆算法 / 间隔重复 | 2000+ |
| Cluster 2 | K12 学生适合用 AI 自学吗？经验和风险 | K12 AI学习 / AI自学 | 2000+ |
| Cluster 3 | AI 一对一辅导和线下辅导班，哪个划算？ | AI一对一价格 / AI辅导 vs 辅导班 | 1500+ |
| Cluster 4 | 2026 年家长必知的 5 个 AI 学习工具 | AI学习工具推荐 / 学习工具评测 | 2000+ |

#### 主题二：记忆与复习科学

| 类型 | 内容 | 目标关键词 | 字数 |
|:----|:-----|:----------|:----:|
| **Pillar** | 遗忘曲线、FSRS、主动回忆：科学的复习方法 | 科学复习 / 记忆曲线 / FSRS | 2500+ |
| Cluster 1 | 为什么学了就忘？——认知科学的答案 | 学了就忘怎么办 / 记忆原理 | 1500+ |
| Cluster 2 | 主动回忆法：比反复翻书有效 10 倍的学习技巧 | 主动回忆学习法 / 高效复习方法 | 2000+ |
| Cluster 3 | 间隔重复（Spaced Repetition）：每天 15 分钟记牢一切 | 间隔重复 / 间隔复习 | 1500+ |

#### 主题三：家长教育决策

| 类型 | 内容 | 目标关键词 | 字数 |
|:----|:-----|:----------|:----:|
| **Pillar** | 2026 年 K12 家庭教育投入指南：什么值得花，什么没必要 | K12教育投入 / 家庭教育规划 | 2500+ |
| Cluster 1 | 孩子不自觉学习怎么办？——行为设计学的方法 | 孩子不自觉 / 自主学习培养 | 2000+ |
| Cluster 2 | AI 学习产品怎么选？6 个维度帮你判断 | AI学习产品推荐 / AI教育产品选择 | 2000+ |

### 5.3 技术实现方案

**推荐：Hugo 静态站点**（最简单、SEO 最好）

```
blog/ 目录结构：
├── content/
│   ├── ai-education/
│   │   ├── _index.md           # Pillar: AI教育评测
│   │   ├── fsrs-vs-ebbinghaus.md
│   │   ├── k12-ai-self-study.md
│   │   └── ...
│   └── memory-science/
│       ├── _index.md
│       └── ...
├── themes/custom/
├── public/                     # 构建输出
└── config.toml
```

**部署**：
```
Nginx 增加路由：
location /blog/ {
    alias /var/www/coevo-blog/public/;
    index index.html;
    try_files $uri $uri/ /blog/index.html;
}
```

**内容质量要求**：
- 每篇原创，字数 1500-3000 字
- 含作者署名和简介（E-E-A-T 信号）
- 引用权威来源（论文、官方数据、专家引语）
- 内链回到主页 `/app/` 和相互链接
- 首图优化（语义化命名 + alt 属性）

### 5.4 内容发布节奏

| 周次 | 内容 | 类型 |
|:----|:-----|:-----|
| 第1周 | AI教育评测 Pillar (3000字) | 支柱内容 |
| 第2周 | FSRS vs 艾宾浩斯 (2000字) | 集群内容 |
| 第2周 | 科学复习 Pillar (2500字) | 支柱内容 |
| 第3周 | K12 AI自学指南 (2000字) | 集群内容 |
| 第3周 | 主动回忆法 (2000字) | 集群内容 |
| 第4周 | AI一对一 vs 辅导班 (1500字) | 集群内容 |
| 第4周 | 孩子不自觉怎么办 (2000字) | 集群内容 |
| 后续 | 保持每周 1-2 篇 | 持续 |

---

## 6. Phase 3 · 关键词与搜索意图策略（第3-6周）

### 6.1 核心关键词矩阵

| 类别 | 关键词 | 百度指数(估) | Google月搜索量(估) | 搜索意图 | 竞争度 | 着陆页 |
|:----|:-------|:------------|:------------------|:---------|:------|:-------|
| 品牌词 | CoEvo | 低 | 低 | 导航型 | 低 | `/app/` |
| 品牌词 | 刻意进化 | 低 | 低 | 导航型 | 低 | `/app/` |
| 核心词 | AI教育 | 中高 | 中 | 交易型 | 高 | 首页+内容页 |
| 核心词 | AI一对一辅导 | 中 | 中 | 交易型 | 中高 | 首页+内容页 |
| 核心词 | AI特级教师 | 中 | 中低 | 交易型 | 中 | 首页+内容页 |
| 核心词 | 在线学习平台 K12 | 中 | 中 | 交易型 | 中 | 内容页+首页 |
| 长尾词 | FSRS记忆算法 | 低 | 低 | 信息型 | 极低 | 博客文章 |
| 长尾词 | 间隔重复学习 | 低 | 中 | 信息型 | 低 | 博客文章 |
| 长尾词 | AI学习工具推荐 | 中 | 中 | 商业调查 | 中 | 博客文章 |
| 长尾词 | 孩子不自觉学习 | 中 | 中 | 信息型 | 低 | 博客文章 |
| 长尾词 | K12线上教育哪个好 | 中 | 中 | 商业调查 | 中高 | 博客文章 |
| 问答词 | AI能代替老师吗 | 中 | 中 | 信息型 | 低 | FAQ+博客 |
| 问答词 | 学了就忘怎么办 | 中 | 中高 | 信息型 | 低 | 博客文章 |

### 6.2 搜索意图映射

```
Top-of-Funnel (信息学习) → 博客内容
  关键词：FSRS、间隔重复、记忆原理、学了就忘
  内容：科普文章、对比分析
  目标：流量入口、建立专业认知

Middle-of-Funnel (商业调查) → 评测对比
  关键词：AI教育哪个好、AI学习工具推荐、AI一对一怎么样
  内容：评测指南、对比表、案例分析
  目标：引导比较、建立信任

Bottom-of-Funnel (交易决策) → 首页 + 产品页
  关键词：AI一对一辅导、AI特级教师、CoEvo价格
  内容：产品展示、定价方案、证言
  目标：转化注册/试用
```

### 6.3 百度关键词工具建议

| 工具 | 用途 |
|:----|:-----|
| 百度指数 `index.baidu.com` | 搜索趋势和人群画像 |
| 百度推广关键词规划师 | PPC关键词量级预估 |
| 5118.com | 长尾词挖掘、竞品词分析 |
| 站长工具 Chinaz | 关键词排名追踪 |
| 下拉建议/相关搜索 | 实时搜索意图捕捉 |

### 6.4 Google 关键词工具建议

| 工具 | 用途 |
|:----|:-----|
| Google Keyword Planner | AdWords 工具，搜索量+竞争度 |
| Google Trends | 搜索趋势、地域差异 |
| Ahrefs / SEMrush | 竞品关键词分析（付费） |
| Google Search Console | 真实搜索查询数据 |
| AnswerThePublic | 问题型关键词挖掘 |

---

## 7. Phase 4 · 权威与链接建设（第4-12周）

### 7.1 百度生态布局

#### 7.1.1 百度百科（品牌词）

**策略**：
- 品牌词条"CoEvo" 或 "刻意进化学习"
- 必须由百科认证编辑创建（找第三方服务，~500-2000元）

**内容要求**：
- 中立客观，富媒体（Logo、截图）
- 产品功能描述（AI一对一、FSRS算法、客观验证）
- 参考资料：媒体报道、官网、权威来源
- 持续维护，防止竞品篡改

**预期效果**：品牌词搜索结果 Top 3 稳定占用一个位置，品牌信任度提升。

#### 7.1.2 百度知道

**策略**：
- 使用高等级帐号操作（非新号）
- 每周 3-5 个问题/答案

**问题投放示例**：

| 问题 | 目标 | 答案策略 |
|:-----|:-----|:---------|
| "AI辅导真的能提高成绩吗？" | 效果验证 | 引用数据 + 自然提及 CoEvo |
| "FSRS记忆算法和Anki算法哪个好？" | 技术对比 | 客观分析 + 自然介绍 CoEvo |
| "K12线上学习平台哪个靠谱？" | 竞品截流 | 评测角度推荐 CoEvo |
| "孩子用AI学习有用吗？" | 价值教育 | 科普 + 试用推荐 |

#### 7.1.3 百度文库

- 上传《2026 K12 AI学习白皮书》（原创内容）
- 标题含目标关键词
- 文末作者简介+网站链接
- PDF 格式（百度更偏好）

#### 7.1.4 百度贴吧

- 在教育/家长/K12 相关贴吧建立品牌人设
- 分享学习方法，软引导试用
- 不硬广，以真实用户视角分享

### 7.2 Google 生态布局

#### 7.2.1 站外内容发布（Guest Post / 投稿）

| 平台 | 策略 |
|:-----|:------|
| 知乎 | 回答问题（"AI学习怎么样"类），专栏文章（深度分析） |
| Medium | 英文版内容，覆盖海外华人 |
| CSDN/掘金 | 技术视角：FSRS算法实现、AI教育系统设计（开发者引流） |
| 微信公众平台 | 品牌内容沉淀，文章被百度收录 |

#### 7.2.2 数字 PR（Digital PR）

**策略**：创造值得报道的故事

| 故事角度 | 媒体类型 | 建议 |
|:---------|:--------|:------|
| "AI教育创业：从0到1的两年" | 创业/教育媒体 | 联系36氪、芥末堆、多知网 |
| "FSRS 记忆算法：比传统方法快 3 倍" | 科技媒体 | 数据报告 → 记者引用 |
| "2026 AI 学习效果数据报告" | 数据新闻 | 原创研究 → 链接资产 |

#### 7.2.3 外链建设（Google）

**高质量外链来源**：

| 类型 | 来源 | 难度 | 策略 |
|:-----|:-----|:----|:------|
| 教育类 | .edu 域名 | 高 | 教育技术评测、案例研究 |
| 行业评测 | G2 / Capterra / Trustpilot | 中 | 创建产品列表，争取评测 |
| 开源社区 | GitHub | 中 | 开源 FSRS 相关工具 |
| 技术社区 | Hacker News / Lobsters | 高 | 发布技术文章 |
| 新闻媒体 | 行业媒体 | 中高 | 数据故事 + 记者 Outreach |
| 目录资源 | 中文教育网站 | 低 | 收录到 educational technology 列表 |

### 7.3 内部链接优化

**虽然目前只有 Flutter SPA，但 Blog 上线后需建立完整内链体系**：

```
首页(app/) → 博客(blog/) 互相链接
博客文章之间相互引用（Topic Cluster 结构）
博客文章内链回首页 CTA（"免费试用 CoEvo"）
面包屑导航：Home > Blog > AI教育
```

---

## 8. Phase 5 · Flutter SPA SEO 深度优化

> **这不是可选项——这是 Flutter Web SEO 的必修课。**

### 8.1 问题分析

| 问题 | 影响 | 严重程度 |
|:-----|:-----|:---------|
| JS 渲染内容 | 百度/Google 爬虫不执行 JS 或只部分执行 | 🔴 致命 |
| 单一路由 | 所有 SPA 路由指向同一个 HTML 壳 | 🔴 严重 |
| 动态内容不可抓 | K12课程、用户卡片等内容动态加载 | 🟠 中等 |
| meta 标签固定 | 路由变化不更新 meta 标签 | 🟠 中等 |

### 8.2 当前对策评估

**已实施的 crawler.html**（当前方案）：
- 在 `/bot-page` 提供了一个包含所有 SEO 元数据的静态 HTML
- 百度站长平台将 `/bot-page` 注册为爬虫读取地址
- ✅ 爬虫能读取元数据和结构化数据
- ❌ **不解决问题**：
  - 内部页面（如 `/app/study-plan`）无法索引
  - Google 爬虫不知道 `/bot-page` 的存在
  - 内容不随 SPA 真实内容变化

### 8.3 推荐方案：SSR（服务端渲染）

**最佳方案：Flutter Web SSR（官方支持，Flutter 3.22+）**

```bash
# 构建 SSR 版本的 Flutter Web
flutter build web --web-renderer=skia --dart-define=FLUTTER_WEB_SSR=true
```

Flutter 3.22+ 已支持服务端渲染，允许爬虫获取完整 HTML 内容。

**替代方案：Prerender.io 中间件**
- Nginx 配置：检测爬虫 User-Agent → 代理到 prerender.io 渲染
- 预渲染后的静态 HTML 返回给爬虫
- 每月免费额度 ~250 个 URL

### 8.4 临时增强方案（在 SSR 就绪前）

**方案：为关键页面添加静态 meta 标签**

- Flutter 内部通过 `dart:html` 动态更新 `<title>` 和 `<meta>` 标签（路由变化时）
- 示例：
```dart
import 'dart:html' as html;

void updateMetaForPage(String page) {
  if (page == 'study-plan') {
    html.document.title = '学习计划 - CoEvo AI特级教师';
    html.document.querySelector('meta[name="description"]')
      ?.setAttribute('content', '定制化K12学习计划，AI因材施教');
  }
}
```

### 8.5 推荐路线图

| 时间 | 方案 | 原因 |
|:-----|:-----|:-----|
| 现在 | 保持 crawler.html 方案 | 快速上线，至少能让爬虫读取结构化数据 |
| 第2-4周 | 启动 Blog 独立站点 | 内容 SEO 不能等 SSR，博客独立于 Flutter |
| 第4-8周 | 评估 Flutter SSR 迁移 | 官方方案，长期最优 |
| 第8-12周 | 实施 SSR / Prerender | 全站内容可索引 |

---

## 9. Phase 6 · 监测体系搭建

### 9.1 双平台监测工具

| 工具 | 百度 | Google | 用途 |
|:----|:----|:-------|:-----|
| 站长平台 | ✅ 已配 | ❌ 待配 | 收录监测、爬虫诊断 |
| 统计分析 | ✅ 百度统计 | ❌ 待配 GA4 | 流量分析、用户行为 |
| PageSpeed | ❌ 未测 | ❌ 待测 | 页面性能监控 |
| Rank Tracker | ❌ 待配 | ❌ 待配 | 关键词排名跟踪 |

### 9.2 排名跟踪工具

| 工具 | 免费/付费 | 推荐理由 |
|:-----|:---------|:---------|
| Google Search Console | 免费 | 官方数据，最准确 |
| 百度资源平台 | 免费 | 百度搜索真实数据 |
| Ahrefs Webmaster Tools | 免费 | 外链分析、排名预估 |
| 5118.com | 付费（基础版） | 百度长尾词挖掘 |
| AccuRanker | 付费 | 精准排名追踪（可选） |

### 9.3 核心 KPI 仪表盘

| 指标 | 当前基线 | 第1个月目标 | 第3个月目标 | 第6个月目标 |
|:-----|:---------|:-----------|:-----------|:-----------|
| Google 收录 URL 数 | 0 | 5+ | 30+ | 100+ |
| 百度收录 URL 数 | 0 | 3+ | 20+ | 50+ |
| Google 月有机点击 | 0 | 100+ | 500+ | 2000+ |
| 百度月有机点击 | 0 | 50+ | 300+ | 1000+ |
| 品牌词排名（双平台） | 无 | 前5 | 前3 | #1 |
| 长尾词排名（Google前10） | 0 | 5+ | 20+ | 50+ |
| 外链域名数 | 0 | 5+ | 20+ | 50+ |
| Domain Authority | 0-5 | 5-10 | 10-20 | 20-30 |
| 内容发布数 | 0 | 4 | 16 | 40+ |
| 移动端 PageSpeed 评分 | 未测 | 70+ | 80+ | 90+ |
| 百度生态覆盖率 | 0% | 20% | 50% | 70% |

### 9.4 周度/月度报告模板

**周报模板**：
```
## 周度 SEO 报告 (YYYY-MM-DD)

### 收录状态
- Google Search Console: X 已收录 / Y 待收录 / Z 错误
- 百度资源平台: X 已收录 / Y 待收录

### 关键词排名变化
| 关键词 | 上周 | 本周 | 变化 | 平台 |
|--------|:----:|:----:|:----:|:----:|
| [词1] | 25 | 18 | ↑7 | Google |
| [词2] | - | 45 | 新 | 百度 |

### 流量数据
- Google 有机点击: X (↑Y% WoW)
- 百度有机点击: X (↑Y% WoW)

### 本周工作
1. [内容发布/技术修复/外链]
2. ...

### 下周计划
1. ...
```

---

## 10. 执行路线图与里程碑

### 时间线总览

```
Week 1-2    Week 3-4    Week 5-8    Week 9-12    Month 4-6
┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
│ Phase 0-1 │ │ Phase 2  │ │ Phase 3  │ │ Phase 4  │ │ Phase 5  │
│ 快速修复  │ │ 内容矩阵  │ │ 关键词+  │ │ 权威建设 │ │ SPA深度  │
│ 技术SEO  │ │ Blog上线 │ │ 搜索意图 │ │ 外链生态 │ │ SSR评估  │
└──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘
```

### 第1-2周（快速修复 + 技术SEO）

| 任务 | 负责人 | 优先级 |
|:-----|:-------|:------|
| Google Search Console 注册验证 | SEO | P0 |
| GA4 安装并验证数据收集 | SEO | P0 |
| PageSpeed 基准测试 | SEO | P0 |
| 结构化数据测试 | SEO | P0 |
| 统一主域名 301 | 开发 | P1 |
| nginx gzip + 缓存配置 | 开发 | P1 |
| 百度统计确认正常 | SEO | P1 |
| Blog 技术选型（Hugo） | 开发 | P1 |
| 撰写第一篇 Pillar 文章 | 内容 | P1 |

### 第3-4周（内容矩阵）

| 任务 | 负责人 | 优先级 |
|:-----|:-------|:------|
| Blog 上线（技术部署） | 开发 | P1 |
| 发布 Pillar 文章 1-2 篇 | 内容 | P1 |
| 发布 Cluster 文章 2-3 篇 | 内容 | P1 |
| 建立 Topic Cluster 内链 | 内容+SEO | P1 |
| 百度知道开始投放 | 生态 | P2 |
| 知乎问答开始布局 | 生态 | P2 |
| 提交 Blog sitemap 到双平台 | SEO | P1 |

### 第5-8周（内容+关键词）

| 任务 | 负责人 | 优先级 |
|:-----|:-------|:------|
| 持续每周 1-2 篇博客 | 内容 | P1 |
| 关键词排名追踪基线建立 | SEO | P1 |
| 5118/Ahrefs 关键词研究 | SEO | P1 |
| 百度百科创建启动 | 生态 | P2 |
| 百度文库白皮书上传 | 生态 | P2 |
| 首篇英文内容（Medium） | 内容 | P2 |
| 评估 Flutter SSR | 开发 | P2 |
| 腾讯云 CDN 接入 | 开发 | P1 |

### 第9-12周（权威建设）

| 任务 | 负责人 | 优先级 |
|:-----|:-------|:------|
| 数字 PR：联系教育媒体 | 生态 | P2 |
| 外链 Outreach 启动 | 生态 | P2 |
| Broken link Reclamation | 生态 | P2 |
| 知乎专栏建立 | 内容+生态 | P2 |
| 百度贴吧品牌人设 | 生态 | P3 |
| GA4 转化事件完善 | 开发+SEO | P2 |
| 第1个月 SEO 报告评审 | SEO | P1 |

### 第4-6个月（深化）

| 任务 | 优先级 |
|:-----|:------|
| Flutter SSR 实施 | P2 |
| Prerender.io 或等效方案 | P2 |
| 百度推广（SEM）评估 | P3 |
| Google Ads 海外推广评估 | P3 |
| 内容矩阵扩展到 40+ 篇 | P1 |
| 外链达到 50+ 域名 | P2 |

---

## 11. 附录：关键词矩阵

### 11.1 百度搜索核心词

| 关键词 | 搜索量（日估） | 竞争度 | 当前排名 | 目标排名 | 着陆页 |
|:-------|:-------------|:------|:--------|:--------|:-------|
| AI教育 | 2000+ | 高 | - | 前10 | 首页+内容 |
| AI一对一辅导 | 500+ | 中高 | - | 前10 | 首页+内容 |
| K12在线教育 | 1000+ | 高 | - | 前20 | 内容 |
| AI特级教师 | 100+ | 中 | - | 前5 | 首页 |
| 在线学习平台 | 800+ | 高 | - | 前20 | 内容 |
| AI学习 | 600+ | 中高 | - | 前10 | 首页+内容 |
| 刻意进化 | <10 | 极低 | - | #1 | 首页 |
| 智能复习系统 | 50+ | 低 | - | 前5 | 内容 |
| FSRS记忆算法 | <10 | 极低 | - | #1 | 内容 |

### 11.2 Google 搜索核心词

| 关键词 | 月搜索量（估） | 竞争度 | 目标排名 | 着陆页 |
|:-------|:-------------|:------|:--------|:-------|
| AI tutor K12 | 1000+ | 中高 | 前10 | 内容+首页 |
| spaced repetition | 5000+ | 高 | 前20 | 内容 |
| FSRS algorithm | 500+ | 低 | 前5 | 内容 |
| AI learning platform | 2000+ | 高 | 前20 | 首页+内容 |
| CoEvo | <10 | 极低 | #1 | 首页 |
| best AI for learning | 1000+ | 高 | 前10 | 内容 |

### 11.3 低竞争·高价值长尾词（快速见效）

| 关键词 | 长尾形式 | 周搜索量（估） | 竞争度 |
|:-------|:--------|:-------------|:------|
| FSRS记忆算法 vs Anki | `[FSRS记忆算法] + [对比]` | 50-100 | 极低 |
| 孩子不自觉学习用AI有效吗 | `[孩子不自觉] + [AI]` | 100-200 | 低 |
| 初中数学AI辅导推荐 | `[初中数学] + [AI辅导]` | 100-200 | 低 |
| 高中物理一对一线上辅导 | `[高中物理] + [一对一] + [线上]` | 100-200 | 中低 |
| 艾宾浩斯遗忘曲线在线工具 | `[遗忘曲线] + [工具]` | 50-100 | 低 |
| K12假期自学AI工具 | `[假期] + [自学] + [AI]` | 50-100 | 极低 |

---

## 12. 附录：执行检查清单

### Phase 0 · 快速修复（本周）

- [ ] Google Search Console 注册 + 域名验证
- [ ] GA4 安装 + 验证数据收集
- [ ] ✅ 字体已本地打包（AlibabaPuHuiTi 嵌入 Flutter Web bundle，无外部加载）
- [ ] PageSpeed Insights 基准测试
- [ ] Google Rich Results 测试
- [ ] 百度统计确认正常工作

### Phase 1 · 技术SEO（第1-2周）

- [ ] www → 非 www 301 重定向
- [ ] sitemap.xml 更新（含所有 URL）
- [ ] nginx gzip 确认开启
- [ ] 静态文件强缓存配置
- [ ] 腾讯云 CDN 接入
- [ ] 图片重命名 + alt 属性
- [ ] Title/Description 微调
- [ ] Organization Schema 添加
- [ ] Blog 技术选型和基础搭建

### Phase 2 · 内容矩阵（第2-4周）

- [ ] Blog 独立站部署上线
- [ ] AI教育 Pillar 文章（3000字）
- [ ] FSRS vs 艾宾浩斯（2000字）
- [ ] 科学复习 Pillar（2500字）
- [ ] K12 AI自学指南（2000字）
- [ ] 主动回忆法文章（2000字）
- [ ] 博客 sitemap 提交双平台
- [ ] Topic Cluster 内链建立

### Phase 3 · 关键词+搜索意图（第3-6周）

- [ ] 关键词排名追踪系统搭建
- [ ] 5118/Ahrefs 关键词批量研究
- [ ] Google Search Console 性能数据检查
- [ ] 百度资源平台收录确认
- [ ] 问答型内容规划（百度知道/知乎）
- [ ] Google Trends 搜索趋势分析

### Phase 4 · 权威建设（第4-12周）

- [ ] 百度百科品牌词条创建
- [ ] 百度知道每周 3-5 问答
- [ ] 百度文库白皮书上传
- [ ] 百度贴吧品牌初建
- [ ] 知乎专栏发布第一篇文章
- [ ] 数字 PR 媒体联系（36氪/芥末堆等）
- [ ] Guest Post 投稿（2-3 个站点）
- [ ] GitHub 开源 FSRS 相关工具
- [ ] G2/Capterra 产品列表创建
- [ ] Broken link outreach

### Phase 5 · SPA 深度优化（第4-24周）

- [ ] Flutter SSR 评估
- [ ] Prerender.io 等中间件评估
- [ ] Flutter SPA 动态 meta 更新
- [ ] SSR 迁移实施（条件具备时）

### Phase 6 · 监测体系（持续）

- [ ] 周度 SEO 报告模板
- [ ] 月度 SEO 报告
- [ ] 关键词排名跟踪表
- [ ] 收录/流量监控
- [ ] 外链增长跟踪
- [ ] 竞品 SEO 动态监控

---

> **文档维护**：本方案 v2.0 是百度+Google 双平台的完整升级版。根据执行效果和搜索算法更新持续修订。  
> **更新频率**：每两周或重大搜索引擎更新后评审更新。  
> **关键原则**：所有内容修改必须先出具方案→审批→实施→观察，严禁未经审批直接上线。

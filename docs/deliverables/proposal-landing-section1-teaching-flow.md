# 落地页内容扩展方案 01：教学流程详解

> **提案状态**：待审批  
> **对应策略**：第二阶段·内容与关键词策略 → 新增区块1  
> **目标关键词**：AI一对一辅导过程 / AI特级教师怎么教学 / AI如何辅导K12  
> **预计字数**：约400字  
> **插入位置**：③动画区 与 ④学习报告区 之间（第237-239行之间）

---

## 1. 修改前后对比

### 修改前（当前）

```
③ 动画区（iframe 嵌入教学演示）
                                    ← 这里是空的
④ 学习报告区（数据展示）
```

两个区域之间无过渡，从动画直接跳转数据展示。

### 修改后

```
③ 动画区（iframe 嵌入教学演示）
                                    ← 新增：教学流程详解区块
④ 学习报告区（数据展示）
```

新增的区块作为"③→④"的自然过渡——先展示**教学方式**，再说**学习数据**。

---

## 2. 新增区块完整HTML

> 在 `E:\CoEvo\landing\index.html` 第238行与第239行之间插入以下代码。

```html
<!-- ═══ ③½ 教学流程详解 ═══ -->
<section class="section" id="how-it-works">
  <div class="container">
    <div class="section-header">
      <span class="section-tag">CoEvo 怎么教</span>
      <h2>AI 费曼教学 · 四步学习法</h2>
      <p>不是聊天机器人，是你请得起的 AI 特级教师。</p>
    </div>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:16px;">
      <div style="background:#151528;border:1px solid #222240;border-radius:14px;padding:20px;">
        <div style="width:32px;height:32px;border-radius:50%;background:#6C63FF20;display:flex;align-items:center;justify-content:center;margin-bottom:12px;color:#6C63FF;font-weight:700;font-size:14px;">1</div>
        <h4 style="color:#fff;font-size:15px;margin:0 0 6px;">AI 费曼教学</h4>
        <p style="color:#AAAACC;font-size:13px;line-height:1.7;margin:0;">你告诉 AI 想学什么，AI 主动用费曼教学法讲解和提问，不是被动问答。</p>
      </div>
      <div style="background:#151528;border:1px solid #222240;border-radius:14px;padding:20px;">
        <div style="width:32px;height:32px;border-radius:50%;background:#6C63FF20;display:flex;align-items:center;justify-content:center;margin-bottom:12px;color:#6C63FF;font-weight:700;font-size:14px;">2</div>
        <h4 style="color:#fff;font-size:15px;margin:0 0 6px;">边教边考·客观验证</h4>
        <p style="color:#AAAACC;font-size:13px;line-height:1.7;margin:0;">教完立刻出验证题，不靠孩子自己说"懂了"。答错换方式再教，直到真会。</p>
      </div>
      <div style="background:#151528;border:1px solid #222240;border-radius:14px;padding:20px;">
        <div style="width:32px;height:32px;border-radius:50%;background:#6C63FF20;display:flex;align-items:center;justify-content:center;margin-bottom:12px;color:#6C63FF;font-weight:700;font-size:14px;">3</div>
        <h4 style="color:#fff;font-size:15px;margin:0 0 6px;">FSRS 科学复习</h4>
        <p style="color:#AAAACC;font-size:13px;line-height:1.7;margin:0;">学过的内容由 FSRS 算法安排复习，在你即将遗忘的节点自动提醒，不遗忘。</p>
      </div>
      <div style="background:#151528;border:1px solid #222240;border-radius:14px;padding:20px;">
        <div style="width:32px;height:32px;border-radius:50%;background:#6C63FF20;display:flex;align-items:center;justify-content:center;margin-bottom:12px;color:#6C63FF;font-weight:700;font-size:14px;">4</div>
        <h4 style="color:#fff;font-size:15px;margin:0 0 6px;">游戏化成就体系</h4>
        <p style="color:#AAAACC;font-size:13px;line-height:1.7;margin:0;">连续学习天数🔥、即时反馈、成就奖章。让孩子"想继续学"，不是"被迫学"。</p>
      </div>
    </div>
    <div style="text-align:center;margin-top:20px;">
      <a href="#cta" class="btn btn-primary">让孩子体验 AI 特级教师 →</a>
    </div>
  </div>
</section>
```

---

## 3. 需要同步新增的 CSS

在 `E:\CoEvo\landing\css\style.css` 中追加以下样式（末尾追加即可）：

```css
/* 教学流程区块（2026-06-15 新增） */
#how-it-works .section-header {
  margin-bottom: 28px;
}
#how-it-works .btn {
  margin-top: 8px;
}
/* 四步卡片 hover 效果 */
#how-it-works [style*="background:#151528"] {
  transition: transform 0.2s ease, border-color 0.2s ease;
}
#how-it-works [style*="background:#151528"]:hover {
  transform: translateY(-2px);
  border-color: #6C63FF60;
}
```

---

## 4. 预期效果

| 维度 | 预期 |
|------|------|
| **SEO** | 新增约400字原创内容，覆盖"费曼教学""AI费曼学习法""FSRS复习"等长尾词 |
| **转化率** | 四张卡片对应CTA区四个卖点（费曼教学/FSRS/家长看板/纯学习场景），前后呼应 |
| **用户体验** | 从动画演示 → 教学流程说明 → 学习数据展示，逻辑更完整 |
| **加载速度** | 新增区块无外部资源依赖（纯文字+背景色），对加载时间影响可忽略（<1KB） |

---

## 5. 实施步骤

| 步骤 | 操作 | 文件 |
|------|------|------|
| 1 | 在 `<section class="section" id="report-embed">` 前插入新增区块HTML | `landing/index.html` 第238行 |
| 2 | 在 `style.css` 末尾追加教学流程样式 | `landing/css/style.css` |
| 3 | 本地预览，确认视觉风格一致 | 浏览器打开 `landing/index.html` |
| 4 | 部署到VPS | `scp` 上传 → 覆盖 |
| 5 | 百度统计监测3天，观察用户行为变化 | 百度统计后台 |

---

## 6. 前后对照速览

| | 当前 | 修改后 |
|--|------|--------|
| 页面长度 | ~440行HTML | ~510行HTML |
| 内容字数 | ~1800字 | ~2200字 |
| 区块数 | 8个（Hero→信任→动画→报告→对比→社会证明→Q&A→角色→CTA） | 9个（+教学流程详解） |
| SEO关键词覆盖 | 约8个 | 约12个（新增：费曼教学/客观验证/FSRS复习/成就体系/游戏化学习） |
| CTA按钮 | 4个（Hero+特惠+角色+Footer） | 5个（+教学流程底部） |
| 加载开销 | 无变化 | +<1KB HTML |

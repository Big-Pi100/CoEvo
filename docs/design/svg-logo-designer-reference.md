# SVG Logo Designer — 参考摘录

> 来源: rknall/claude-skills@svg-logo-designer (1.2K installs)
> 提取时间: 2026-06-20 | 用途: CoEvo 海报/H5 SVG 设计参考

---

## 一、SVG 代码规范

### 基础结构
```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="200" height="200">
  <defs>
    <!-- 渐变、图案、滤镜 -->
    <linearGradient id="gradient1" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:#4F46E5;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#7C3AED;stop-opacity:1" />
    </linearGradient>
  </defs>

  <g id="logo-symbol">
    <!-- 视觉元素 -->
  </g>

  <g id="logo-text">
    <!-- 文字 -->
  </g>
</svg>
```

### 颜色管理 — 用 class 或 defs 统一定义
```xml
<defs>
  <style>
    .primary { fill: #4F46E5; }
    .secondary { fill: #10B981; }
    .text { fill: #1F2937; }
  </style>
</defs>
<rect class="primary" x="0" y="0" width="100" height="100" />
```

### 无障碍
```xml
<svg role="img" aria-labelledby="title desc">
  <title id="title">公司 Logo</title>
  <desc id="desc">蓝色圆形图标</desc>
</svg>
```

---

## 二、几何图形模式

### 多边形/六边形
```xml
<polygon points="50,5 95,27.5 95,72.5 50,95 5,72.5 5,27.5"
  fill="url(#grad)" stroke="#312E81" stroke-width="2" />
<circle cx="50" cy="50" r="20" fill="#FFFFFF" />
```

### 抽象流动线条
```xml
<path d="M10,50 Q30,20 50,50 T90,50 Q70,80 50,50 T10,50 Z"
  fill="#10B981" opacity="0.8" />
<path d="M15,55 Q35,25 55,55 T95,55"
  fill="none" stroke="#059669" stroke-width="3" stroke-linecap="round" />
```

### 组合标记（图标+文字）
```xml
<g id="icon">
  <circle cx="40" cy="40" r="30" fill="#4F46E5" />
  <path d="M30,35 L35,45 L50,25" stroke="#FFFFFF" stroke-width="3"
    fill="none" stroke-linecap="round" stroke-linejoin="round" />
</g>
<g id="text">
  <text x="85" y="45" font-family="Arial, sans-serif"
    font-size="28" font-weight="700" fill="#1F2937">COMPANY</text>
</g>
```

---

## 三、色彩心理学

| 颜色 | 情感 | 适用行业 |
|------|------|---------|
| 蓝色 | 信任、专业、稳定 | 金融、科技、医疗 |
| 绿色 | 成长、健康、环保 | 环保、健康 |
| 红色 | 能量、热情、紧迫 | 食品、娱乐、零售 |
| 紫色 | 创意、奢华、灵性 | 美妆、科技、创意 |
| 橙色 | 友好、活力、亲民 | 零售、食品 |
| 黄色 | 乐观、清晰、温暖 | 食品、儿童、能源 |
| 黑/灰 | 精致、现代、经典 | 奢品、时尚、科技 |

---

## 四、可迁移到海报设计的原则

1. **用 `<defs>` 统一定义颜色** — 不要在每个元素上写死颜色
2. **用 `<g>` 组织层次** — 背景、装饰、数据卡片、二维码分层管理
3. **善用渐变** — 比纯色有质感
4. **描述性文件名** — `campaign-poster-daily-evolve.svg`
5. **圆角 + 投影** — 现代感的关键
6. **路径简化** — 同样的视觉效果用更少的路径点

你是一个极富创意的海报设计师。请为以下营销活动设计一张 SVG 分享海报模板（600×900px）。

活动信息：
- 活动名称：{campaign_name}
- 活动奖励：{campaign_rewards}

### 设计风格
- **仅使用几何装饰元素**（圆、线、色块、渐变条、点阵等），不使用任何具象插画、角色、动物或实物图形
- 依靠排版、留白和色彩对比来营造视觉冲击力
- 渐变、阴影、发光效果可以用

### 品牌风格
整体采用多邻国风格的品牌视觉体系：
- 主色调：Duo Green (#58cc02)，辅以 Sky Blue (#1cb0f6) 作为高亮色
- 背景纯白 (#ffffff)，文字使用 Almost Black (#3c3c3c)
- 卡片圆角 12px，留白充裕，数据分段展示
- 按钮使用底部实色投影效果（类似 box-shadow 方案）
- 品牌标识 "⟐ CoEvo" 放在底部

### 可用数据
以下变量会在生成海报时替换为用户的真实数据，请根据活动主题选择适合的展示（不必全部使用）：
- {real_name} — 用户真实姓名
- {display_name} — 用户昵称
- {streak_days} — 连续学习天数
- {current_focus} — 当前学习的任务
- {plan_count} — 正在学习的科目数
- {completed_plans} — 已完成的学习计划数
- {achievement_count} — 已获得成就数
- {referral_code} — 用户推广码

### QR码位置
将 `{QR_PLACEHOLDER}` 放在你希望二维码中心出现的位置（即 QR 框的几何中心点）。代码会将其替换为 180×180px 的二维码（自居中，以该点为中心）。
{QR_PLACEHOLDER} 周围不要放其他内容。
示例（将二维码中心放在 x=300, y=740 处）：
```
<g transform="translate(300, 740)">
{QR_PLACEHOLDER}
</g>
```

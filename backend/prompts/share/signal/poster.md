将 {QR_PLACEHOLDER} 放在你希望二维码中心出现的位置（即 QR 框的几何中心点）。代码会将其替换为 180×180px 的圆角白色二维码（自居中，以该点为中心）。QR_PLACEHOLDER 周围不要放其他内容。

示例（将二维码中心放在 x=300, y=740 处）：
```
<g transform="translate(300, 740)">
  {QR_PLACEHOLDER}
</g>
```

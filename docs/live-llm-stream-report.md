# 真实 LLM 流式渲染验证报告

**时间**: 2026-05-14 20:12:38

## 结果

- **状态**: PASS
- **Chunk 数**: 558
- **总字符数**: 1144
- **修复前闪烁率**: 2.9%
- **修复后闪烁率**: 0%
- **公式总数**: 16
- **Display**: 1, Inline: 15

## 提取的公式

1. `\theta`
2. `\sin \theta = \frac{\text{对边}}{\text{斜边}}`
3. `\cos \theta = \frac{\text{邻边}}{\text{斜边}}`
4. `\theta`
5. `\sin^2 \theta + \cos^2 \theta = 1`
6. `\theta`
7. `\sin \theta = \frac{3}{5}`
8. `\cos \theta = \pm \frac{4}{5}`
9. `\sin 2\theta = 2 \sin \theta \cos \theta`
10. `\cos 2\theta = \cos^2 \theta - \sin^2 \theta`
11. `\sin^2 \theta + \cos^2 \theta = 1`
12. `\cos 2\theta = 2\cos^2 \theta - 1`
13. `\cos 2\theta = 1 - 2\sin^2 \theta`
14. `\sin^2 \theta + \cos^2 \theta = 1`
15. `\sin 2\theta = 2 \sin \theta \cos \theta`
16. `\cos 2\theta = \cos^2 \theta - \sin^2 \theta`

## LLM 完整输出

```
好的，同学们，今天我们一起来学习三角函数的基础知识。三角函数是数学中非常重要的一类函数，它描述了角度与直角三角形边长之间的关系，在物理、工程、天文等领域都有广泛应用。掌握了三角函数，你们就能更好地理解周期运动、波动等现象。

首先，我们来认识两个最基本的三角函数：正弦函数和余弦函数。

在直角三角形中，对于一个锐角 \( \theta \)，我们定义：
- 正弦函数：\(\sin \theta = \frac{\text{对边}}{\text{斜边}}\)
- 余弦函数：\(\cos \theta = \frac{\text{邻边}}{\text{斜边}}\)

这两个定义是基础，但更一般地，在单位圆（半径为1的圆）上，对于任意角 \( \theta \)，正弦和余弦分别对应圆上点的纵坐标和横坐标。

接下来，我们学习一个最重要的恒等式，它被称为“三角恒等式之母”。这个恒等式揭示了正弦和余弦之间的平方关系：

\[
\sin^2 \theta + \cos^2 \theta = 1
\]

这个公式对任意角 \( \theta \) 都成立，非常有用。例如，已知 \(\sin \theta = \frac{3}{5}\)，就可以通过它求出 \(\cos \theta = \pm \frac{4}{5}\)。

现在，我们来看倍角公式。倍角公式可以帮助我们用单角的正弦、余弦表示二倍角的正弦和余弦。它们非常实用，比如在化简表达式或解方程时经常用到。

- 正弦的倍角公式：\(\sin 2\theta = 2 \sin \theta \cos \theta\)
- 余弦的倍角公式：\(\cos 2\theta = \cos^2 \theta - \sin^2 \theta\)

注意，余弦的倍角公式还有另外两种形式，利用恒等式 \(\sin^2 \theta + \cos^2 \theta = 1\) 可以推导出：
\(\cos 2\theta = 2\cos^2 \theta - 1\) 和 \(\cos 2\theta = 1 - 2\sin^2 \theta\)。

最后，我们来总结一下今天的内容。我们学习了三角函数的定义（正弦和余弦），掌握了最重要的恒等式 \(\sin^2 \theta + \cos^2 \theta = 1\)，以及倍角公式 \(\sin 2\theta = 2 \sin \theta \cos \theta\) 和 \(\cos 2\theta = \cos^2 \theta - \sin^2 \theta\)。这些是三角函数大厦的基石，希望大家课后多加练习，熟悉它们的应用。记住，理解定义和公式的推导过程，比死记硬背更重要。
```

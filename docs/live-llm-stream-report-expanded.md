# 真实 LLM 流式渲染验证报告 (扩展版)

**时间**: 2026-05-14 20:19:35
**测试用例**: 5 个领域

## 汇总

| 领域 | 公式数 | 复杂公式 | Display | 闪烁率 | 括号 |
|------|--------|----------|---------|--------|------|
| 微积分 | 69 | 6 | 11 | 5.0% | ✅ |
| 线性代数 | 47 | 0 | 13 | 3.9% | ✅ |
| 概率论 | 52 | 3 | 6 | 4.2% | ✅ |
| 复杂公式压力测试 | 56 | 2 | 6 | 3.5% | ✅ |
| 高密度公式 | 24 | 3 | 21 | 3.0% | ✅ |

## 各领域公式详情

### 微积分

1. [INLINE] `\varepsilon` — SIMPLE
2. [INLINE] `\delta` — SIMPLE
3. [INLINE] `x` — SIMPLE
4. [INLINE] `a` — SIMPLE
5. [INLINE] `f(x)` — SIMPLE
6. [INLINE] `L` — SIMPLE
7. [INLINE] `x` — SIMPLE
8. [INLINE] `a` — SIMPLE
9. [INLINE] `f(x)` — SIMPLE
10. [INLINE] `L` — SIMPLE
11. [INLINE] `f(x)` — SIMPLE
12. [INLINE] `a` — SIMPLE
13. [INLINE] `\varepsilon` — SIMPLE
14. [INLINE] `\delta` — SIMPLE
15. [INLINE] `0 < |x - a| < \delta` — SIMPLE
16. [INLINE] `|f(x) - L| < \varepsilon` — SIMPLE
17. [INLINE] `x` — SIMPLE
18. [INLINE] `a` — SIMPLE
19. [INLINE] `f(x)` — SIMPLE
20. [INLINE] `L` — SIMPLE
21. [DISPLAY] `\lim_{x \to a} f(x) = L` — MEDIUM (lim)
22. [INLINE] `\forall \varepsilon > 0, \exists \delta > 0, \text{ 使得 } 0 < |x - a| < \delta \R` — MEDIUM (text)
23. [INLINE] `f(x)` — SIMPLE
24. [INLINE] `x_0` — SIMPLE
25. [INLINE] `x_0` — SIMPLE
26. [INLINE] `x_0 + h` — SIMPLE
27. [INLINE] `f(x_0 + h) - f(x_0)` — SIMPLE
28. [INLINE] `\frac{f(x_0 + h) - f(x_0)}{h}` — MEDIUM (frac)
29. [INLINE] `h` — SIMPLE
30. [INLINE] `f(x)` — SIMPLE
31. [INLINE] `x_0` — SIMPLE
32. [DISPLAY] `f'(x_0) = \lim_{h \to 0} \frac{f(x_0 + h) - f(x_0)}{h}` — MEDIUM (frac,lim)
33. [INLINE] `f(x) = x^2` — SIMPLE
34. [INLINE] `x` — SIMPLE
35. [DISPLAY] `f'(x) = \lim_{h \to 0} \frac{(x+h)^2 - x^2}{h} = \lim_{h \to 0} \frac{2xh + h^2}` — MEDIUM (frac,lim)
36. [INLINE] `F'(x) = f(x)` — SIMPLE
37. [INLINE] `F(x)` — SIMPLE
38. [INLINE] `f(x)` — SIMPLE
39. [DISPLAY] `\int f(x) \, dx = F(x) + C` — MEDIUM (int)
40. [INLINE] `C` — SIMPLE
41. [INLINE] `f(x)` — SIMPLE
42. [INLINE] `[a, b]` — SIMPLE
43. [DISPLAY] `\int_a^b f(x) \, dx = F(b) - F(a)` — MEDIUM (int)
44. [INLINE] `F` — SIMPLE
45. [INLINE] `f` — SIMPLE
46. [INLINE] `\int_0^1 x^2 \, dx` — MEDIUM (int)
47. [INLINE] `\frac{x^3}{3}` — MEDIUM (frac)
48. [INLINE] `x^2` — SIMPLE
49. [DISPLAY] `\int_0^1 x^2 \, dx = \left[ \frac{x^3}{3} \right]_0^1 = \frac{1}{3} - 0 = \frac{` — COMPLEX (frac,int,big-paren)
50. [INLINE] `f(x)` — SIMPLE
51. [INLINE] `a` — SIMPLE
52. [DISPLAY] `f(x) = \sum_{n=0}^{\infty} \frac{f^{(n)}(a)}{n!} (x - a)^n` — COMPLEX (frac,sum,∞)
53. [INLINE] `f^{(n)}(a)` — SIMPLE
54. [INLINE] `f` — SIMPLE
55. [INLINE] `a` — SIMPLE
56. [INLINE] `n` — SIMPLE
57. [INLINE] `n!` — SIMPLE
58. [INLINE] `n` — SIMPLE
59. [INLINE] `a = 0` — SIMPLE
60. [INLINE] `e^x` — SIMPLE
61. [INLINE] `x=0` — SIMPLE
62. [DISPLAY] `e^x = \sum_{n=0}^{\infty} \frac{x^n}{n!} = 1 + x + \frac{x^2}{2!} + \frac{x^3}{3` — COMPLEX (frac,sum,∞,op)
63. [DISPLAY] `\sin x = \sum_{n=0}^{\infty} \frac{(-1)^n x^{2n+1}}{(2n+1)!} = x - \frac{x^3}{3!` — COMPLEX (frac,sum,∞,op)
64. [INLINE] `u(x,t)` — SIMPLE
65. [DISPLAY] `\frac{\partial u}{\partial t} = \alpha \frac{\partial^2 u}{\partial x^2}` — MEDIUM (frac,∂)
66. [INLINE] `\alpha` — SIMPLE
67. [INLINE] `\lim_{x \to \infty} \frac{\sqrt{x^2 + 1}}{x}` — COMPLEX (frac,lim,sqrt,∞)
68. [INLINE] `x` — SIMPLE
69. [DISPLAY] `\lim_{x \to \infty} \frac{\sqrt{1 + \frac{1}{x^2}}}{1} = 1` — COMPLEX (frac,lim,sqrt,∞)

**LLM 完整输出**:

```
好的，同学们，今天我们开始微积分的学习。微积分是研究变化和累积的数学工具，它的核心概念包括极限、导数、积分和泰勒级数。下面我们逐一讲解。

---

### 1. 极限的 \(\varepsilon\)-\(\delta\) 定义

极限是微积分的基石。直观上，我们说当 \(x\) 趋近于 \(a\) 时，函数 \(f(x)\) 的极限是 \(L\)，意思是当 \(x\) 无限接近 \(a\) 时，\(f(x)\) 可以无限接近 \(L\)。但为了严谨，我们需要精确的数学定义：

设函数 \(f(x)\) 在 \(a\) 的某个去心邻域内有定义。如果对于任意给定的正数 \(\varepsilon\)，都存在一个正数 \(\delta\)，使得当 \(0 < |x - a| < \delta\) 时，总有 \(|f(x) - L| < \varepsilon\)，那么我们就说当 \(x\) 趋近于 \(a\) 时，\(f(x)\) 的极限是 \(L\)，记作：

\[
\lim_{x \to a} f(x) = L
\]

这个定义用行内公式可以写成：\( \forall \varepsilon > 0, \exists \delta > 0, \text{ 使得 } 0 < |x - a| < \delta \Rightarrow |f(x) - L| < \varepsilon \)。

---

### 2. 导数的定义（差商极限）

导数描述了函数在某一点的变化率。考虑函数 \(f(x)\) 在点 \(x_0\) 附近的变化：当自变量从 \(x_0\) 变化到 \(x_0 + h\) 时，函数值的改变量为 \(f(x_0 + h) - f(x_0)\)。平均变化率就是差商 \(\frac{f(x_0 + h) - f(x_0)}{h}\)。当 \(h\) 趋近于 0 时，如果这个差商的极限存在，我们就称该极限为 \(f(x)\) 在 \(x_0\) 处的导数，记作：

\[
f'(x_0) = \lim_{h \to 0} \frac{f(x_0 + h) - f(x_0)}{h}
\]

例如，对于 \(f(x) = x^2\)，在任意点 \(x\) 处的导数为：

\[
f'(x) = \lim_{h \to 0} \frac{(x+h)^2 - x^2}{h} = \lim_{h \to 0} \frac{2xh + h^2}{h} = \lim_{h \to 0} (2x + h) = 2x
\]

---

### 3. 不定积分和定积分（牛顿-莱布尼茨公式）

积分是导数的逆运算，用于计算累积量（如面积、体积）。

- **不定积分**：如果 \(F'(x) = f(x)\)，则 \(F(x)\) 是 \(f(x)\) 的一个原函数，不定积分表示为：
  \[
  \int f(x) \, dx = F(x) + C
  \]
  其中 \(C\) 是任意常数。

- **定积分**：表示函数 \(f(x)\) 在区间 \([a, b]\) 上的累积效果（如曲线下的面积）。牛顿-莱布尼茨公式将定积分与原函数联系起来：
  \[
  \int_a^b f(x) \, dx = F(b) - F(a)
  \]
  其中 \(F\) 是 \(f\) 的任意一个原函数。

例如，计算 \(\int_0^1 x^2 \, dx\)：因为 \(\frac{x^3}{3}\) 是 \(x^2\) 的一个原函数，所以
\[
\int_0^1 x^2 \, dx = \left[ \frac{x^3}{3} \right]_0^1 = \frac{1}{3} - 0 = \frac{1}{3}
\]

---

### 4. 泰勒级数展开

泰勒级数用多项式来逼近一个光滑函数。如果函数 \(f(x)\) 在点 \(a\) 附近有任意阶导数，那么它可以展开为幂级数：

\[
f(x) = \sum_{n=0}^{\infty} \frac{f^{(n)}(a)}{n!} (x - a)^n
\]

其中 \(f^{(n)}(a)\) 表示 \(f\) 在 \(a\) 处的 \(n\) 阶导数，\(n!\) 是 \(n\) 的阶乘。特别地，当 \(a = 0\) 时，称为麦克劳林级数。

例如，指数函数 \(e^x\) 在 \(x=0\) 处的展开为：
\[
e^x = \sum_{n=0}^{\infty} \frac{x^n}{n!} = 1 + x + \frac{x^2}{2!} + \frac{x^3}{3!} + \cdots
\]

另一个例子是正弦函数：
\[
\sin x = \sum_{n=0}^{\infty} \frac{(-1)^n x^{2n+1}}{(2n+1)!} = x - \frac{x^3}{3!} + \frac{x^5}{5!} - \cdots
\]

---

### 5. 包含复杂 LaTeX 的综合示例

为了展示这些符号的用法，我们看一个偏微分方程的例子（虽然不属于基础微积分，但能体现符号的丰富性）：

热传导方程中，温度 \(u(x,t)\) 满足：
\[
\frac{\partial u}{\partial t} = \alpha \frac{\partial^2 u}{\partial x^2}
\]
其中 \(\alpha\) 是热扩散系数。这个方程的解可以用傅里叶级数表示，涉及积分和无穷求和。

另一个例子：计算一个函数的极限，如 \(\lim_{x \to \infty} \frac{\sqrt{x^2 + 1}}{x}\)，可以分子分母同除以 \(x\) 得到：
\[
\lim_{x \to \infty} \frac{\sqrt{1 + \frac{1}{x^2}}}{1} = 1
\]

---

总结一下，微积分的基础就是：用极限定义导数（变化率），用积分（原函数差）计算累积，用泰勒级数将函数展开为多项式以便近似计算。希望大家课后多加练习，掌握这些核心概念。
```

### 线性代数

1. [INLINE] `A` — SIMPLE
2. [INLINE] `m \times n` — MEDIUM (op)
3. [INLINE] `B` — SIMPLE
4. [INLINE] `n \times p` — MEDIUM (op)
5. [INLINE] `C = AB` — SIMPLE
6. [INLINE] `m \times p` — MEDIUM (op)
7. [INLINE] `i` — SIMPLE
8. [INLINE] `j` — SIMPLE
9. [DISPLAY] `C_{ij} = \sum_{k=1}^{n} A_{ik} B_{kj}` — MEDIUM (sum)
10. [INLINE] `C_{ij}` — SIMPLE
11. [INLINE] `A` — SIMPLE
12. [INLINE] `i` — SIMPLE
13. [INLINE] `B` — SIMPLE
14. [INLINE] `j` — SIMPLE
15. [DISPLAY] `A = \begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}, \quad
B = \begin{pmatrix} 5 & ` — MEDIUM (env)
16. [DISPLAY] `AB = \begin{pmatrix} 1\cdot5 + 2\cdot7 & 1\cdot6 + 2\cdot8 \\ 3\cdot5 + 4\cdot7 ` — MEDIUM (env,op)
17. [INLINE] `AB \neq BA` — SIMPLE
18. [INLINE] `\det(A)` — SIMPLE
19. [DISPLAY] `A = \begin{pmatrix} a & b \\ c & d \end{pmatrix}` — MEDIUM (env)
20. [DISPLAY] `\det(A) = ad - bc` — SIMPLE
21. [DISPLAY] `A = \begin{pmatrix} a_{11} & a_{12} & a_{13} \\ a_{21} & a_{22} & a_{23} \\ a_{3` — MEDIUM (env)
22. [DISPLAY] `\det(A) = a_{11}a_{22}a_{33} + a_{12}a_{23}a_{31} + a_{13}a_{21}a_{32} - a_{13}a` — SIMPLE
23. [DISPLAY] `\det(A) = a_{11} \det\begin{pmatrix} a_{22} & a_{23} \\ a_{32} & a_{33} \end{pma` — MEDIUM (env)
24. [INLINE] `n \times n` — MEDIUM (op)
25. [INLINE] `A` — SIMPLE
26. [INLINE] `\mathbf{v} \in \mathbb{R}^n` — MEDIUM (mathbb)
27. [INLINE] `\lambda \in \mathbb{R}` — MEDIUM (mathbb)
28. [DISPLAY] `A \mathbf{v} = \lambda \mathbf{v}` — SIMPLE
29. [INLINE] `\lambda` — SIMPLE
30. [INLINE] `A` — SIMPLE
31. [INLINE] `\mathbf{v}` — SIMPLE
32. [INLINE] `\lambda` — SIMPLE
33. [DISPLAY] `(A - \lambda I) \mathbf{v} = \mathbf{0}` — SIMPLE
34. [INLINE] `I` — SIMPLE
35. [DISPLAY] `\det(A - \lambda I) = 0` — SIMPLE
36. [INLINE] `\lambda` — SIMPLE
37. [DISPLAY] `A = \begin{bmatrix} 2 & 1 \\ 1 & 2 \end{bmatrix}` — MEDIUM (env)
38. [DISPLAY] `\det(A - \lambda I) = \det\begin{pmatrix} 2-\lambda & 1 \\ 1 & 2-\lambda \end{pm` — MEDIUM (env)
39. [INLINE] `\lambda_1 = 3` — SIMPLE
40. [INLINE] `\lambda_2 = 1` — SIMPLE
41. [INLINE] `\lambda = 3` — SIMPLE
42. [INLINE] `(A - 3I)\mathbf{v} = \mathbf{0}` — SIMPLE
43. [INLINE] `\mathbf{v} = \begin{pmatrix} 1 \\ 1 \end{pmatrix}` — MEDIUM (env)
44. [INLINE] `(AB)_{ij} = \sum_k A_{ik}B_{kj}` — MEDIUM (sum)
45. [INLINE] `ad-bc` — SIMPLE
46. [INLINE] `A\mathbf{v} = \lambda\mathbf{v}` — SIMPLE
47. [INLINE] `\det(A-\lambda I)=0` — SIMPLE

**LLM 完整输出**:

```
好的，我们开始今天的内容。作为一名线性代数教授，我将为你讲解三个核心概念：矩阵乘法、行列式计算以及特征值与特征向量。

---

### 1. 矩阵乘法的定义

矩阵乘法是线性代数中最基本的运算之一。设 \( A \) 是一个 \( m \times n \) 的矩阵，\( B \) 是一个 \( n \times p \) 的矩阵，那么它们的乘积 \( C = AB \) 是一个 \( m \times p \) 的矩阵，其第 \( i \) 行第 \( j \) 列的元素定义为：

\[
C_{ij} = \sum_{k=1}^{n} A_{ik} B_{kj}
\]

换句话说，\( C_{ij} \) 是 \( A \) 的第 \( i \) 行向量与 \( B \) 的第 \( j \) 列向量的点积。

**示例**：  
设  
\[
A = \begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}, \quad
B = \begin{pmatrix} 5 & 6 \\ 7 & 8 \end{pmatrix}
\]  
则  
\[
AB = \begin{pmatrix} 1\cdot5 + 2\cdot7 & 1\cdot6 + 2\cdot8 \\ 3\cdot5 + 4\cdot7 & 3\cdot6 + 4\cdot8 \end{pmatrix}
= \begin{pmatrix} 19 & 22 \\ 43 & 50 \end{pmatrix}
\]

注意：矩阵乘法不满足交换律，即一般情况下 \( AB \neq BA \)。

---

### 2. 行列式的计算

行列式是一个将方阵映射到实数的函数，记作 \( \det(A) \)。它反映了矩阵的某些几何性质，如体积缩放因子。

#### 2×2 矩阵的行列式

对于  
\[
A = \begin{pmatrix} a & b \\ c & d \end{pmatrix}
\]  
其行列式为  
\[
\det(A) = ad - bc
\]

#### 3×3 矩阵的行列式

对于  
\[
A = \begin{pmatrix} a_{11} & a_{12} & a_{13} \\ a_{21} & a_{22} & a_{23} \\ a_{31} & a_{32} & a_{33} \end{pmatrix}
\]  
其行列式可以用 Sarrus 法则或展开公式计算：

\[
\det(A) = a_{11}a_{22}a_{33} + a_{12}a_{23}a_{31} + a_{13}a_{21}a_{32} - a_{13}a_{22}a_{31} - a_{11}a_{23}a_{32} - a_{12}a_{21}a_{33}
\]

也可以按第一行展开：
\[
\det(A) = a_{11} \det\begin{pmatrix} a_{22} & a_{23} \\ a_{32} & a_{33} \end{pmatrix}
- a_{12} \det\begin{pmatrix} a_{21} & a_{23} \\ a_{31} & a_{33} \end{pmatrix}
+ a_{13} \det\begin{pmatrix} a_{21} & a_{22} \\ a_{31} & a_{32} \end{pmatrix}
\]

---

### 3. 特征值和特征向量的定义

特征值和特征向量是理解线性变换本质的关键。对于一个 \( n \times n \) 的方阵 \( A \)，如果存在一个非零向量 \( \mathbf{v} \in \mathbb{R}^n \) 和一个标量 \( \lambda \in \mathbb{R} \)，使得

\[
A \mathbf{v} = \lambda \mathbf{v}
\]

那么 \( \lambda \) 称为 \( A \) 的**特征值**，\( \mathbf{v} \) 称为对应于 \( \lambda \) 的**特征向量**。

这个方程可以改写为：
\[
(A - \lambda I) \mathbf{v} = \mathbf{0}
\]
其中 \( I \) 是单位矩阵。要使非零解存在，必须满足：
\[
\det(A - \lambda I) = 0
\]
这个方程称为**特征方程**，解出的 \( \lambda \) 就是特征值。

**示例**：  
设  
\[
A = \begin{bmatrix} 2 & 1 \\ 1 & 2 \end{bmatrix}
\]  
则  
\[
\det(A - \lambda I) = \det\begin{pmatrix} 2-\lambda & 1 \\ 1 & 2-\lambda \end{pmatrix}
= (2-\lambda)^2 - 1 = \lambda^2 - 4\lambda + 3 = 0
\]  
解得 \( \lambda_1 = 3 \)，\( \lambda_2 = 1 \)。  
对于 \( \lambda = 3 \)，解 \( (A - 3I)\mathbf{v} = \mathbf{0} \) 得特征向量 \( \mathbf{v} = \begin{pmatrix} 1 \\ 1 \end{pmatrix} \)（或任意非零倍数）。

---

### 总结

- 矩阵乘法：\( (AB)_{ij} = \sum_k A_{ik}B_{kj} \)
- 行列式：2×2 为 \( ad-bc \)，3×3 可用 Sarrus 法则或展开
- 特征值与特征向量：满足 \( A\mathbf{v} = \lambda\mathbf{v} \)，通过 \( \det(A-\lambda I)=0 \) 求解

这些概念在后续的线性变换、对角化、微分方程等领域中会反复出现。希望你能熟练掌握它们！
```

### 概率论

1. [INLINE] `A` — SIMPLE
2. [INLINE] `B` — SIMPLE
3. [INLINE] `P(B) > 0` — SIMPLE
4. [INLINE] `B` — SIMPLE
5. [INLINE] `A` — SIMPLE
6. [DISPLAY] `P(A \mid B) = \frac{P(A \cap B)}{P(B)}` — MEDIUM (frac)
7. [INLINE] `P(A \cap B) = P(A \mid B) P(B)` — SIMPLE
8. [INLINE] `A_1, A_2, \ldots, A_n` — SIMPLE
9. [INLINE] `B` — SIMPLE
10. [INLINE] `P(B) > 0` — SIMPLE
11. [DISPLAY] `P(A_i \mid B) = \frac{P(B \mid A_i) P(A_i)}{\sum_{j=1}^{n} P(B \mid A_j) P(A_j)}` — MEDIUM (frac,sum)
12. [INLINE] `P(A_i)` — SIMPLE
13. [INLINE] `P(A_i \mid B)` — SIMPLE
14. [INLINE] `P(B \mid A_i)` — SIMPLE
15. [INLINE] `\sum` — MEDIUM (sum)
16. [INLINE] `X` — SIMPLE
17. [INLINE] `\{x_1, x_2, \ldots\}` — SIMPLE
18. [INLINE] `p(x_i) = P(X = x_i)` — SIMPLE
19. [INLINE] `\mathbb{E}[X]` — MEDIUM (mathbb)
20. [DISPLAY] `\mathbb{E}[X] = \sum_{i} x_i \, p(x_i)` — MEDIUM (sum,mathbb)
21. [INLINE] `\mathbb{E}[X] = \frac{1+2+3+4+5+6}{6} = 3.5` — MEDIUM (frac,mathbb)
22. [INLINE] `\text{Var}(X)` — MEDIUM (text)
23. [INLINE] `\sigma^2` — SIMPLE
24. [DISPLAY] `\text{Var}(X) = \mathbb{E}[(X - \mathbb{E}[X])^2] = \sum_{i} (x_i - \mathbb{E}[X` — COMPLEX (sum,mathbb,text)
25. [INLINE] `\text{Var}(X) = \mathbb{E}[X^2] - (\mathbb{E}[X])^2` — MEDIUM (mathbb,text)
26. [INLINE] `\sigma = \sqrt{\text{Var}(X)}` — MEDIUM (sqrt,text)
27. [INLINE] `\mu` — SIMPLE
28. [INLINE] `\sigma` — SIMPLE
29. [INLINE] `\sigma > 0` — SIMPLE
30. [DISPLAY] `f(x) = \frac{1}{\sigma \sqrt{2\pi}} \, \exp\left( -\frac{(x - \mu)^2}{2\sigma^2}` — COMPLEX (frac,sqrt,∞,big-paren)
31. [INLINE] `\sqrt{2\pi}` — MEDIUM (sqrt)
32. [INLINE] `\frac{(x - \mu)^2}{2\sigma^2}` — MEDIUM (frac)
33. [INLINE] `x = \mu` — SIMPLE
34. [INLINE] `\mu = 0, \sigma = 1` — SIMPLE
35. [INLINE] `\phi(x) = \frac{1}{\sqrt{2\pi}} e^{-x^2/2}` — MEDIUM (frac,sqrt)
36. [INLINE] `\mathbb{E}[X] = \mu` — MEDIUM (mathbb)
37. [INLINE] `\text{Var}(X) = \sigma^2` — MEDIUM (text)
38. [INLINE] `X_1, X_2, \ldots, X_n` — SIMPLE
39. [INLINE] `\mu = \mathbb{E}[X_i]` — MEDIUM (mathbb)
40. [INLINE] `\bar{X}_n = \frac{1}{n} \sum_{i=1}^{n} X_i` — MEDIUM (frac,sum)
41. [INLINE] `\epsilon > 0` — SIMPLE
42. [DISPLAY] `\lim_{n \to \infty} P\left( \left| \bar{X}_n - \mu \right| < \epsilon \right) = ` — COMPLEX (lim,∞,big-paren)
43. [INLINE] `n` — SIMPLE
44. [INLINE] `\mu` — SIMPLE
45. [INLINE] `\mathbb{E}[X]` — MEDIUM (mathbb)
46. [INLINE] `\sigma^2` — SIMPLE
47. [INLINE] `\mu` — SIMPLE
48. [INLINE] `\sigma` — SIMPLE
49. [INLINE] `\sqrt{2\pi}` — MEDIUM (sqrt)
50. [INLINE] `\bar{X}_n` — SIMPLE
51. [INLINE] `n \to \infty` — MEDIUM (∞)
52. [INLINE] `\mu` — SIMPLE

**LLM 完整输出**:

```
好的，作为一名概率论教授，我将为你系统地讲解这几个核心概念。请仔细阅读以下内容，并注意公式的规范表达。

---

### 1. 条件概率与贝叶斯定理

首先，我们引入**条件概率**。对于两个事件 \(A\) 和 \(B\)，且 \(P(B) > 0\)，在事件 \(B\) 发生的条件下事件 \(A\) 发生的概率定义为：

\[
P(A \mid B) = \frac{P(A \cap B)}{P(B)}
\]

这个公式是理解依赖关系的基础。由此，我们可以推导出**乘法公式**：\(P(A \cap B) = P(A \mid B) P(B)\)。

**贝叶斯定理**则是条件概率的一个逆用，它允许我们根据结果（证据）来更新对原因（假设）的信念。设事件 \(A_1, A_2, \ldots, A_n\) 是样本空间的一个完备划分（即互斥且并集为全集），则对于任意事件 \(B\)（\(P(B) > 0\)），有：

\[
P(A_i \mid B) = \frac{P(B \mid A_i) P(A_i)}{\sum_{j=1}^{n} P(B \mid A_j) P(A_j)}
\]

这里，\(P(A_i)\) 称为**先验概率**，\(P(A_i \mid B)\) 称为**后验概率**，而 \(P(B \mid A_i)\) 是**似然**。分母中的 \(\sum\) 符号表示对所有可能的原因求和，确保概率归一化。

---

### 2. 离散随机变量的期望和方差

对于一个离散随机变量 \(X\)，其取值集合为 \(\{x_1, x_2, \ldots\}\)，对应的概率质量函数为 \(p(x_i) = P(X = x_i)\)。

**期望**（或称均值）是随机变量取值的加权平均，记为 \(\mathbb{E}[X]\)：

\[
\mathbb{E}[X] = \sum_{i} x_i \, p(x_i)
\]

期望是概率分布的中心位置度量。例如，掷一个公平骰子的期望值为 \(\mathbb{E}[X] = \frac{1+2+3+4+5+6}{6} = 3.5\)。

**方差**衡量随机变量取值相对于期望的离散程度，记为 \(\text{Var}(X)\) 或 \(\sigma^2\)：

\[
\text{Var}(X) = \mathbb{E}[(X - \mathbb{E}[X])^2] = \sum_{i} (x_i - \mathbb{E}[X])^2 \, p(x_i)
\]

一个常用的计算方差公式是：\(\text{Var}(X) = \mathbb{E}[X^2] - (\mathbb{E}[X])^2\)。方差的正平方根称为**标准差** \(\sigma = \sqrt{\text{Var}(X)}\)。

---

### 3. 正态分布的概率密度函数

正态分布（又称高斯分布）是概率论中最重要且应用最广泛的连续分布。它的概率密度函数由两个参数决定：均值 \(\mu\)（位置参数）和标准差 \(\sigma\)（尺度参数，\(\sigma > 0\)）。其公式为：

\[
f(x) = \frac{1}{\sigma \sqrt{2\pi}} \, \exp\left( -\frac{(x - \mu)^2}{2\sigma^2} \right), \quad -\infty < x < \infty
\]

这里：
- \(\sqrt{2\pi}\) 是归一化常数，确保曲线下总面积为1。
- 指数部分中的 \(\frac{(x - \mu)^2}{2\sigma^2}\) 决定了曲线的形状：在 \(x = \mu\) 处达到峰值，并向两侧对称衰减。
- 当 \(\mu = 0, \sigma = 1\) 时，称为**标准正态分布**，其概率密度函数简化为 \(\phi(x) = \frac{1}{\sqrt{2\pi}} e^{-x^2/2}\)。

正态分布的期望和方差分别为 \(\mathbb{E}[X] = \mu\) 和 \(\text{Var}(X) = \sigma^2\)。

---

### 4. 大数定律的表述

大数定律是概率论中描述大量重复试验平均结果稳定性的定理。这里给出**弱大数定律**的一种常见表述：

设 \(X_1, X_2, \ldots, X_n\) 是独立同分布的随机变量，具有共同的有限期望 \(\mu = \mathbb{E}[X_i]\)。定义样本均值 \(\bar{X}_n = \frac{1}{n} \sum_{i=1}^{n} X_i\)。则对于任意 \(\epsilon > 0\)，有：

\[
\lim_{n \to \infty} P\left( \left| \bar{X}_n - \mu \right| < \epsilon \right) = 1
\]

换句话说，随着样本量 \(n\) 趋向无穷大，样本均值依概率收敛于总体均值 \(\mu\)。这个定理为统计推断（如用样本均值估计总体均值）提供了理论基础。

---

### 总结

- **贝叶斯定理**：通过条件概率和全概率公式，实现从结果到原因的逆向推理。
- **期望与方差**：期望 \(\mathbb{E}[X]\) 描述中心位置，方差 \(\sigma^2\) 描述离散程度。
- **正态分布**：由 \(\mu\) 和 \(\sigma\) 决定的钟形曲线，其概率密度函数包含 \(\sqrt{2\pi}\) 和指数项。
- **大数定律**：样本均值 \(\bar{X}_n\) 在 \(n \to \infty\) 时趋近于总体均值 \(\mu\)。

希望这些讲解能帮助你建立清晰的概念框架。如有疑问，欢迎继续探讨！
```

### 复杂公式压力测试

1. [DISPLAY] `f(x) = \begin{cases} x^2 & x \geq 0 \\ -x^2 & x < 0 \end{cases}` — MEDIUM (env)
2. [INLINE] `f(x)` — SIMPLE
3. [INLINE] `x` — SIMPLE
4. [INLINE] `x^2` — SIMPLE
5. [INLINE] `x` — SIMPLE
6. [INLINE] `-x^2` — SIMPLE
7. [INLINE] `x=0` — SIMPLE
8. [INLINE] `x=0` — SIMPLE
9. [INLINE] `f(0)=0` — SIMPLE
10. [INLINE] `f(x) = x|x|` — SIMPLE
11. [INLINE] `x` — SIMPLE
12. [INLINE] `x` — SIMPLE
13. [DISPLAY] `\frac{\frac{a}{b}}{\frac{c}{d}} = \frac{ad}{bc}` — MEDIUM (frac)
14. [INLINE] `\frac{a}{b}` — MEDIUM (frac)
15. [INLINE] `\frac{c}{d}` — MEDIUM (frac)
16. [INLINE] `\frac{a}{b} \div \frac{c}{d}` — MEDIUM (frac)
17. [INLINE] `\frac{a}{b} \div \frac{c}{d} = \frac{a}{b} \times \frac{d}{c} = \frac{a \times d` — MEDIUM (frac,op)
18. [INLINE] `a/b` — SIMPLE
19. [INLINE] `d/c` — SIMPLE
20. [DISPLAY] `\int_{-\infty}^{\infty} e^{-x^2} dx = \sqrt{\pi}` — COMPLEX (int,sqrt,∞)
21. [INLINE] `e^{-x^2}` — SIMPLE
22. [INLINE] `e^{-x^2}` — SIMPLE
23. [INLINE] `x=0` — SIMPLE
24. [INLINE] `\sqrt{\pi}` — MEDIUM (sqrt)
25. [INLINE] `e^{-x^2}` — SIMPLE
26. [INLINE] `\pi` — SIMPLE
27. [INLINE] `\sqrt{\pi}` — MEDIUM (sqrt)
28. [DISPLAY] `\nabla \cdot \mathbf{E} = \frac{\rho}{\varepsilon_0}` — MEDIUM (frac,op)
29. [INLINE] `\mathbf{E}` — SIMPLE
30. [INLINE] `\nabla \cdot` — MEDIUM (op)
31. [INLINE] `\mathbf{E}` — SIMPLE
32. [INLINE] `\rho` — SIMPLE
33. [INLINE] `\varepsilon_0` — SIMPLE
34. [DISPLAY] `x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}` — COMPLEX (frac,sqrt,±)
35. [INLINE] `ax^2 + bx + c = 0` — SIMPLE
36. [INLINE] `a \neq 0` — SIMPLE
37. [INLINE] `a, b, c` — SIMPLE
38. [INLINE] `\pm` — MEDIUM (±)
39. [INLINE] `b^2 - 4ac` — SIMPLE
40. [INLINE] `\Delta` — SIMPLE
41. [INLINE] `\Delta > 0` — SIMPLE
42. [INLINE] `\Delta = 0` — SIMPLE
43. [INLINE] `\Delta < 0` — SIMPLE
44. [DISPLAY] `\lim_{x \to 0} \frac{\sin x}{x} = 1` — MEDIUM (frac,lim)
45. [INLINE] `x` — SIMPLE
46. [INLINE] `\frac{\sin x}{x}` — MEDIUM (frac)
47. [INLINE] `x=0` — SIMPLE
48. [INLINE] `\sin 0 = 0` — SIMPLE
49. [INLINE] `x=0` — SIMPLE
50. [INLINE] `\frac{0}{0}` — MEDIUM (frac)
51. [INLINE] `x=0` — SIMPLE
52. [INLINE] `x` — SIMPLE
53. [INLINE] `x` — SIMPLE
54. [INLINE] `\sin x` — SIMPLE
55. [INLINE] `x` — SIMPLE
56. [INLINE] `\frac{d}{dx} \sin x = \cos x` — MEDIUM (frac)

**LLM 完整输出**:

```
好的，各位同学，我是你们的数学教授。今天我们来解析几个在数学中非常基础且重要的公式。请大家注意，每个公式我都会用标准的数学定界符包裹起来，并详细解释其含义。

---

**1. 分段函数**

首先，我们来看一个分段函数的例子：

\[
f(x) = \begin{cases} x^2 & x \geq 0 \\ -x^2 & x < 0 \end{cases}
\]

这个公式定义了一个函数 \( f(x) \)。它的特别之处在于，函数在不同区间内的表达式是不同的。这里的“分段”体现在大括号 `{` 和 `cases` 环境上。

*   **含义**：当自变量 \( x \) 大于或等于 0 时，函数值等于 \( x^2 \)（即一个开口向上的抛物线的一半）。当 \( x \) 小于 0 时，函数值等于 \( -x^2 \)（即一个开口向下的抛物线的一半）。
*   **图像**：这个函数的图像在 \( x=0 \) 处连接，但方向发生了改变。在 \( x=0 \) 处，两个表达式都给出 \( f(0)=0 \)，所以函数是连续的。这个函数实际上就是 \( f(x) = x|x| \)，即 \( x \) 乘以 \( x \) 的绝对值。

---

**2. 嵌套分式**

接下来，我们处理一个看起来有点复杂的分数：

\[
\frac{\frac{a}{b}}{\frac{c}{d}} = \frac{ad}{bc}
\]

这个公式展示了如何化简一个“分数套分数”的表达式。

*   **含义**：左边是一个大分式，分子是 \( \frac{a}{b} \)，分母是 \( \frac{c}{d} \)。这相当于 \( \frac{a}{b} \div \frac{c}{d} \)。
*   **化简过程**：根据分数除法的法则，“除以一个分数等于乘以它的倒数”。所以，\( \frac{a}{b} \div \frac{c}{d} = \frac{a}{b} \times \frac{d}{c} = \frac{a \times d}{b \times c} = \frac{ad}{bc} \)。
*   **关键点**：这个公式告诉我们，处理嵌套分式时，只需将外层的分子（\( a/b \)）乘以内层分母的倒数（\( d/c \)），或者更直观地，将最外层的分子和分母分别乘以它们各自分母的最小公倍数，也能得到相同的结果。最终结果就是“外外相乘，内内相乘”的交叉相乘形式。

---

**3. 含积分和求和的大型表达式**

这是一个非常著名的积分公式，它连接了指数函数、无穷区间和圆周率：

\[
\int_{-\infty}^{\infty} e^{-x^2} dx = \sqrt{\pi}
\]

这个公式被称为**高斯积分**，在概率论、统计学和物理学中极其重要。

*   **含义**：它计算了函数 \( e^{-x^2} \) 从负无穷到正无穷的曲线下的面积。
*   **函数特性**：\( e^{-x^2} \) 是一个钟形曲线（也叫高斯函数或正态分布曲线），它在 \( x=0 \) 处达到最大值 1，并向两侧迅速衰减到 0。这个积分的结果是一个常数：\( \sqrt{\pi} \)。
*   **重要性**：这个结果非常神奇，因为它将看似不相关的指数函数 \( e^{-x^2} \) 和圆周率 \( \pi \) 联系在了一起。它没有初等原函数，但通过巧妙的技巧（如极坐标变换）可以证明其值等于 \( \sqrt{\pi} \)。它是整个概率论和统计学的基石。

---

**4. 麦克斯韦方程组之一（矢量形式）**

麦克斯韦方程组是电磁学的基础。这里我们展示其中一个，即**高斯电场定律**：

\[
\nabla \cdot \mathbf{E} = \frac{\rho}{\varepsilon_0}
\]

*   **含义**：这个公式描述了电场 \( \mathbf{E} \) 是如何由电荷产生的。
*   **符号解释**：
    *   \( \nabla \cdot \) 是**散度**算子，它衡量一个矢量场在某一点是“发散”还是“汇聚”。
    *   \( \mathbf{E} \) 是电场强度矢量。
    *   \( \rho \) 是电荷密度（单位体积内的电荷量）。
    *   \( \varepsilon_0 \) 是真空介电常数，一个基本物理常数。
*   **物理意义**：公式表明，电场在某一点的散度，等于该点的电荷密度除以介电常数。换句话说，**电荷是电场的源**。正电荷发出电场线（散度为正），负电荷吸收电场线（散度为负）。在没有电荷的地方，电场的散度为零，即电场线是连续的。

---

**5. 二次公式**

这是代数中求解一元二次方程最核心的公式：

\[
x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}
\]

*   **含义**：这个公式给出了形如 \( ax^2 + bx + c = 0 \)（其中 \( a \neq 0 \)）的一元二次方程的解。
*   **符号解释**：
    *   \( a, b, c \) 是方程的系数。
    *   \( \pm \) 表示有两个解：一个用加号，一个用减号。
    *   根号内的部分 \( b^2 - 4ac \) 被称为**判别式**，记作 \( \Delta \)。
*   **判别式的作用**：
    *   如果 \( \Delta > 0 \)，方程有两个不同的实数解。
    *   如果 \( \Delta = 0 \)，方程有两个相同的实数解（一个重根）。
    *   如果 \( \Delta < 0 \)，方程没有实数解，但有两个共轭复数解。
*   **推导**：这个公式是通过“配方法”推导出来的，它将任何二次方程的解都归结为这个统一的形式。

---

**6. 极限**

最后，我们来看一个微积分中极其重要的极限：

\[
\lim_{x \to 0} \frac{\sin x}{x} = 1
\]

*   **含义**：这个公式描述了当自变量 \( x \) 无限趋近于 0 时，函数 \( \frac{\sin x}{x} \) 的极限值。
*   **关键点**：当 \( x=0 \) 时，分子 \( \sin 0 = 0 \)，分母 \( x=0 \)，得到 \( \frac{0}{0} \) 的不定式。这个极限告诉我们，尽管这个比值在 \( x=0 \) 处没有定义，但当 \( x \) 非常接近 0 时，它的值会无限接近 1。
*   **几何解释**：想象一个单位圆，当角度 \( x \)（以弧度为单位）非常小时，\( \sin x \) 近似等于 \( x \)（即弧长近似等于弦长），所以它们的比值趋近于 1。
*   **重要性**：这个极限是推导所有三角函数导数的基础。例如，\( \frac{d}{dx} \sin x = \cos x \) 的证明就依赖于这个极限。它是整个微积分学中处理三角函数的基石。

希望这些讲解能帮助大家更好地理解这些公式。数学之美就在于这些简洁的符号背后，蕴含着深刻而丰富的思想。
```

### 高密度公式

1. [DISPLAY] `\sin(\alpha \pm \beta) = \sin\alpha \cos\beta \pm \cos\alpha \sin\beta` — MEDIUM (±)
2. [DISPLAY] `\cos 2\theta = 2\cos^2\theta - 1 = 1 - 2\sin^2\theta` — SIMPLE
3. [DISPLAY] `\log_a b = \frac{\log_c b}{\log_c a}` — MEDIUM (frac)
4. [DISPLAY] `\log_a (x^y) = y \log_a x` — SIMPLE
5. [DISPLAY] `a^{x+y} = a^x \cdot a^y` — MEDIUM (op)
6. [DISPLAY] `e^{\ln x} = x \quad (x>0)` — SIMPLE
7. [DISPLAY] `\lim_{x \to 0} \frac{\sin x}{x} = 1` — MEDIUM (frac,lim)
8. [DISPLAY] `\lim_{n \to \infty} \left(1 + \frac{1}{n}\right)^n = e` — COMPLEX (frac,lim,∞,big-paren)
9. [DISPLAY] `\frac{d}{dx} \sin x = \cos x, \quad \frac{d}{dx} \ln x = \frac{1}{x}` — MEDIUM (frac)
10. [DISPLAY] `(uv)' = u'v + uv'` — SIMPLE
11. [DISPLAY] `\int x^n \, dx = \frac{x^{n+1}}{n+1} + C \quad (n \neq -1)` — MEDIUM (frac,int)
12. [DISPLAY] `\int u \, dv = uv - \int v \, du` — MEDIUM (int)
13. [INLINE] `a` — SIMPLE
14. [INLINE] `r` — SIMPLE
15. [INLINE] `|r|<1` — SIMPLE
16. [DISPLAY] `\sum_{k=0}^{\infty} a r^k = \frac{a}{1-r}` — COMPLEX (frac,sum,∞)
17. [DISPLAY] `e^x = \sum_{n=0}^{\infty} \frac{x^n}{n!}` — COMPLEX (frac,sum,∞)
18. [DISPLAY] `\det\begin{pmatrix} a & b \\ c & d \end{pmatrix} = ad - bc` — MEDIUM (env)
19. [DISPLAY] `\begin{pmatrix} a & b \\ c & d \end{pmatrix}
\begin{pmatrix} e & f \\ g & h \end` — MEDIUM (env)
20. [DISPLAY] `P(n, k) = \frac{n!}{(n-k)!}` — MEDIUM (frac)
21. [DISPLAY] `C(n, k) = \binom{n}{k} = \frac{n!}{k!(n-k)!}` — MEDIUM (frac)
22. [DISPLAY] `(a+b)^n = \sum_{k=0}^n \binom{n}{k} a^{n-k} b^k` — MEDIUM (sum)
23. [DISPLAY] `e^{i\theta} = \cos\theta + i\sin\theta` — SIMPLE
24. [DISPLAY] `\cos\theta = \frac{e^{i\theta} + e^{-i\theta}}{2}, \quad \sin\theta = \frac{e^{i` — MEDIUM (frac)

**LLM 完整输出**:

```
好的，我们快速过一遍竞赛中高频出现的核心公式，每个都配上简要说明。

**1. 三角恒等式**  
两角和公式：  
\[
\sin(\alpha \pm \beta) = \sin\alpha \cos\beta \pm \cos\alpha \sin\beta
\]  
倍角公式：  
\[
\cos 2\theta = 2\cos^2\theta - 1 = 1 - 2\sin^2\theta
\]

**2. 对数运算**  
换底公式：  
\[
\log_a b = \frac{\log_c b}{\log_c a}
\]  
幂的对数：  
\[
\log_a (x^y) = y \log_a x
\]

**3. 指数函数**  
指数恒等式：  
\[
a^{x+y} = a^x \cdot a^y
\]  
自然指数与对数关系：  
\[
e^{\ln x} = x \quad (x>0)
\]

**4. 极限**  
重要极限：  
\[
\lim_{x \to 0} \frac{\sin x}{x} = 1
\]  
另一个常用极限：  
\[
\lim_{n \to \infty} \left(1 + \frac{1}{n}\right)^n = e
\]

**5. 导数**  
基本导数公式：  
\[
\frac{d}{dx} \sin x = \cos x, \quad \frac{d}{dx} \ln x = \frac{1}{x}
\]  
乘积法则：  
\[
(uv)' = u'v + uv'
\]

**6. 积分**  
幂函数积分：  
\[
\int x^n \, dx = \frac{x^{n+1}}{n+1} + C \quad (n \neq -1)
\]  
分部积分公式：  
\[
\int u \, dv = uv - \int v \, du
\]

**7. 级数**  
等比级数求和（首项 \(a\)，公比 \(r\)，\(|r|<1\)）：  
\[
\sum_{k=0}^{\infty} a r^k = \frac{a}{1-r}
\]  
泰勒展开（指数函数）：  
\[
e^x = \sum_{n=0}^{\infty} \frac{x^n}{n!}
\]

**8. 矩阵**  
二阶矩阵行列式：  
\[
\det\begin{pmatrix} a & b \\ c & d \end{pmatrix} = ad - bc
\]  
矩阵乘法（2×2示例）：  
\[
\begin{pmatrix} a & b \\ c & d \end{pmatrix}
\begin{pmatrix} e & f \\ g & h \end{pmatrix}
= \begin{pmatrix} ae+bg & af+bh \\ ce+dg & cf+dh \end{pmatrix}
\]

**9. 排列组合**  
排列数：  
\[
P(n, k) = \frac{n!}{(n-k)!}
\]  
组合数：  
\[
C(n, k) = \binom{n}{k} = \frac{n!}{k!(n-k)!}
\]  
二项式定理：  
\[
(a+b)^n = \sum_{k=0}^n \binom{n}{k} a^{n-k} b^k
\]

**10. 补充：三角与复数**  
欧拉公式：  
\[
e^{i\theta} = \cos\theta + i\sin\theta
\]  
由此可得：  
\[
\cos\theta = \frac{e^{i\theta} + e^{-i\theta}}{2}, \quad \sin\theta = \frac{e^{i\theta} - e^{-i\theta}}{2i}
\]

这些公式在竞赛中几乎每次都会用到，建议熟练推导并灵活变形。
```


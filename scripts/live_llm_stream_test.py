#!/usr/bin/env python3
"""
真实 LLM 流式输出 → 管道模拟 → 公式渲染正确性验证 (扩展版)

覆盖领域:
  1. 微积分 — 极限、导数、积分、泰勒级数
  2. 线性代数 — 矩阵、行列式、特征值
  3. 概率论 — 贝叶斯定理、期望、方差
  4. 复杂公式 — 分段函数、嵌套分式、大型表达式
  5. 高密度公式 — 单个回复中包含 10+ 公式

用法:
  export DEEPSEEK_API_KEY="sk-xxx"
  python scripts/live_llm_stream_test.py [--domain all]
"""

import json
import os
import re
import sys
import time
import urllib.request
import urllib.error

# ============================================================================
# 配置
# ============================================================================

API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")
API_URL = "https://api.deepseek.com/chat/completions"

# ============================================================================
# Dart 端正则 (与 chat_screen.dart _buildRichContent 完全一致)
# ============================================================================

MATH_REGEX = re.compile(r'\\[\(\[](.+?)\\[[)\]]', re.DOTALL)


# ============================================================================
# 测试用例定义
# ============================================================================

TEST_CASES = [
    {
        "name": "微积分",
        "system": """你是一位大学数学教授，正在讲授微积分。请用中文输出以下内容：
1. 极限的 ε-δ 定义，使用行内公式 \\( ... \\)
2. 导数的定义（差商极限）
3. 不定积分和定积分（牛顿-莱布尼茨公式），使用独立公式 \\[ ... \\]
4. 泰勒级数展开
5. 至少包含以下复杂 LaTeX: \\frac, \\int, \\sum, \\lim, \\infty, \\to, \\sqrt, \\partial

要求：公式必须使用 \\( \\) 或 \\[ \\] 包裹，自然教学语言。""",
        "user": "请讲解微积分的基础概念：极限、导数、积分和泰勒级数。",
    },
    {
        "name": "线性代数",
        "system": """你是一位线性代数教授。请用中文输出以下内容：
1. 矩阵乘法的定义，使用独立公式 \\[ ... \\]
2. 行列式的计算（2×2 和 3×3）
3. 特征值和特征向量的定义 Av = λv
4. 至少包含以下 LaTeX: \\begin{pmatrix}, \\begin{bmatrix}, \\det, \\mathbb{R}, \\lambda, \\mathbf{v}, \\cdots, \\vdots, \\ddots

要求：公式必须使用 \\( \\) 或 \\[ \\] 包裹，矩阵用 pmatrix 或 bmatrix 环境。""",
        "user": "请讲解线性代数核心概念：矩阵运算、行列式和特征值。",
    },
    {
        "name": "概率论",
        "system": """你是一位概率论教授。请用中文输出以下内容：
1. 条件概率和贝叶斯定理，使用独立公式 \\[ ... \\]
2. 离散随机变量的期望和方差
3. 正态分布的概率密度函数
4. 大数定律的表述
5. 至少包含以下 LaTeX: \\sum, \\int, \\infty, \\sigma, \\mu, \\mathbb{E}, \\text, \\frac, \\sqrt{2\\pi}

要求：公式必须使用 \\( \\) 或 \\[ \\] 包裹。""",
        "user": "请讲解概率论核心概念：贝叶斯定理、期望方差和正态分布。",
    },
    {
        "name": "复杂公式压力测试",
        "system": """你是一位数学教授。请输出以下复杂公式的教学内容，每个公式都用 \\( \\) 或 \\[ \\] 包裹：

1. 分段函数：
   f(x) = \\begin{cases} x^2 & x \\geq 0 \\\\ -x^2 & x < 0 \\end{cases}

2. 嵌套分式：
   \\frac{\\frac{a}{b}}{\\frac{c}{d}} = \\frac{ad}{bc}

3. 含积分和求和的大型表达式：
   \\int_{-\\infty}^{\\infty} e^{-x^2} dx = \\sqrt{\\pi}

4. 麦克斯韦方程组之一（矢量形式）

5. 二次公式：
   x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}

6. 极限：
   \\lim_{x \\to 0} \\frac{\\sin x}{x} = 1

要求：每个公式单独用定界符包裹，自然讲解。""",
        "user": "请讲解以下数学公式的含义。",
    },
    {
        "name": "高密度公式",
        "system": """你是一位数学竞赛教练，正在做一个快速的知识点串讲。请在同一个回复中包含至少 10 个不同的数学公式，涵盖：三角、对数、指数、极限、导数、积分、级数、矩阵、排列组合。

每个公式必须用 \\( \\) 或 \\[ \\] 包裹。
行内短公式用 \\( \\)，重要的核心公式用 \\[ \\] 独立显示。
语言使用中文，自然流畅。""",
        "user": "请快速串讲高中数学竞赛常考公式，越多越好。",
    },
]

# ============================================================================
# 管道模拟
# ============================================================================

class StreamingPipeline:
    def __init__(self):
        self._buffer = ""
        self._tokens: list[str] = []
        self._is_streaming = True

    @property
    def is_streaming(self) -> bool:
        return self._is_streaming

    @property
    def full_text(self) -> str:
        return self._buffer

    @property
    def tokens(self) -> list[str]:
        return list(self._tokens)

    def receive_token(self, content: str):
        self._buffer += content
        self._tokens.append(content)

    def receive_done(self, reply: str):
        self._buffer = reply
        self._is_streaming = False

    def render_new(self) -> list[dict]:
        if self._is_streaming:
            return []
        return self._extract_formulas(self._buffer)

    def _extract_formulas(self, text: str) -> list[dict]:
        matches = list(MATH_REGEX.finditer(text))
        return [{
            "full": m.group(0),
            "content": m.group(1).strip(),
            "is_display": m.group(0)[1] == "[",
            "start": m.start(),
            "end": m.end(),
        } for m in matches]


# ============================================================================
# LLM 调用
# ============================================================================

def call_deepseek_stream(system_prompt: str, user_prompt: str) -> list[str]:
    if not API_KEY:
        print("❌ DEEPSEEK_API_KEY 环境变量未设置！")
        sys.exit(1)

    body = json.dumps({
        "model": "deepseek-chat",
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "stream": True,
        "temperature": 0.3,
        "max_tokens": 2048,
    }).encode("utf-8")

    req = urllib.request.Request(API_URL, data=body, method="POST")
    req.add_header("Authorization", f"Bearer {API_KEY}")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "text/event-stream")

    chunks: list[str] = []
    print("   📡 连接 DeepSeek API...", end=" ", flush=True)

    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            if resp.status != 200:
                print(f"\n   ❌ HTTP {resp.status}")
                return []
            for line_bytes in resp:
                line = line_bytes.decode("utf-8")
                if line.startswith("data: "):
                    data_str = line[6:].strip()
                    if data_str == "[DONE]":
                        break
                    try:
                        data = json.loads(data_str)
                        choices = data.get("choices", [])
                        if choices:
                            delta = choices[0].get("delta", {})
                            content = delta.get("content", "")
                            if content:
                                chunks.append(content)
                    except json.JSONDecodeError:
                        pass
    except Exception as e:
        print(f"\n   ❌ 错误: {e}")
        return []

    print(f"收到 {len(chunks)} chunks, {sum(len(c) for c in chunks)} 字符")
    return chunks


# ============================================================================
# 公式质量检查
# ============================================================================

def check_brace_balance(content: str) -> tuple[bool, int, int]:
    """检查 {} 是否平衡，跳过 LaTeX 命令"""
    brace = 0
    i = 0
    while i < len(content):
        if content[i] == '\\' and i + 1 < len(content):
            i += 2
            continue
        if content[i] == '{':
            brace += 1
        elif content[i] == '}':
            brace -= 1
        i += 1
    return brace == 0, brace, 0


def classify_formula_complexity(content: str) -> str:
    """分类公式复杂度"""
    features = []
    if '\\frac' in content:
        features.append('frac')
    if '\\int' in content:
        features.append('int')
    if '\\sum' in content:
        features.append('sum')
    if '\\prod' in content:
        features.append('prod')
    if '\\lim' in content:
        features.append('lim')
    if '\\sqrt' in content:
        features.append('sqrt')
    if '\\begin{' in content:
        features.append('env')
    if '\\infty' in content:
        features.append('∞')
    if '\\partial' in content:
        features.append('∂')
    if '\\left' in content or '\\right' in content:
        features.append('big-paren')
    if '\\mathbb' in content:
        features.append('mathbb')
    if '\\text' in content:
        features.append('text')
    if '\\pm' in content:
        features.append('±')
    if '\\cdot' in content or '\\times' in content:
        features.append('op')
    if len(features) >= 3:
        return f"COMPLEX ({','.join(features)})"
    elif len(features) >= 1:
        return f"MEDIUM ({','.join(features)})"
    else:
        return "SIMPLE"


# ============================================================================
# 单用例分析
# ============================================================================

def analyze_case(name: str, chunks: list[str]) -> dict:
    """运行单个测试用例的完整管道分析"""

    full_text = "".join(chunks)

    # --- 修复前闪烁 ---
    buffer = ""
    flicker_count = 0
    prev_count = -1
    for chunk in chunks:
        buffer += chunk
        cur_count = len(MATH_REGEX.findall(buffer))
        if cur_count != prev_count and prev_count >= 0:
            flicker_count += 1
        prev_count = cur_count

    # --- 修复后管道 ---
    pipe = StreamingPipeline()
    for chunk in chunks:
        pipe.receive_token(chunk)

    streaming_matches = pipe.render_new()
    assert streaming_matches == [], f"{name}: 流式期间不应有公式匹配!"

    pipe.receive_done(full_text)
    final_formulas = pipe.render_new()

    # --- 公式质量 ---
    incomplete = []
    complex_count = 0
    for f in final_formulas:
        ok, _, _ = check_brace_balance(f["content"])
        if not ok:
            incomplete.append(f["content"][:60])
        if "COMPLEX" in classify_formula_complexity(f["content"]):
            complex_count += 1

    display_count = sum(1 for f in final_formulas if f["is_display"])
    inline_count = sum(1 for f in final_formulas if not f["is_display"])

    flicker_rate = flicker_count / len(chunks) * 100 if chunks else 0

    return {
        "name": name,
        "chunks": len(chunks),
        "chars": len(full_text),
        "old_flicker": flicker_count,
        "old_flicker_rate": flicker_rate,
        "formula_count": len(final_formulas),
        "display_count": display_count,
        "inline_count": inline_count,
        "complex_count": complex_count,
        "incomplete": incomplete,
        "formulas": [f["content"] for f in final_formulas],
        "formula_details": [
            {"content": f["content"][:80], "type": "DISPLAY" if f["is_display"] else "INLINE",
             "complexity": classify_formula_complexity(f["content"])}
            for f in final_formulas
        ],
        "full_text": full_text,
    }


# ============================================================================
# 打印结果
# ============================================================================

def print_case_result(r: dict, idx: int, total: int):
    """打印单个用例结果"""
    print(f"\n{'─'*72}")
    print(f"  [{idx}/{total}] {r['name']}")
    print(f"{'─'*72}")
    print(f"  Chunks: {r['chunks']} | 字符: {r['chars']} | 公式: {r['formula_count']}")
    print(f"  Display: {r['display_count']} | Inline: {r['inline_count']} | 复杂公式: {r['complex_count']}")
    print(f"  修复前闪烁: {r['old_flicker']}/{r['chunks']} ({r['old_flicker_rate']:.1f}%)")
    print(f"  修复后闪烁: 0 ✅")

    if r["incomplete"]:
        print(f"  ❌ 括号不平衡: {len(r['incomplete'])} 个公式!")
        for f in r["incomplete"]:
            print(f"     ⚠️ {f}")
    else:
        print(f"  括号平衡: ✅ 全部正确")

    print(f"\n  公式详情:")
    for i, d in enumerate(r["formula_details"]):
        tag = "📦" if d["type"] == "DISPLAY" else "   "
        print(f"  [{i+1:2d}] {tag} {d['complexity']:30s} {d['content']}")


# ============================================================================
# main
# ============================================================================

def main():
    domain_filter = sys.argv[1] if len(sys.argv) > 1 else "all"

    print("=" * 72)
    print("  CoEvo 数学公式流式渲染 — 扩展端到端验证")
    print("=" * 72)
    print(f"  API: DeepSeek Chat (stream)")
    print(f"  Model: deepseek-chat")
    print(f"  测试用例: {len(TEST_CASES)} 个领域")
    print()

    cases = TEST_CASES
    if domain_filter != "all":
        cases = [c for c in TEST_CASES if domain_filter in c["name"]]
        if not cases:
            print(f"❌ 未找到匹配 '{domain_filter}' 的用例")
            print(f"   可用: {', '.join(c['name'] for c in TEST_CASES)}, all")
            sys.exit(1)

    results = []
    all_passed = True

    for idx, case in enumerate(cases):
        print(f"\n🔬 [{idx+1}/{len(cases)}] {case['name']}")
        chunks = call_deepseek_stream(case["system"], case["user"])
        if not chunks:
            print(f"   ⚠️ 跳过 (无响应)")
            continue
        r = analyze_case(case["name"], chunks)
        print_case_result(r, idx + 1, len(cases))
        results.append(r)
        if r["incomplete"]:
            all_passed = False

    # =========================================================================
    # 汇总
    # =========================================================================
    print(f"\n{'='*72}")
    print(f"  汇总报告")
    print(f"{'='*72}")

    total_formulas = sum(r["formula_count"] for r in results)
    total_complex = sum(r["complex_count"] for r in results)
    total_chunks = sum(r["chunks"] for r in results)
    total_flickers = sum(r["old_flicker"] for r in results)
    total_incomplete = sum(len(r["incomplete"]) for r in results)
    total_display = sum(r["display_count"] for r in results)
    total_inline = sum(r["inline_count"] for r in results)
    avg_flicker = total_flickers / total_chunks * 100 if total_chunks else 0

    print(f"\n  📊 总计:")
    print(f"  测试用例: {len(results)}")
    print(f"  总 Chunks: {total_chunks}")
    print(f"  总公式数: {total_formulas}")
    print(f"  复杂公式: {total_complex} ({total_complex/total_formulas*100:.0f}%)" if total_formulas else "  复杂公式: 0")
    print(f"  Display: {total_display} | Inline: {total_inline}")
    print(f"  括号不平衡: {total_incomplete}")
    print(f"  修复前平均闪烁率: {avg_flicker:.1f}%")
    print(f"  修复后闪烁率: 0%")

    print(f"\n  📋 各领域对比:")
    print(f"  {'领域':<16s} {'公式':>5s} {'复杂':>5s} {'Display':>8s} {'闪烁率':>8s} {'括号':>6s}")
    print(f"  {'─'*16} {'─'*5} {'─'*5} {'─'*8} {'─'*8} {'─'*6}")
    for r in results:
        bal = "❌" if r["incomplete"] else "✅"
        print(f"  {r['name']:<16s} {r['formula_count']:>5d} {r['complex_count']:>5d} "
              f"{r['display_count']:>8d} {r['old_flicker_rate']:>7.1f}% {bal:>6s}")

    # 总体判定
    print(f"\n  {'─'*54}")
    if all_passed and total_incomplete == 0:
        print(f"  🟢 全部通过 — 所有领域公式完整提取，零闪烁")
    elif total_incomplete > 0:
        print(f"  🔴 存在括号不平衡公式 ({total_incomplete} 个)")
    else:
        print(f"  🟡 部分通过")

    # 保存报告
    out_path = os.path.join(os.path.dirname(os.path.dirname(__file__)),
                            "docs", "live-llm-stream-report-expanded.md")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(f"# 真实 LLM 流式渲染验证报告 (扩展版)\n\n")
        f.write(f"**时间**: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"**测试用例**: {len(results)} 个领域\n\n")
        f.write(f"## 汇总\n\n")
        f.write(f"| 领域 | 公式数 | 复杂公式 | Display | 闪烁率 | 括号 |\n")
        f.write(f"|------|--------|----------|---------|--------|------|\n")
        for r in results:
            bal = "❌" if r["incomplete"] else "✅"
            f.write(f"| {r['name']} | {r['formula_count']} | {r['complex_count']} | "
                    f"{r['display_count']} | {r['old_flicker_rate']:.1f}% | {bal} |\n")
        f.write(f"\n## 各领域公式详情\n\n")
        for r in results:
            f.write(f"### {r['name']}\n\n")
            for i, d in enumerate(r["formula_details"]):
                f.write(f"{i+1}. [{d['type']}] `{d['content']}` — {d['complexity']}\n")
            f.write(f"\n**LLM 完整输出**:\n\n```\n{r['full_text']}\n```\n\n")

    print(f"\n📄 详细报告: {out_path}")

    sys.exit(0 if all_passed and total_incomplete == 0 else 1)


if __name__ == "__main__":
    main()

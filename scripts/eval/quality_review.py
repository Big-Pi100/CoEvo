#!/usr/bin/env python3
"""
CoEvo 教学质量评审脚本 (质量评审脚本)
读取 E2E 测试日志，调用 LLM 做 6 维度评审，输出 markdown 报告。

用法:
  python scripts/eval/quality_review.py --run <run_id>
  python scripts/eval/quality_review.py --run eval_20260527_123839 --compare eval_20260527_120404

环境变量: DEEPSEEK_API_KEY (或 .env)
"""

import argparse
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

# ── 配置 ──
DATA_DIR = Path("backend/data/eval_runs")
API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")
API_URL = "https://api.deepseek.com/chat/completions"

DIMENSIONS = [
    ("教学点覆盖", "L2", "教师是否围绕 focus 展开，extra_points 是否在 focus 之后引入"),
    ("流程执行", "L2", "是否按 ①引文→②精读→③赏析→④主旨→⑤巩固 流程"),
    ("卡片利用", "L2", "是否有引用卡片中的全文/赏析/手法内容"),
    ("交互质量", "L2", "学生是否有深度互动，教师是否有效回应"),
    ("推进合规", "L1", "task 标记完成的时机是否合理，CP2 评估是否准确"),
    ("学段适应性", "L2", "教学语言、难度、深度是否符合该学段认知水平"),
    ("上下文纯净度", "L1", "教师输出的语言风格是否与学段匹配，有无上下文污染导致的跨学段风格错配"),
]

GRADE_BAND_RULES = {
    "g1-2": {
        "label": "小学低年级",
        "baseline": "短句、重复、游戏化、多感官教学",
        "bonus": "韵律感强、互动式教学",
        "penalty": "抽象术语、长复合句、要求书面化表达",
        "allowed": "具体名词、简单动词、颜色/声音词",
        "forbidden": "抽象概念（如'意象''暗喻''象征'）、学术术语",
    },
    "g3-4": {
        "label": "小学中年级",
        "baseline": "半结构化、有引导的分析",
        "bonus": "适度抽象但举例充分",
        "penalty": "跳过铺垫直接给结论",
        "allowed": "简单修辞概念（比喻、拟人）、因果关系",
        "forbidden": "解构主义、互文性等超纲术语",
    },
    "g5-6": {
        "label": "小学高年级",
        "baseline": "独立赏析、比较分析",
        "bonus": "引导自主发现",
        "penalty": "超纲术语",
        "allowed": "修辞手法分析、文章结构、主旨概括",
        "forbidden": "批判性理论术语",
    },
    "g7-9": {
        "label": "初中",
        "baseline": "正式文学赏析、手法分析",
        "bonus": "多角度独立解读",
        "penalty": "语言过于幼稚或过于学术",
        "allowed": "意象、铺垫、对比、象征、细节描写",
        "forbidden": "解构主义、互文性、能指/所指",
    },
    "g10-12": {
        "label": "高中",
        "baseline": "批判性阅读、深度思辨",
        "bonus": "跨文本比较",
        "penalty": "缺乏挑战性",
        "allowed": "文学批评视角、社会文化分析",
        "forbidden": "无（可以引入适当理论框架）",
    },
}


# ── LLM 调用 ──

def llm_call(system: str, user: str, temperature=0.0) -> str:
    if not API_KEY:
        return '{"error": "DEEPSEEK_API_KEY not set"}'
    payload = json.dumps({
        "model": "deepseek-v4-flash",
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": temperature,
        "max_tokens": 2000,
    }).encode()
    req = urllib.request.Request(
        API_URL, data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {API_KEY}",
        },
    )
    try:
        resp = urllib.request.urlopen(req, timeout=120)
        body = resp.read().decode()
        result = json.loads(body)
        return result["choices"][0]["message"]["content"]
    except Exception as e:
        return f'{{"error": "LLM call failed: {e}"}}'


# ── 静态分析 ──

def static_analysis(run_dir: Path) -> dict:
    """分析 plan_state 变化和关键词命中"""
    turns = sorted(
        [d for d in run_dir.iterdir() if d.name.startswith("turn_")],
        key=lambda d: d.name,
    )

    task_events = []  # [(turn, task_name, old_status, new_status)]
    card_keyword_hits = {}  # keyword → count per turn

    prev_plan = {}
    for t in turns:
        plan_file = t / "plan_state_before.json"
        if plan_file.exists():
            curr = json.loads(plan_file.read_text(encoding="utf-8"))
            # 对比 prev_plan → curr
            for task, status in curr.items():
                old = prev_plan.get(task, "unknown")
                if old != status:
                    task_events.append((t.name, task, old, status))
            prev_plan = curr

        # 关键词命中统计
        reply_file = t / "llm_reply_raw.txt"
        if reply_file.exists():
            text = reply_file.read_text(encoding="utf-8")
            keywords = [
                "比喻", "拟人", "排比", "夸张", "象征", "对比",
                "意象", "主旨", "手法", "赏析", "语言特色",
                "全文", "语句", "段落", "朗读",
            ]
            for kw in keywords:
                count = text.count(kw)
                if count > 0:
                    card_keyword_hits.setdefault(t.name, {})[kw] = count

    # 回复长度统计
    reply_stats = {}
    for t in turns:
        reply_file = t / "llm_reply_raw.txt"
        meta_file = t / "llm_metadata.json"
        if reply_file.exists():
            text = reply_file.read_text(encoding="utf-8")
            meta = json.loads(meta_file.read_text(encoding="utf-8")) if meta_file.exists() else {}
            reply_stats[t.name] = {
                "chars": len(text),
                "latency_ms": meta.get("latency_ms", 0),
            }

    return {
        "task_events": task_events,
        "keyword_hits": card_keyword_hits,
        "reply_stats": reply_stats,
        "total_turns": len(turns),
    }


# ── 逐轮评审 ──

def review_turn(turn_dir: Path, grade_band: str) -> dict:
    """对单轮对话做 LLM 评审"""
    meta_file = turn_dir / "meta.json"
    if not meta_file.exists():
        # 读取本轮的上下文文件
        plan_ctx = ""
        ctx_file = turn_dir / "plan_context.txt"
        if ctx_file.exists():
            plan_ctx = ctx_file.read_text(encoding="utf-8")[:1000]

        user_msg = ""
        user_file = turn_dir / "user.txt"
        if user_file.exists():
            user_msg = user_file.read_text(encoding="utf-8")[:800]

        teacher_reply = ""
        reply_file = turn_dir / "llm_reply_raw.txt"
        if reply_file.exists():
            teacher_reply = reply_file.read_text(encoding="utf-8")[:1500]

        plan_before = ""
        pb_file = turn_dir / "plan_state_before.json"
        if pb_file.exists():
            plan_before = pb_file.read_text(encoding="utf-8")

        plan_after = ""
        pa_file = turn_dir / "plan_state_after.json"
        if pa_file.exists():
            plan_after = pa_file.read_text(encoding="utf-8")
    else:
        plan_ctx = user_msg = teacher_reply = ""
        plan_before = plan_after = ""

    # 判断当前 session 使用的 prompt 类型
    if grade_band in ("g1-2", "g3-4"):
        is_nursery = "教学模式: nursery_rhyme" in plan_ctx
        prompt_type = "nursery" if is_nursery else "primary"
        expected_flow = "唱读→理解→输出→考核" if is_nursery else "引文→精读→输出→识字→考核"
    else:
        prompt_type = "secondary"
        expected_flow = "引文→精读→赏析→主旨→考核"

    gb_info = GRADE_BAND_RULES.get(grade_band, GRADE_BAND_RULES.get("g7-9", {}))

    system_prompt = f"""你是一位教学评估专家。请对语文课上的教学对话进行评审。

## 学段信息
- 当前学段：{gb_info.get('label', '?')}（{grade_band}）
- prompt 类型：{prompt_type}
- 预期教学流程：{expected_flow}

## 评审注意事项
- 进度管理由系统（CP2）自动处理，教师不使用任何 XML 标签。
  **不要因为教师没有手动标记完成而扣"推进合规"的分。**
- 考核阶段（最后一步）只出题让学生回答，不教新内容——这是正常的。
  **不要因为考核轮次缺少教学内容而扣"教学点覆盖"的分。**
- g1-2/g3-4 小学学段禁止使用抽象术语和手法分析。
  **不要要求小学学段教师使用"手法""意象""主旨"等术语。**
- 学段越低，交互越应以教师引导为主，学生跟读模仿为辅。
  **不要因为学生没有"深度追问"而扣低学段的交互质量分。**

## 评审维度（每项 0-100）

1. 教学点覆盖: 教师是否围绕核心教学点展开？（小学学段不要求"手法分析"、"主旨"等抽象概念）
2. 流程执行: 是否按该学段的预期流程教学？有无遗漏环节？
   - 小学（primary）：{expected_flow}
   - 中学（secondary）：引文→精读→赏析→主旨→考核
   - 考核轮次只有出题环节是正常的，不应视为"流程缺失"
3. 卡片利用: 教师是否引用了卡片中的原文、例句、易错点等具体教学内容？

   **⚠️ 重要：小学学段（primary, g1-2/g3-4）的 prompt 明确禁止使用"比喻、拟人、排比、象征、列举法"等手法/修辞术语名称。**
   - primary 学段的"卡片利用"评分依据：教师是否引用了卡片中的生字、词语、例句、画面描述、易错字提醒——**而不是手法名称或术语**
   - secondary 学段的"卡片利用"评分依据：教师是否引用了卡片中的原文、赏析语句、手法名称、主旨概括
   - 如果教师未使用任何卡片内容而完全自创教学，则扣分；如果使用了卡片中的具体内容但未使用术语名称，**不扣分**
4. 交互质量: 师生互动是否有效？
   - 低学段以教师引导为主是正常的
5. 推进合规: 进度管理由系统自动处理，教师不使用标签。
   **评分依据：plan_state 变化是否合理（由 CP2 评估），而不是教师是否手动标记。**
6. 学段适应性: 教学语言是否符合该学段认知水平？
7. 上下文纯净度: 教师的语言风格是否与该学段一致？有无跨学段污染？

## 学段要求（当前：{gb_info.get('label', '?')}）
- 基准要求：{gb_info.get('baseline', '')}
- 允许的抽象程度：{gb_info.get('allowed', '')}
- 禁止使用：{gb_info.get('forbidden', '')}

## 输出格式
只输出 JSON，格式：
{{
  "教学点覆盖": {{"score": 85, "evidence": "具体的引用和判断", "missing": "缺少的内容"}},
  "流程执行": {{"score": 75, "evidence": "...", "missing": "..."}},
  "卡片利用": {{"score": 80, "evidence": "...", "missing": "..."}},
  "交互质量": {{"score": 70, "evidence": "...", "missing": "..."}},
  "推进合规": {{"score": 90, "evidence": "...", "missing": "..."}},
  "学段适应性": {{"score": 85, "evidence": "...", "missing": "..."}},
  "上下文纯净度": {{"score": 80, "evidence": "...", "missing": "..."}}
}}"""

    user_prompt = f"""教学计划上下文（摘要）：
{plan_ctx}

学生发言：
{user_msg}

教师回复：
{teacher_reply}

Plan 状态变化：
前: {plan_before}
后: {plan_after}
"""

    if not teacher_reply or not user_msg:
        return {
            dim[0]: {"score": 0, "evidence": "无数据", "missing": "本轮无有效对话"}
            for dim in DIMENSIONS
        }

    raw = llm_call(system_prompt, user_prompt, temperature=0.0)
    # 提取 JSON — 先尝试整体 parse，再 fallback 到正则
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        pass
    try:
        m = re.search(r'\{[^{]*"教学点覆盖".*"上下文纯净度".*\}', raw, re.DOTALL)
        if not m:
            m = re.search(r'\{.*\}', raw, re.DOTALL)
        if m:
            return json.loads(m.group(0))
    except (json.JSONDecodeError, ValueError):
        pass
    return {
        dim[0]: {"score": 50, "evidence": f"解析失败: {raw[:100]}", "missing": "LLM 响应解析异常"}
        for dim in DIMENSIONS
    }


# ── 卡片分析 ──

def card_analysis(run_dir: Path) -> dict:
    """分析 Phase 2/3 数据：卡片导入 + 复习就绪度"""
    cards_summary_file = run_dir / "cards_summary.json"
    review_session_file = run_dir / "review_session.json"
    cards_imported_file = run_dir / "cards_imported.json"

    cards_data = {}
    if cards_summary_file.exists():
        cards_data = json.loads(cards_summary_file.read_text(encoding="utf-8"))
    elif review_session_file.exists():
        cards_data = {"total_cards": 0, "by_type": {}, "card_memory_records": 0}
    else:
        return {"status": "no_data", "total_cards": 0}

    total = cards_data.get("total_cards", 0)
    by_type = cards_data.get("by_type", {})
    memory = cards_data.get("card_memory_records", 0)
    expected = cards_data.get("expected_from_completed_tasks", {})

    # 卡片导入完整性评分
    completeness = 0
    exp_vocab = expected.get("vocab_card_ids", 0)
    exp_reading = expected.get("reading_card_id", 0)
    if exp_vocab > 0 or exp_reading > 0:
        actual_vocab = by_type.get("vocab", 0)
        actual_reading = by_type.get("reading", 0)
        # Simplified: count fields might use different names
        matched = min(1.0, total / max(1, exp_vocab + exp_reading))
        completeness = int(matched * 100)
    else:
        completeness = 100 if total > 0 else 0

    # 复习就绪度
    due_cards = 0
    sample_card = None
    if review_session_file.exists():
        rs = json.loads(review_session_file.read_text(encoding="utf-8"))
        due_cards = rs.get("total_due", 0)
        sample_card = rs.get("sample_card", None)

    readiness = min(100, int(due_cards / max(1, total) * 100) * 2) if total > 0 else 0

    # 卡片多样性
    type_count = len([v for v in by_type.values() if v > 0])
    diversity = min(100, type_count * 50)  # 2+ types → 100, 1 type → 50

    # 详细卡片列表
    imported_list = []
    if cards_imported_file.exists():
        imported_data = json.loads(cards_imported_file.read_text(encoding="utf-8"))
        imported_list = imported_data.get("cards", [])

    return {
        "status": "ok",
        "total_cards": total,
        "card_memory_records": memory,
        "by_type": by_type,
        "expected": expected,
        "due_cards": due_cards,
        "sample_card_front": sample_card.get("front", "") if isinstance(sample_card, dict) else "",
        "scores": {
            "卡片导入完整性": completeness,
            "复习就绪度": readiness,
            "卡片多样性": diversity,
        },
        "imported_list": imported_list[:5],  # 只保留前 5 张用作示例
    }


# ── 报告生成 ──

def generate_report(run_dir: Path, grade_band: str, subject: str, stats: dict, per_turn_reviews: list, card_info: dict = None) -> str:
    gb_info = GRADE_BAND_RULES.get(grade_band, {})

    # 聚合维度分数
    dim_scores = {d[0]: [] for d in DIMENSIONS}
    all_evidence = {d[0]: [] for d in DIMENSIONS}
    for review in per_turn_reviews:
        for dim in DIMENSIONS:
            dn = dim[0]
            if dn in review:
                val = review[dn]
                score = val.get("score", 0) if isinstance(val, dict) else (val if isinstance(val, (int, float)) else 0)
                dim_scores[dn].append(score)
                if isinstance(val, dict):
                    ev = val.get("evidence", "")
                    if ev and ev != "无数据":
                        all_evidence[dn].append(ev)

    avg_scores = {}
    for dn, scores in dim_scores.items():
        if scores:
            avg_scores[dn] = round(sum(scores) / len(scores), 1)
        else:
            avg_scores[dn] = 0

    # 推进合规门禁
    advance_events = [e for e in stats["task_events"] if e[3] == "done"]
    gate_pass = len(advance_events) > 0

    # 回复长度统计
    all_latency = [s["latency_ms"] for s in stats["reply_stats"].values()]
    avg_latency = round(sum(all_latency) / len(all_latency)) if all_latency else 0
    all_chars = [s["chars"] for s in stats["reply_stats"].values()]
    avg_chars = round(sum(all_chars) / len(all_chars)) if all_chars else 0
    total_chars = sum(all_chars)

    # 关键词统计
    total_keyword_hits = sum(
        sum(kwds.values()) for kwds in stats["keyword_hits"].values()
    )

    lines = []
    lines.append(f"# 教学质量评审报告 ({subject}·{gb_info.get('label', grade_band)})")
    lines.append("")
    lines.append(f"## 概览")
    lines.append(f"")
    lines.append(f"| 指标 | 值 |")
    lines.append(f"|:----|:---|")
    lines.append(f"| 轮次 | {stats['total_turns']} |")
    lines.append(f"| 任务交付数 | {len(advance_events)} |")
    lines.append(f"| 推进合规门禁 | {'✅ 通过' if gate_pass else '🔴 未通过'} |")
    lines.append(f"| 平均回复长度 | {avg_chars} chars |")
    lines.append(f"| 总回复字符 | {total_chars} chars |")
    lines.append(f"| 平均延迟 | {avg_latency} ms |")
    lines.append(f"| 卡片关键词总命中 | {total_keyword_hits} 次 |")
    lines.append(f"")

    # 卡片概览（Phase 2/3 数据）
    if card_info and card_info.get("status") == "ok":
        cs = card_info["scores"]
        lines.append(f"### 卡片与复习概览")
        lines.append(f"")
        lines.append(f"| 指标 | 值 |")
        lines.append(f"|:----|:---|")
        lines.append(f"| 卡片总数 | {card_info['total_cards']} |")
        lines.append(f"| card_memory 记录 | {card_info['card_memory_records']} |")
        lines.append(f"| 到期复习数 | {card_info['due_cards']} |")
        lines.append(f"| 卡片导入完整性 | {cs.get('卡片导入完整性',0)}/100 |")
        lines.append(f"| 复习就绪度 | {cs.get('复习就绪度',0)}/100 |")
        lines.append(f"| 卡片多样性 | {cs.get('卡片多样性',0)}/100 |")
        if card_info.get("by_type"):
            type_detail = " | ".join(f"{k}: {v}" for k, v in card_info["by_type"].items() if v > 0)
            lines.append(f"| 卡片类型分布 | {type_detail} |")
        if card_info.get("sample_card_front"):
            lines.append(f"| 示例卡片 | {card_info['sample_card_front'][:30]} |")
        if card_info.get("imported_list"):
            lines.append(f"| 已导入卡示例 | {' · '.join(c.get('front','')[:15] for c in card_info['imported_list'][:5])} |")
        lines.append(f"")

    lines.append(f"### 任务交付事件")
    lines.append(f"")
    for ev in advance_events:
        lines.append(f"- **{ev[0]}**: `{ev[1]}` → `{ev[3]}`")
    lines.append(f"")

    # 各维度评分
    lines.append(f"## 维度评分")
    lines.append(f"")
    lines.append(f"| 维度 | 评分 | 关键发现 |")
    lines.append(f"|:----|:---:|:---------|")
    for dn, score in avg_scores.items():
        evidence_list = all_evidence.get(dn, [])
        top_evidence = evidence_list[0] if evidence_list else "（无）"
        lines.append(f"| {dn} | {score}/100 | {top_evidence[:80]} |")
    lines.append(f"")

    # 详细证据
    lines.append(f"## 逐轮证据")
    lines.append(f"")
    for i, (review, turn_name) in enumerate(
        [(r, f"turn_{i+1:03d}") for i, r in enumerate(per_turn_reviews)]
    ):
        lines.append(f"### {turn_name}")
        lines.append(f"")
        lines.append(f"| 维度 | 评分 | 证据 | 缺失 |")
        lines.append(f"|:----|:---:|:-----|:-----|")
        for dn, ev in review.items():
            if isinstance(ev, dict):
                score = ev.get("score", 0)
                evidence = str(ev.get("evidence", ""))[:60]
                missing = str(ev.get("missing", ""))[:40]
            else:
                score = ev if isinstance(ev, (int, float)) else 0
                evidence = str(ev)[:60]
                missing = ""
            lines.append(f"| {dn} | {score} | {evidence} | {missing} |")
        lines.append(f"")

    # 优化建议
    lines.append(f"## Prompt 优化建议")
    lines.append(f"")
    lines.append(f"基于评审发现的共性问题，建议以下优化：")
    lines.append(f"")
    
    for dn, score in sorted(avg_scores.items(), key=lambda x: x[1]):
        if score < 70:
            severity = "🔴 P0"
        elif score < 80:
            severity = "⚠️ P1"
        else:
            severity = "✅ P2"
        evidence_list = all_evidence.get(dn, [])
        sample = evidence_list[0] if evidence_list else "（无具体证据）"
        lines.append(f"- **{severity} {dn} ({score}/100)**: {sample}")
        if evidence_list:
            lines.append(f"  - 建议：根据以上证据优化对应 prompt 指令")
    lines.append(f"")

    # 学段适应性专项
    if grade_band in GRADE_BAND_RULES:
        gb = GRADE_BAND_RULES[grade_band]
        ada_score = avg_scores.get("学段适应性", 0)
        lines.append(f"## 学段适应性专项")
        lines.append(f"")
        lines.append(f"当前学段：{gb['label']}")
        lines.append(f"")
        if ada_score < 70:
            lines.append(f"⚠️ 需要关注：教学语言的学段匹配度不足。")
            lines.append(f"- 避免使用：{gb.get('forbidden', '')}")
            lines.append(f"- 优先使用：{gb.get('allowed', '')}")
        else:
            lines.append(f"✅ 学段匹配度良好。")
        lines.append(f"")

    lines.append(f"---")
    lines.append(f"*报告生成于自动化评审流程*")
    
    return "\n".join(lines)


# ── 主入口 ──

def main():
    parser = argparse.ArgumentParser(description="CoEvo 教学质量评审")
    parser.add_argument("--run", required=True, help="eval 运行 ID（如 eval_20260527_123839）")
    parser.add_argument("--compare", help="对比运行 ID（可选）")
    parser.add_argument("--data-dir", default=DATA_DIR, help="数据目录路径")
    parser.add_argument("--api-key", help="DeepSeek API Key")
    args = parser.parse_args()

    global API_KEY
    if args.api_key:
        API_KEY = args.api_key
    elif not API_KEY:
        # 尝试 .env
        for p in [".env", "../.env", "../../.env"]:
            env_path = Path(p)
            if env_path.exists():
                for line in env_path.read_text().splitlines():
                    if line.startswith("DEEPSEEK_API_KEY="):
                        API_KEY = line.split("=", 1)[1].strip().strip('"').strip("'")

    data_dir = Path(args.data_dir)
    if not data_dir.exists():
        print(f"❌ 数据目录不存在: {data_dir}")
        sys.exit(1)

    # 查找所有匹配的 session 目录
    base_run = args.run
    sessions = []
    for d in data_dir.iterdir():
        if d.is_dir() and d.name.startswith(base_run):
            sessions.append(d)

    if not sessions:
        print(f"❌ 未找到匹配的 session 目录: {base_run} 在 {data_dir}")
        print(f"   可用目录: {[d.name for d in data_dir.iterdir() if d.is_dir()][:10]}")
        sys.exit(1)

    for session_dir in sorted(sessions):
        meta_file = session_dir / "meta.json"
        aggregate_file = session_dir / "aggregate.json"

        meta = json.loads(meta_file.read_text(encoding="utf-8")) if meta_file.exists() else {}
        grade_band = meta.get("grade_band", "g7-9")
        subject = meta.get("subject", "语文")

        print(f"\n{'='*60}")
        print(f"📊 评审: {session_dir.name}")
        print(f"   学段: {grade_band}")
        print(f"{'='*60}")

        # 1. 静态分析
        print(f"  🔍 静态分析...")
        stats = static_analysis(session_dir)
        print(f"     {stats['total_turns']} 轮, {len(stats['task_events'])} 次状态变更")

        # 2. 逐轮评审
        turns = sorted(
            [d for d in session_dir.iterdir() if d.name.startswith("turn_")],
            key=lambda d: d.name,
        )
        per_turn_reviews = []
        for i, tdir in enumerate(turns):
            print(f"  🤖 LLM 评审 turn_{i+1:03d}/{len(turns)}...")
            review = review_turn(tdir, grade_band)
            per_turn_reviews.append(review)
            if "推进合规" in review:
                cr = review["推进合规"]
                print(f"     教学点覆盖={review.get('教学点覆盖',{}).get('score','?')} "
                      f"流程执行={review.get('流程执行',{}).get('score','?')} "
                      f"推进合规={cr.get('score','?')}")

        # 3. 卡片分析（Phase 2/3 数据）
        print(f"  🃏 卡片分析...")
        card_info = card_analysis(session_dir)
        if card_info["status"] == "ok":
            scores = card_info["scores"]
            print(f"     {card_info['total_cards']} 张卡, 导入完整性={scores.get('卡片导入完整性',0)}, "
                  f"复习就绪度={scores.get('复习就绪度',0)}, 到期={card_info['due_cards']}")
        else:
            print(f"     无卡片数据")

        # 4. 生成报告
        report = generate_report(session_dir, grade_band, subject, stats, per_turn_reviews, card_info)
        report_path = data_dir / f"quality_report_{session_dir.name}.md"
        report_path.write_text(report, encoding="utf-8")
        print(f"  ✅ 报告已写入: {report_path}")

    # 对比模式（简单 diff）
    if args.compare:
        ref_runs = sorted(
            [d for d in data_dir.iterdir() if d.is_dir() and d.name.startswith(args.compare)],
        )
        cur_runs = sorted(sessions)
        if len(ref_runs) == len(cur_runs):
            print(f"\n📊 对比: {args.compare} vs {args.run}")
            for ref_dir, cur_dir in zip(ref_runs, cur_runs):
                ref_report = data_dir / f"quality_report_{ref_dir.name}.md"
                cur_report = data_dir / f"quality_report_{cur_dir.name}.md"
                if ref_report.exists() and cur_report.exists():
                    ref_text = ref_report.read_text(encoding="utf-8")
                    cur_text = cur_report.read_text(encoding="utf-8")
                    # 提取维度评分
                    ref_scores = re.findall(r'([\u4e00-\u9fff]+)\s*\|\s*(\d+\.?\d*)/100', ref_text)
                    cur_scores = re.findall(r'([\u4e00-\u9fff]+)\s*\|\s*(\d+\.?\d*)/100', cur_text)
                    if ref_scores and cur_scores:
                        print(f"\n  {ref_dir.name.replace(args.compare, '').strip('_')}:")
                        for (r_dim, r_score), (c_dim, c_score) in zip(ref_scores, cur_scores):
                            diff = float(c_score) - float(r_score)
                            arrow = "✅" if diff > 0 else ("❌" if diff < 0 else "—")
                            print(f"    {r_dim}: {r_score} → {c_score} ({diff:+.1f}) {arrow}")

    print(f"\n✅ 评审完成!")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
全量卡片质量评估脚本
对 chinese_reading_*.json 中的每张卡做 6 维度 LLM 评估，输出汇总报告。

用法: python3 scripts/eval/card_quality_eval.py
       python3 scripts/eval/card_quality_eval.py --sample 50  # 抽样
       python3 scripts/eval/card_quality_eval.py --report-only  # 只生成报告（不调用LLM）
"""
import json, sys, time, re, urllib.request, argparse
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from collections import Counter
sys.stdout.reconfigure(encoding='utf-8')

AK = open("backend/.env").read().strip().split("DEEPSEEK_API_KEY=")[1].split("\n")[0].strip().strip('"').strip("'")
CARD_DIR = Path("data/curriculum/prebuilt/cards")
OUTPUT_DIR = Path("docs/eval")

# 各文件配置
FILES = [
    {"path": "chinese_reading_primary.json",   "label": "小学课文"},
    {"path": "chinese_reading_extended.json",  "label": "拓展阅读"},
    {"path": "chinese_reading_missing.json",   "label": "补录课文"},
]

# 评估维度（每项使用 LLM 打分 0-100）
EVAL_DIMENSIONS = [
    "全文完整度",
    "赏析质量",
    "手法分析",
    "主旨概括",
    "易错提示",
    "整体质量",
]

# 结构评分（无需 LLM）
def structural_score(card: dict) -> dict:
    """基于字段存在的结构评分"""
    scores = {}
    issues = []
    
    # 必需字段
    required = ["card_type", "front", "full_text", "id", "level", "grade_band"]
    for f in required:
        if f not in card or not card[f]:
            issues.append(f"缺少字段: {f}")
    
    # 核心字段
    core_fields = ["appreciation", "technique", "theme", "common_mistakes"]
    present = sum(1 for f in core_fields if f in card and card[f])
    scores["core_fields"] = present * 25  # 每个25分，最高100
    
    if present < 4:
        missing = [f for f in core_fields if f not in card or not card[f]]
        issues.append(f"核心字段缺失: {missing}")
    
    # full_text 长度
    ft = card.get("full_text", "") or ""
    if len(ft) < 10:
        scores["full_text_len"] = 0
        issues.append("全文过短 (<10字)")
    elif len(ft) < 50:
        scores["full_text_len"] = 40
    elif len(ft) < 100:
        scores["full_text_len"] = 70
    else:
        scores["full_text_len"] = 100
    
    # 赏析/手法非空检查
    for f in ["appreciation", "technique"]:
        val = card.get(f, "")
        if isinstance(val, list):
            if len(val) == 0:
                scores[f"{f}_nonempty"] = 0
                issues.append(f"{f} 为空列表")
            elif any(len(s.strip()) < 5 for s in val):
                scores[f"{f}_nonempty"] = 60
                issues.append(f"{f} 有条目内容过短")
            else:
                scores[f"{f}_nonempty"] = 100
        elif isinstance(val, str):
            scores[f"{f}_nonempty"] = 80 if len(val.strip()) > 0 else 0
    
    # typo 检查
    if "common_mystakes" in card:
        issues.append("字段拼写错误: common_mystakes (应为 common_mistakes)")
    
    # 作者/背景（not required but good to have）
    author = card.get("author", "")
    background = card.get("background", "")
    scores["author_bg"] = 0
    if author:
        scores["author_bg"] += 50
    if background:
        scores["author_bg"] += 50
    
    total = sum(scores.values()) / max(len(scores), 1)
    return {
        "structural_score": round(total, 1),
        "details": scores,
        "issues": issues,
    }


def call_llm(prompt, max_tokens=1500, temperature=0.0):
    payload = json.dumps({
        "model": "deepseek-v4-flash",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temperature,
    }).encode()
    req = urllib.request.Request(
        "https://api.deepseek.com/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {AK}"},
    )
    for _ in range(3):
        try:
            resp = urllib.request.urlopen(req, timeout=120)
            return json.loads(resp.read().decode())["choices"][0]["message"]["content"]
        except Exception as e:
            time.sleep(5)
    return ""


def llm_evaluate_card(card: dict, label: str) -> dict:
    """使用 LLM 对单张卡片做内容质量评估"""
    name = card.get("front", "?")
    card_type = card.get("card_type", "?")
    ft = (card.get("full_text", "") or "")[:600]
    appreciation = card.get("appreciation", [])
    technique = card.get("technique", [])
    theme = card.get("theme", "")
    mistakes = card.get("common_mistakes", "")
    
    if isinstance(appreciation, str):
        appreciation = [appreciation]
    if isinstance(technique, str):
        technique = [technique]
    
    card_preview = f"""卡片名称: {name}
卡片类型: {card_type}
全文（前600字）: {ft[:600]}
赏析: {json.dumps(appreciation, ensure_ascii=False)}
手法: {json.dumps(technique, ensure_ascii=False)}
主旨: {theme}
易错点: {mistakes}
"""
    
    prompt = f"""你是一位语文教学评估专家。请评估以下学习卡片的质量，逐项打分（0-100）。

卡片信息：
{card_preview}

评估维度及标准：
1. **全文完整度**: 全文是否真实、完整，是否与卡片名称匹配？
2. **赏析质量**: 赏析是否引用原文具体语句？是否言之有物，而非泛泛而谈？
3. **手法分析**: 手法分析是否准确？是否符合文本实际？
4. **主旨概括**: 主旨是否精准概括核心思想？是否简洁明了（20字内为佳）？
5. **易错提示**: 易错点是否具体、有用？是否切中该课常见问题？
6. **整体质量**: 综合以上维度，这张卡片的整体质量如何？

只输出 JSON，格式：
{{
  "全文完整度": {{"score": 85, "reason": "简要理由"}},
  "赏析质量": {{"score": 80, "reason": "简要理由"}},
  "手法分析": {{"score": 75, "reason": "简要理由"}},
  "主旨概括": {{"score": 90, "reason": "简要理由"}},
  "易错提示": {{"score": 70, "reason": "简要理由"}},
  "整体质量": {{"score": 82, "reason": "简要理由"}}
}}
"""
    
    raw = call_llm(prompt, max_tokens=800)
    try:
        result = json.loads(raw)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", raw, re.DOTALL)
        if m:
            try:
                result = json.loads(m.group(0))
            except json.JSONDecodeError:
                result = {d: {"score": 50, "reason": f"解析失败: {raw[:80]}"} for d in EVAL_DIMENSIONS}
        else:
            result = {d: {"score": 50, "reason": f"LLM 返回格式异常"} for d in EVAL_DIMENSIONS}
    
    return result


def evaluate_all(cards: list, label: str, max_workers=5, sample=None):
    """评估所有卡片"""
    if sample and sample < len(cards):
        import random
        random.seed(42)
        cards = random.sample(cards, sample)
    
    results = []
    struct_scores = []
    
    # Phase 1: 结构评分（快）
    print(f"  📋 结构评分 {len(cards)} 张...")
    for c in cards:
        sr = structural_score(c)
        struct_scores.append(sr)
    
    avg_struct = round(sum(s["structural_score"] for s in struct_scores) / len(struct_scores), 1)
    all_issues = []
    for c, s in zip(cards, struct_scores):
        for iss in s.get("issues", []):
            all_issues.append(f"{c.get('front','?')}: {iss}")
    
    issue_counts = Counter(iss.split(":")[1].strip() if ":" in iss else iss for iss in all_issues)
    
    print(f"  🤖 LLM 内容质量评估 {len(cards)} 张 (5 并发)...")
    llm_scores = []
    
    def eval_one(card):
        return llm_evaluate_card(card, label)
    
    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        fs = {ex.submit(eval_one, c): c for c in cards}
        done = 0
        for f in as_completed(fs):
            card = fs[f]
            name = card.get("front", "?")
            try:
                result = f.result()
                llm_scores.append(result)
                
                # Print per-card result
                overall = result.get("整体质量", {}).get("score", 0)
                reasons = []
                for d in EVAL_DIMENSIONS:
                    r = result.get(d, {})
                    if isinstance(r, dict):
                        reasons.append(f"{d}={r.get('score', 0)}")
                print(f"    {name:12s} | {' '.join(reasons)}", flush=True)
            except Exception as e:
                llm_scores.append({d: {"score": 0, "reason": f"异常: {e}"} for d in EVAL_DIMENSIONS})
                print(f"    {name:12s} | ❌ 异常: {e}", flush=True)
            
            done += 1
    
    # Aggregate LLM scores
    dim_totals = {d: [] for d in EVAL_DIMENSIONS}
    for ls in llm_scores:
        for d in EVAL_DIMENSIONS:
            val = ls.get(d, {})
            score = val.get("score", 0) if isinstance(val, dict) else (val if isinstance(val, (int, float)) else 0)
            dim_totals[d].append(score)
    
    dim_avgs = {d: round(sum(v)/len(v), 1) for d, v in dim_totals.items() if v}
    
    # 低分卡片列表 (< 60)
    low_score_cards = []
    for c, ls in zip(cards, llm_scores):
        overall = ls.get("整体质量", {}).get("score", 50)
        if overall < 60:
            low_score_cards.append({
                "name": c.get("front", "?"),
                "id": c.get("id", "?"),
                "overall": overall,
                "weak_dims": [(d, ls.get(d, {}).get("score", 0)) for d in EVAL_DIMENSIONS[:-1] 
                             if isinstance(ls.get(d, {}), dict) and ls[d].get("score", 0) < 60]
            })
    
    return {
        "label": label,
        "total": len(cards),
        "avg_structural": avg_struct,
        "avg_llm": dim_avgs,
        "issue_counts": dict(issue_counts.most_common(15)),
        "all_issues": all_issues,
        "low_score_cards": low_score_cards,
        "struct_scores": struct_scores,
    }


def generate_report(results: list):
    """生成综合报告 Markdown"""
    lines = []
    lines.append("# 卡片质量评估报告")
    lines.append(f"")
    lines.append(f"生成时间: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"")
    
    # 总览表
    lines.append("## 总览")
    lines.append("")
    lines.append("| 文件 | 卡片数 | 结构评分 | 全文完整度 | 赏析质量 | 手法分析 | 主旨概括 | 易错提示 | 整体质量 |")
    lines.append("|:----|:----:|:-------:|:--------:|:-------:|:-------:|:-------:|:-------:|:-------:|")
    
    all_low = []
    for r in results:
        l = r["label"]
        n = r["total"]
        s = r["avg_structural"]
        d = r["avg_llm"]
        lines.append(f"| {l} | {n} | {s} | {d.get('全文完整度', '-')} | {d.get('赏析质量', '-')} | "
                     f"{d.get('手法分析', '-')} | {d.get('主旨概括', '-')} | "
                     f"{d.get('易错提示', '-')} | {d.get('整体质量', '-')} |")
        all_low.extend(r.get("low_score_cards", []))
    
    lines.append("")
    
    # 整体平均
    lines.append("### 综合平均")
    lines.append("")
    all_avg = {}
    for d in EVAL_DIMENSIONS:
        vals = []
        for r in results:
            if d in r.get("avg_llm", {}):
                vals.append(r["avg_llm"][d])
        all_avg[d] = round(sum(vals)/len(vals), 1) if vals else 0
    lines.append("| 维度 | 平均分 |")
    lines.append("|:----|:-----:|")
    for d, v in all_avg.items():
        bar = "🟢" if v >= 80 else ("🟡" if v >= 60 else "🔴")
        lines.append(f"| {d} | {bar} {v} |")
    lines.append("")
    
    # 低分卡片
    lines.append("## 低分卡片（整体 < 60）")
    lines.append("")
    if all_low:
        lines.append(f"共 {len(all_low)} 张：")
        lines.append("")
        lines.append("| 卡片 | 文件 | 整体分 | 薄弱维度 |")
        lines.append("|:----|:----|:-----:|:---------|")
        for lc in all_low:
            weak = "; ".join(f"{d}({s})" for d, s in lc["weak_dims"])
            source = ""
            for r in results:
                if any(c["id"] == lc["id"] for c in r.get("low_score_cards", [])):
                    source = r["label"]
            lines.append(f"| {lc['name']} | {source} | {lc['overall']} | {weak} |")
    else:
        lines.append("🎉 无低分卡片！")
    lines.append("")
    
    # 常见问题
    lines.append("## 常见问题")
    lines.append("")
    all_issue_counts = Counter()
    for r in results:
        for iss, cnt in r.get("issue_counts", {}).items():
            all_issue_counts[iss] += cnt
    if all_issue_counts:
        lines.append("| 问题 | 出现次数 |")
        lines.append("|:----|:-------:|")
        for iss, cnt in all_issue_counts.most_common(20):
            lines.append(f"| {iss} | {cnt} |")
    lines.append("")
    
    # 逐文件详情
    lines.append("## 逐文件详情")
    lines.append("")
    for r in results:
        lines.append(f"### {r['label']} ({r['total']} 张)")
        lines.append("")
        lines.append(f"- 结构平均分: {r['avg_structural']}")
        lines.append(f"- 低分卡片: {len(r['low_score_cards'])} 张")
        
        low_list = r.get("low_score_cards", [])
        if low_list:
            lines.append("")
            lines.append("| 卡片 | 整体分 | 薄弱维度 |")
            lines.append("|:----|:-----:|:---------|")
            for lc in low_list:
                weak = "; ".join(f"{d}({s})" for d, s in lc["weak_dims"])
                lines.append(f"| {lc['name']} | {lc['overall']} | {weak} |")
        
        issues = r.get("all_issues", [])
        if issues:
            lines.append("")
            lines.append(f"**常见问题（前10）**:")
            ic = Counter(iss.split(": ")[-1] if ": " in iss else iss for iss in issues)
            for iss, cnt in ic.most_common(10):
                lines.append(f"- {iss} ({cnt}次)")
        
        lines.append("")
    
    lines.append("---")
    lines.append("*报告由 card_quality_eval.py 自动生成*")
    
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="CoEvo 卡片质量评估")
    parser.add_argument("--sample", type=int, help="每文件抽样数（用于快速验证）")
    parser.add_argument("--file", type=str, help="仅评估指定文件（如 primary/extended/missing）")
    parser.add_argument("--report-only", action="store_true", help="仅从已有数据生成报告")
    args = parser.parse_args()
    
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    
    all_results = []
    
    for f_info in FILES:
        fp = CARD_DIR / f_info["path"]
        if not fp.exists():
            print(f"❌ 文件不存在: {fp}")
            continue
        
        # 文件过滤
        if args.file:
            file_key = f_info["path"].replace("chinese_reading_", "").replace(".json", "")
            if args.file not in file_key:
                continue
        
        data = json.loads(fp.read_text(encoding="utf-8"))
        cards = data.get("cards", data)
        if isinstance(cards, dict):
            cards = list(cards.values())
        
        label = f_info["label"]
        print(f"\n{'='*60}")
        print(f"📊 评估: {label} ({len(cards)} 张)")
        print(f"{'='*60}")
        
        result = evaluate_all(cards, label, sample=args.sample)
        all_results.append(result)
        
        print(f"\n  ✅ {label} 评估完成")
        print(f"     结构分: {result['avg_structural']}")
        print(f"     LLM 整体质量: {result['avg_llm'].get('整体质量', '?')}")
        print(f"     低分卡片: {len(result['low_score_cards'])}")
    
    # 保存中间结果
    for r in all_results:
        label = r["label"]
        data_path = OUTPUT_DIR / f"card_scores_{label}.json"
        json.dump(r, open(data_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2, default=str)
        print(f"  💾 中间结果已保存: {data_path}")

    # 生成报告
    report = generate_report(all_results)
    report_path = OUTPUT_DIR / "card_quality_report.md"
    report_path.write_text(report, encoding="utf-8")
    
    print(f"\n{'='*60}")
    print(f"✅ 评估完成！报告已写入: {report_path}")
    print(f"{'='*60}")
    
    # 保存完整原始数据
    data_path = OUTPUT_DIR / "card_quality_scores.json"
    json.dump(all_results, open(data_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2, default=str)
    print(f"📊 原始分数已保存: {data_path}")


if __name__ == "__main__":
    main()

"""
Prompt A/B test: compare different task name instructions for plan creation.
Runs 5 variants in parallel against the same dialogue context.
"""
import json, os, requests, time, sys
from concurrent.futures import ThreadPoolExecutor, as_completed

API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")
if not API_KEY:
    try:
        with open(r"E:\CoEvo\backend\.env") as f:
            for line in f:
                if "DEEPSEEK_API_KEY" in line:
                    API_KEY = line.split("=", 1)[1].strip().strip('"\'')
                    break
    except: pass

BASE_URL = "https://api.deepseek.com/v1"

# ── 固定的 prompt 基座（除 task name 指令外完全相同） ──
PROMPT_BASE = """根据以下师生对话，为学生制定一个详细的学习计划。

对话：
{dialogue_text}

请输出 JSON 格式的学习计划，包含：
- goal: 简洁的学习目标（**15字以内**，概括即可）
- stages: 阶段数组，每个阶段包含 name、tasks 数组
- 每项 task 包含 name、description
- completed_concepts: []
- current_task_complete: false
- next_stage_suggestion: null

{name_instruction}

根据对话内容生成覆盖完整学习路径的计划，按合理粒度拆分阶段和任务。

只返回 JSON，不要加其他文字：
{{"is_new_plan": true, "goal": "...", "domain": "...", "stages": [...], "completed_concepts": [], "current_task_complete": false, "next_stage_suggestion": null}}

关于 domain 字段：
- "science": 物理、化学、生物、数学、地理、信息技术等自然科学
- "language": 语言类（英文、中文、日文等）的词汇、语法、发音学习
- "literature": 文学类（诗歌、散文、小说、寓言等）的赏析与理解
- "humanities": 历史、政治等社会科学
- 根据对话内容选择最合适的 domain，不要自造 domain 值"""

# ── 对话历史（道德经81篇章节目录） ──
DIALOGUE = """学生: 我需要帛书版道德经的章节目录
教师: 帛书版《道德经》也叫《老子帛书》，1973年在湖南长沙马王堆汉墓出土，是目前最接近原貌的版本。它与通行本（王弼本）在篇章结构和文字上有较大差异。
---
帛书版分为《德经》（上篇）和《道经》（下篇），共81章，但编排顺序和王弼本不同。核心区别：
- 帛书版：《德经》在前（上篇）、《道经》在后（下篇）
- 通行本：《道经》在前（上篇）、《德经》在后（下篇）

帛书版81章结构：
《德经》（第1章～第44章）：
第1章对应通行本第38章：上德不德
第2章对应通行本第39章：昔之得一者
第3章对应通行本第40章：反者道之动
第4章对应通行本第41章：上士闻道
第5章对应通行本第42章：道生一
第6章对应通行本第43章：天下之至柔
第7章对应通行本第44章：名与身孰亲
第8章对应通行本第45章：大成若缺
第9章对应通行本第46章：天下有道
第10章对应通行本第47章：不出户
（以下略，共44章）

《道经》（第45章～第81章）：
第45章对应通行本第1章：道可道非常道
第46章对应通行本第2章：天下皆知美之为美
第47章对应通行本第3章：不尚贤
第48章对应通行本第4章：道冲
第49章对应通行本第5章：天地不仁
第50章对应通行本第6章：谷神不死
（以下略，共38章）
---
学生: 每一篇章作为一个独立的阶段，给出完整的按章节的学习计划"""

# ── 5 种不同的 task name 指令 ──
VARIANTS = {
    "A-禁止编号": """- 每项 task 包含 name、description。name 必须描述该 task 的核心学习内容（如"配方法"、"现在完成时"）。name 中禁止出现任何序号、章节编号、书目名称、页码范围、括号引用。注意：上面的对话历史中有章节目录，但那只作为上下文参考，不要直接复制其中的编号作为名称。用你自己的知识为每个章节提炼主题名称""",

    "B-强制标题": """- 每项 task 包含 name、description。name 必须是该章节最具代表性的**内容标题或核心概念**（如"道可道非常道"、"上德不德"），而不是"第X章"之类的定位描述。如果对话历史中有"上德不德"这类标题，直接用它们作为 name。如果你不知道某章节的具体标题，用该章节的核心哲学概念作为名称（如"无为"、"反者道动"）。严格禁止在 name 中使用数字""",

    "C-样例对照": """- 每项 task 包含 name、description。
✗ 错误示例（不要这样写）："第38章"、"德经第1章"、"Lesson 3"、"第二章"
✓ 正确示例（请这样写）："上德不德"、"反者道之动"、"大成若缺"、"道可道非常道"
规则：如果对话历史中提到了章节的正式标题（如"上德不德"是第38章的标题），请使用那个标题作为 name。不要添加数字和编号""",

    "D-摘要策略": """- 每项 task 包含 name、description。name 应该用 2-8 个字的精炼短语概括该 task 的**哲学主题**（如"无为而治"、"上善若水"、"大智若愚"）。禁止使用任何数字。从对话历史中提取章节标题（如"上德不德"、"反者道之动"）作为 name。如果对话中没有给出某章的标题，用你自己的知识为该章提炼一个 2-6 字的核心概念作为名称""",

    "E-角色扮演": """- name 的命名规则是整个输出中**最重要的规则**，优先级高于其他所有指令：
规则：name 必须是描述该章核心哲学思想的**实质性名称**（如"上德不德"、"道可道非常道"、"大成若缺"），不能包含任何数字、编号、序号。想象你是一位语文老师，你给学生布置学习任务时，任务名称一定是"今天我们学《上德不德》"而不是"今天我们学第38章"。
违反这条规则会导致整个计划无效。请严格遵守。""",
}

def call_api(prompt: str, variant_name: str) -> dict:
    """Call DeepSeek API with the given prompt."""
    t0 = time.time()
    try:
        resp = requests.post(
            f"{BASE_URL}/chat/completions",
            headers={
                "Authorization": f"Bearer {API_KEY}",
                "Content-Type": "application/json"
            },
            json={
                "model": "deepseek-v4-flash",
                "messages": [{"role": "user", "content": prompt}],
                "max_tokens": 65536,
                "temperature": 0.5,
            },
            timeout=120
        )
        elapsed = time.time() - t0
        if resp.status_code != 200:
            return {"variant": variant_name, "error": f"HTTP {resp.status_code}: {resp.text[:200]}", "elapsed": elapsed}
        
        data = resp.json()
        content = data["choices"][0]["message"]["content"]
        
        # Extract JSON
        json_start = content.find('{')
        json_end = content.rfind('}') + 1
        if json_start >= 0 and json_end > json_start:
            plan = json.loads(content[json_start:json_end])
            
            # Extract all task names
            task_names = []
            for s in plan.get("stages", []):
                for t in s.get("tasks", []):
                    task_names.append(t.get("name", ""))
            
            # Count bad names (containing numbers)
            bad_names = [n for n in task_names if any(c.isdigit() for c in n)]
            good_names = [n for n in task_names if not any(c.isdigit() for c in n)]
            
            return {
                "variant": variant_name,
                "elapsed": round(elapsed, 1),
                "total_tasks": len(task_names),
                "bad_names": len(bad_names),
                "good_names": len(good_names),
                "bad_examples": bad_names[:5],
                "good_examples": good_names[:5],
                "all_names": task_names,
                "plan": plan,
            }
        else:
            return {"variant": variant_name, "error": f"No JSON found in response", "elapsed": elapsed}
    except Exception as e:
        return {"variant": variant_name, "error": str(e), "elapsed": time.time() - t0}

def main():
    results = {}
    
    with ThreadPoolExecutor(max_workers=5) as executor:
        futures = {}
        for name, instruction in VARIANTS.items():
            prompt = PROMPT_BASE.format(dialogue_text=DIALOGUE, name_instruction=instruction)
            futures[executor.submit(call_api, prompt, name)] = name
        
        for future in as_completed(futures):
            name = futures[future]
            result = future.result()
            results[name] = result
    
    # 排序打印
    print("\n" + "="*80)
    print("PROMPT A/B TEST RESULTS")
    print("="*80)
    
    # 按 bad_names 排序
    sorted_results = sorted(
        results.values(),
        key=lambda r: r.get("bad_names", 999) if "bad_names" in r else 999
    )
    
    for r in sorted_results:
        if "error" in r:
            print(f"\n[{r['variant']}] ❌ ERROR: {r['error']} ({r['elapsed']}s)")
        else:
            badge = "✅" if r["bad_names"] == 0 else "⚠️"
            print(f"\n[{r['variant']}] {badge} {r['total_tasks']} tasks, "
                  f"{r['bad_names']} bad / {r['good_names']} good ({r['elapsed']}s)")
            if r["bad_examples"]:
                print(f"   Bad examples: {r['bad_examples']}")
            if r["good_examples"]:
                print(f"   Good examples: {r['good_examples']}")
    
    # 完整输出
    print("\n" + "="*80)
    print("DETAILED TASK NAMES BY VARIANT")
    print("="*80)
    for name in sorted(results.keys()):
        r = results[name]
        if "error" not in r:
            print(f"\n--- {name} ---")
            for n in r["all_names"][:10]:
                marker = "❌" if any(c.isdigit() for c in n) else "✅"
                print(f"  {marker} {n}")
            if len(r["all_names"]) > 10:
                print(f"  ... and {len(r['all_names'])-10} more")
    
    # Summary
    print("\n" + "="*80)
    print("SUMMARY (sorted by bad count)")
    print("="*80)
    for r in sorted_results:
        if "error" not in r:
            print(f"  {r['variant']:20s}: {r['bad_names']:2d} bad / {r['good_names']:2d} good  "
                  f"({r['elapsed']:4.1f}s)")
    
    # Save full results
    output_path = r"E:\CoEvo\tmp\prompt_ab_results.json"
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print(f"\nFull results saved to: {output_path}")

if __name__ == "__main__":
    main()

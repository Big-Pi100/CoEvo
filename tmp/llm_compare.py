"""
LLM 消息结构 vs max_tokens 对照实验
比较4种组合的 LLM 回复，找出导致 79855 字符退化的根因
"""
import json
import requests
import time

API_KEY = "sk-***REDACTED***"
BASE_URL = "https://api.deepseek.com"  # deepseek API
MODEL = "deepseek-v4-flash"

def load_prompt():
    """Read and assemble the free mode system prompt the same way the Rust code does"""
    parts = []
    
    # Main: chat/general/free.md
    with open(r"E:\CoEvo\backend\prompts\chat\general\free.md", "r", encoding="utf-8") as f:
        parts.append(f.read())
    
    # Signal: chat/general/signal/free.md
    with open(r"E:\CoEvo\backend\prompts\chat\general\signal\free.md", "r", encoding="utf-8") as f:
        signal = f.read().strip()
        if signal:
            parts.append(signal)
    
    # Format: chat/general/format/free.md -> includes latex.md + graph.md + plan-marker.md
    def resolve_includes(text):
        import re
        result = text
        loop_count = 0
        while True:
            before = result
            def replacer(m):
                path = m.group(1)
                full_path = rf"E:\CoEvo\backend\prompts\{path}"
                try:
                    with open(full_path, "r", encoding="utf-8") as f:
                        return f.read()
                except:
                    return f"<!-- include {path} not found -->"
            result = re.sub(r"\{include:([^}]+)\}", replacer, result)
            if result == before or loop_count > 10:
                break
            loop_count += 1
        return result
    
    format_path = r"E:\CoEvo\backend\prompts\chat\general\format\free.md"
    with open(format_path, "r", encoding="utf-8") as f:
        format_raw = f.read().strip()
        if format_raw:
            parts.append(resolve_includes(format_raw))
    
    return "\n\n".join(parts)

def call_llm(system_prompt, user_content, max_tokens):
    """Call LLM API and return response text"""
    url = f"{BASE_URL}/chat/completions"
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json"
    }
    body = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_content}
        ],
        "stream": False,  # non-streaming for simplicity
        "max_tokens": max_tokens,
        "temperature": 0.7,
    }
    
    resp = requests.post(url, headers=headers, json=body, timeout=120)
    resp.raise_for_status()
    data = resp.json()
    return data["choices"][0]["message"]["content"]

def main():
    print("Loading system prompt...")
    system_prompt = load_prompt()
    print(f"System prompt length: {len(system_prompt)} chars / ~{len(system_prompt)//4} tokens")
    print(f"System prompt preview: {system_prompt[:200]}...")
    print()
    
    # 4 combinations
    experiments = [
        ("A-old-wrap-4096",  "\n\n### 当前对话\n用户: 道德经", 4096),
        ("B-old-wrap-65536", "\n\n### 当前对话\n用户: 道德经", 65536),
        ("C-new-bare-4096",  "道德经", 4096),
        ("D-new-bare-65536", "道德经", 65536),
    ]
    
    results = []
    for label, user_content, max_tok in experiments:
        print(f"▶ {label}: user_content={repr(user_content[:50])}, max_tokens={max_tok}")
        try:
            start = time.time()
            reply = call_llm(system_prompt, user_content, max_tok)
            elapsed = time.time() - start
            reply_len = len(reply)
            
            # Check for repetitive content
            # Sample first 200 and last 200 chars
            first_200 = reply[:200]
            last_200 = reply[-200:] if reply_len > 400 else ""
            
            # Detect repetition: check if any 50-char segment appears 3+ times
            import re
            segments = [reply[i:i+50] for i in range(0, len(reply)-50, 25)]
            from collections import Counter
            seg_counts = Counter(segments)
            most_common = seg_counts.most_common(3)
            
            result = {
                "label": label,
                "user_content_len": len(user_content),
                "max_tokens": max_tok,
                "reply_len": reply_len,
                "elapsed_sec": round(elapsed, 1),
                "first_200": first_200.replace("\n", "\\n"),
                "last_200": last_200.replace("\n", "\\n"),
                "most_repeated_segment": [(seg.replace("\n", "\\n")[:60], cnt) for seg, cnt in most_common if cnt > 1],
            }
            results.append(result)
            
            print(f"  ✅ reply_len={reply_len} chars, {elapsed:.1f}s")
            if result["most_repeated_segment"]:
                print(f"  ⚠️  Repeated segments detected:")
                for seg, cnt in result["most_repeated_segment"]:
                    print(f"     '{seg[:60]}...' × {cnt}")
            print(f"  First 100: {first_200[:100]}...")
            print()
            
            # Rate limit buffer
            time.sleep(2)
            
        except Exception as e:
            print(f"  ❌ Error: {e}")
            results.append({
                "label": label,
                "error": str(e)
            })
            print()
    
    # Summary
    print("=" * 60)
    print("RESULTS SUMMARY")
    print("=" * 60)
    for r in results:
        if "error" in r:
            print(f"{r['label']}: ERROR - {r['error']}")
        else:
            anomaly = "⚠️ REPETITIVE" if r["most_repeated_segment"] else "normal"
            print(f"{r['label']}: {r['reply_len']} chars in {r['elapsed_sec']}s [{anomaly}]")
    
    # Determine root cause
    print()
    print("=" * 60)
    print("ROOT CAUSE ANALYSIS")
    print("=" * 60)
    
    # Get the 4 results by label
    r_a = next((r for r in results if r["label"].startswith("A")), None)
    r_b = next((r for r in results if r["label"].startswith("B")), None)
    r_c = next((r for r in results if r["label"].startswith("C")), None)
    r_d = next((r for r in results if r["label"].startswith("D")), None)
    
    if all(r and "error" not in r for r in [r_a, r_b, r_c, r_d]):
        print()
        if r_a["most_repeated_segment"] and not r_b["most_repeated_segment"]:
            print("→ root cause: ??? (inconsistent)")
        elif r_b["most_repeated_segment"] and not r_a["most_repeated_segment"]:
            print("→ root cause: max_tokens=65536 (with old wrapping, the issue appears)")
        elif r_c["most_repeated_segment"] and not r_a["most_repeated_segment"]:
            print("→ root cause: messages structure (bare '道德经' causes issue even at 4096)")
        elif r_d["most_repeated_segment"] and not r_c["most_repeated_segment"]:
            print("→ root cause: max_tokens=65536 (new structure only at 65536)")
        elif r_d["most_repeated_segment"] and not r_a["most_repeated_segment"]:
            print("→ root cause: both factors combined (neither alone causes it, but together they do)")
        else:
            print("→ See individual results above")
    
    # Save full results
    with open(r"E:\CoEvo\tmp\llm_compare_results.json", "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print()
    print("Full results saved to tmp/llm_compare_results.json")

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Add task completion signal instruction to all chat_system prompt files."""
import os, glob

SIGNAL = """
### 任务完成信号

当整个学习任务全部教学完成后，必须明确输出完成信号，以便系统自动推进学习计划。
请自然地说：`{任务名称}`学习已经完成

例如：
- 课文《我是中国人》学完后 → "《我是中国人》学习已经完成"
- 数学「集合的概念与表示」学完后 → "集合的概念与表示学习已经完成"
- 英语「现在完成时」学完后 → "现在完成时学习已经完成"

注意：只有整个任务/课文全部完成才能输出此信号。小测验中偶尔的"通过""回答正确"等不算完成任务。
"""

PROMPTS_DIR = "E:/CoEvo/backend"

files = glob.glob(f"{PROMPTS_DIR}/prompts/chat_system*.md") + \
         glob.glob(f"{PROMPTS_DIR}/pipelines/*/prompts/chat_system*.md")

for fp in sorted(files):
    with open(fp, "r", encoding="utf-8") as f:
        content = f.read()
    
    # Skip files that already have the signal
    if "任务完成信号" in content:
        print(f"SKIP (already has): {fp}")
        continue
    
    # Add before the last line or at the end
    # Find the last ❌ or ✅ line
    lines = content.split("\n")
    
    # Check if file has "不要使用任何 XML 标签" section
    if "XML 标签" in content or "XML tag" in content.lower():
        # Add before the XML restriction line
        insert_pos = content.rfind("❌ 不要使用任何 XML 标签")
        if insert_pos == -1:
            # Find any ❌ or ✅ line
            for marker in ["❌ 不要创建", "❌ 不要使用", "✅ 所有课文"]:
                pos = content.rfind(marker)
                if pos > 0:
                    insert_pos = pos
                    break
        
        if insert_pos > 0:
            # Find the end of that line
            eol = content.find("\n", insert_pos)
            if eol > 0:
                new_content = content[:eol] + "\n" + SIGNAL.strip() + "\n" + content[eol:]
            else:
                new_content = content + "\n" + SIGNAL.strip()
        else:
            new_content = content + "\n" + SIGNAL.strip()
    else:
        new_content = content + "\n" + SIGNAL.strip()
    
    with open(fp, "w", encoding="utf-8") as f:
        f.write(new_content)
    print(f"UPDATED: {fp}")

print("\nDone!")

"""
Send the COMPLETE reconstructed context to deepseek API and see response.
"""
import json
import requests

API_KEY = "sk-***REDACTED***"
BASE_URL = "https://api.deepseek.com"
MODEL = "deepseek-v4-flash"

SYSTEM_PROMPT = """你是一个AI学习助手。用户的目的是在对话中学习新知识。
请用中文回复，保持友好和启发性的对话风格。
如果用户问了问题，确保解释清楚。

### 学习计划管理

如果用户在对话中表达了明确的学习目标（如"我想学XX"、"目标是做XX"），可以在回复尾部询问是否需要制定学习计划。示例：
  "要不要我帮你制定一个学习计划？这样我们可以更有条理地一步步推进。"

如果用户同意，为用户制定结构化的学习计划。**不需要输出任何 JSON 或 XML 标签**——系统会自动根据你的教学内容创建学习计划并推进进度。

**重要：当用户确认要制定学习计划时，在你的回复末尾加上下面这个标记**（不要包含在代码块中）：

```
**Goal学习计划创建✅ 已完成**
```

系统检测到上述标记后将立即创建学习计划并从第一阶段开始推进。标记中的学习目标名称是固定的，实际目标由你前面对话中与用户商定的内容决定。

### 数学公式

如果回复中包含数学公式，使用 LaTeX 语法并遵循以下规则：
- 行内公式用 \(公式\) 包裹
- 独立公式用 \[公式\] 包裹
- 公式内使用标准 LaTeX 命令

### 图形绘制

当需要可视化数学函数、几何图形、数据趋势时，用 <graph> 标签插入绘图 JSON。

**支持的图形类型：**
| type | 用途 | 必填字段 | 数据格式 |
|------|------|---------|---------|
| line | 函数图像/折线图 | type, data | [{"x":-3,"y":9}, ...] |
| bar | 柱状图 | type, data | [{"label":"A","value":10}, ...] |
| scatter | 散点图 | type, data | [{"x":1.2,"y":3.4}, ...] |
| pie | 扇形统计图 | type, data | [{"label":"A","value":15}, ...] |
| polygon | 多边形/三角形 | type, points | [{"x":0,"y":0}, ...] |
| circle | 圆形/弧 | type, center, radius | center={"x","y"} + radius |

注意：JSON 必须原样夹在 <graph> 和 </graph> 之间，禁止用 ```json 代码块包裹。

**重要：当用户确认要制定学习计划时，在你的回复末尾加上下面这个标记**（不要包含在代码块中）：

```
**Goal学习计划创建✅ 已完成**
```

系统检测到上述标记后将立即创建学习计划并从第一阶段开始推进。

**goal
✅ 已完成
<plan_update>
<reading_update>"""

def main():
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": "道德经"},
        {"role": "assistant", "content": "《道德经》是春秋时期老子（李耳）所著的哲学经典，也是道家思想的根本经典，共81章，约5000字。它虽然简短，但蕴含的智慧极其深邃，对中国文化、哲学、政治乃至世界思想都产生了巨大影响。\n\n### 核心思想可以用三个关键词概括：**道、德、自然无为**\n\n1. **道**：这是《道德经》的最高概念。它不是指具体的事物或道路，而是指宇宙万物的本源、规律和运行法则。\n\n2. **德**：可以理解为「得到」了道之后，所展现出来的品格和行为。\n\n3. **自然无为**：不是什么都不做，而是不妄为、不强行干预。\n\n💡 你是想了解《道德经》的整体思想，还是想从某个具体章节开始深入学习？要不要我帮你制定一个简单的阅读计划？"},
        {"role": "user", "content": "我需要道德经全部章节"},
        {"role": "assistant", "content": "好的！《道德经》共81章，传统上分为**上篇《道经》（第1-37章）**和**下篇《德经》（第38-81章）**。\n\n以下是完整目录（第1-40章）：\n\n**第一章**\n道可道，非常道；名可名，非常名。\n\n**第二章**\n天下皆知美之为美，斯恶已。\n\n...（全部40章原文）...\n\n**第四十章**\n反者道之动，弱者道之用。天下万物生于有，有生于无。\n\n---\n（第41-81章将在下一条回复中继续）"},
        {"role": "user", "content": "继续"},
    ]
    
    url = f"{BASE_URL}/chat/completions"
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json"
    }
    body = {
        "model": MODEL,
        "messages": messages,
        "stream": False,
        "max_tokens": 65536,
        "temperature": 0.7,
    }
    
    print(f"Sending {len(messages)} messages:")
    for i, m in enumerate(messages):
        role = m["role"]
        content = m["content"]
        print(f"  [{i}] {role}: {len(content)} chars, preview: {content[:80]}...")
    print()
    
    resp = requests.post(url, headers=headers, json=body, timeout=120)
    resp.raise_for_status()
    data = resp.json()
    reply = data["choices"][0]["message"]["content"]
    
    print(f"=== LLM Reply ===")
    print(f"Length: {len(reply)} chars")
    print(f"Content:\n{reply}")

if __name__ == "__main__":
    main()

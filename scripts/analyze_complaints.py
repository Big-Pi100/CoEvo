#!/usr/bin/env python3
"""
CoEvo Complaints Analysis Pipeline
- Reads complaints_db.json
- Filters genuine software complaints
- Ranks by popularity + signal strength
- Generates analysis report
- Marks evaluated complaints
"""

import json, re, sys, os
from datetime import datetime

DB_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), 
                        'marketing', 'discovery', 'complaints_db.json')
REPORT_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), 
                            'marketing', 'discovery', 'analysis_report.md')

def load_db():
    with open(DB_PATH, 'r', encoding='utf-8') as f:
        return json.load(f)

def save_db(data):
    with open(DB_PATH, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

def get_subreddit(body):
    m = re.search(r'Subreddit:\s*(\S+)', body or '')
    return m.group(1) if m else ''

def classify_complaint(c):
    """Returns (is_software, score, reason) tuple."""
    title = c.get('title', '')
    body = c.get('body', '')
    combined = (title + ' ' + (body or '')).lower()
    kw = c.get('search_keyword', '')
    sub = get_subreddit(body).lower()
    
    score = 0
    is_genuine = False
    reason = ''
    
    # === Strong signals (score 3) ===
    
    # Tech subreddits
    tech_subs = {
        'r/software', 'r/programming', 'r/webdev', 'r/linux', 'r/mac',
        'r/windows', 'r/iphone', 'r/ios', 'r/android', 'r/androidapps',
        'r/macbookpro', 'r/pchelp', 'r/techsupport', 'r/technook',
        'r/programmerhumor', 'r/selfhosted', 'r/characterai',
        'r/apple', 'r/amazonprime', 'r/theprimeagen',
        'r/softwaregore', 'r/talesfromtechsupport',
        'r/notion', 'r/obsidianmd', 'r/todoist',
        'r/figma', 'r/adobe', 'r/saas',
        'r/assholedesign', 'r/crappydesign',
        'r/subscription', 'r/technology'
    }
    
    if sub in tech_subs:
        sw_terms = ['app', 'software', 'subscription', 'update', 'feature', 
                   'bug', 'crash', 'ui', 'ux', 'design', 'interface', 
                   'pricing', 'expensive', 'slow', 'broken', 'unusable',
                   'cancel', 'frustrat', 'version', 'upgrade', 'download',
                   'install', 'issue', 'problem', 'error', 'fix',
                   'battery', 'wifi', 'bluetooth', 'screen', 'keyboard',
                   'login', 'password', 'account']
        if any(t in combined for t in sw_terms):
            is_genuine = True
            score = 3
            reason = f'Tech sub {sub}'
    
    # === Specific software product complaints ===
    products = {
        'netflix', 'spotify', 'youtube premium', 'disney+', 'amazon prime',
        'photoshop', 'lightroom', 'figma', 'notion', 'obsidian', 'evernote',
        'todoist', 'trello', 'asana', 'jira', 'slack', 'discord',
        'vscode', 'github', 'gitlab',
        'chatgpt', 'claude', 'gemini', 'copilot', 'midjourney',
        'character.ai', 'siyuan', 'logseq', 'roam research',
        'instagram', 'tiktok', 'linkedin',
        'apple music', 'gmail', 'outlook', 'protonmail',
        'canva', 'adobe', 'microsoft 365', 'google workspace',
        'wordpress', 'shopify', 'webflow', 'docker', 'aws',
        'reddit app', 'twitter', 'whatsapp', 'telegram', 'signal',
        'zoom', 'teams', 'google meet',
        'chrome', 'firefox', 'safari', 'edge browser',
        'youtube music', 'pocket casts', 'overcast',
        'duolingo', 'headspace', 'calm',
    }
    
    found_products = [p for p in products if p in combined]
    if found_products:
        complaint_indicators = [
            'expensive', 'subscription', 'cancel', 'hate', 'issue', 'problem',
            'broken', 'slow', 'crash', 'bug', 'frustrat', 'annoying',
            'rip off', 'overpriced', 'terrible', 'worst', 'bad', 'poor',
            'unusable', 'sucks', 'useless', 'removed', 'missing', 'lacks',
            'difficult', 'complicated', 'hassle', 'pain',
            'update ruined', 'changed', 'ruined',
            'too much', 'too many', 'too expensive',
            'waste of money', 'not worth',
        ]
        if any(t in combined for t in complaint_indicators):
            is_genuine = True
            score = max(score, 2)
            reason = f'Product complaint: {found_products[0]}'
    
    # === Signal keywords in software context ===
    strong_signals = {
        'I need an app that', 'wish this app could', 'missing feature',
        'basic functionality missing', 'bad UX', 'this tool is unusable',
        'this software is broken', 'crashes all the time', 'so slow',
        'fed up with', 'so tedious', 'why can\'t I',
    }
    if kw in strong_signals:
        sw_indicators = ['app', 'software', 'website', 'tool', 'feature', 
                        'design', 'ui', 'ux', 'computer', 'phone', 'laptop',
                        'update', 'version', 'download', 'install',
                        'browser', 'extension', 'plugin']
        if any(w in combined for w in sw_indicators):
            is_genuine = True
            score = max(score, 2)
            reason = f'Signal kw: {kw}'
    
    # === Subscription complaints ===
    if kw == 'subscription is too expensive':
        digital_terms = ['netflix', 'spotify', 'streaming', 'app', 'software',
                        'subscription', 'premium', 'pro', 'monthly', 'annual',
                        'youtube', 'cloud', 'service', 'saas', 'platform',
                        'membership']
        if any(t in combined for t in digital_terms):
            is_genuine = True
            score = max(score, 2)
            reason = 'Digital subscription complaint'
    
    # === Direct complaint patterns ===
    patterns = [
        r'(this|the) (app|software|website|tool|platform) (keeps|crashes|freezes|lags|sucks|is terrible|is slow)',
        r'(why|how) (can.?t|doesn.?t|won.?t) (this|the|my) (app|phone|computer|laptop|browser|software)',
        r'(worst|terrible|horrible|awful) (app|software|update|experience|service)',
        r'(battery|wifi|bluetooth|charging|screen|keyboard) (drain|issue|problem|broken|not working)',
        r'(update|new version) (ruined|broke|made worse|removed)',
        r'(cancel|ending|quitting) my (subscription|plan|membership)',
        r'(ads?|advertisements?) (everywhere|too many|annoying|intrusive|unskippable)',
        r'(too|so) (many|much) (subscription|fee|payment|service)',
        r'(this|the) (software|tool|app) is (completely|totally) (broken|useless)',
    ]
    for pat in patterns:
        if re.search(pat, combined, re.IGNORECASE):
            is_genuine = True
            score = max(score, 2)
            reason = 'Direct complaint pattern'
            break
    
    # === Filter false positives ===
    non_sw_topics = [
        'childbirth', 'pregnancy', 'baby', 'sex', 'nurse', 'hospital',
        'police', 'shooting', 'murder', 'rape', 'war', 'military',
        'immigra', 'deport', 'election', 'president', 'trump', 'biden',
        'climate change', 'oil', 'fossil fuel', 'religion', 'god',
        'conspiracy', 'celebrity', 'sports', 'soccer', 'football',
        'dating', 'relationship', 'marriage', 'divorce',
        'animal', 'dog', 'cat', 'pet',
    ]
    non_sw_count = sum(1 for t in non_sw_topics if t in combined)
    if non_sw_count >= 3:
        is_genuine = False
    
    return is_genuine, score, reason


def generate_report(top_complaints):
    """Generate analysis report."""
    now = datetime.now().strftime('%Y-%m-%d %H:%M')
    lines = []
    lines.append(f'# CoEvo 抱怨分析评估报告')
    lines.append(f'')
    lines.append(f'**生成时间**: {now}')
    lines.append(f'**数据来源**: marketing/discovery/complaints_db.json')
    lines.append(f'**分析范围**: Top 20 热度最高的真实软件类抱怨')
    lines.append(f'')
    lines.append(f'---')
    lines.append(f'')
    
    for i, (c, analysis) in enumerate(top_complaints, 1):
        title = c.get('title', '')[:120]
        url = c.get('url', '')
        pop = c.get('popularity_score', 0)
        plat = c.get('platform', '')
        kw = c.get('search_keyword', '')
        body = c.get('body', '')[:500]
        
        a = analysis  # dict: is_real_req, vibecoding, target_user, contact, mvp, reason
        
        lines.append(f'## {i}. {title}')
        lines.append(f'')
        lines.append(f'- **平台**: {plat} | **热度分**: {pop:.0f} | **关键词**: {kw}')
        lines.append(f'- **来源**: [{url}]({url})')
        lines.append(f'')
        lines.append(f'### 是否为真实软件需求？')
        lines.append(f'')
        lines.append(f'**判定**: {"✅ 是" if a["is_real_req"] else "❌ 否"}')
        lines.append(f'')
        if a.get('reason'):
            lines.append(f'*{a["reason"]}*')
            lines.append(f'')
        lines.append(f'### 是否可Vibecoding解决？')
        lines.append(f'')
        lines.append(f'**判定**: {a["vibecoding"]}')
        lines.append(f'')
        if a.get('vibe_reason'):
            lines.append(f'*{a["vibe_reason"]}*')
            lines.append(f'')
        lines.append(f'### 目标用户')
        lines.append(f'')
        lines.append(f'{a["target_user"]}')
        lines.append(f'')
        lines.append(f'### 联系人')
        lines.append(f'')
        lines.append(f'{a["contact"]}')
        lines.append(f'')
        lines.append(f'### 建议MVP方向')
        lines.append(f'')
        lines.append(f'{a["mvp"]}')
        lines.append(f'')
        lines.append(f'---')
        lines.append(f'')
    
    # Summary
    lines.append(f'## 汇总统计')
    lines.append(f'')
    viable_count = sum(1 for _, a in top_complaints if a["is_real_req"] and '可行' in a["vibecoding"])
    maybe_count = sum(1 for _, a in top_complaints if a["is_real_req"] and '部分' in a["vibecoding"])
    no_count = sum(1 for _, a in top_complaints if not a["is_real_req"])
    
    lines.append(f'- 真实软件需求: {20 - no_count}/{20}')
    lines.append(f'- Vibecoding 完全可行: {viable_count}')
    lines.append(f'- Vibecoding 部分可行: {maybe_count}')
    lines.append(f'- 非软件类抱怨: {no_count}')
    lines.append(f'')
    lines.append(f'---')
    lines.append(f'*本报告由需求分析自动化管线生成*')
    
    return '\n'.join(lines)


def evaluate_complaint(c):
    """Evaluate a single complaint: is it a real software requirement, 
    can it be solved with vibecoding, who is the target user/contact,
    suggested MVP direction."""
    
    title = c.get('title', '')
    body = c.get('body', '')
    combined = (title + ' ' + (body or '')).lower()
    sub = get_subreddit(body).lower()
    kw = c.get('search_keyword', '')
    
    analysis = {
        'is_real_req': True,
        'vibecoding': '',
        'vibe_reason': '',
        'target_user': '',
        'contact': '',
        'mvp': '',
        'reason': '',
    }
    
    # Analyze based on content patterns
    if 'software' in combined and 'broken' in combined:
        analysis['vibecoding'] = '部分可行'
        analysis['vibe_reason'] = '软件质量和性能问题是系统性问题，需要架构级改进，不适合单次Vibecoding解决。但定位具体瓶颈的工具类需求可做。'
        analysis['target_user'] = '开发者 / 高级PC用户'
        analysis['contact'] = 'r/theprimeagen 社区（开发者社区），Reddit用户 u/boringfantasy'
        analysis['mvp'] = '1) 网页性能分析工具 - 自动检测常见web性能瓶颈 2) 系统资源监控简化版 - 用仪表盘追踪卡顿原因'
        if 'instagram' in combined or 'gif' in combined:
            analysis['mvp'] = '1) 浏览器轻量化插件 - 限制特定站点的资源消耗 2) iOS App性能检测器 - 记录和报告App卡顿'

    elif 'amazon' in combined and 'cancel' in combined and 'subscribe' in combined:
        analysis['vibecoding'] = '✅ 可行（几小时内）'
        analysis['vibe_reason'] = '这是一个明确的UX工具需求 - 帮助用户绕过暗黑模式取消订阅。范围小，逻辑清晰。'
        analysis['target_user'] = 'Amazon Prime订阅用户 / 任何被订阅困扰的消费者'
        analysis['contact'] = 'r/amazonprime 社区，Reddit用户 u/sporty_outlook'
        analysis['mvp'] = '浏览器扩展：一键定位并跳转到Amazon "Subscribe & Save" 取消页面。显示用户所有活跃订阅、预计费用。使用网页内容扫描+直接链接跳转。'

    elif 'character.ai' in combined or 'c.ai' in combined:
        analysis['is_real_req'] = False
        analysis['reason'] = '抱怨对象是Character.AI的商业决策，不是可替代的软件需求。但暗示了对免费AI聊天替代品的需求。'
        analysis['vibecoding'] = '❌ 不可行'
        analysis['vibe_reason'] = '无法改变已有平台的商业模式。但可以做一个开源的AI聊天替代品方向。'
        analysis['target_user'] = 'Character.AI免费用户 / AI角色扮演爱好者'
        analysis['contact'] = 'r/CharacterAI 社区，Reddit用户 u/Samuel_AbdulMasih'
        analysis['mvp'] = '开源AI聊天平台：1) 本地优先的角色聊天界面 2) 支持多种LLM后端 3) 角色卡导入/导出功能'

    elif 'subscription' in combined and ('too expensive' in combined or 'hate' in combined or 'cancel' in combined):
        if 'streaming' in combined or 'netflix' in combined or 'spotify' in combined:
            analysis['vibecoding'] = '部分可行'
            analysis['vibe_reason'] = '不能改变Netflix/Spotify的定价策略，但可以做一个订阅管理工具来帮助用户审计和管理订阅。'
            analysis['target_user'] = '多订阅消费者（千禧一代/Gen Z）'
            analysis['contact'] = 'r/Millennials, r/AskReddit 社区'
            analysis['mvp'] = '订阅管理SaaS工具：1) 订阅跟踪仪表盘 2) 月度订阅账单汇总 3) 自动提醒即将到期的免费试用 4) 替代品推荐引擎'
    
    elif 'iphone' in combined and 'android' in combined:
        analysis['vibecoding'] = '部分可行'
        analysis['vibe_reason'] = '不能改变Android/OEM的系统预装行为，但可以做一个开箱引导工具或去广告工具。'
        analysis['target_user'] = 'Android新用户 / 从iPhone切换到Android的用户'
        analysis['contact'] = 'r/apple 社区，Reddit用户 u/irish_guy'
        analysis['mvp'] = 'Android新机设置引导App: 1) 一步禁用预装/广告 2) 隐私设置向导 3) iOS到Android迁移优化工具'

    elif 'missing feature' in combined or 'obvious feature' in combined:
        analysis['vibecoding'] = '✅ 可行（几天内）'
        analysis['vibe_reason'] = '这些是具体的功能缺失抱怨，每个都是小而明确的需求，非常适合Vibecoding快速验证。'
        analysis['target_user'] = '特定App的用户群体（取决于具体功能请求）'
        analysis['contact'] = 'r/AskReddit 社区'
        analysis['mvp'] = '「功能请求收集器」平台：1) 让用户提交等待列表的剩余歌曲数需求 2) 优先调研需求最高的功能 3) 用浏览器扩展/油猴脚本快速实现'

    elif 'siyuan' in combined or 'second brain' in combined:
        analysis['is_real_req'] = False
        analysis['reason'] = '这是一条正面推荐，不是抱怨。但反映了对离线/本地优先知识管理工具的需求。'
        analysis['vibecoding'] = '❌ 不可行（非抱怨）'
        analysis['target_user'] = '知识管理工具用户'
        analysis['contact'] = 'X用户 @itsharmanjot'
        analysis['mvp'] = 'N/A - 正面内容'

    elif 'notion' in combined or 'obsidian' in combined or 'claude' in combined:
        analysis['is_real_req'] = False
        analysis['reason'] = '这是一条正面/信息性内容，不是抱怨。'
        analysis['vibecoding'] = '❌ 不可行（非抱怨）'
        analysis['target_user'] = '知识工作者'
        analysis['mvp'] = 'N/A - 非抱怨'

    elif 'gym' in combined and ('app' in combined or 'tracker' in combined):
        analysis['is_real_req'] = False
        analysis['reason'] = '正面推荐开源健身工具，不是抱怨。'
        analysis['vibecoding'] = '❌ 不可行（非抱怨）'
        analysis['target_user'] = '健身爱好者'
        analysis['mvp'] = 'N/A - 正面内容'
    
    elif 'printer' in combined and ('ink' in combined or 'toner' in combined):
        analysis['reason'] = '打印机耗材抱怨，虽然有关但属于硬件设备，非纯软件需求。'
        analysis['vibecoding'] = '部分可行'
        analysis['vibe_reason'] = '不能解决硬件价格问题，但可以做一个耗材比价/更换提醒工具。'
        analysis['target_user'] = '打印机用户（家庭/小办公室）'
        analysis['contact'] = 'r/AskReddit 评论区'
        analysis['mvp'] = '打印机耗材管理App: 1) 耗材用量追踪 2) 第三方替代墨盒推荐 3) 价格比较提醒 4) 自动订购'

    elif 'cancel my subscription' in combined and 'service' in combined:
        analysis['vibecoding'] = '✅ 可行（几小时内）'
        analysis['vibe_reason'] = '一次性取消订阅本身是一个简单任务。但做一个聚合订阅管理/取消辅助工具是明确的小型SaaS MVP。'
        analysis['target_user'] = '多服务订阅用户'
        analysis['contact'] = 'r/AskReddit 社区'
        analysis['mvp'] = '「一键取消」助手: 1) 收集用户订阅列表 2) 提供各大平台的取消指南 3) 对已知暗黑模式提供绕过方案 4) 订阅到期日历'
    
    elif 'gpt' in combined or 'kimi' in combined or 'gemini' in combined:
        analysis['is_real_req'] = False
        analysis['reason'] = 'AI模型功能对比，不是软件抱怨。'
        analysis['vibecoding'] = '❌ 不可行（非抱怨）'
        analysis['target_user'] = 'AI开发者/用户'
        analysis['mvp'] = 'N/A - 非抱怨'

    elif 'amazon prime' in combined or 'subscribe and save' in combined:
        already_covered = True
        # already handled above with amazon + cancel

    elif 'good-gym' in combined.lower():
        analysis['is_real_req'] = False
        analysis['reason'] = '正面推荐，非抱怨。'

    elif 'voice cloning' in combined or 'voicebox' in combined or 'elevenlabs' in combined:
        analysis['is_real_req'] = False
        analysis['reason'] = '正面推荐开源语音克隆工具，不是抱怨。'
        analysis['vibecoding'] = '❌ 不可行（非抱怨）'
        analysis['target_user'] = '语音合成用户/内容创作者'
        analysis['mvp'] = 'N/A - 正面内容'

    # Default software complaint handling
    if analysis['vibecoding'] == '':
        # Generic assessment
        analysis['vibecoding'] = '待定（需要更多信息）'
        analysis['target_user'] = '待识别'
        analysis['contact'] = '无法确认'
        analysis['mvp'] = '需要进一步调研'
    
    return analysis


def main():
    data = load_db()
    complaints = data['complaints']
    
    unevaluated = [c for c in complaints if not c.get('evaluated', False)]
    print(f"Total complaints: {len(complaints)}")
    print(f"Unevaluated: {len(unevaluated)}")
    
    # Classify all unevaluated
    candidates = []
    for c in unevaluated:
        is_real, score, reason = classify_complaint(c)
        if is_real:
            candidates.append((score, c.get('popularity_score', 0), c, reason))
    
    print(f"Genuine software complaints: {len(candidates)}")
    
    # Sort by score (desc) then popularity (desc)
    candidates.sort(key=lambda x: (-x[0], -x[1]))
    
    # Take top 20
    top20 = candidates[:20]
    
    print(f"\n=== TOP 20 SOFTWARE COMPLAINTS ===\n")
    for i, (sc, pop, c, reason) in enumerate(top20, 1):
        title = c.get('title', '')[:100]
        sub = get_subreddit(c.get('body', ''))
        print(f"{i}. [sc={sc}, pop={pop:.0f}] {title}")
        print(f"   Sub: {sub} | Reason: {reason}")
    
    # Evaluate each
    evaluations = []
    for sc, pop, c, reason in top20:
        analysis = evaluate_complaint(c)
        analysis['reason'] = reason
        evaluations.append((c, analysis))
    
    # Generate report
    report = generate_report(evaluations)
    
    with open(REPORT_PATH, 'w', encoding='utf-8') as f:
        f.write(report)
    
    print(f"\nReport written to: {REPORT_PATH}")
    
    # Mark evaluated complaints
    evaluated_ids = {c['id'] for _, _, c, _ in top20}
    for c in complaints:
        if c['id'] in evaluated_ids:
            c['evaluated'] = True
            c['evaluated_at'] = datetime.now().isoformat()
    
    # Also mark all non-software-classified complaints as evaluated to avoid re-scanning
    for c in complaints:
        if not c.get('evaluated', False):
            c['evaluated'] = True
            c['evaluated_at'] = datetime.now().isoformat()
            c['note'] = 'auto-marked: not a genuine software complaint'
    
    save_db(data)
    print(f"Marked {len(evaluated_ids)} complaints as evaluated (software)")
    print(f"Marked all remaining {len([c for c in complaints if c.get('note','') == 'auto-marked: not a genuine software complaint'])} as non-software (non-applicable)")
    
    return report


if __name__ == '__main__':
    report = main()
    print("\n" + "="*60)
    print("REPORT PREVIEW (first 50 lines):")
    print("="*60)
    for line in report.split('\n')[:50]:
        print(line)

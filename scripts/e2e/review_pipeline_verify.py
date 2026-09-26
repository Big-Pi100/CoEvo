#!/usr/bin/env python3
"""验证卡片复习三管线的完整数据流"""
import json, urllib.request, time, websocket

BASE = "http://<OLD_VPS_IP>:8080"
WS_BASE = "ws://<OLD_VPS_IP>:8080"

def api(method, path, body=None, tok=None):
    h = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"} if tok else {"Content-Type": "application/json"}
    data = json.dumps(body).encode() if body else None
    r = urllib.request.urlopen(urllib.request.Request(f"{BASE}{path}", data=data, headers=h, method=method), timeout=30)
    return json.loads(r.read())

# 1. 创建新用户（干净环境）
print("="*60)
print("1. 创建测试用户")
print("="*60)
r = api("POST", "/api/auth/register", {"username":"reviewtest01","password":"test123"})
if "user_id" not in r:
    r = api("POST", "/api/auth/login", {"username":"reviewtest01","password":"test123"})
UID = r["user_id"]
TOK = r["token"]
print(f"  user_id={UID}")
print(f"  token={TOK[:8]}...")

# 2. 选语文 → g1-2（词卡+课文卡管线）
print("\n" + "="*60)
print("2. 选语文 g1-2 → k12ReadingInit")
print("="*60)
r = api("POST", "/api/k12/reading/init",
    {"user_id":UID, "subject":"语文", "grade_band":"g1-2"}, tok=TOK)
CONVID = r.get("conversation_id", "")
RESUMED = r.get("resumed", False)
print(f"  conv_id={CONVID}")
print(f"  resumed={RESUMED}")

# 3. 检查计划——看有没有 tasks
print("\n" + "="*60)
print("3. 检查计划")
print("="*60)
plans = api("GET", f"/api/plans?user_id={UID}", tok=TOK)
plan_list = plans if isinstance(plans, list) else plans.get("plans", [])
if plan_list:
    p = plan_list[0]
    plan_data = p.get("plan", {})
    stages = plan_data.get("stages", [])
    print(f"  mode={p.get('mode')}  goal={p.get('goal','')[:40]}")
    print(f"  stages: {len(stages)}")
    for s in stages:
        tasks = s.get("tasks", [])
        task_names = [t.get("name","?") for t in tasks]
        print(f"    stage={s.get('name')} tasks={task_names}")
        
        # 看第一个任务有没有 vocab/reading 链接
        if tasks:
            t0 = tasks[0]
            vids = t0.get("vocab_card_ids", [])
            rid = t0.get("reading_card_id", "")
            gold = t0.get("gold_cr_ids", [])
            print(f"      vocab_card_ids: {len(vids)} ({vids[:3]})")
            print(f"      reading_card_id: {rid[:30] if rid else '无'}")
            print(f"      gold_cr_ids: {len(gold)}")

# 4. 做几轮对话推进计划
print("\n" + "="*60)
print("4. 对话推进 + CP2 计划推进")
print("="*60)
MESSAGES = [
    "我们开始学习吧！",
    "这篇课文很有意思，我已经理解了。",
    "我已经掌握了这个任务，可以进入下一个了。",
    "我学完了，请推进。",
]
for i, msg in enumerate(MESSAGES):
    print(f"\n  对话 {i+1}: '{msg}'")
    try:
        ws = websocket.create_connection(f"{WS_BASE}/ws", timeout=60)
        ws.send(json.dumps({"user_id":UID, "conversation_id":CONVID, "message":msg, "token":TOK}))
        got_reply = False
        while True:
            try:
                resp = json.loads(ws.recv())
                if "reply" in resp:
                    got_reply = True
                    print(f"    reply: {resp['reply'][:60]}...")
                    print(f"    plan_updated: {resp.get('plan_updated',False)}")
                    break
            except:
                break
        ws.close()
        if not got_reply:
            print(f"    ⚠️ no reply")
    except Exception as e:
        print(f"    ❌ WS error: {e}")
        break

# 5. 检查当前 plan 状态
print("\n" + "="*60)
print("5. 对话后 plan 状态")
print("="*60)
plans = api("GET", f"/api/plans?user_id={UID}", tok=TOK)
plan_list = plans if isinstance(plans, list) else plans.get("plans", [])
if plan_list:
    plan_data = plan_list[0].get("plan", {})
    stages = plan_data.get("stages", [])
    for s in stages:
        for t in s.get("tasks", []):
            print(f"  task='{t.get('name','')}' status='{t.get('status','')}'")

# 6. 检查到期卡片
print("\n" + "="*60)
print("6. 到期卡片（复习页数据源）")
print("="*60)
due = api("GET", f"/api/review/due?user_id={UID}", tok=TOK)
due_list = due if isinstance(due, list) else due.get("cards", [])
print(f"  total due: {len(due_list)}")
for c in due_list[:5]:
    print(f"  [{c.get('card_type','?')}] front={c.get('front','')[:30]} domain={c.get('domain','')} state={c.get('state',0)}")

# 7. 按 domain 分组（对应复习页 Tab）
print("\n" + "="*60)
print("7. 按 domain 分组（→ Tab 显示）")
print("="*60)
domains = {}
for c in due_list:
    d = c.get("domain", "未知")
    domains.setdefault(d, []).append(c)
for d, cards in domains.items():
    print(f"  domain='{d}' → {len(cards)} 张卡片")
    for c in cards[:2]:
        t = c.get("card_type","?")
        f = c.get("front","")[:25]
        print(f"    [{t}] {f}")

# 8. 模拟复习操作
print("\n" + "="*60)
print("8. 模拟复习操作")
print("="*60)
if due_list:
    card = due_list[0]
    print(f"  测试卡片: [{card['card_type']}] {card['front'][:25]}")
    
    # 8a. 翻转（纯前端，API 不可见 — 需要眼睛看）
    print(f"   → 翻转: front='{card['front']}' back='{card['back']}'")
    
    # 8b. 验证（LLM 出题）
    questions = api("POST", "/api/review/verify", {
        "user_id":UID, "card_id":card["id"], "front":card["front"], "back":card["back"],
    }, tok=TOK)
    qlist = questions if isinstance(questions, list) else questions.get("questions", [])
    print(f"   → LLM 出题: {len(qlist)} 道")
    for i, q in enumerate(qlist):
        print(f"     Q{i+1}: {q.get('question','')[:40]} → 答案: {q.get('answer','')[:20]}")

    # 8c. 判题
    if qlist:
        judge_input = []
        for q in qlist:
            ans = q.get("answer","")
            user_ans = ans[:-1] if len(ans) > 3 else ans  # 故意错一点
            judge_input.append({
                "question": q["question"],
                "expected_answer": ans,
                "user_answer": f"我的回答: {user_ans}",
            })
        judge = api("POST", "/api/review/judge", {
            "questions": judge_input,
        }, tok=TOK)
        jlist = judge if isinstance(judge, list) else judge.get("results", [])
        correct = sum(1 for j in jlist if j.get("correct"))
        print(f"   → LLM 判题: {correct}/{len(jlist)} 正确")

    # 8d. 提交复习
    sr = api("POST", "/api/review/submit", {
        "user_id":UID,
        "card_id":card["id"],
        "rating":3,
        "verification_type":"ai_dialogue",
        "verification_result":"pass",
        "details_json":json.dumps([{"question":"q","correct":True,"feedback":"ok"}]),
    }, tok=TOK)
    print(f"   → submitReview: achievements={len(sr.get('achievements',[]))}")

    # 8e. 验证 FSRS 状态已更新
    due2 = api("GET", f"/api/review/due?user_id={UID}", tok=TOK)
    due2_list = due2 if isinstance(due2, list) else due2.get("cards", [])
    for c in due2_list:
        if c["id"] == card["id"]:
            print(f"   → FSRS: state {card.get('state')}→{c.get('state')}, reps {card.get('reps')}→{c.get('reps')}")

print("\n" + "="*60)
print("  需要眼睛看的部分")
print("="*60)
print("  打开 http://<OLD_VPS_IP>/app/")
print(f"  用 reviewtest01 / test123 登录")
print("  然后:")
print("  1. 点底部「复习」— 看到 Tab 了吗？")
print("     Tab 标签应该是：语文g1-2 (N) | 全部卡片")
print(f"  2. 语文g1-2 Tab 里 {len(due_list)} 张卡片能看到吗？")
print("  3. 点击卡片 → 翻转 → 看到背面")
print("  4. 点「验证一下」→ LLM 出题")
print("  5. 答题 → 评分 → 下一张")
print("="*60)

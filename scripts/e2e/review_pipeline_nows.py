#!/usr/bin/env python3
"""验证复习管线 - 纯 HTTP，无 websocket 依赖"""
import json, urllib.request, sys

BASE = "http://<OLD_VPS_IP>:8080"

def api(method, path, body=None, tok=None):
    h = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"} if tok else {"Content-Type": "application/json"}
    data = json.dumps(body).encode() if body else None
    r = urllib.request.urlopen(urllib.request.Request(f"{BASE}{path}", data=data, headers=h, method=method), timeout=30)
    return json.loads(r.read())

PASS, FAIL = 0, 0
def check(name, ok, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1; print(f"  [PASS] {name}")
    else:
        FAIL += 1; print(f"  [FAIL] {name}: {detail}")

# 1. 登录已有用户 (reviewtest01 上一步注册的)
print("="*60)
print("1. 登录用户")
print("="*60)
try:
    r = api("POST", "/api/auth/login", {"username":"reviewtest01","password":"test123"})
    UID = r["user_id"]; TOK = r["token"]
    check("登录成功", True, f"uid={UID[:16]}...")
except:
    r = api("POST", "/api/auth/register", {"username":"reviewtest01","password":"test123"})
    UID = r.get("user_id","")
    if not UID:
        r = api("POST", "/api/auth/login", {"username":"reviewtest01","password":"test123"})
        UID = r["user_id"]
    TOK = r["token"]
    check("注册/登录成功", bool(UID))

print(f"  UID={UID}")

# 2. 选语文阅读模式
print("\n" + "="*60)
print("2. 选语文 g1-2")
print("="*60)
r = api("POST", "/api/k12/reading/init", {"user_id":UID, "subject":"语文", "grade_band":"g1-2"}, tok=TOK)
CONVID = r.get("conversation_id", "")
check("k12ReadingInit 返回 conv_id", bool(CONVID), f"resumed={r.get('resumed',False)}")

# 3. 检查计划
print("\n" + "="*60)
print("3. 检查计划")
print("="*60)
plans = api("GET", f"/api/plans?user_id={UID}", tok=TOK)
plan_list = plans if isinstance(plans, list) else plans.get("plans", [])
check("有计划", len(plan_list) > 0)
if plan_list:
    p = plan_list[0]
    plan_data = p.get("plan", {})
    stages = plan_data.get("stages", [])
    check("计划有 stages", len(stages) > 0, f"{len(stages)} stages")
    check("计划 mode 是 structured 或 reading", p.get("mode") in ("structured","reading"), p.get("mode",""))
    print(f"  goal={p.get('goal','')[:50]}")
    for s in stages[:1]:
        for t in s.get("tasks", [])[:2]:
            n = t.get("name","?")
            v = len(t.get("vocab_card_ids",[]))
            r = t.get("reading_card_id","")
            print(f"  task: {n} | vocab_ids={v} | reading_id={'yes' if r else 'no'}")

# 4. 检查到期卡片
print("\n" + "="*60)
print("4. 到期卡片")
print("="*60)
due = api("GET", f"/api/review/due?user_id={UID}", tok=TOK)
due_list = due if isinstance(due, list) else due.get("cards", [])
check("有到期卡片", len(due_list) > 0, f"{len(due_list)} cards")
for c in due_list[:5]:
    print(f"  [{c.get('card_type','?')}] {c.get('front','')[:30]} domain={c.get('domain','')} id={c['id'][:25]}")

# 5. 按 domain 分组（对应前端 Tab）
print("\n" + "="*60)
print("5. 按 domain 分组 → Tab 映射")
print("="*60)
domains = {}
for c in due_list:
    d = c.get("domain", "未知")
    domains.setdefault(d, []).append(c)
for d, cards in domains.items():
    types = set(c.get("card_type","?") for c in cards)
    print(f"  domain='{d}' -> {len(cards)} cards, types={types}")
    check(f"domain '{d}' 有卡片", len(cards) > 0, f"{len(cards)} cards")

# 6. 验证 + 判题接口
print("\n" + "="*60)
print("6. verify + judge API")
print("="*60)
if due_list:
    card = due_list[0]
    check("卡片有 front", bool(card.get("front","")), card.get("front","")[:20])
    check("卡片有 back", bool(card.get("back","")), card.get("back","")[:20])

    # Verify (LLM 出题)
    questions = api("POST", "/api/review/verify", {
        "user_id":UID, "card_id":card["id"],
        "front":card["front"], "back":card["back"],
    }, tok=TOK)
    qlist = questions if isinstance(questions, list) else questions.get("questions", [])
    check("LLM 生成验证题", len(qlist) > 0, f"{len(qlist)} questions")
    for q in qlist[:1]:
        print(f"  样题: {q.get('question','')[:50]} | 答案: {q.get('answer','')[:20]}")

    # Judge (判题)
    if qlist:
        jinput = [{"question":q["question"], "expected_answer":q["answer"], "user_answer":f"我的回答是{q['answer']}"} for q in qlist[:2]]
        judge = api("POST", "/api/review/judge", {"questions":jinput}, tok=TOK)
        jlist = judge if isinstance(judge, list) else judge.get("results", [])
        correct = sum(1 for j in jlist if j.get("correct"))
        check("LLM 判题正常", len(jlist) > 0, f"{correct}/{len(jlist)} correct")

    # Submit review
    sr = api("POST", "/api/review/submit", {
        "user_id":UID, "card_id":card["id"],
        "rating":3, "verification_type":"ai_dialogue", "verification_result":"pass",
    }, tok=TOK)
    check("submitReview 正常", True, f"achievements={len(sr.get('achievements',[]))}")

# 汇总
print("\n" + "="*60)
print(f"  API 层验证: {PASS} 通过 / {FAIL} 失败 / {PASS+FAIL} 总计")
print("="*60)
print()
print("需要眼睛验证的（HTTP 验证不到）:")
print("-"*40)
print(f"1. 打开 http://<OLD_VPS_IP>/app/")
print(f"   登录: reviewtest01 / test123")
print(f"2. 点底部「复习」Tab")
print(f"   应该看到 Tab 栏: 语文g1-2 ({len(due_list)}) | 全部卡片")
print(f"   卡片列表: {len(due_list)} 张，按 state 颜色显示")
if domains:
    for d, cards in domains.items():
        print(f"   domain='{d}': {len(cards)} 张 (含 {set(c.get('card_type','') for c in cards)})")
print(f"3. 点一张卡片 → 翻转看背面")
print(f"4. 点「验证一下」→ LLM 出题")
print(f"5. 答题 → 判题 → 评分")
print(f"6. 全部完成后看 FSRS 状态变化")
print("-"*40)

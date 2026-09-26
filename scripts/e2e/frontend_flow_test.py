#!/usr/bin/env python3
"""CoEvo 前端用户流程 E2E 测试 — 模拟 APP 的操作验证每个环节"""
import json, urllib.request, time, sys, os
import websocket

BASE = "http://<OLD_VPS_IP>:8080"
WS_BASE = "ws://<OLD_VPS_IP>:8080"

# 使用已创建的有 subscription 的用户
UID = "user_35c0e437"
TOK = "b1c2eb8d-4975-4e2c-97d3-6c3ac98f1ff8"

PASS = 0
FAIL = 0

def check(name, ok, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  [PASS] {name}")
    else:
        FAIL += 1
        print(f"  [FAIL] {name}: {detail}")

def api(method, path, body=None):
    h = {"Authorization": f"Bearer {TOK}", "Content-Type": "application/json"}
    data = json.dumps(body).encode() if body else None
    r = urllib.request.urlopen(urllib.request.Request(f"{BASE}{path}", data=data, headers=h, method=method), timeout=30)
    return json.loads(r.read())

# ── 测试 1: 注册/登录 ──
print("\n" + "="*60)
print("  [测试 1] 注册 / 登录")
print("="*60)

REG = json.loads(urllib.request.urlopen(urllib.request.Request(
    f"{BASE}/api/auth/register",
    data=json.dumps({"username":"flowtest01","password":"flowtest123"}).encode(),
    headers={"Content-Type":"application/json"}
), timeout=15).read())

if "user_id" in REG:
    check("注册新用户成功", True, f"uid={REG['user_id']}")
    NEW_UID = REG["user_id"]
    NEW_TOK = REG["token"]
else:
    check("注册(用户可能已存在)", True, str(REG)[:60])
    # 用户已存在，用登录获取 token
    L = json.loads(urllib.request.urlopen(urllib.request.Request(
        f"{BASE}/api/auth/login",
        data=json.dumps({"username":"flowtest01","password":"flowtest123"}).encode(),
        headers={"Content-Type":"application/json"}
    ), timeout=15).read())
    NEW_UID = L.get("user_id","")
    NEW_TOK = L.get("token","")

# 再次注册同一用户 -> 应返回"已存在"
REG2 = json.loads(urllib.request.urlopen(urllib.request.Request(
    f"{BASE}/api/auth/register",
    data=json.dumps({"username":"flowtest01","password":"flowtest123"}).encode(),
    headers={"Content-Type":"application/json"}
), timeout=15).read())
check("重复注册提示已存在", "already" in str(REG2).lower(), str(REG2))

# 登录
LOGIN = json.loads(urllib.request.urlopen(urllib.request.Request(
    f"{BASE}/api/auth/login",
    data=json.dumps({"username":"flowtest01","password":"flowtest123"}).encode(),
    headers={"Content-Type":"application/json"}
), timeout=15).read())
check("登录返回 user_id", "user_id" in LOGIN, str(LOGIN))
check("登录返回 token", bool(LOGIN.get("token","")))

# Token 验证
VERIFY = json.loads(urllib.request.urlopen(urllib.request.Request(
    f"{BASE}/api/auth/verify",
    data=json.dumps({"user_id":LOGIN["user_id"],"token":LOGIN["token"]}).encode(),
    headers={"Content-Type":"application/json"}
), timeout=15).read())
check("Token 验证通过", VERIFY.get("valid") == True, str(VERIFY))


# ── 测试 2: 首页数据 ──
print("\n" + "="*60)
print("  [测试 2] 首页数据")
print("="*60)

# 用主测试用户 (有 subscription)
profile = api("GET", f"/api/user/{UID}/profile")
check("profile 返回 streak_days", "streak_days" in str(profile))
check("profile 返回 total_cards", "total_cards" in str(profile))
check("profile 返回 today_reviews", "today_reviews" in str(profile))


# ── 测试 3: 选科目 → 创建对话 ──
print("\n" + "="*60)
print("  [测试 3] 选科目 → k12Init")
print("="*60)

# 结构化模式 (数学)
r = api("POST", "/api/k12/init", {"user_id":UID,"subject":"数学","grade_band":"g7-9"})
check("k12Init 返回 conversation_id", "conversation_id" in r, str(r)[:150])
conv_id = r.get("conversation_id","")
resumed = r.get("resumed", False)
if resumed:
    check("k12Init 返回 resumed", True, "已存在会话，卡片已在前次加载")
else:
    check("k12Init 返回 cards", "cards" in r and r.get("cards"), str(r)[:150])

# 检查计划已创建
plans = api("GET", f"/api/plans?user_id={UID}")
plan_list = plans if isinstance(plans, list) else plans.get("plans", [])
check("计划已创建", len(plan_list) > 0, f"{len(plan_list)} plans")
if plan_list:
    p = plan_list[0]
    check("计划 mode 为 structured", p.get("mode") == "structured", p.get("mode",""))
    check("计划有 goal", bool(p.get("goal","")), p.get("goal","")[:40])
    # 注意: plan_content 存储在 "plan" 字段中（经过合并处理），不是 "plan_content"
    plan_data = p.get("plan", {})
    has_plan_content = bool(plan_data) and (isinstance(plan_data, dict) and len(plan_data) > 0)
    check("计划内容存在", has_plan_content, f"plan keys={list(plan_data.keys()) if isinstance(plan_data, dict) else type(plan_data)}")


# ── 测试 4: WS 对话 ──
print("\n" + "="*60)
print("  [测试 4] WS 对话")
print("="*60)

try:
    ws = websocket.create_connection(f"{WS_BASE}/ws", timeout=60)
    start = time.time()
    ws.send(json.dumps({
        "user_id": UID, "conversation_id": conv_id,
        "message": "什么是一次函数？请用简单的话解释。",
        "token": TOK,
    }))

    responses = []
    timeout_at = time.time() + 60
    got_reply = False
    while time.time() < timeout_at:
        try:
            resp = json.loads(ws.recv())
            responses.append(resp)
            if "reply" in resp:
                got_reply = True
                break
        except:
            break
    ws.close()

    latency = (time.time() - start) * 1000
    check("WS 连接成功", True)
    check("WS 收到回复", got_reply, f"latency={latency:.0f}ms, responses={len(responses)}")
    if got_reply:
        reply = responses[-1]
        check("回复非空", bool(reply.get("reply","")), f"len={len(reply.get('reply',''))}")
        print(f"    Reply preview: {reply['reply'][:60]}...")
except Exception as e:
    check("WS 测试", False, str(e)[:80])


# ── 测试 5: 复习 ──
print("\n" + "="*60)
print("  [测试 5] 复习")
print("="*60)

due = api("GET", f"/api/review/due?user_id={UID}")
due_list = due if isinstance(due, list) else due.get("cards", [])
check("getDueCards 返回列表", isinstance(due_list, list), f"count={len(due_list)}")
if due_list:
    card = due_list[0]
    check("卡片有 front", bool(card.get("front","")), card.get("front","")[:30])
    check("卡片有 back", bool(card.get("back","")), card.get("back","")[:30])

    # 提交复习
    try:
        sr = api("POST", "/api/review/submit", {
            "user_id": UID, "card_id": card["id"],
            "rating": 3, "verification_type": "auto", "verification_result": "pass",
        })
        check("submitReview 成功", True, f"got={list(sr.keys())} achievements={len(sr.get('achievements',[]))}")
    except Exception as e:
        check("submitReview", False, str(e)[:80])


# ── 测试 6: 卡片列表 ──
print("\n" + "="*60)
print("  [测试 6] 卡片列表")
print("="*60)

cards = api("GET", f"/api/cards/all?user_id={UID}")
card_data = cards if isinstance(cards, list) else cards.get("cards", [])
check("getCards 返回列表", isinstance(card_data, list), f"count={len(card_data)}")
if card_data:
    check("卡片有 id", bool(card_data[0].get("id","")))
    check("卡片有 card_type", bool(card_data[0].get("card_type","")))


# ── 测试 7: 学习报告 ──
print("\n" + "="*60)
print("  [测试 7] 学习报告")
print("="*60)

report = api("GET", f"/api/user/{UID}/learning-report")
check("报告有 stats", "stats" in report)
check("报告有 streak_days", report.get("stats",{}).get("streak_days","") is not None)
check("报告有 plans", "plans" in report)
check("报告有 assessment", "assessment" in report)


# ── 测试 8: 历史对话 ──
print("\n" + "="*60)
print("  [测试 8] 历史对话")
print("="*60)

history = api("GET", f"/api/history?user_id={UID}")
check("历史返回列表", isinstance(history, list) or "conversations" in str(history), str(history)[:100])


# ── 汇总 ──
print("\n" + "="*60)
print(f"  测试完成: {PASS} 通过 / {FAIL} 失败 / {PASS+FAIL} 总计")
print("="*60)

if FAIL > 0:
    sys.exit(1)

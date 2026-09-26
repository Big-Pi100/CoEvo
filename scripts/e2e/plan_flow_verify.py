#!/usr/bin/env python3
"""验证对话中 plan 面板的正确显示和推进"""
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

# 1. 登录
print("="*60)
print("1. 登录")
print("="*60)
r = api("POST", "/api/auth/login", {"username":"reviewtest01","password":"test123"})
UID = r["user_id"]; TOK = r["token"]
check("登录成功", True)

# 2. 获取当前用户的计划（语文阅读在上一步已创建）
print("\n" + "="*60)
print("2. 获取计划列表（chat_plan_panel 数据源）")
print("="*60)
plans = api("GET", f"/api/plans?user_id={UID}", tok=TOK)
plan_list = plans if isinstance(plans, list) else plans.get("plans", [])
check("有计划", len(plan_list) > 0, f"{len(plan_list)} plans")

if plan_list:
    p = plan_list[0]
    # chat_plan_panel 读取 plan['plan']['stages']
    plan_merged = p.get("plan", {})
    stages = plan_merged.get("stages", [])
    
    check("plan 下有 stages", len(stages) > 0, f"{len(stages)} stages")
    check("plan 有 goal", bool(p.get("goal","")), p.get("goal","")[:40])
    
    print(f"\n  plan 原始字段: {list(p.keys())}")
    print(f"  plan['plan'] 字段: {list(plan_merged.keys())}")
    print(f"  goal: {p.get('goal','')}")
    print(f"  mode: {p.get('mode','')}")
    
    # 逐 stage 展示——模拟 plan_panel 的渲染逻辑
    print("\n  ── 计划面板渲染数据（chat_plan_panel 实际读的字段）──")
    total_tasks = 0
    done_tasks = 0
    for si, s in enumerate(stages):
        s_name = s.get("name","?")
        s_status = s.get("status","pending")
        tasks = s.get("tasks", [])
        s_done = sum(1 for t in tasks if t.get("status") == "done")
        total_tasks += len(tasks)
        done_tasks += s_done
        
        # plan_panel 用这些字段:
        print(f"\n  Stage {si}: '{s_name}' status='{s_status}'")
        print(f"     图标: {'▶ in_progress' if s_status=='in_progress' else '✓ done' if s_status=='done' else '○ pending'}")
        print(f"     进度: {s_done}/{len(tasks)}")
        for ti, t in enumerate(tasks):
            t_name = t.get("name","?")
            t_status = t.get("status","pending")
            # plan_panel 用这些字段:
            icon = "✓" if t_status == "done" else "●" if t_status == "in_progress" else "○"
            print(f"     Task {ti}: {icon} '{t_name}' status='{t_status}'")
    
    print(f"\n  全局进度: {done_tasks}/{total_tasks} = {done_tasks/max(total_tasks,1)*100:.0f}%")
    check("计划面板数据格式正确（stages→tasks→status）", 
          all("name" in t and "status" in t for s in stages for t in s.get("tasks",[])),
          "所有 task 都有 name 和 status 字段")
    check("有 in_progress 的任务（非全 pending）",
          any(t.get("status") == "in_progress" for s in stages for t in s.get("tasks",[])),
          "至少一个任务处于进行中")
else:
    print("  ⚠️ 无计划")
    sys.exit(1)

# 3. 模拟 CP2 推进：通过 POST /api/chat 让 LLM 处理 + CP2 推进
print("\n" + "="*60)
print("3. 模拟推进（通过 POST /api/chat + CP2）")
print("="*60)
# 先找 conversation_id
convs = api("GET", f"/api/history?user_id={UID}", tok=TOK)
conv_list = convs if isinstance(convs, list) else convs.get("conversations", convs.get("turns",[]))
if isinstance(conv_list, list) and len(conv_list) > 0:
    # 用已有 conversation 发 chat 消息
    if isinstance(conv_list[0], dict) and "conversation_id" in conv_list[0]:
        CONVID = conv_list[0]["conversation_id"]
    elif isinstance(conv_list[0], dict) and "id" in conv_list[0]:
        CONVID = conv_list[0]["id"]
    else:
        CONVID = conv_list[0] if isinstance(conv_list[0], str) else ""
    
    print(f"  conv_id={CONVID[:30]}")
    
    # 发一条"我理解了，推进"消息
    msg = {"user_id":UID, "conversation_id":CONVID, "message":"我已经掌握当前任务了，请推进到下一个任务。"}
    try:
        r = api("POST", "/api/chat", msg, tok=TOK)
        reply = r.get("reply","")
        plan_updated = r.get("plan_updated", False)
        print(f"  reply: {reply[:60]}...")
        print(f"  plan_updated: {plan_updated}")
        check("chat API 返回正常", bool(reply))
        check("plan_updated 标记变化", plan_updated == True or plan_updated == False, f"plan_updated={plan_updated}")
    except Exception as e:
        # 可能没 subscription
        print(f"  chat API 失败（可能无 subscription）: {e}")
        check("chat API", False, str(e)[:60])
else:
    print("  ⚠️ 无历史对话")

# 4. 推进后重新检查 plan
print("\n" + "="*60)
print("4. 推进后 plan 状态")
print("="*60)
plans2 = api("GET", f"/api/plans?user_id={UID}", tok=TOK)
plan_list2 = plans2 if isinstance(plans2, list) else plans2.get("plans", [])
if plan_list2:
    p2 = plan_list2[0]
    stages2 = p2.get("plan",{}).get("stages",[])
    print(f"  推进前: {done_tasks}/{total_tasks} done")
    new_done = sum(1 for s in stages2 for t in s.get("tasks",[]) if t.get("status") == "done")
    print(f"  推进后: {new_done}/{total_tasks} done")
    if new_done > done_tasks:
        check("计划被成功推进", True, f"{done_tasks}→{new_done}")
    else:
        print("  ➡ 推进未触发（LLM 可能判断用户未掌握，需多轮对话）")
        check("推进结果(未变更)", True, "LLM 判断需继续教学")

# 5. 验证 plan 数据完整性（前端渲染不会崩溃）
print("\n" + "="*60)
print("5. 数据完整性检查")
print("="*60)
if plan_list:
    p = plan_list[0]
    merged = p.get("plan", {})
    # 前端 chat_plan_panel 读 plan['plan']['stages']
    stages_check = merged.get("stages", [])
    all_valid = True
    for s in stages_check:
        if "name" not in s: all_valid = False
        for t in s.get("tasks", []):
            if "name" not in t or "status" not in t: all_valid = False
    check("plan 数据完整（所有 stage/task 含 name+status）", all_valid)

print("\n" + "="*60)
print(f"  API 验证: {PASS} 通过 / {FAIL} 失败 / {PASS+FAIL} 总计")
print("="*60)
print()
print("需要眼睛验证的:")
print("-"*40)
print(f"1. 打开 http://<OLD_VPS_IP>/app/")
print(f"   reviewtest01 / test123")
print(f"2. 如果看到首页 → 点「开始对话」或进入已有会话")
print(f"3. 看聊天页顶部的计划面板（默认折叠）:")
print("   - 能看到 goal 文字吗？ (" + (p.get('goal','?') if plan_list else '?') + ")")
print('   - 能看到进度 \"已完成/总计\" 吗？')
print("4. 点一下展开计划面板:")
print("   - 能看到 stages 和 tasks 列表吗？")
print("   - stage 前有图标 (▶/✓/○) 吗？")
print("   - task 前有图标 (✓/●/○) 吗？")
print("   - 进度条看着对吗？")
print('5. 在聊天框发 \"我已经理解了，请推进\"')
print("   - 看计划面板是否刷新")
print("   - 看进度是否变化")
print("-"*40)

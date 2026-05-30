#!/usr/bin/env python3
"""Dual-LLM plan E2E: free, math structured, Chinese reading."""
import asyncio, websockets, json, urllib.request, time, os
from datetime import datetime

API = "http://<OLD_VPS_IP>:8080"
WS = "ws://<OLD_VPS_IP>:8080/ws"
DS_KEY = "sk-***REDACTED***"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
    f"plan_e2e_{datetime.now().strftime('%Y%m%d_%H%M%S')}")
os.makedirs(OUT, exist_ok=True)

USERS = {
    "free":    {"uid": "user_817ed72e", "token": "86552e0b-eebe-41a4-bbf6-e5fc4218999a", "cid": "user_817ed72e"},
    "math":    {"uid": "user_df4227cf", "token": "bd56f53a-4e02-46b6-b223-5217b192a42d", "cid": "8ebd9423-6146-4432-86b5-ff05711dbb60"},
    "chinese": {"uid": "user_7571ffe6", "token": "1f033411-2062-410b-9760-e64876b59357", "cid": "865913e7-ba8d-4180-a04c-5efcae54beed"},
}
STUDENTS = {
    "free":    "你是一个对学习充满好奇的小学生。请基于老师的教学内容自然回应。用你自己的话回答问题。",
    "math":    "你是初中生在学习数学。认真回答老师的问题。如果不懂就问。直接输出回复。",
    "chinese": "你是一个小学低年级学生。语文老师正在教你课文。用小朋友的语气说话，句子简短。",
}
FIRST_MSGS = {
    "free":    "老师你好！我想学习新的知识！",
    "math":    "老师好！请开始教我数学。",
    "chinese": "老师好！我们今天学什么课文呀？",
}

def log(m):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] {m}")
    with open(os.path.join(OUT, "run.log"), "a", encoding="utf-8") as f:
        f.write(f"[{ts}] {m}\n")

def get(path):
    return json.loads(urllib.request.urlopen(urllib.request.Request(f"{API}{path}"), timeout=30).read().decode())

def llm(sys, msg, temp=0.7):
    p = {"model": "deepseek-chat", "temperature": temp, "max_tokens": 512,
         "messages": [{"role": "system", "content": sys}, {"role": "user", "content": msg}]}
    req = urllib.request.Request("https://api.deepseek.com/chat/completions",
        json.dumps(p).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {DS_KEY}"},
        method="POST")
    return json.loads(urllib.request.urlopen(req, timeout=60).read().decode())["choices"][0]["message"]["content"]

def save(name, turn, fn, c):
    p = os.path.join(OUT, name)
    if isinstance(turn, int): p = os.path.join(p, f"turn_{turn:03d}")
    os.makedirs(p, exist_ok=True)
    with open(os.path.join(p, fn), "w", encoding="utf-8") as f: f.write(c)

def check_plan(cid):
    try:
        ps = get(f"/api/plans?conversation_id={cid}")
        plans = ps.get("plans", [])
        return plans[0].get("plan", {}) if plans else None
    except: return None

def parse_tasks(plan):
    if not plan: return None
    stages = plan.get("stages", [])
    if not stages: return None
    return stages[0].get("tasks", [])

def parse_stages(plan):
    if not plan: return None
    return plan.get("stages", [])

async def run_mode(name, turns=8):
    u = USERS[name]
    uid, token, cid = u["uid"], u["token"], u["cid"]
    ss = STUDENTS[name]
    first = FIRST_MSGS[name]
    plan_versions = 0
    last_plan_str = ""

    log(f"\n{'='*60}\n=== {name} ({turns}轮) ===")
    async with websockets.connect(WS) as ws:
        hist = []
        await ws.send(json.dumps({"user_id": uid, "conversation_id": cid, "token": token,
            "message": first}))
        reply = ""
        while True:
            d = json.loads(await asyncio.wait_for(ws.recv(), 90))
            t = d.get("type", "")
            if t == "token": reply += d.get("content", "")
            elif t == "done": break
            elif t == "error": log(f"  ERR: {d.get('content')}"); return False

        log(f"[T0] T({len(reply)}字): {reply[:60]}...")
        save(name, 0, "teacher.txt", reply)
        hist.append(f"老师: {reply}")

        for turn in range(1, turns + 1):
            ctx = "\n".join(hist[-6:])
            sm = llm(ss, ctx)
            log(f"[T{turn}] S({len(sm)}字): {sm[:60]}...")
            save(name, turn, "student.txt", sm)

            await ws.send(json.dumps({"user_id": uid, "conversation_id": cid, "message": sm}))
            reply = ""
            while True:
                d = json.loads(await asyncio.wait_for(ws.recv(), 120))
                t = d.get("type", "")
                if t == "token": reply += d.get("content", "")
                elif t == "done": break
                elif t == "error": log(f"  ERR: {d.get('content')}"); return False

            log(f"[T{turn}] T({len(reply)}字): {reply[:60]}...")
            save(name, turn, "teacher.txt", reply)
            hist.append(f"老师: {reply}")

            ps = check_plan(cid)
            ps_str = json.dumps(ps, sort_keys=True) if ps else ""
            if ps_str != last_plan_str:
                plan_versions += 1
                last_plan_str = ps_str

            tasks = parse_tasks(ps)
            if tasks:
                dc = sum(1 for t in tasks if t.get("status") == "done")
                ip = sum(1 for t in tasks if t.get("status") == "in_progress")
                log(f"[T{turn}] 任务: {dc}完成/{ip}进行, plan更新{plan_versions}次")
                if dc >= 2:
                    log(f"✅ {name}: 完成{dc}个任务，提前结束")
                    break

            await asyncio.sleep(0.5)

    # Final summary
    ps = check_plan(cid)
    stages = parse_stages(ps)
    all_tasks = []
    if stages:
        for s in stages:
            for t in s.get("tasks", []):
                all_tasks.append(t)
    if all_tasks:
        dc = sum(1 for t in all_tasks if t.get("status") == "done")
        ip = sum(1 for t in all_tasks if t.get("status") == "in_progress")
        stages_done = sum(1 for s in stages if s.get("status") == "done")
        log(f"📊 最终: {dc}/{len(all_tasks)}任务完成, {stages_done}/{len(stages)}阶段完成, {plan_versions}次plan更新")
    return plan_versions > 0

async def main():
    log("=== Plan E2E 全模式测试 ===")

    # Lightweight
    log("\n═══ 轻量 (6轮) ═══")
    for mode in ["free", "math", "chinese"]:
        ok = await run_mode(mode, 6)
        log(f"  {'✅' if ok else '⚠️'} {mode}")

    # Full (if lightweight passed)
    log("\n═══ 完整 (15轮) ═══")
    for mode in ["free_full", "math_full", "chinese_full"]:
        base = mode.replace("_full", "")
        u = USERS[base]
        # Create fresh user for full test
        if mode == "free_full":
            r = json.loads(urllib.request.urlopen(urllib.request.Request(
                f"{API}/api/auth/register",
                data=json.dumps({"username": f"free{int(time.time())}","password":"test123"}).encode(),
                headers={"Content-Type":"application/json"}, method="POST")).read().decode())
            USERS["free_full"] = {"uid": r["user_id"], "token": r["token"], "cid": r["user_id"]}
            import subprocess
            subprocess.run(["ssh","-i",os.path.expanduser("~/.ssh/coevo_key"),
                "ubuntu@<OLD_VPS_IP>",
                f"sudo sqlite3 /opt/coevo/data/coevo.db \"INSERT OR REPLACE INTO user_preferences"
                f" (user_id, key, value, updated_at) VALUES ('{r['user_id']}', 'subscription_expires',"
                f" '2099-12-31T23:59:59Z', datetime('now'));\""], capture_output=True, timeout=15)
            STUDENTS["free_full"] = STUDENTS["free"]
            FIRST_MSGS["free_full"] = FIRST_MSGS["free"]
        elif mode == "math_full":
            USERS["math_full"] = u
            STUDENTS["math_full"] = STUDENTS["math"]
            FIRST_MSGS["math_full"] = FIRST_MSGS["math"]
        elif mode == "chinese_full":
            USERS["chinese_full"] = u
            STUDENTS["chinese_full"] = STUDENTS["chinese"]
            FIRST_MSGS["chinese_full"] = FIRST_MSGS["chinese"]
        ok = await run_mode(mode, 15)
        log(f"  {'✅' if ok else '⚠️'} {mode}")

    log(f"\n输出: {OUT}")

asyncio.run(main())

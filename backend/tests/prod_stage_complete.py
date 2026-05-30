#!/usr/bin/env python3
"""Run until at least 1 full stage is completed per mode."""
import asyncio, websockets, json, urllib.request, time, os
from datetime import datetime

API = "http://<OLD_VPS_IP>:8080"
WS = "ws://<OLD_VPS_IP>:8080/ws"
DS_KEY = "sk-***REDACTED***"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
    f"stage_full_{datetime.now().strftime('%Y%m%d_%H%M%S')}")
os.makedirs(OUT, exist_ok=True)
MAX = 45

def log(m):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] {m}")
    with open(os.path.join(OUT, "run.log"), "a", encoding="utf-8") as f:
        f.write(f"[{ts}] {m}\n")

def get(path):
    return json.loads(urllib.request.urlopen(
        urllib.request.Request(f"{API}{path}"), timeout=30).read().decode())

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

def plan_info(cid):
    try:
        ps = get(f"/api/plans?conversation_id={cid}")
        plans = ps.get("plans", [])
        if not plans: return (0,0,0,0,[])
        p = plans[0].get("plan", {})
        stages = p.get("stages", [])
        if not stages: return (0,0,0,0,[])
        tt, dt, ds, sn = 0, 0, 0, []
        for s in stages:
            tasks = s.get("tasks", [])
            s_all_done = all(t.get("status") == "done" for t in tasks) if tasks else False
            tt += len(tasks)
            dt += sum(1 for t in tasks if t.get("status") == "done")
            if s_all_done: ds += 1
            sn.append(s.get("name", "?"))
        return (dt, tt, ds, len(stages), sn)
    except: return (0,0,0,0,[])

async def run(name, uid, token, cid, ss, first):
    log(f"\n{'='*60}\n=== {name} ===")
    dt0, tt0, ds0, ts0, sn0 = plan_info(cid)
    log(f"开始: {dt0}/{tt0}任务完成, {ds0}/{ts0}阶段完成")

    async with websockets.connect(WS) as ws:
        hist, pv, last_ts = [], 0, ""
        await ws.send(json.dumps({"user_id": uid, "conversation_id": cid, "token": token, "message": first}))
        reply = ""
        while True:
            d = json.loads(await asyncio.wait_for(ws.recv(), 120))
            t = d.get("type", "")
            if t == "token": reply += d.get("content", "")
            elif t == "done": break
            elif t == "error": log(f"ERR: {d.get('content')}"); return False
        hist.append(f"老师: {reply}")

        for turn in range(1, MAX + 1):
            ctx = "\n".join(hist[-6:])
            sm = llm(ss, ctx)
            await ws.send(json.dumps({"user_id": uid, "conversation_id": cid, "message": sm}))
            reply = ""
            while True:
                d = json.loads(await asyncio.wait_for(ws.recv(), 120))
                t = d.get("type", "")
                if t == "token": reply += d.get("content", "")
                elif t == "done": break
                elif t == "error": log(f"ERR: {d.get('content')}"); return False
            hist.append(f"老师: {reply}")

            dt, tt, ds, ts, sn = plan_info(cid)
            cur_ts = f"{ds}/{ts}"
            if cur_ts != last_ts:
                pv += 1; last_ts = cur_ts
                log(f"  📋 Plan#{pv}: {dt}/{tt}任务, {ds}/{ts}阶段")
                save(name, turn, f"plan_v{pv}.json",
                    json.dumps(get(f"/api/plans?conversation_id={cid}"), indent=2, ensure_ascii=False))

            if ds >= 1:
                log(f"✅ {name}: 完成{ds}/{ts}个阶段! ({dt}/{tt}任务)")
                return True

            if turn % 5 == 0:
                log(f"  [T{turn}] {dt}/{tt}任务, {ds}/{ts}阶段, {pv}次plan更新")

            await asyncio.sleep(0.3)

        dt, tt, ds, ts, sn = plan_info(cid)
        log(f"  [{name}] 结束: {dt}/{tt}任务, {ds}/{ts}阶段, {pv}次更新")
        return ds >= 1

async def main():
    log(f"=== 阶段完成测试 (最多{MAX}轮/模式) ===")
    configs = [
        ("chinese", "user_7571ffe6", "1f033411-2062-410b-9760-e64876b59357",
         "865913e7-ba8d-4180-a04c-5efcae54beed",
         "你是一个小学低年级学生。语文老师正在教你课文。用小朋友的语气说话，句子简短。",
         "老师好！我们继续学课文吧！"),
    ]

    for name, uid, token, cid, ss, first in configs:
        ok = await run(name, uid, token, cid, ss, first)
        log(f"  {'✅' if ok else '⚠️'} {name}")

    log(f"\n输出: {OUT}")

asyncio.run(main())

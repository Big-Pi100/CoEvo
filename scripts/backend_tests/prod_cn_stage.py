#!/usr/bin/env python3
"""Stage completion test with CORRECT Chinese subject names."""
import asyncio, websockets, json, urllib.request, time, os
from datetime import datetime

API = "http://<OLD_VPS_IP>:8080"
WS = "ws://<OLD_VPS_IP>:8080/ws"
DS_KEY = os.environ.get("DEEPSEEK_API_KEY", "")  # 2026-09-26 移除硬编码密钥
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
    f"cn_stage_{datetime.now().strftime('%Y%m%d_%H%M%S')}")
os.makedirs(OUT, exist_ok=True)
MAX = 40

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

suser = {"math":{"sys":"你是初中生在学习数学。认真回答老师的问题。","first":"老师好！请开始教我数学。"},
         "chinese":{"sys":"你是一个小学低年级学生。语文老师正在教你课文。用小朋友的语气说话。","first":"老师好！我们今天学什么课文呀？"}}

async def run(name, uid, token, cid, cfg):
    log(f"\n{'='*60}\n=== {name} ===")
    dt0, tt0, ds0, ts0, _ = plan_info(cid) or (0,0,0,0,[])
    log(f"开始: {dt0}/{tt0}任务, {ds0}/{ts0}阶段")

    async with websockets.connect(WS) as ws:
        hist, pv, last = [], 0, ""
        msg = json.dumps({"user_id": uid, "conversation_id": cid, "token": token, "message": cfg["first"]})
        await ws.send(msg)
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
            sm = llm(cfg["sys"], ctx)
            await ws.send(json.dumps({"user_id": uid, "conversation_id": cid, "message": sm}))
            reply = ""
            while True:
                d = json.loads(await asyncio.wait_for(ws.recv(), 120))
                t = d.get("type", "")
                if t == "token": reply += d.get("content", "")
                elif t == "done": break
                elif t == "error": log(f"ERR: {d.get('content')}"); return False
            hist.append(f"老师: {reply}")

            dt, tt, ds, ts, sn = plan_info(cid) or (0,0,0,0,[])
            cur = f"{ds}/{ts}"
            if cur != last:
                pv += 1; last = cur
                log(f"  Plan#{pv}: {dt}/{tt}任务, {ds}/{ts}阶段")
            if ds >= 1:
                log(f"✅ {name}: 完成{ds}/{ts}阶段! ({dt}/{tt}任务, {pv}次更新)")
                return True
            if turn % 5 == 0 and pv > 0:
                log(f"  [T{turn}] {dt}/{tt}任务, {ds}/{ts}阶段")
            await asyncio.sleep(0.3)

        dt, tt, ds, ts, _ = plan_info(cid) or (0,0,0,0,[])
        log(f"  [{name}] 结束: {dt}/{tt}任务, {ds}/{ts}阶段")
        return ds >= 1

def plan_info(cid):
    try:
        p = get(f"/api/plans?conversation_id={cid}")
        plans = p.get("plans", [])
        if not plans: return (0,0,0,0,[])
        p = plans[0].get("plan", {})
        stages = p.get("stages", [])
        if not stages: return (0,0,0,0,[])
        tt, dt, ds, sn = 0, 0, 0, []
        for s in stages:
            tasks = s.get("tasks", [])
            sdone = all(t.get("status") == "done" for t in tasks) if tasks else False
            tt += len(tasks)
            dt += sum(1 for t in tasks if t.get("status") == "done")
            if sdone: ds += 1
            sn.append(s.get("name", "?"))
        return (dt, tt, ds, len(stages), sn)
    except: return None

async def main():
    log("=== 正确中文名 阶段完成测试 ===")
    configs = [
        ("math", "user_b2a1299b", "724bb995-76f7-44bd-8943-15982b6e2fca", "3d600bd5-c387-4ac1-9920-e11d3fc06782",
         suser["math"]["sys"], suser["math"]["first"]),
        ("chinese", "user_1038ae9e", "4b010780-f609-4aea-8909-1f122da7fe3d", "21d51292-5fba-44a7-9731-7ca28cb436a7",
         suser["chinese"]["sys"], suser["chinese"]["first"]),
    ]
    for name, uid, token, cid, ss, first in configs:
        c = {"sys": ss, "first": first}
        ok = await run(name, uid, token, cid, c)
        log(f"  {'✅' if ok else '⚠️'} {name}")

    log(f"\n输出: {OUT}")
    log(f"\n前端登录账号:")
    log(f"  数学: mathcn... / test123 (查看用户列表确定完整用户名)")
    log(f"  语文: chicn... / test123")

asyncio.run(main())

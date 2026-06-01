#!/usr/bin/env python3
"""Test CP2 plan creation after signal prompt fix."""
import asyncio, websockets, json, urllib.request, ssl

API = "https://keyievolution.fun"
WS = "wss://keyievolution.fun/ws"
UID = "user_56177744"
TKN = "9a2a0fc7-a60e-4338-a7e7-c06aaa7bb8f0"

async def main():
    ctx = ssl.create_default_context()
    
    async with websockets.connect(WS, ssl=ctx) as ws:
        print("[1/2] Sending '教集合' ...")
        await ws.send(json.dumps({
            "user_id": UID, "conversation_id": UID, "token": TKN,
            "message": "老师你好！请教我集合的概念。"
        }))
        
        reply, done, plan_upd = "", False, False
        while True:
            try:
                data = json.loads(await asyncio.wait_for(ws.recv(), 90))
            except asyncio.TimeoutError:
                break
            t = data.get("type","")
            if t == "token": reply += data.get("content","")
            elif t == "done": done = True
            elif t == "plan_updated": plan_upd = True; print("  [plan_updated!]")
            elif t == "error": print(f"  [Error: {data}]")
            if done:
                try:
                    while True:
                        extra = json.loads(await asyncio.wait_for(ws.recv(), 15))
                        if extra.get("type") == "plan_updated": plan_upd = True; print("  [plan_updated!]")
                except asyncio.TimeoutError:
                    break
                break
    
    print(f"  Plan updated notification: {'YES' if plan_upd else 'NO'}")
    
    # Check plan
    req = urllib.request.Request(f"{API}/api/plans?conversation_id={UID}",
        headers={"Authorization": f"Bearer {TKN}"})
    after = json.loads(urllib.request.urlopen(req, context=ctx, timeout=15).read().decode())
    plans = after.get("plans", [])
    print(f"  Plans found: {len(plans)}")
    if plans:
        p = plans[0]
        plan = p.get("plan", {})
        stages = plan.get("stages", [])
        print(f"  Goal: {p.get('goal','?')[:60]}")
        print(f"  Stages: {len(stages)}")
        for s in stages[:2]:
            print(f"    {s.get('name','?')}: {len(s.get('tasks',[]))} tasks")
        print("\n✅ CP2 plan creation SUCCESS!")
    else:
        print("\n❌ CP2 plan creation FAILED")
        print(f"  Teacher ({len(reply)} chars): {reply[:150]}...")

asyncio.run(main())

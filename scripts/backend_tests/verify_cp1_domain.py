#!/usr/bin/env python3
"""Verify CP1 domain fix: free dialogue cards get domain='general'."""
import asyncio, websockets, json, urllib.request, time

API = "https://keyievolution.fun"
WS = "wss://keyievolution.fun/ws"

async def main():
    ts = int(time.time())
    r = json.loads(urllib.request.urlopen(urllib.request.Request(f"{API}/api/auth/register",
        data=json.dumps({"username": f"cp1v{ts}", "password": "test123"}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")).read().decode())
    uid, token = r["user_id"], r["token"]
    print(f"User: {uid}")

    async with websockets.connect(WS) as ws:
        await ws.send(json.dumps({"user_id": uid, "conversation_id": uid, "token": token,
            "message": "老师你好！请教我关于黑洞的知识。"}))
        candidates = []
        done = False
        while True:
            data = json.loads(await asyncio.wait_for(ws.recv(), 120))
            t = data.get("type", "")
            if t == "candidates":
                candidates.extend(data.get("candidates", []))
            elif t == "done":
                done = True
            if done:
                try:
                    extra = json.loads(await asyncio.wait_for(ws.recv(), 15))
                    if extra.get("type") == "candidates":
                        candidates.extend(extra.get("candidates", []))
                except asyncio.TimeoutError:
                    break

    print(f"\nCandidates: {len(candidates)}")
    for c in candidates:
        print(f"  front={c.get('front','?')[:30]} domain={c.get('domain','?')}")
    domains = set(c.get("domain", "?") for c in candidates)
    if "general" in domains:
        print("\nPASS: domain=general for free dialogue")
    else:
        print(f"\nUNEXPECTED domains: {domains}")

asyncio.run(main())

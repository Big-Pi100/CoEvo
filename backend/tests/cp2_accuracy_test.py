#!/usr/bin/env python3
"""CP2 accuracy test: verify CP2 doesn't fire on quiz passes, only on task completion."""
import asyncio, websockets, json, urllib.request, time

API = "http://<OLD_VPS_IP>:8080"
WS = "ws://<OLD_VPS_IP>:8080/ws"
DS_KEY = "sk-***REDACTED***"
UID = "user_c775635f"
CID = "e6554101-bc73-40a6-820a-540ac1dba865"
TKN = "426e1618-14c7-4f02-97e2-c31a5c3e1479"
SYS = "你是初中生学习数学。认真回答老师的问题。如果不懂就问。"

def log(m):
    print(f"[{time.strftime('%H:%M:%S')}] {m}")

def student_reply(context):
    p = {"model": "deepseek-chat", "temperature": 0.7, "max_tokens": 512,
         "messages": [{"role": "system", "content": SYS}, {"role": "user", "content": context}]}
    req = urllib.request.Request("https://api.deepseek.com/chat/completions",
        json.dumps(p).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {DS_KEY}"},
        method="POST")
    return json.loads(urllib.request.urlopen(req, timeout=60).read().decode())["choices"][0]["message"]["content"]

def plan_summary():
    try:
        ps = json.loads(urllib.request.urlopen(
            urllib.request.Request(f"{API}/api/plans?conversation_id={CID}"), timeout=30).read().decode())
        for plan in ps.get("plans", []):
            p = plan.get("plan", {})
            for s in p.get("stages", []):
                tasks = s.get("tasks", [])
                dt = sum(1 for t in tasks if t.get("status") == "done")
                ip = sum(1 for t in tasks if t.get("status") == "in_progress")
                sn = s.get("name", "?")
                log(f"  Stage [{sn}]: {dt}/{len(tasks)} done, {ip} in_progress")
        return True
    except Exception as e:
        log(f"  Plan check error: {e}")
        return False

async def send_turn(ws, msg):
    await ws.send(json.dumps({"user_id": UID, "conversation_id": CID, "token": TKN, "message": msg}))
    reply = ""
    while True:
        try:
            data = json.loads(await asyncio.wait_for(ws.recv(), 90))
        except asyncio.TimeoutError:
            break
        t = data.get("type", "")
        if t == "token": reply += data.get("content", "")
        elif t in ("done",): break
    return reply

async def main():
    log("=" * 60)
    log("CP2 误判测试: 小测验通过 vs 完整任务完成")
    log("=" * 60)
    log("初始计划状态:")
    plan_summary()

    async with websockets.connect(WS) as ws:
        # R1: 开始教学
        log("\n--- R1: 学生要求开始教学 ---")
        reply = await send_turn(ws, "老师好！请开始教我数学。")
        log(f"  T({len(reply)}字): {reply[:80]}...")

        # R2-R4: 学生自然回应教师的教学/小测验
        for r in range(2, 7):
            msg = student_reply(reply)
            log(f"\n--- R{r}: 学生回应 ---")
            log(f"  S: {msg[:60]}...")
            reply = await send_turn(ws, msg)
            log(f"  T({len(reply)}字): {reply[:80]}...")
            log("计划状态:")
            plan_summary()

        # R7: 学生说学完了
        log("\n--- R7: 学生表示全部学会 ---")
        reply = await send_turn(ws, "老师，我全部学完了！都会了！")
        log(f"  T({len(reply)}字): {reply[:80]}...")
        log("计划状态:")
        plan_summary()

        # R8-R10: 继续对话，看教师是否推进
        for r in range(8, 11):
            msg = student_reply(reply)
            log(f"\n--- R{r}: 继续 ---")
            log(f"  S: {msg[:60]}...")
            reply = await send_turn(ws, msg)
            log(f"  T({len(reply)}字): {reply[:80]}...")
            log("计划状态:")
            plan_summary()

    log("\n最终计划状态:")
    plan_summary()

    # CP2 日志检查
    log("\n--- CP2 日志分析 ---")
    try:
        import subprocess
        r = subprocess.run(["ssh", "-i", "C:/Users/Lenovo/.ssh/coevo_key",
            "ubuntu@<OLD_VPS_IP>",
            f"grep 'CP2 complete' /opt/coevo/data/logs/coevo.log.2026-05-31 2>/dev/null | grep '{UID[:15]}' | tail -5"],
            capture_output=True, text=True, timeout=10)
        if r.stdout.strip():
            log("CP2 触发了 complete_task:")
            for line in r.stdout.strip().split("\n"):
                log(f"  {line[:120]}")
        else:
            log("CP2 未触发 complete_task (无误判)")
    except Exception as e:
        log(f"  SSH error: {e}")

if __name__ == "__main__":
    asyncio.run(main())

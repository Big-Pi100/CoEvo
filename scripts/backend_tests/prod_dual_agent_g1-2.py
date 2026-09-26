#!/usr/bin/env python3
"""Production dual-agent test: Chinese g1-2 reading mode."""
import asyncio, websockets, json, urllib.request, time, os, subprocess
from datetime import datetime

API = "http://<OLD_VPS_IP>:8080"
WS = "ws://<OLD_VPS_IP>:8080/ws"
DS_KEY = os.environ.get("DEEPSEEK_API_KEY", "")  # 2026-09-26 移除硬编码密钥
DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
    "prod_g1-2_" + datetime.now().strftime("%Y%m%d_%H%M%S"))
MAX_T = 6
os.makedirs(DIR, exist_ok=True)

# Pre-created: user with subscription + reading plan initialized
# user_d28db062, conversation=18943012-9297-42db-b079-8dbb5239c4e7
UID = "user_6f0ce5fb"
CID = "29999e25-3ffa-47f5-916d-a726a7c8b47b"

def log(m):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] {m}")
    with open(os.path.join(DIR, "run.log"), "a", encoding="utf-8") as f:
        f.write(f"[{ts}] {m}\n")

def post(path, data, token=None):
    h = {"Content-Type": "application/json"}
    if token: h["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(f"{API}{path}", json.dumps(data).encode(), headers=h, method="POST")
    return json.loads(urllib.request.urlopen(req, timeout=30).read().decode())

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

def save(t, fn, c):
    p = os.path.join(DIR, f"turn_{t:03d}")
    os.makedirs(p, exist_ok=True)
    with open(os.path.join(p, fn), "w", encoding="utf-8") as f:
        f.write(c)

SYS_STU = (
    "你是一个小学低年级学生（一、二年级）。你的语文老师正在教你课文。\n"
    "行为规则：\n- 用小朋友的语气说话，句子简短\n"
    "- 老师提问时，尽可能回答\n- 如果老师问你是否理解，用你自己的话简单复述\n"
    "- 对不明白的地方可以问老师\n- 直接输出你要说的话，不要加前缀"
)

async def main():
    log("=== 语文 g1-2 阅读模式双智能体测试 ===")

    # Login
    r = post("/api/auth/login", {"username": "cp2fix2", "password": "test123"})
    token = r["token"]
    log(f"登录: {UID}")

    # WS
    async with websockets.connect(WS) as ws:
        log("WS 连接成功\n")
        hist = []
        pstates = []

        # Turn 0
        await ws.send(json.dumps({"user_id": UID, "conversation_id": CID, "token": token,
            "message": "老师好！我们今天要学什么课文呀？",
            "mode": "reading", "subject": "chinese", "grade_band": "g1-2"}))
        log("[T0] 学生: 老师好！我们今天要学什么课文呀？")
        save(0, "student.txt", "老师好！我们今天要学什么课文呀？")

        reply = ""
        while True:
            data = await asyncio.wait_for(ws.recv(), timeout=60)
            j = json.loads(data)
            t = j.get("type", "")
            if t == "token": reply += j.get("content", "")
            elif t == "planning": log("  [生成学习计划...]")
            elif t == "plan_updated": log("  [学习计划已更新!]")
            elif t == "done":
                reply = j.get("reply", reply); break
            elif t == "error": log(f"  ERROR: {j.get('content')}"); return

        log(f"[T0] 教师 ({len(reply)}字)\n{reply[:400]}...\n")
        save(0, "teacher.txt", reply)
        hist.append(f"老师: {reply}")
        try:
            ps = get(f"/api/plans?conversation_id={CID}")
            pstates.append(ps); save(0, "plan_state.json", json.dumps(ps, indent=2, ensure_ascii=False))
        except Exception as e: log(f"[T0] plan: {e}")

        # Turns 1-N
        for turn in range(1, MAX_T + 1):
            log(f"\n{'='*50}\n第{turn}轮\n{'='*50}")

            ctx = "\n".join(hist[-6:])
            sm = llm(SYS_STU, ctx)
            log(f"[T{turn}] 学生 ({len(sm)}字)\n{sm}\n")
            save(turn, "student.txt", sm)

            await ws.send(json.dumps({"user_id": UID, "conversation_id": CID, "message": sm}))

            reply = ""
            while True:
                data = await asyncio.wait_for(ws.recv(), timeout=90)
                j = json.loads(data)
                t = j.get("type", "")
                if t == "token": reply += j.get("content", "")
                elif t == "planning": log("  [更新学习计划...]")
                elif t == "plan_updated": log("  [学习计划已更新!]")
                elif t == "done":
                    reply = j.get("reply", reply); break
                elif t == "error": log(f"  ERROR: {j.get('content')}"); return

            log(f"[T{turn}] 教师 ({len(reply)}字)\n{reply[:400]}...\n")
            save(turn, "teacher.txt", reply)
            hist.append(f"老师: {reply}")

            # Plan check
            try:
                ps = get(f"/api/plans?conversation_id={CID}")
                pstates.append(ps); save(turn, "plan_state.json", json.dumps(ps, indent=2, ensure_ascii=False))
                plans = (ps or {}).get("plans", [])
                if plans:
                    pj = plans[0].get("plan_json", {})
                    if isinstance(pj, str): pj = json.loads(pj)
                    tasks = pj.get("task_status", {}) if isinstance(pj, dict) else {}
                    if tasks:
                        dc = sum(1 for v in tasks.values() if v == "done")
                        log(f"[T{turn}] 任务: {dc}/{len(tasks)} 完成")
                        if dc >= 2: break
            except Exception as e: log(f"[T{turn}] plan: {e}")

            await asyncio.sleep(0.5)

        log(f"\n对话完成，共{len(hist)}轮")

    # CP2 logs
    log("\n-- CP2日志 --")
    r = subprocess.run(
        ["ssh", "-i", os.path.expanduser("~/.ssh/coevo_key"),
         "ubuntu@<OLD_VPS_IP>",
         "sudo journalctl -u coevo --since '10 minutes ago' --no-pager | "
         "grep -i 'cp2\\|analyze_turn\\|WS turn\\|complete_task\\|plan_update\\|unlock_next' | tail -60"],
        capture_output=True, text=True, timeout=30)
    with open(os.path.join(DIR, "cp2_logs.txt"), "w", encoding="utf-8") as f:
        f.write(r.stdout or "(none)")
    if r.stdout:
        log("CP2内容:")
        for l in r.stdout.strip().split(chr(10)):
            log(f"  {l}")
    else:
        log("无CP2日志")

    # Full conversation
    fp = os.path.join(DIR, "full_conversation.txt")
    with open(fp, "w", encoding="utf-8") as f:
        f.write(f"语文 g1-2 对话\n日期:{datetime.now().isoformat()}\n{'='*60}\n\n")
        for ti in range(MAX_T + 1):
            base = os.path.join(DIR, f"turn_{ti:03d}")
            for rl in ["student", "teacher"]:
                rfp = os.path.join(base, rl + ".txt")
                if os.path.exists(rfp):
                    with open(rfp, encoding="utf-8") as rf:
                        f.write(f"【第{ti}轮 {'学生' if rl=='student' else '教师'}】\n{rf.read()}\n\n")
            f.write("-" * 40 + "\n")

    log(f"\n✅ 输出: {DIR}")
    log(f"对话: {fp}")
    return DIR

asyncio.run(main())

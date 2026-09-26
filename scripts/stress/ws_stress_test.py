#!/usr/bin/env python3
"""
CoEvo WS 并发压力 + 持续负载测试
1. WS 并发: 多用户同时 WebSocket 聊天
2. 持续负载: 数分钟持续对话
3. 启动前部署内存监控脚本到 VPS

用法: python scripts/stress/ws_stress_test.py [--users 5] [--rounds 3]
"""

import sys, os, json, time, threading, statistics, argparse
from datetime import datetime
import requests

BASE = "http://<OLD_VPS_IP>:8080"
WS_BASE = "ws://<OLD_VPS_IP>:8080"
SSH_KEY = os.path.expanduser("~/.ssh/coevo_key")
TIMEOUT = 120

results = []
errors = []
lock = threading.Lock()


def ssh_run(cmd):
    import subprocess
    full_cmd = ["ssh", "-i", SSH_KEY, "-o", "StrictHostKeyChecking=no",
                "-o", "ConnectTimeout=10", "ubuntu@<OLD_VPS_IP>", cmd]
    try:
        r = subprocess.run(full_cmd, capture_output=True, text=True, timeout=30)
        return r.stdout, r.stderr, r.returncode
    except:
        return "", "timeout", -1


def setup_memory_monitor():
    """部署内存监控脚本到 VPS 后台运行"""
    print("  [Setup] 安装内存监控...")
    monitor_script = """#!/bin/bash
INTERVAL=5
LOG=/tmp/mem_monitor_$(date +%Y%m%d_%H%M%S).log
echo "timestamp,total_mb,used_mb,free_mb,available_mb,cpu_pct" > $LOG
while true; do
  TS=$(date +%H:%M:%S)
  MEM=$(free -m | grep Mem | awk '{print $2","$3","$4","$7}')
  CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2+$4}')
  echo "$TS,$MEM,$CPU" >> $LOG
  sleep $INTERVAL
done
"""
    # Write script on VPS
    ssh_run(f"cat > /tmp/mem_monitor.sh << 'SCRIPT'\n{monitor_script}\nSCRIPT\nchmod +x /tmp/mem_monitor.sh")
    ssh_run("pkill -f mem_monitor.sh 2>/dev/null; nohup /tmp/mem_monitor.sh > /dev/null 2>&1 &")
    print("  [Setup] 内存监控已在 VPS 后台启动")
    time.sleep(1)


def stop_memory_monitor():
    """停止内存监控并获取日志"""
    print("\n  [Collect] 停止内存监控...")
    logfile = ssh_run("ls -t /tmp/mem_monitor_*.log | head -1")[0].strip()
    if logfile:
        data = ssh_run(f"tail -20 {logfile}")[0]
        print(f"  [Collect] 内存日志最后 20 行:\n{data}")
        # Calculate peak and avg
        all_lines = ssh_run(f"cat {logfile}")[0].strip().split("\n")[1:]
        if len(all_lines) > 1:
            used_vals = [int(l.split(",")[2]) for l in all_lines if len(l.split(",")) >= 4]
            avail_vals = [int(l.split(",")[4]) for l in all_lines if len(l.split(",")) >= 5]
            if used_vals:
                print(f"  [Collect] Used: min={min(used_vals)} avg={sum(used_vals)//len(used_vals)} max={max(used_vals)} MB")
            if avail_vals:
                print(f"  [Collect] Available: min={min(avail_vals)} avg={sum(avail_vals)//len(avail_vals)} max={max(avail_vals)} MB")
        ssh_run(f"rm -f {logfile}")
    ssh_run("pkill -f mem_monitor.sh 2>/dev/null")
    print("  [Collect] 已清理")


def setup_users(n):
    """预建 n 个有 subscription 的用户（复用 chat_stress 的 setup 逻辑）"""
    print(f"  [Setup] 创建 {n} 个测试用户...")
    # Try to create users via API, set subscription via SSH
    for i in range(n):
        uname = f"wsstress{i}"
        try:
            r = requests.post(f"{BASE}/api/auth/register", json={
                "username": uname, "password": "stress123",
            }, timeout=15)
            uid = r.json().get("user_id", "")
            if not uid:
                # Try login
                r2 = requests.post(f"{BASE}/api/auth/login", json={
                    "username": uname, "password": "stress123",
                }, timeout=15)
                uid = r2.json().get("user_id", "")
        except:
            pass
    print(f"  [Setup] 完成")


def ws_session(username, round_num, msg):
    """单用户单轮 WS 对话"""
    try:
        # 1. Login to get token
        t0 = time.time()
        r = requests.post(f"{BASE}/api/auth/login", json={
            "username": username, "password": "stress123",
        }, timeout=30)
        d = r.json()
        uid = d.get("user_id", "")
        token = d.get("token", "")
        if not uid or not token:
            raise Exception(f"Login failed: {d}")
        login_lat = (time.time() - t0) * 1000

        # 2. Open WS and send message
        import websocket
        ws_lat_start = time.time()
        ws = websocket.create_connection(
            f"{WS_BASE}/ws", timeout=TIMEOUT,
            enable_multithread=True
        )

        # Send auth message first (with token)
        auth_msg = json.dumps({
            "user_id": uid,
            "conversation_id": f"wsstress{round_num}_{uid[:8]}",
            "message": msg,
            "token": token,
        })
        ws.send(auth_msg)

        # Receive responses
        responses = []
        timeout_at = time.time() + 60
        while time.time() < timeout_at:
            try:
                resp = json.loads(ws.recv())
                responses.append(resp)
                if "reply" in resp:
                    break
            except:
                break

        ws.close()
        ws_lat = (time.time() - ws_lat_start) * 1000

        # Parse response
        reply_text = ""
        plan_updated = False
        for resp in responses:
            if "reply" in resp:
                reply_text = resp.get("reply", "")
                plan_updated = resp.get("plan_updated", False)
                break

        with lock:
            results.append({
                "op": "ws_chat", "lat_ms": ws_lat, "status": "ok" if reply_text else "no_reply",
                "chars": len(reply_text), "plan_updated": plan_updated,
            })
        status = f"{'✅' if reply_text else '❌'} {ws_lat:.0f}ms"
        print(f"  [{username}] WS chat: {ws_lat:.0f}ms {'✅' if reply_text else '❌'}")

    except Exception as e:
        with lock:
            errors.append({"user": username, "error": str(e)[:100]})
        print(f"  ❌ [{username}] {str(e)[:60]}")


def run(users=5, rounds=3):
    print(f"\n{'='*60}")
    print(f"  CoEvo VPS — WS 并发 + 持续负载测试")
    print(f"  目标: {WS_BASE}/ws")
    print(f"  用户: {users} x {rounds} 轮 = {users * rounds} WS 调用")
    print(f"  每轮: websocket 发送消息 → 接收 LLM 回复")
    print(f"{'='*60}")

    MESSAGES = [
        "什么是欧姆定律？",
        "帮我解释一下光合作用的过程。",
        "《静夜思》表达了什么情感？",
        "勾股定理的证明方法有哪些？",
        "简述细胞分裂的过程。",
    ]

    setup_memory_monitor()
    setup_users(users)
    time.sleep(2)

    start = time.time()

    for rnd in range(1, rounds + 1):
        print(f"\n--- Round {rnd}/{rounds} ---")
        msg = MESSAGES[(rnd - 1) % len(MESSAGES)]
        threads = []
        for i in range(users):
            name = f"wsstress{i}"
            t = threading.Thread(target=ws_session, args=(name, rnd, msg))
            threads.append(t)
            t.start()
        for t in threads:
            t.join()
        print(f"  Round {rnd} done. Errors so far: {len(errors)}")

    elapsed = time.time() - start
    stop_memory_monitor()

    # Report
    print(f"\n{'='*60}")
    print(f"  WS 压力测试结果")
    print(f"{'='*60}")

    ops = {}
    for r in results:
        ops.setdefault(r["op"], []).append(r)

    print(f"\n  {'Op':<20} {'Count':>6} {'Min(ms)':>10} {'Avg(ms)':>10} {'Max(ms)':>10} {'P99(ms)':>10} {'Fail':>6}")
    print("  " + "-" * 72)
    all_lats = []
    total_chars = 0
    plan_updates = 0
    for op, vals in sorted(ops.items()):
        lats = [v["lat_ms"] for v in vals if v["lat_ms"] > 0]
        if not lats:
            continue
        fails = sum(1 for v in vals if v.get("status") not in ("ok",))
        p99 = sorted(lats)[int(len(lats) * 0.99)] if len(lats) > 10 else max(lats)
        print(f"  {op:<20} {len(lats):>6} {min(lats):>10.0f} {statistics.mean(lats):>10.0f} {max(lats):>10.0f} {p99:>10.0f} {fails:>6}")
        all_lats.extend(lats)
        if op == "ws_chat":
            total_chars = sum(v.get("chars", 0) for v in vals)
            plan_updates = sum(1 for v in vals if v.get("plan_updated"))

    print(f"\n  {'-'*60}")
    print(f"  Total WS calls: {sum(len(v) for v in ops.values())}")
    print(f"  Duration: {elapsed:.1f}s")
    print(f"  Avg WS latency: {statistics.mean(all_lats):.0f}ms" if all_lats else "")
    print(f"  Errors: {len(errors)}")
    print(f"  Throughput: {sum(len(v) for v in ops.values()) / elapsed:.1f} req/s" if elapsed > 0 else "")
    print(f"")
    print(f"  WS 统计:")
    print(f"    Total reply chars: {total_chars}")
    print(f"    Plan updates: {plan_updates}")
    print(f"")
    print(f"  Overall: {'PASS' if len(errors) == 0 else 'WARN' if len(errors) < sum(len(v) for v in ops.values()) * 0.1 else 'FAIL'}")

    if errors:
        print(f"\n  Errors:")
        for e in errors[:5]:
            print(f"    {e['user']}: {e['error'][:80]}")

    print(f"{'='*60}\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--users", type=int, default=5)
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    try:
        run(args.users, args.rounds)
    except KeyboardInterrupt:
        print("\nInterrupted, cleaning...")
        stop_memory_monitor()
        sys.exit(1)
    except Exception as e:
        print(f"\nError: {e}")
        stop_memory_monitor()
        sys.exit(1)

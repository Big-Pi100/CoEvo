#!/usr/bin/env python3
"""
CoEvo VPS 生产环境 — 真实 LLM 对话流压力测试
测试内容: POST /api/chat (认证 + DB + DeepSeek API 调用 + 计划更新)
成本估算: 每次 LLM 调用约 0.001-0.003 元 (DeepSeek-V4-Flash)
          200 次 ≈ 0.2-0.6 元

用法: python scripts/stress/chat_stress_test.py [--users 10] [--rounds 1] [--batch 10]
"""

import sys, os, json, time, threading, statistics, argparse
from datetime import datetime
import requests

BASE = "http://<OLD_VPS_IP>:8080"
SSH_KEY = os.path.expanduser("~/.ssh/coevo_key")
STRESS_PREFIX = "chatstress"
TIMEOUT = 60  # LLM 调用可能需要更长时间

results = []
errors = []
lock = threading.Lock()


def ssh_run(cmd):
    """在 VPS 上运行命令，返回 stdout, stderr, rc"""
    import subprocess
    full_cmd = ["ssh", "-i", SSH_KEY, "-o", "StrictHostKeyChecking=no",
                "-o", "ConnectTimeout=10", "ubuntu@<OLD_VPS_IP>", cmd]
    r = subprocess.run(full_cmd, capture_output=True, text=True, timeout=30)
    if r.stderr:
        print(f"  [SSH stderr] {r.stderr[:200]}")
    return r.stdout, r.stderr, r.returncode


def setup(n):
    """注册用户 + 写入 subscription + 创建 conversation"""
    print(f"\n{'='*60}")
    print(f"  [Setup] 创建 {n} 个用户 + subscription + conversation")
    print(f"{'='*60}")
    success = 0
    for i in range(n):
        name = f"{STRESS_PREFIX}{i}"
        try:
            r = requests.post(f"{BASE}/api/auth/register", json={
                "username": name, "password": "stress123",
            }, timeout=15)
            data = r.json()
            uid = data.get("user_id", "")
            if r.status_code == 200 and uid:
                out, err, _ = ssh_run(f"sqlite3 /opt/coevo/data/coevo.db 'INSERT OR IGNORE INTO user_preferences (user_id, key, value, updated_at) VALUES (\"{uid}\", \"subscription_expires\", \"2099-12-31T23:59:59Z\", \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\");'")
                success += 1
            else:
                # 已存在，检查能否登录
                r2 = requests.post(f"{BASE}/api/auth/login", json={
                    "username": name, "password": "stress123",
                }, timeout=15)
                d2 = r2.json()
                uid = d2.get("user_id", "")
                if uid:
                    out, err, _ = ssh_run(f"sqlite3 /opt/coevo/data/coevo.db 'INSERT OR IGNORE INTO user_preferences (user_id, key, value, updated_at) VALUES (\"{uid}\", \"subscription_expires\", \"2099-12-31T23:59:59Z\", \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\");'")
                    success += 1
        except Exception as e:
            print(f"  [WARN] {name}: {e}")

    for i in range(n):
        uid_query = f"{STRESS_PREFIX}{i}"
        uid = get_uid(uid_query)
        if uid:
            now = datetime.utcnow().isoformat()
            conv_id = f"{uid_query}_conv"
            ssh_run(f"sqlite3 /opt/coevo/data/coevo.db 'INSERT OR IGNORE INTO conversations (id, user_id, turn_count, started_at, subject, grade_band) VALUES (\"{conv_id}\", \"{uid}\", 0, \"{now}\", \"语文\", \"g1-2\");'")

    print(f"  [Setup] {success}/{n} 就绪")
    return True


def get_uid(username):
    """通过 SSH 查 DB 获取 user_id"""
    out, _, _ = ssh_run(
        f"cd /opt/coevo/data && sqlite3 coevo.db "
        f"\"SELECT id FROM users WHERE username = '{username}' LIMIT 1;\""
    )
    return out.strip()


def cleanup():
    """清理所有测试数据"""
    print("\n  [Cleanup] 清理测试数据...")
    sql = ("DELETE FROM cards WHERE user_id IN (SELECT id FROM users WHERE username LIKE 'chatstress%');"
           "DELETE FROM card_memory WHERE card_id IN (SELECT id FROM cards WHERE user_id IN (SELECT id FROM users WHERE username LIKE 'chatstress%'));"
           "DELETE FROM learning_plans WHERE conversation_id LIKE 'chatstress%';"
           "DELETE FROM conversation_turns WHERE conversation_id LIKE 'chatstress%';"
           "DELETE FROM conversations WHERE id LIKE 'chatstress%';"
           "DELETE FROM tokens WHERE user_id IN (SELECT id FROM users WHERE username LIKE 'chatstress%');"
           "DELETE FROM user_preferences WHERE user_id IN (SELECT id FROM users WHERE username LIKE 'chatstress%');"
           "DELETE FROM users WHERE username LIKE 'chatstress%';")
    ssh_run(f"sqlite3 /opt/coevo/data/coevo.db '{sql}'")
    print("  [Cleanup] 完成")


def session(username, conv_id, message, round_num):
    """单用户一轮真实对话"""
    try:
        # 1. Login -> token
        t0 = time.time()
        r = requests.post(f"{BASE}/api/auth/login", json={
            "username": username, "password": "stress123",
        }, timeout=30)
        data = r.json()
        uid = data.get("user_id", "")
        token = data.get("token", "")
        if not uid or not token:
            raise Exception(f"Login failed: {data}")
        login_lat = (time.time() - t0) * 1000
        with lock:
            results.append({"op": "login", "lat_ms": login_lat, "status": "ok"})

        headers = {"Authorization": f"Bearer {token}"}

        # 2. Chat (real LLM call!)
        t0 = time.time()
        r = requests.post(f"{BASE}/api/chat", json={
            "user_id": uid,
            "conversation_id": conv_id,
            "message": message,
        }, headers=headers, timeout=TIMEOUT)
        t1 = time.time()
        data = r.json()
        chat_lat = (t1 - t0) * 1000

        if r.status_code == 200 and "reply" in data:
            reply = data["reply"]
            reply_chars = len(reply)
            plan_updated = data.get("plan_updated", False)
            token_est = reply_chars // 2
            with lock:
                results.append({
                    "op": "chat", "lat_ms": chat_lat, "status": "ok",
                    "chars": reply_chars, "tokens_est": token_est,
                    "plan_updated": plan_updated,
                })
            status = "ok"
        else:
            error_msg = str(data.get("error", data))[:80]
            with lock:
                results.append({"op": "chat", "lat_ms": chat_lat, "status": "error",
                               "error": error_msg})
            status = f"ERR: {error_msg}"

        print(f"  [{username}] Chat: {chat_lat:.0f}ms {status}")

    except Exception as e:
        with lock:
            errors.append({"user": username, "error": str(e)[:100]})


def run(users=10, rounds=1, batch=10):
    print(f"\n{'='*60}")
    print(f"  CoEvo VPS - 真实 LLM 对话流压力测试")
    print(f"  目标: {BASE}")
    print(f"  并发: {users} 用户 x {rounds} 轮 = {users * rounds} 次 LLM 调用")
    print(f"  分批: 每批 {batch} 用户（防 API 限流）")
    print(f"  每次调用: POST /api/chat -> DeepSeek-V4-Flash")
    print(f"  预计成本: ~{users * rounds * 0.002:.2f} 元 (约 {users * rounds * 0.002 * 100:.2f} 分)")
    print(f"{'='*60}")

    setup(users)
    time.sleep(2)

    MESSAGES = [
        "请用简单的话介绍什么是机器学习？",
        "勾股定理是什么？",
        "《静夜思》的作者是谁？这首诗表达了什么？",
        "什么是光合作用？",
        "帮我解释一下牛顿第一定律。",
    ]

    start = time.time()

    for rnd in range(1, rounds + 1):
        print(f"\n--- Round {rnd}/{rounds} ---")
        for batch_start in range(0, users, batch):
            batch_end = min(batch_start + batch, users)
            batch_no = batch_start // batch + 1
            total_b = (users - 1) // batch + 1
            msg = MESSAGES[(rnd - 1 + batch_no) % len(MESSAGES)]
            print(f"  Batch {batch_no}/{total_b}: [{batch_start}-{batch_end-1}] msg='{msg}'")

            threads = []
            for i in range(batch_start, batch_end):
                name = f"{STRESS_PREFIX}{i}"
                conv_id = f"{name}_conv"
                t = threading.Thread(target=session, args=(name, conv_id, msg, rnd))
                threads.append(t)
                t.start()
            for t in threads:
                t.join()
            print(f"  Batch {batch_no} done. Errors so far: {len(errors)}")

    elapsed = time.time() - start

    # Report
    print(f"\n{'='*60}")
    print(f"  LLM 对话流压力测试结果")
    print(f"{'='*60}")

    ops = {}
    for r in results:
        op = r["op"]
        ops.setdefault(op, []).append(r)

    print(f"\n  {'Op':<20} {'Count':>6} {'Min(ms)':>10} {'Avg(ms)':>10} {'Max(ms)':>10} {'P99(ms)':>10} {'Fail':>6}")
    print("  " + "-" * 72)
    all_lats = []
    total_chars = 0
    total_tokens = 0
    plan_updates = 0
    for op, vals in sorted(ops.items()):
        lats = [v["lat_ms"] for v in vals if v["lat_ms"] > 0]
        if not lats:
            continue
        fails = sum(1 for v in vals if v.get("status") in ("error", "fail"))
        p99 = sorted(lats)[int(len(lats) * 0.99)] if len(lats) > 10 else max(lats)
        print(f"  {op:<20} {len(lats):>6} {min(lats):>10.0f} {statistics.mean(lats):>10.0f} {max(lats):>10.0f} {p99:>10.0f} {fails:>6}")
        all_lats.extend(lats)

        if op == "chat":
            total_chars = sum(v.get("chars", 0) for v in vals)
            total_tokens = sum(v.get("tokens_est", 0) for v in vals)
            plan_updates = sum(1 for v in vals if v.get("plan_updated"))

    chat_vals = [v for v in results if v["op"] == "chat"]
    lats = [v["lat_ms"] for v in chat_vals if v["lat_ms"] > 0]
    llm_avg = statistics.mean(lats) if lats else 0

    print(f"\n  {'-'*60}")
    print(f"  Total requests: {len(results)}")
    print(f"  Duration: {elapsed:.1f}s")
    print(f"  Avg latency: {statistics.mean(all_lats):.0f}ms" if all_lats else "")
    print(f"  Errors: {len(errors)}")
    print(f"  Throughput: {len(results) / elapsed:.1f} req/s" if elapsed > 0 else "")
    print(f"")
    print(f"  LLM 对话统计:")
    print(f"    Chat calls: {len(chat_vals)}")
    print(f"    Avg LLM latency: {llm_avg:.0f}ms")
    print(f"    Total reply chars: {total_chars}")
    print(f"    Estimated output tokens: {total_tokens}")
    print(f"    Plan updates triggered: {plan_updates}")
    print(f"    Estimated cost: ~{total_tokens / 1_000_000 * 2:.2f} 元 (DeepSeek 输出 ~2元/百万token)")
    print(f"")
    print(f"  Overall: {'PASS' if len(errors) == 0 else 'WARN' if len(errors) < len(results) * 0.1 else 'FAIL'}")

    if errors:
        print(f"\n  Errors:")
        for e in errors[:5]:
            print(f"    {e['user']}: {e['error'][:80]}")

    print(f"{'='*60}\n")
    cleanup()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--users", type=int, default=10,
                        help="用户数 (默认 10, 每次聊天调用真实 LLM)")
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--batch", type=int, default=5,
                        help="每批并发数 (默认 5, 防 API 限流)")
    args = parser.parse_args()
    try:
        run(args.users, args.rounds, args.batch)
    except KeyboardInterrupt:
        print("\nInterrupted, cleaning...")
        cleanup()
        sys.exit(1)
    except Exception as e:
        print(f"\nError: {e}")
        cleanup()
        sys.exit(1)

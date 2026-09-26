#!/usr/bin/env python3
"""
CoEvo VPS 生产环境压力测试
测试项目：多用户并发、用户隔离、API 响应性能
用法：python scripts/stress/vps_stress_test.py [--users 200] [--rounds 1]
"""

import sys, os, json, time, threading, statistics, argparse
from datetime import datetime
import requests

BASE = "http://<OLD_VPS_IP>:8080"
SSH_KEY = os.path.expanduser("~/.ssh/coevo_key")
STRESS_PREFIX = "stress"
TIMEOUT = 30

results = []
errors = []
lock = threading.Lock()


def ssh_run(cmd):
    import subprocess
    full_cmd = ["ssh", "-i", SSH_KEY, "-o", "StrictHostKeyChecking=no",
                "-o", "ConnectTimeout=10", "ubuntu@<OLD_VPS_IP>", cmd]
    r = subprocess.run(full_cmd, capture_output=True, text=True, timeout=30)
    return r.stdout, r.stderr, r.returncode


def setup_test_users(n):
    """通过 API 注册 n 个用户"""
    print(f"\n{'='*60}")
    print(f"  [Setup] 创建 {n} 个压力测试用户")
    print(f"{'='*60}")

    success = 0
    for i in range(n):
        username = f"{STRESS_PREFIX}{i}"
        try:
            r = requests.post(f"{BASE}/api/auth/register", json={
                "username": username, "password": "stress123",
            }, timeout=15)
            data = r.json()
            if r.status_code == 200 and "user_id" in data:
                uid = data["user_id"]
                ssh_run(f"cd /opt/coevo/data && sqlite3 coevo.db "
                        f"\"INSERT OR IGNORE INTO user_preferences (user_id, key, value) "
                        f"VALUES ('{uid}', 'subscription_expires', '2099-12-31T23:59:59Z');\"")
                success += 1
            else:
                # 尝试登录
                r2 = requests.post(f"{BASE}/api/auth/login", json={
                    "username": username, "password": "stress123",
                }, timeout=15)
                if r2.status_code == 200 and "user_id" in r2.json():
                    uid2 = r2.json()["user_id"]
                    ssh_run(f"cd /opt/coevo/data && sqlite3 coevo.db "
                            f"\"INSERT OR IGNORE INTO user_preferences (user_id, key, value) "
                            f"VALUES ('{uid2}', 'subscription_expires', '2099-12-31T23:59:59Z');\"")
                    success += 1
        except Exception as e:
            print(f"  [WARN] 用户 {username}: {e}")

    for i in range(n):
        uid = f"{STRESS_PREFIX}{i}"
        now = datetime.utcnow().isoformat()
        ssh_run(f"cd /opt/coevo/data && sqlite3 coevo.db "
                f"\"INSERT OR IGNORE INTO conversations (id, user_id, turn_count, started_at) "
                f"VALUES ('{uid}_conv', '{uid}', 0, '{now}');\"")

    print(f"  [Setup] {success}/{n} 用户就绪")
    return success > 0


def clean_test_users():
    print("\n  [Cleanup] 清理压力测试数据...")
    sql = (f"DELETE FROM cards WHERE user_id LIKE '{STRESS_PREFIX}%';"
           f"DELETE FROM card_memory WHERE card_id LIKE 'stress_%';"
           f"DELETE FROM learning_plans WHERE conversation_id LIKE '{STRESS_PREFIX}%';"
           f"DELETE FROM conversation_turns WHERE conversation_id LIKE '{STRESS_PREFIX}%';"
           f"DELETE FROM conversations WHERE id LIKE '{STRESS_PREFIX}%';"
           f"DELETE FROM tokens WHERE user_id LIKE '{STRESS_PREFIX}%';"
           f"DELETE FROM user_preferences WHERE user_id LIKE '{STRESS_PREFIX}%';"
           f"DELETE FROM users WHERE id LIKE '{STRESS_PREFIX}%' OR username LIKE '{STRESS_PREFIX}%';")
    ssh_run(f"cd /opt/coevo/data && sqlite3 coevo.db \"{sql}\"")
    print("  [Cleanup] 完成")


def session(username, round_num):
    """单用户单轮操作序列"""
    token = None
    uid = None

    try:
        # 1. Login
        t0 = time.time()
        r = requests.post(f"{BASE}/api/auth/login", json={
            "username": username, "password": "stress123",
        }, timeout=TIMEOUT)
        t1 = time.time()
        data = r.json()
        lat = (t1 - t0) * 1000

        if r.status_code == 200 and "user_id" in data:
            uid = data["user_id"]
            token = data.get("token", "")
            with lock:
                results.append({"op": "login", "lat_ms": lat, "status": "ok"})
        elif "already" in str(data).lower():
            # 被踢了，再登一次
            r2 = requests.post(f"{BASE}/api/auth/login", json={
                "username": username, "password": "stress123",
            }, timeout=TIMEOUT)
            t1 = time.time()
            d2 = r2.json()
            if "user_id" in d2:
                uid = d2["user_id"]
                token = d2.get("token", "")
                with lock:
                    results.append({"op": "login", "lat_ms": (t1 - t0) * 1000, "status": "ok"})
        else:
            raise Exception(f"Login failed: {data}")

        if not token or not uid:
            raise Exception("No token/user_id")

        headers = {"Authorization": f"Bearer {token}"}
        conv_id = f"{STRESS_PREFIX}{round_num}_{uid.split('_')[-1]}"

        # 2. Create plan
        t0 = time.time()
        r = requests.post(f"{BASE}/api/plans", json={
            "user_id": uid, "conversation_id": conv_id,
            "goal": f"test_round{round_num}", "domain": "stress",
            "plan_json": {"stages": [{"name": "阶段", "tasks": [{"name": "任务", "status": "in_progress"}]}]}
        }, headers=headers, timeout=TIMEOUT)
        t1 = time.time()
        if r.status_code == 200:
            with lock:
                results.append({"op": "create_plan", "lat_ms": (t1 - t0) * 1000, "status": "ok"})
        else:
            raise Exception(f"CreatePlan: {r.status_code} {r.text[:100]}")

        # 3. List plans
        t0 = time.time()
        r = requests.get(f"{BASE}/api/plans?user_id={uid}", headers=headers, timeout=TIMEOUT)
        t1 = time.time()
        if r.status_code == 200:
            with lock:
                results.append({"op": "list_plans", "lat_ms": (t1 - t0) * 1000, "status": "ok"})

        # 4. Batch create cards
        t0 = time.time()
        r = requests.post(f"{BASE}/api/cards/batch-create", json={
            "user_id": uid, "conversation_id": conv_id,
            "candidates": [{"front": f"概念{round_num}_{ci}", "back": f"释义{round_num}_{ci}", "source_sentence": ""} for ci in range(3)],
        }, headers=headers, timeout=TIMEOUT)
        t1 = time.time()
        with lock:
            results.append({"op": "create_card", "lat_ms": (t1 - t0) * 1000,
                           "status": "ok" if r.status_code == 200 else "fail"})

        # 5. List cards + data isolation
        t0 = time.time()
        r = requests.get(f"{BASE}/api/cards/all?user_id={uid}", headers=headers, timeout=TIMEOUT)
        t1 = time.time()
        if r.status_code == 200:
            cards = r.json()
            card_list = cards if isinstance(cards, list) else cards.get("cards", [])
            my_count = sum(1 for c in card_list if str(c.get("user_id", "")).startswith(STRESS_PREFIX))
            total = len(card_list)
            with lock:
                results.append({"op": "list_cards", "lat_ms": (t1 - t0) * 1000, "status": "ok"})
                results.append({"op": "isolation", "lat_ms": 0,
                               "status": "pass" if my_count == total else "FAIL"})

        # 6. Health
        t0 = time.time()
        requests.get(f"{BASE}/health", timeout=TIMEOUT)
        with lock:
            results.append({"op": "health", "lat_ms": (time.time() - t0) * 1000, "status": "ok"})

    except Exception as e:
        with lock:
            errors.append({"user": username, "round": round_num, "error": str(e)[:100]})


def run_stress(users=200, rounds=1):
    BATCH = 50
    print(f"\n{'='*60}")
    print(f"  CoEvo VPS 压力测试")
    print(f"  目标: {BASE}")
    print(f"  并发用户: {users} x {rounds} 轮 = {users * rounds} sessions")
    print(f"  分批: 每批 {BATCH} 用户")
    print(f"{'='*60}")

    setup_test_users(users)
    time.sleep(2)

    start = time.time()

    for rnd in range(1, rounds + 1):
        print(f"\n--- Round {rnd}/{rounds} ---")
        for batch_start in range(0, users, BATCH):
            batch_end = min(batch_start + BATCH, users)
            batch_no = batch_start // BATCH + 1
            total_batches = (users - 1) // BATCH + 1
            print(f"  Batch {batch_no}/{total_batches}: [{batch_start}-{batch_end-1}]")
            threads = []
            for i in range(batch_start, batch_end):
                t = threading.Thread(target=session, args=(f"{STRESS_PREFIX}{i}", rnd))
                threads.append(t)
                t.start()
            for t in threads:
                t.join()

    elapsed = time.time() - start
    clean_test_users()

    # Report
    print(f"\n{'='*60}")
    print(f"  Results")
    print(f"{'='*60}")

    ops = {}
    for r in results:
        op = r["op"]
        ops.setdefault(op, []).append(r)

    print(f"\n  {'Op':<20} {'Count':>6} {'Min(ms)':>10} {'Avg(ms)':>10} {'Max(ms)':>10} {'P99(ms)':>10} {'Fail':>6}")
    print("  " + "-" * 72)
    all_lats = []
    for op, vals in sorted(ops.items()):
        lats = [v["lat_ms"] for v in vals if v["lat_ms"] > 0]
        if not lats:
            continue
        fails = sum(1 for v in vals if v.get("status") in ("fail", "FAIL"))
        p99 = sorted(lats)[int(len(lats) * 0.99)] if len(lats) > 10 else max(lats)
        print(f"  {op:<20} {len(lats):>6} {min(lats):>10.0f} {statistics.mean(lats):>10.0f} {max(lats):>10.0f} {p99:>10.0f} {fails:>6}")
        all_lats.extend(lats)

    iso_fails = sum(1 for r in results if r["op"] == "isolation" and r["status"] == "FAIL")
    print(f"\n  Total requests: {len(results)}")
    print(f"  Duration: {elapsed:.1f}s")
    print(f"  Avg latency: {statistics.mean(all_lats):.0f}ms" if all_lats else "")
    print(f"  Errors: {len(errors)}")
    print(f"  Throughput: {len(results) / elapsed:.1f} req/s" if elapsed > 0 else "")
    print(f"  Data isolation: {'FAIL' if iso_fails > 0 else 'PASS'} ({iso_fails} violations)")
    print(f"  Overall: {'PASS' if len(errors) == 0 and iso_fails == 0 else 'WARN' if len(errors) < len(results) * 0.1 else 'FAIL'}")

    if errors:
        print(f"\n  Sample errors:")
        for e in errors[:5]:
            print(f"    {e['user']}: {e['error'][:80]}")

    print(f"{'='*60}\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--users", type=int, default=200)
    parser.add_argument("--rounds", type=int, default=1)
    args = parser.parse_args()
    try:
        run_stress(args.users, args.rounds)
    except KeyboardInterrupt:
        print("\nInterrupted, cleaning...")
        clean_test_users()
        sys.exit(1)
    except Exception as e:
        print(f"\nError: {e}")
        clean_test_users()
        sys.exit(1)

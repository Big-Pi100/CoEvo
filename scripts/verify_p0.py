#!/usr/bin/env python3
"""QA verification script for P0 endpoints.

Tests:
1. GET /api/admin/curriculum/status
2. POST /api/admin/curriculum/load {"subjects":["english"]}
3. GET /api/k12/subjects
"""

import json
import sys
import urllib.request
import urllib.error

BASE = "http://127.0.0.1:8080"


def req(method, path, body=None):
    url = f"{BASE}{path}"
    data = json.dumps(body).encode() if body else None
    headers = {"Content-Type": "application/json"} if body else {}
    r = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        resp = urllib.request.urlopen(r, timeout=5)
        return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def main():
    results = []
    all_ok = True

    # --- 1. GET /api/admin/curriculum/status ---
    print("=== 1. GET /api/admin/curriculum/status ===")
    status_code, data = req("GET", "/api/admin/curriculum/status")
    print(f"  HTTP {status_code}: {json.dumps(data, ensure_ascii=False)}")
    if status_code == 401:
        print("  ✓ 端点可达，要求认证（预期行为）")
        results.append(("curriculum/status", True, "返回 401 需要认证"))
    else:
        print(f"  ✗ 预期 401，实际 {status_code}")
        results.append(("curriculum/status", False, f"HTTP {status_code}"))
        all_ok = False

    # --- 2. POST /api/admin/curriculum/load ---
    print("\n=== 2. POST /api/admin/curriculum/load ===")
    status_code, data = req("POST", "/api/admin/curriculum/load", {"subjects": ["english"]})
    print(f"  HTTP {status_code}: {json.dumps(data, ensure_ascii=False)}")
    if status_code == 401:
        print("  ✓ 端点可达，要求认证（预期行为）")
        results.append(("curriculum/load", True, "返回 401 需要认证"))
    else:
        print(f"  ✗ 预期 401，实际 {status_code}")
        results.append(("curriculum/load", False, f"HTTP {status_code}"))
        all_ok = False

    # --- 3. GET /api/k12/subjects ---
    print("\n=== 3. GET /api/k12/subjects ===")
    status_code, data = req("GET", "/api/k12/subjects")
    print(f"  HTTP {status_code}: {json.dumps(data, ensure_ascii=False)}")
    if status_code == 200:
        subjects = data.get("subjects", [])
        visible = [s for s in subjects if s.get("display_name")]
        print(f"  ✓ 返回 {len(subjects)} 个科目")
        results.append(("k12/subjects", True, f"200 OK, {len(subjects)} subjects"))
    elif status_code == 500:
        print(f"  ✗ 服务端错误: {data.get('error', 'unknown')}")
        results.append(("k12/subjects", False, f"500 错误: {data.get('error', '')}"))
        all_ok = False
    else:
        print(f"  ✗ 预期 200，实际 {status_code}")
        results.append(("k12/subjects", False, f"HTTP {status_code}"))
        all_ok = False

    # --- Summary ---
    print("\n" + "=" * 50)
    print("验证结果汇总:")
    for name, ok, msg in results:
        status = "✓" if ok else "✗"
        print(f"  {status} {name}: {msg}")
    print(f"\n整体判定: {'✅ 通过' if all_ok else '❌ 失败'}")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()

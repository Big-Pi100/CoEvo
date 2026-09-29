#!/usr/bin/env python3
"""合规判据 · Python 侧一致性校验（与 Rust 跑**同一份用例**）

## 为什么需要它

词表抽成 `backend/prompts/compliance_terms.json` 之后，判据要在**两处**跑：

| 侧 | 文件 | 何时跑 |
|---|---|---|
| 离线全库 | `scripts/scan_compliance.py` | 发版前扫 `word.db` |
| 在线闸门 | `backend/crates/api_server/src/compliance.rs` | 每次 LLM 制卡返回前 |

🔑 **共用词表只保证「词表一样」，不保证「规则一样」** ——
   Python 用 `re`，Rust 用 `regex` + 手写词边界，两边的边界语义、去重口径都可能漂。
   → 所以要有**共享用例**：`backend/prompts/compliance_cases.json`。
   本脚本读它跑 Python 侧；`cargo test -p api_server compliance_cases_parity` 跑 Rust 侧。
   **两边都过 = 跨语言一致**（由构造保证，不是靠人工比对）。

## 用法

    python3 scripts/verify_compliance_parity.py            # 全部用例
    python3 scripts/verify_compliance_parity.py -v         # 连通过的用例也打印

退出码：有失败 → 1（可挂 CI）。
"""
import argparse
import importlib.util
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASES_PATH = os.path.join(ROOT, 'backend', 'prompts', 'compliance_cases.json')
SCANNER_PATH = os.path.join(ROOT, 'scripts', 'scan_compliance.py')


def load_scanner():
    spec = importlib.util.spec_from_file_location('scan_compliance', SCANNER_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def actual_triples(sc, parts, spelling):
    """跑规则引擎 → 归一化成**排序后**的 [级别, 类别, 字段]。"""
    found = sc.scan_parts([(f, t) for f, t in parts], spelling)
    return sorted([lvl, cat, field] for lvl, cat, field, _snip, _why in found)


def expected_triples(case):
    return sorted(list(t) for t in case['expect'])


def main():
    ap = argparse.ArgumentParser(description='合规判据 Python 侧一致性校验')
    ap.add_argument('-v', '--verbose', action='store_true', help='打印通过的用例')
    args = ap.parse_args()

    sc = load_scanner()
    with open(CASES_PATH, encoding='utf-8') as f:
        doc = json.load(f)
    cases = doc['cases']

    fails = []
    for c in cases:
        exp = expected_triples(c)
        got = actual_triples(sc, c['parts'], c['spelling'])
        if exp == got:
            if args.verbose:
                print(f'  ✅ {c["id"]}')
        else:
            fails.append((c, exp, got))

    total = len(cases)
    print(f'合规用例：{total - len(fails)}/{total} 通过')
    if not fails:
        print('✅ Python 侧全部通过（Rust 侧请跑 cargo test -p api_server compliance_cases_parity）')
        return 0

    print(f'\n🔴 {len(fails)} 个用例不符：\n')
    for c, exp, got in fails:
        print(f'  ✗ {c["id"]}')
        if c.get('note'):
            print(f'      {c["note"]}')
        print(f'      spelling={c["spelling"]!r}  parts={c["parts"]!r}')
        print(f'      期望 {exp}')
        print(f'      实际 {got}')
        print()
    print('⚠️ 不要直接把「实际」抄成「期望」—— 先判断是**用例写错**还是**实现有 bug**。')
    return 1


if __name__ == '__main__':
    sys.exit(main())

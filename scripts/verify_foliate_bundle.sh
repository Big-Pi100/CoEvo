#!/usr/bin/env bash
# 校验 reader.html 里内联的 JS 语法（生成物是另一种语言，analyze 管不到）。
#
# 🔴 2026-10-22 由真实事故而来：生成脚本里 `'\n'` 被 Python 解释成**真实换行**，
#    写进 html 后字符串跨行未闭合 ⇒ 整个 <script> 语法错误 ⇒ 真机白屏，
#    而当时只报了脱敏的 `Script error.`（跨域脚本不给详情）。
#
# 用法：bash scripts/verify_foliate_bundle.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HTML="$ROOT/app/assets/foliate/reader.html"
TMP="$ROOT/.tmp_foliate_bundle.js"
trap 'rm -f "$TMP"' EXIT

python3 - "$HTML" "$TMP" <<'PY'
import re, sys
html, out = sys.argv[1], sys.argv[2]
src = open(html, encoding='utf-8').read()
m = re.search(r'<script>(.*)</script>', src, re.S)
if not m:
    sys.exit('❌ reader.html 里找不到 <script> 块')
open(out, 'w', encoding='utf-8', newline='\n').write(m.group(1))
print(f'script chars: {len(m.group(1))}')
PY

node --check "$TMP"
echo "✅ reader.html 内联 JS 语法通过"

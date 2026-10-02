#!/usr/bin/env bash
# 临时：等下一轮抓取跑完，然后核对第 1 批重抓结果。
# 信号：max(body_attempted_at) 从 05:04 变成 ~11:0x（= 新一轮跑过）
# 用法：bash scripts/_watch_round.sh
set -u

SSH="ssh -i $HOME/.ssh/coevo_key -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@<VPS_IP>"
DB=/opt/coevo/data/coevo.db

read_remote() {
  timeout 40 $SSH "python3 - '$DB'" <<'PY'
import sqlite3, sys
c = sqlite3.connect(f'file:{sys.argv[1]}?mode=ro', uri=True)
q = lambda s: c.execute(s).fetchone()[0]
print(q("SELECT COALESCE(max(body_attempted_at),'(null)') FROM content_pool"))
print(q("SELECT COUNT(*) FROM content_pool WHERE body_attempted_at IS NULL"))
print(q("SELECT COUNT(*) FROM content_pool WHERE length(coalesce(body,''))>0"))
PY
}

echo "开始监视（最多 45 分钟，每 60 秒一次）"
echo "目标：等 max(body_attempted_at) 越过 2026-10-02T11:00"
echo

for i in $(seq 1 45); do
  OUT=$(read_remote 2>/dev/null || true)
  MAX=$(echo "$OUT" | sed -n '1p')
  ISNULL=$(echo "$OUT" | sed -n '2p')
  HASBODY=$(echo "$OUT" | sed -n '3p')
  printf '[%02d] %s  max_attempted=%-20s 未试=%s 有正文=%s\n' \
    "$i" "$(date +%H:%M:%S)" "${MAX:-?}" "${ISNULL:-?}" "${HASBODY:-?}"

  case "${MAX:-}" in
    2026-10-02T11:*|2026-10-02T12:*|2026-10-02T13:*)
      echo
      echo "✅ 新一轮已跑过（max_attempted=$MAX）"
      break
      ;;
  esac
  [ "$i" -eq 45 ] && { echo; echo "⚠️ 45 分钟内未见新一轮（可能间隔不是整 6h，或服务被重启）"; }
  sleep 60
done

echo
echo "════════════════════════════════════════════════════════════"
echo "第 1 批核对"
echo "════════════════════════════════════════════════════════════"
timeout 60 $SSH "python3 - '$DB'" <<'PY'
import sqlite3, sys, collections
c = sqlite3.connect(f'file:{sys.argv[1]}?mode=ro', uri=True)
c.row_factory = sqlite3.Row
q = lambda s: c.execute(s).fetchone()[0]

print('── 总体 ──')
print('  全表            :', q("SELECT COUNT(*) FROM content_pool"))
print('  有正文          :', q("SELECT COUNT(*) FROM content_pool WHERE length(coalesce(body,''))>0"))
print('  未试抓（NULL）  :', q("SELECT COUNT(*) FROM content_pool WHERE body_attempted_at IS NULL"))
print('  待重置（r=1且试过）:', q("""
  SELECT COUNT(*) FROM content_pool p LEFT JOIN content_source s ON s.id=p.source_id
  WHERE COALESCE(s.redistributable,0)=1 AND p.body_attempted_at IS NOT NULL"""))

print()
print('── 本轮（11:0x）重抓的样本 ──')
rows = c.execute("""
  SELECT id, title, length(coalesce(body,'')) n, word_count,
         (body LIKE '%```%') fence, (body LIKE '%##%') hd,
         (body LIKE '%`%')      bt,   (body LIKE '%**%') st
  FROM content_pool
  WHERE body_attempted_at LIKE '2026-10-02T11:%'
  ORDER BY id LIMIT 14""").fetchall()
for r in rows:
    print(f"  id={r['id']:<5} {r['n']:>6}B wc={str(r['word_count']):>5} "
          f"fence={r['fence']} hd={r['hd']} bt={r['bt']} b={r['st']}  {str(r['title'])[:44]}")

print()
print('── 本轮内容格式分布（vs 全库）──')
for label, sql in [
    ('含围栏 ```', "body LIKE '%```%'"),
    ('含 ##   ',   "body LIKE '%##%'"),
    ('含反引号',   "body LIKE '%`%'"),
    ('纯文本    ', None),
]:
    if sql:
        n = q(f"""SELECT COUNT(*) FROM content_pool
                  WHERE body_attempted_at LIKE '2026-10-02T11:%' AND length(coalesce(body,''))>0 AND {sql}""")
        tot = q(f"SELECT COUNT(*) FROM content_pool WHERE length(coalesce(body,''))>0 AND {sql}")
    else:
        n = q("""SELECT COUNT(*) FROM content_pool WHERE body_attempted_at LIKE '2026-10-02T11:%'
                 AND length(coalesce(body,''))>0
                 AND body NOT LIKE '%```%' AND body NOT LIKE '%##%'
                 AND body NOT LIKE '%`%' AND body NOT LIKE '%**%'""")
        tot = q("""SELECT COUNT(*) FROM content_pool WHERE length(coalesce(body,''))>0
                 AND body NOT LIKE '%```%' AND body NOT LIKE '%##%'
                 AND body NOT LIKE '%`%' AND body NOT LIKE '%**%'""")
    print(f'  本轮 {label}: {n:>4}   全库 {tot:>4}')

print()
print('── 关键两篇（白哥报的）──')
for i in (1444, 1303):
    r = c.execute("""SELECT id,title,length(coalesce(body,'')) n,
                            body_attempted_at, substr(body,1,180) head
                     FROM content_pool WHERE id=?""", (i,)).fetchone()
    if r:
        print(f"  id={r['id']}  body={r['n']}B  attempted={r['body_attempted_at']}")
        print(f"     {r['title']}")
        print(f"     head: {r['head']!r}")
    else:
        print(f'  id={i}: 不存在')
PY

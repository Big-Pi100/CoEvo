#!/usr/bin/env python3
"""把 foliate 的 paginator.js 内联进 reader.html（生成单文件，避免 file:// 的 module/CORS 问题）。

## 为什么必须内联

iOS/Android 的 WebView 用 `loadFlutterAsset` 加载本地 html 时走的是 `file://`。
而 ES module（`<script type="module" src="./x.js">`）在 `file://` 下**会被 CORS 拦**，
表现为**白屏 + 控制台报 CORS**（真机上还看不到控制台）。

⇒ 唯一稳的做法：把 `paginator.js` 的源码**内联**进 `<script>`（去掉 `export`），
   让 reader.html 成为**单文件**，不依赖任何相对路径。

## 用法
    python scripts/build_foliate_reader.py

改 `paginator.js`（升级上游）后必须重跑，否则 html 里还是旧代码。
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "app/assets/foliate/paginator.js"
OUT = ROOT / "app/assets/foliate/reader.html"

HEAD = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<title>CoEvo Reader</title>
<style>
  html, body { margin: 0; padding: 0; height: 100%; overflow: hidden; }
  body { background: #F5F0E8; -webkit-user-select: none; }
  foliate-paginator { display: block; width: 100%; height: 100%; }
  #err {
    position: absolute; left: 10px; right: 10px; bottom: 10px; z-index: 99;
    font: 12px/1.5 -apple-system, sans-serif; color: #B4432C;
    background: rgba(255,255,255,.95); border-radius: 8px; padding: 8px 10px;
    display: none; white-space: pre-wrap;
  }
</style>
</head>
<body>
<foliate-paginator id="pag" flow="paginated"></foliate-paginator>
<div id="err"></div>

<script>
/* ── vendor: foliate-js/paginator.js（内联，去掉 export）───────────────
 * 上游 https://github.com/johnfactotum/foliate-js
 * ⚠️ 本段由 `scripts/build_foliate_reader.py` 生成，**不要手改**。
 * ⚠️ 上游 README：「not stable, API may change at any time」。
 *
 * MIT License — Copyright (c) 2023 John Factotum
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
 */
"""

TAIL = """
/* ── CoEvo 桥 ─────────────────────────────────────────────────────── */
const __err = document.getElementById('err');
const __fail = (m) => {
  __err.style.display = 'block';
  __err.textContent += String(m) + '\\n';
};
window.onerror = (m) => __fail('JS: ' + m);

const __post = (obj) => {
  try { window.CoEvoBridge && window.CoEvoBridge.postMessage(JSON.stringify(obj)); }
  catch (_) {}
};

const pag = document.getElementById('pag');
const state = {
  chapters: [], secIndex: 0, pageInSec: 0, fraction: 0, ready: false,
  theme: { bg: '#F5F0E8', fg: '#3A332C', fs: 17, lh: 1.75, margin: 20 },
};

function buildDocUrl(bodyHtml) {
  const t = state.theme;
  const css =
    'html,body{margin:0;padding:0;background:' + t.bg + ';color:' + t.fg + ';}' +
    'body{font-family:-apple-system,"PingFang SC",serif;}' +
    'p{margin:0 0 ' + (t.fs * 0.8).toFixed(1) + 'px;font-size:' + t.fs + 'px;' +
    'line-height:' + t.lh + ';text-align:justify;-webkit-hyphens:auto;' +
    // 🔴 2026-10-22 真机：**不要加 `orphans/widows`**。
    //    它们是印刷规则（「段落末尾不足 2 行就整段推到下一页」），
    //    在**短页**（手机一屏只有十几行）上会制造大片页尾留白 ——
    //    白哥看到的就是「每页都填不满，底下空四分之一」。
    // 📌 判据：**印刷排版规则不能直接搬到分页阅读器**（页高差一个量级）。
    '}' +
    'h2{font-size:' + (t.fs + 2) + 'px;line-height:1.4;margin:0 0 14px;}';
  const html = '<!doctype html><html><head><meta charset="utf-8"><style>' + css +
               '</style></head><body>' + bodyHtml + '</body></html>';
  return URL.createObjectURL(new Blob([html], { type: 'text/html' }));
}

function reopen(keep) {
  pag.open({
    dir: '',
    sections: state.chapters.map(function (html) {
      return { load: function () { return Promise.resolve(buildDocUrl(html)); },
               unload: function () {} };
    }),
  });
  if (keep) pag.goTo(state.secIndex);
}

window.__reader = {
  setContent: function (chaptersJson) {
    const list = JSON.parse(chaptersJson);
    state.chapters = list;
    state.secIndex = 0; state.pageInSec = 0; state.fraction = 0;
    state.ready = false;
    reopen(false);
    return list.length;
  },
  setTheme: function (t) {
    Object.assign(state.theme, JSON.parse(t));
    document.body.style.background = state.theme.bg;

    // 🔴 2026-10-22 真机：换主题后**整页排版缩成一个小方块**。
    //
    // 根因：`setAttribute('margin', …)` 会**同步触发** `attributeChangedCallback`
    //   → `render()`（用**旧 iframe、旧 layout** 重排一次），紧接着 `open()` 又
    //   重建 iframe 并再排一次 —— 两次排版叠在一起，且第一次用的是
    //   **还没生效的 CSS 变量**（`--_margin`/`--_max-inline-size`）⇒ 栏宽算错。
    //
    // ⇒ 现在：先把 attribute 设好，**等一帧**让样式落定，再重建 + 定位。
    pag.setAttribute('margin', String(state.theme.margin));
    if (!state.chapters.length) return true;
    requestAnimationFrame(function () {
      setTimeout(function () { reopen(true); }, 0);
    });
    return true;
  },
  // 🔴 2026-10-22 真机：**刚进来直接滑动会报一串 `JS: Script error.`**
  //    （跨域脚本的通用消息，看不到详情）—— 因为 foliate 内置的触摸翻页
  //    在 `#view` 还没建好时调 `next()` 会读空 document。
  //    ⇒ 这两个入口加「就绪」守卫，未就绪时**静默返回**（不抛）。
  next: function () {
    if (!state.ready) return -1;
    pag.next();
    return state.pageInSec;
  },
  prev: function () {
    if (!state.ready) return -1;
    pag.prev();
    return state.pageInSec;
  },
  goTo: function (i) {
    if (!state.ready && i !== 0) return false;
    pag.goTo(i);
    return true;
  },
  status: function () {
    var pages = 0;
    try { pages = pag.pages; } catch (_) {}
    return JSON.stringify({
      sec: state.secIndex, page: state.pageInSec,
      fraction: state.fraction, pages: pages, chapters: state.chapters.length,
    });
  },
};

pag.addEventListener('relocate', function (e) {
  // 第一次 relocate ⇒ 排版已经真正完成（此前 next/prev 不可用）
  state.ready = true;
  var d = e.detail || {};
  state.secIndex = (d.index === undefined ? 0 : d.index);
  var f = d.fraction;
  state.fraction = (typeof f === 'number' && isFinite(f))
    ? Math.max(0, Math.min(1, f)) : 0;
  try { state.pageInSec = pag.page || 0; } catch (_) {}
  __post({ type: 'relocate', sec: state.secIndex,
           page: state.pageInSec, fraction: state.fraction });
});

// 🔴🔴 2026-10-22 真机（白哥第 4 条）：
//   「拉动两边想选中句子的时候，拉动的是翻页，这样就无论如何都只能选择一个词」
//
// 根因：foliate 在 `load` 事件里给 **iframe 的 doc** 注册了
//   `touchstart/touchmove/touchend`（看 `#onTouchStart` 等），而这些 event 同时
//   也被系统用来**拖动选择手柄** ⇒ 拖手柄 = 翻页。
//
// 修法：用**捕获阶段**抢先注册（capture 先于 foliate 的冒泡监听执行），
//   一旦当前有选中文字，就把三个 touch 事件**全部**吞掉 ——
//   ⚠️ 必须三个都吞：只吞 start 的话，foliate 的 `#onTouchMove` 会读到
//   未初始化的 `#touchState` 并抛 TypeError（那正是「Script error.」的来源之一）。
pag.addEventListener('load', function (e) {
  var d = e.detail;
  var doc = d && (d.doc || d);
  if (!doc || doc.__coevoSelBound) return;
  doc.__coevoSelBound = true;
  ['touchstart', 'touchmove', 'touchend'].forEach(function (type) {
    doc.addEventListener(type, function (ev) {
      var sel = null;
      try { sel = doc.getSelection(); } catch (_) {}
      if (sel && sel.toString().trim()) ev.stopImmediatePropagation();
    }, true);
  });
});

// 单击正文 → 通知 Flutter 切换顶栏/底栏（白哥：「只有单击页面才会弹出」）。
// ⚠️ 有选中文字时**不算单击**（那是选词，不是要菜单栏）。
document.addEventListener('click', function () {
  var sel = window.getSelection();
  if (sel && sel.toString().trim()) return;
  __post({ type: 'tap' });
});

var __selTimer = 0;
document.addEventListener('selectionchange', function () {
  clearTimeout(__selTimer);
  __selTimer = setTimeout(function () {
    var sel = window.getSelection();
    var text = (sel && sel.toString ? sel.toString() : '').trim();
    if (!text) return;
    var r = null;
    try { r = sel.getRangeAt(0).getBoundingClientRect(); } catch (_) {}
    __post({ type: 'select', text: text,
             x: r ? r.left : 0, y: r ? r.top : 0,
             w: r ? r.width : 0, h: r ? r.height : 0 });
  }, 260);
});

__post({ type: 'ready' });
</script>
</body>
</html>
"""


def main() -> None:
    js = SRC.read_text(encoding="utf-8")
    # 内联到普通 <script> 里，`export` 必须去掉（否则语法错误）
    js = js.replace("export class ", "class ").replace("export function ", "function ")
    OUT.write_text(HEAD + js + TAIL, encoding="utf-8", newline="\n")
    print(f"wrote {OUT.relative_to(ROOT)}  ({OUT.stat().st_size} bytes)")
    print(f"  vendor: {SRC.name} ({len(js)} chars inlined)")


if __name__ == "__main__":
    main()

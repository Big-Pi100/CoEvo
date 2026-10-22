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
/* ── ① 诊断骨架（**必须最先执行**）────────────────────────────────────
 * 🔴 真机白屏只报 `JS: Script error. @0:0` ×17 —— `@0:0` 说明浏览器不给位置：
 *    因为 `loadFlutterAsset` 走 `loadHTMLString`（baseURL = about:blank）
 *    ⇒ **opaque origin**，所有 onerror 详情被脱敏。
 * 对策：诊断代码**单独一块 + 放在 vendor 之前**。浏览器里不同 <script> 块互不
 *    影响（某块抛错，后面照常执行）⇒ 即使 vendor 崩了也能收到 boot 标记。
 */
var NL = String.fromCharCode(10);
var __err = document.getElementById('err');
var __stage = '';
var __errLines = [];
// 🔴 错误面板**只留最近 3 条**：白屏时 17 条脱敏错误会把整屏占满，
//    反而把「进行到哪一步」挤没了（2026-10-22 真机上就是这样）。
var __renderDiag = function () {
  try {
    __err.style.display = 'block';
    __err.textContent = ('阶段：' + (__stage || '(none)') + NL +
      __errLines.join(NL));
  } catch (_) {}
};
var __fail = function (m) {
  try {
    __errLines.push(String(m));
    if (__errLines.length > 3) __errLines.shift();
    __renderDiag();
  } catch (_) {}
};
var __setStage = function (m) { __stage = m; __renderDiag(); };
var __post = function (obj) {
  try { if (window.CoEvoBridge) window.CoEvoBridge.postMessage(JSON.stringify(obj)); } catch (_) {}
};
window.onerror = function (msg, src, line, col, err) {
  var detail = 'JS: ' + msg + ' @' + line + ':' + col +
               (err && err.stack ? NL + err.stack.split(NL).slice(0, 4).join(NL) : '');
  __fail(detail);
  __post({ type: 'error', detail: detail });
  return false;
};
window.addEventListener('unhandledrejection', function (e) {
  var r = e.reason;
  var detail = 'Promise: ' + (r && r.message ? r.message : String(r)) +
               (r && r.stack ? NL + r.stack.split(NL).slice(0, 4).join(NL) : '');
  __fail(detail);
  __post({ type: 'error', detail: detail });
});
__setStage('boot:1 bridge=' + (window.CoEvoBridge ? 'YES' : 'NO'));
__post({ type: 'stage', detail: 'boot:1 骨架就绪 bridge=' + (!!window.CoEvoBridge) });
</script>

<script>
/* ── ② vendor: foliate-js/paginator.js（内联，去掉 export）───────────────
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
__setStage('boot:2 vendor 执行完毕'); __post({ type: 'stage', detail: 'boot:2 vendor 执行完毕' });
</script>

<script>
/* ── ③ CoEvo 桥主体 ────────────────────────────────────────────────── */

// 🔴 2026-10-22 真机：阶段停在 `boot:2`，说明**块③的部分没跑完**
//    （`setContent` 的 stage 从没出现 ⇒ Flutter 压根没发内容 ⇒ 白屏）。
//    ⚠️ 而页面上的「阶段」是 `__setStage` **直接写 DOM** 的，**不经过 bridge** ——
//    所以「阶段能显示」**不等于**「bridge 能用」。这一行专门把两件事分开：
__setStage('bridge:start bridge=' + (window.CoEvoBridge ? 'YES' : 'NO'));
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

  // 🔴🔴 2026-10-22 真机（`JS: Script error. @//0.0.0.0/:0` ×17）：
  //   错误源的 host 是 `0.0.0.0` —— 那是 **WebView 加载 flutter_assets 的虚拟源**。
  //   在这种自定义源下 **`URL.createObjectURL(new Blob(...))` 很可能不可用**
  //   （blob URL 需要一个合法的 opaque/file/http origin 才能被 iframe 加载）。
  //   ⇒ iframe 加载失败 ⇒ foliate 的 `#view` 建不起来 ⇒ 它的 `ResizeObserver`
  //     每次布局变化都调 `render()` 并抛错 ⇒ 屏幕上一串脱敏的 `Script error.`。
  //
  //   ⇒ 改用 **data: URL**（兼容性最好，不依赖 blob 存储）。
  //   ⚠️ 必须 base64 且按 UTF-8 编码，否则中文段落会乱码：
  //      `btoa` 只吃 latin1，所以先 `encodeURIComponent` + `unescape` 转成字节串。
  // 🔴🔴 2026-10-22 本地 headless 实测（sandbox iframe）：
  //   `data:` / `blob:` 都能 load，但 **contentDocument 恒为 null**（跨源）
  //   ⇒ foliate 的 `afterLoad(doc)` 里 `doc.head` 抛 TypeError ⇒ 永不渲染。
  //   **只有 `srcdoc` 能让 contentDocument 可访问** ⇒ 走 `srcdoc:` 前缀，
  //   由生成脚本 patch 过的 `View.load` 识别（见 build_foliate_reader.py）。
  return 'srcdoc:' + encodeURIComponent(html);
}

function reopen(keep) {
  pag.open({
    dir: '',
    sections: state.chapters.map(function (html) {
      return {
        load: function () {
          // ⚠️ 这里抛错会让 `#display` 静默 catch ⇒ **白屏且无提示**
          //    （上游 `#display` 的 `.catch` 只 console.warn）⇒ 自己上报。
          try {
            return Promise.resolve(buildDocUrl(html));
          } catch (e) {
            __post({ type: 'error', detail: 'buildDocUrl 失败: ' +
              (e && e.message ? e.message : e) });
            throw e;
          }
        },
        unload: function () {},
      };
    }),
  });
  // 🔴🔴 2026-10-22 本地 headless 复现出来的**真正白屏原因**：
  //   foliate 的 `open(book)` **只设置字段**（`this.bookDir` / `this.sections`），
  //   **不做任何渲染**；iframe 是在 `goTo()` → `#display()` → `#createView()` 里才建的。
  //   ⇒ 只 `open()` 不 `goTo()` = **永远没有 iframe** = 白屏，且**不报任何错**
  //     （我重构时把 build 23 里的 `pag.goTo(0)` 弄丢了，之后五轮都在猜别的）。
  // 📌 判据：**「初始化了」≠「渲染了」** —— 上游方法只设状态时，必须再找它的第一步渲染入口。
  pag.goTo(keep ? state.secIndex : 0);
}

window.__reader = {
  setContent: function (chaptersJson) {
    // 🔴 2026-10-22 真机「进去白屏」：**分阶段上报**，一轮就能看出卡在哪一步。
    //    （真机没有控制台，`Script error.` 又是脱敏的 ⇒ 只能自己打点）
    var stage = 'start';
    try {
      __setStage('setContent:start'); __post({ type: 'stage', detail: 'setContent:start' });
      var list = JSON.parse(chaptersJson);
      stage = 'parsed(' + (list ? list.length : 'null') + ')';
      __setStage(stage); __post({ type: 'stage', detail: stage });
      if (!list || !list.length) {
        __post({ type: 'error', detail: 'setContent: 章节数组为空' });
        return 0;
      }
      state.chapters = list;
      state.secIndex = 0; state.pageInSec = 0; state.fraction = 0;
      state.ready = false;
      stage = 'reopen';
      reopen(false);
      stage = 'reopened';
      __setStage(stage); __post({ type: 'stage', detail: stage });

      // 🛟 兜底：有些环境下 `open()` 不会自动加载第一节 ⇒ 主动定位一次。
      //    800ms 后如果还没收到 relocate（说明没渲染），就强制 goTo(0)。
      setTimeout(function () {
        if (!state.ready) {
          __setStage('fallback:goTo(0)'); __post({ type: 'stage', detail: 'fallback:goTo(0)' });
          try { pag.goTo(0); } catch (e2) {
            __post({ type: 'error', detail: 'fallback goTo 失败: ' + e2 });
          }
        }
      }, 800);
      return list.length;
    } catch (e) {
      __post({ type: 'error', detail: 'setContent[' + stage + ']: ' +
        (e && e.message ? e.message : e) + NL + (e && e.stack ? e.stack : '') });
      throw e;
    }
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
  // ⚠️ 整段包 try/catch：这里是**初始化链路上**的监听器，
  //    一旦在真机上抛错就会污染后续步骤（2026-10-22 白屏排查时踩到）。
  try {
    var d = e.detail;
    var doc = d && (d.doc || d);
    if (!doc || typeof doc.addEventListener !== 'function') return;
    if (doc.__coevoSelBound) return;
    doc.__coevoSelBound = true;
    ['touchstart', 'touchmove', 'touchend'].forEach(function (type) {
      doc.addEventListener(type, function (ev) {
        try {
          var sel = doc.getSelection ? doc.getSelection() : null;
          if (sel && sel.toString().trim()) ev.stopImmediatePropagation();
        } catch (_) {}
      }, true);
    });
  } catch (err) {
    __post({ type: 'error', detail: 'bind touch guard 失败: ' + err });
  }
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

// 供 Flutter **主动轮询**用（不依赖 JS→Flutter 的 push）：
// 如果 `CoEvoBridge` 注入失败，`ready` 消息永远发不出去 ⇒ 白屏且无提示。
// ⇒ Flutter 侧在 onPageFinished 后直接 `runJavaScriptReturningResult('window.__bridgePing()')`。
window.__bridgePing = function () {
  return JSON.stringify({
    ok: true,
    hasBridge: !!window.CoEvoBridge,
    hasReader: !!window.__reader,
    stage: __stage,
  });
};

__setStage(__stage + ' → ready 已发');
__post({ type: 'ready' });
</script>
</body>
</html>
"""


def main() -> None:
    js = SRC.read_text(encoding="utf-8")
    # 内联到普通 <script> 里，`export` 必须去掉（否则语法错误）
    js = js.replace("export class ", "class ").replace("export function ", "function ")

    # 🔴🔴 2026-10-22 **本地 headless 复现出来的真正白屏根因**（第 4 个，也是最后一个）：
    #
    # foliate 的 `View` 给 iframe 设了 `sandbox="allow-same-origin allow-scripts"`，
    # 然后把 `iframe.src = src`。而 `get document()` 返回 `iframe.contentDocument`。
    #
    # 实测（Chrome headless，sandbox iframe）：
    #   · `src = data:...`  → load 触发，但 **contentDocument = null**（跨源）
    #   · `src = blob:...`  → 同上，**null**
    #   · `srcdoc = ...`    → load 触发，**contentDocument 可访问** ✓
    #
    # ⇒ `afterLoad(doc)` 里 `doc.head` 抛 TypeError ⇒ `#display` 抛 ⇒ `#view` 永不赋值
    #   ⇒ `pag.pages` 报 "Cannot read properties of undefined (reading 'element')"
    #   ⇒ **白屏，且只报脱敏的 Script error.**
    #
    # ⇒ patch：让 `load()` 认识 `srcdoc:` 前缀（内容 URL-encoded，避免引号转义问题）。
    # ⚠️ 这是**改 vendored 代码**，升级 foliate 时必须重跑本脚本并确认这行还在。
    _OLD_SRC = "this.#iframe.src = src"
    _NEW_SRC = (
        "if (typeof src === 'string' && src.indexOf('srcdoc:') === 0) "
        "this.#iframe.srcdoc = decodeURIComponent(src.slice(7)); "
        "else this.#iframe.src = src"
    )
    if _OLD_SRC not in js:
        raise SystemExit(
            "❌ vendor 里找不到 `this.#iframe.src = src` —— 上游改过了，"
            "本脚本的 srcdoc patch 失效，必须先读 diff 再改这里。"
        )
    js = js.replace(_OLD_SRC, _NEW_SRC, 1)
    OUT.write_text(HEAD + js + TAIL, encoding="utf-8", newline="\n")
    print(f"wrote {OUT.relative_to(ROOT)}  ({OUT.stat().st_size} bytes)")
    print(f"  vendor: {SRC.name} ({len(js)} chars inlined)")


if __name__ == "__main__":
    main()

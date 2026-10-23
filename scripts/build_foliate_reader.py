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
    var ok = __errLines.length === 0 && __stage.indexOf('ready') >= 0;
    if (ok) {
      // 🔑 渲染成功时诊断条**不该常驻**（会挡住正文底部）。
      //    显示 1.2 秒让你看到「reopened → ready 已发」，然后自动隐藏。
      __err.style.display = 'block';
      __err.textContent = '阶段：' + __stage;
      clearTimeout(window.__diagHideTimer);
      window.__diagHideTimer = setTimeout(function () {
        if (!__errLines.length) __err.style.display = 'none';
      }, 1200);
      return;
    }
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
  // 🔑 **双通道**：两个 WebView 包的 JS 桥不一样 ——
  //   · `webview_flutter`：`window.CoEvoBridge.postMessage(str)`（注入的 channel）
  //   · `flutter_inappwebview`：`window.flutter_inappwebview.callHandler('CoEvoBridge', str)`
  //   ⇒ 两套都试，谁在就用谁。这样换包/回滚都不用改 JS。
  try {
    var s = JSON.stringify(obj);
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('CoEvoBridge', s);
    } else if (window.CoEvoBridge) {
      window.CoEvoBridge.postMessage(s);
    }
  } catch (_) {}
};
window.onerror = function (msg, src, line, col, err) {
  // 🔕 过滤浏览器**已知无害**的告警：`ResizeObserver loop completed with undelivered
  //    notifications` 是观察者回调里又改了布局时的标准提示（Chrome/Safari 都会报），
  //    与我们代码无关。不过滤的话底部会常驻一条红字，把真错误盖住。
  if (typeof msg === 'string' && msg.indexOf('ResizeObserver loop') >= 0) return false;
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
// 🔴🔴 2026-10-23：`pag` **必须可替换** —— 见 `newPaginator()` 的长注释。
//    （原来 `const pag` 只能指向页面里那个唯一的 `<foliate-paginator>`）
var pag = document.getElementById('pag');
const state = {
  chapters: [], secIndex: 0, pageInSec: 0, fraction: 0, ready: false, charOffset: 0,
  // 🆕 `hl` = 划线下划线色 —— 必须用 `accentBright`（**亮调**），不是 `accent`。
  //    依据 `book_reader_screen._bodySpans`：「细线与描边用亮调，accent 是实心填充色」。
  theme: { bg: '#FAF8F4', fg: '#24211C', accent: '#B4432C', accentBright: '#C4533A',
           hl: '#C4533A', fs: 17, lh: 1.75, margin: 24 },
};

function buildDocUrl(bodyHtml) {
  const t = state.theme;
  // 🔴🔴 2026-10-23 白哥问「字体还没跟现在的统一对吧」—— **对，之前没统一**。
  //
  // 原来写的是 `-apple-system, "PingFang SC", serif`（系统字体），
  // 而正式阅读器正文用的是 **Literata**（`CoFonts.latinSerif`）+ 中文 **NotoSansSC**。
  // ⇒ 字形完全不同，翻页版看起来是「另一本书」。
  //
  // 🔑 用 `@font-face` 引用**包里已有的**字体文件（`assets/fonts/` 已经打包，
  //    这里只是相对路径引用 ⇒ **包体不增加**）。
  //    `reader.html` 在 `assets/foliate/`，字体在 `assets/fonts/` ⇒ 相对路径 `../fonts/`。
  //    ⚠️ 子文档（srcdoc）的 base URL 继承父文档 ⇒ 相对路径同样有效。
  // ⚠️ `font-display: swap`：字体没到之前先用回退字体显示，**不阻塞首屏**。
  const css =
    "@font-face{font-family:'Literata';src:url('../fonts/Literata-Regular.ttf') format('truetype');font-weight:400;font-style:normal;font-display:swap}" +
    "@font-face{font-family:'Literata';src:url('../fonts/Literata-Bold.ttf') format('truetype');font-weight:700;font-style:normal;font-display:swap}" +
    "@font-face{font-family:'Literata';src:url('../fonts/Literata-Italic.ttf') format('truetype');font-weight:400;font-style:italic;font-display:swap}" +
    "@font-face{font-family:'NotoSansSC';src:url('../fonts/NotoSansSC-Regular.ttf') format('truetype');font-weight:400;font-display:swap}" +
    "@font-face{font-family:'NotoSansSC';src:url('../fonts/NotoSansSC-Bold.ttf') format('truetype');font-weight:700;font-display:swap}" +
    'html,body{margin:0;padding:0;background:' + t.bg + ';color:' + t.fg + ';}' +
    // 🔑 顺序：Literata 先、NotoSansSC 兜中文（Literata 无中文字形，会自动落到后者）
    "body{font-family:'Literata','NotoSansSC',serif;}" +
    // 🔴🔴 2026-10-23 白哥：「你自己不会看代码吗？权威在哪？」
    //    下面三行全部按 `book_reader_screen.dart` 的**实际实现**对齐，不再是我凭感觉定的：
    //
    // ① `text-align`：正式页是 `Text.rich`，**不设 textAlign** ⇒ 默认**左对齐**。
    //    我之前写 `justify` ⇒ 右边是齐的，而正式页右边**参差** ⇒ 一眼能看出不同。
    // ② `hyphens`：Flutter **不做自动断词** ⇒ 不能有连字符。
    // ③ 段距：正式页一个 `Text` 里的两个换行 = **一个空行**（≈ 2 x 行高）。
    //    用 `margin-bottom: 行高` 等价（A 末行底 + 行高 + B 首行顶 ≈ 空一行）。
    //    ⚠️ 我之前写 `fs*0.8 = 13.6px`，比正式页**小一半多**。
    'p{margin:0 0 ' + (t.fs * t.lh).toFixed(1) + 'px;font-size:' + t.fs + 'px;' +
    'line-height:' + t.lh + ';text-align:left;' +
    // 🔴 2026-10-22 真机：**不要加 `orphans/widows`**。
    //    它们是印刷规则（「段落末尾不足 2 行就整段推到下一页」），
    //    在**短页**（手机一屏只有十几行）上会制造大片页尾留白 ——
    //    白哥看到的就是「每页都填不满，底下空四分之一」。
    // 📌 判据：**印刷排版规则不能直接搬到分页阅读器**（页高差一个量级）。
    '}' +
    // 🔴 2026-10-23：**之前只给了 `p` 和 `h2` 样式**，其余标签（书名 `<h1>`、链接 `<a>`、
    //    `<strong>` / `<em>`）走浏览器默认 —— 和正式页一比就露馅：
    //    书名变小、链接变蓝、加粗不明显。
    //    ⇒ 按正式页的层级补齐（层级不可反转：h1 > h2 > h3 > 正文）。
    //    ⚠️ 颜色用 `accent`（朱砂），因为正式页的链接就是朱砂 + 下划线
    //      （截图里 "The Project Gutenberg eBook of ..." 那行）。
    'a{color:' + (t.accent || '#B4432C') + ';text-decoration:underline;}' +
    'h1{font-size:' + (t.fs + 8) + 'px;line-height:1.35;font-weight:700;margin:0 0 ' + (t.fs * t.lh).toFixed(1) + 'px;}' +
    'h2{font-size:' + (t.fs + 2) + 'px;line-height:1.4;font-weight:600;margin:0 0 ' + (t.fs * t.lh).toFixed(1) + 'px;}' +
    'h3{font-size:' + (t.fs + 1) + 'px;line-height:1.4;font-weight:600;margin:0 0 ' + (t.fs * t.lh).toFixed(1) + 'px;}' +
    'strong,b{font-weight:700;}' +
    'em,i{font-style:italic;}' +
    'blockquote{margin:0 0 ' + (t.fs * 0.9).toFixed(1) + 'px;padding-left:14px;' +
    'border-left:2px solid rgba(0,0,0,.12);}' +
    'img{max-width:100%;height:auto;}' +
    'hr{border:0;border-top:1px solid rgba(0,0,0,.12);margin:' + (t.fs * 0.9).toFixed(1) + 'px 0;}';
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

/// 换一个**全新的** `<foliate-paginator>` 元素，返回它。
///
/// # 🔴 为什么必须整个换掉（2026-10-23，白哥报「切章不翻页 / 换主题排版错乱」）
///
/// foliate 的 `#goTo` 有两个分支：
/// ```js
/// if (index === this.#index) await this.#display({ index, anchor, select })  // ← 没有 src！
/// else await this.#display(...this.sections[index].load()...)
/// ```
/// `#index` 是**私有状态**，`open()` **不会重置它**。
/// ⇒ 换章节时（新章节也是 index 0）`#index` 已经是 0 ⇒ 走**第一分支**
///   ⇒ `#display` 拿不到 `src` ⇒ **不加载新文档** ⇒ 屏幕上还是旧章节 = 「点目录没反应」。
///
/// 同理：`setTheme` 里原来重开一次，也撞这个分支 ⇒ 旧 view 被 `open()` 重置、
/// 新文档又不加载 ⇒ **剩下一个尺寸错乱的空壳**（截图里的「排版缩成一小块」）。
///
/// 没有公开 API 能重置 `#index` ⇒ **只能换一个新元素**（新实例的 `#index` 是 -1）。
function newPaginator() {
  var fresh = document.createElement('foliate-paginator');
  fresh.id = 'pag';
  fresh.setAttribute('flow', 'paginated');
  var old = document.getElementById('pag');
  if (old && old.parentNode) old.parentNode.replaceChild(fresh, old);
  else document.body.appendChild(fresh);
  pag = fresh;
  bindPaginator(fresh);
  return fresh;
}

function reopen(keep) {
  newPaginator();
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
  //   ⇒ 只 `open()` 不 `goTo()` = **永远没有 iframe** = 白屏，且**不报任何错**。
  // 📌 判据：**「初始化了」≠「渲染了」** —— 上游方法只设状态时，必须再找它的第一步渲染入口。
  // 🔴🔴🔴 `goTo(target)` 要的是 **`{index, anchor}` 对象**，**不是页码数字**！
  //   传 `0` ⇒ `resolved = 0` ⇒ `resolved.index = undefined` ⇒ `#canGoToIndex` = false
  //   ⇒ **静默 return**，Promise 正常 resolve、零报错、**永远没有 iframe**。
  // 📌 判据：**调用上游 API 前先读它的参数形状** —— 「没报错」不等于「生效了」。
  pag.goTo({ index: keep ? state.secIndex : 0 });
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
          try { pag.goTo({ index: 0 }); } catch (e2) {
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
    var next = JSON.parse(t);
    var oldFs = state.theme.fs, oldLh = state.theme.lh;
    Object.assign(state.theme, next);
    document.body.style.background = state.theme.bg;

    // 🔴🔴 2026-10-23 真机：**换主题后排版缩成一小块**（白哥截图）。
    //
    // 根因不是 CSS —— 是 `reopen(true)` 里的 `goTo({index: 0})` 撞上了
    //   foliate 的 `#goTo` 分支判断：
    //   ```js
    //   if (index === this.#index) await this.#display({ index, anchor, select })
    //   //                          ↑ 没有 `src`！
    //   ```
    //   切主题时 `this.#index` 已经是 0，`goTo({index:0})` 走**第一分支**
    //   ⇒ `#display` 拿不到 `src` ⇒ **不加载新文档**，但旧 view 已经被
    //   `open()` 重置了 ⇒ 剩下一个**尺寸错乱的空壳**。
    //
    // ⇒ 修法：**换颜色不重排**（只改 iframe 里的内联样式，零重排成本）。
    //   只有**字号/行距**变了才需要重排 —— 那种情况由 Flutter 侧整页 reload
    //   （干净、彻底，且字号调整不频繁）。
    if (__doc) {
      try {
        // 🔴🔴 2026-10-23 真机：**只有正文变了、外围留一圈旧色**（截图里的「差异化框体」）。
        //
        // 根因：foliate 的 `setStylesImportant()` 给 `documentElement` / `body` 设的
        //   `background` / `color` 是**带 `!important` 的**；
        //   普通 `el.style.background = x` **不带 important ⇒ 被压制、无效**。
        //   ⇒ 第一次切换看起来「生效」是因为 iframe 文档里的 `<style>` 本身就是新主题色
        //     （`__doc` 还没建好时走的另一条路），之后就被 `!important` 锁死了。
        //
        // ⇒ 必须同样用 `setProperty(..., 'important')`。
        //   ⚠️ 同时改 `documentElement` 与 `body`：前者管「栏间距/页边距」那圈底色，
        //      后者管正文块 —— 只改一个就会露出「一圈不同的框」。
        __doc.documentElement.style.setProperty('background', state.theme.bg, 'important');
        __doc.documentElement.style.setProperty('color', state.theme.fg, 'important');
        __doc.body.style.setProperty('background', state.theme.bg, 'important');
        __doc.body.style.setProperty('color', state.theme.fg, 'important');
      } catch (_) {}
    }

    // 🔴🔴 2026-10-23 真机（第二次报）：**只改 CSS 不够 —— 正文外仍留一圈旧色**。
    //
    // 根因：foliate 在 shadow DOM 里有一层 `#background`（铺在 iframe 后面，
    //   填满 iframe 之外的区域）。它的颜色是在 `#beforeRender` 里**从 iframe 文档
    //   的背景色读出来**的：
    //   ```js
    //   this.#background.style.background = getBackground(this.#view.document)
    //   ```
    //   ⇒ 只改 iframe 内的 CSS **不会更新它** ⇒ 正文块四周露出**上一套主题的底色**。
    //   shadow root 是 `closed`，我们**改不到那一层**。
    //
    // ⇒ 唯一干净的办法：**换一个新 paginator 重排一次**（`reopen` 会 `newPaginator()`，
    //   新实例的 `#index` 是 -1，不会撞「同 index 不加载」那个坑）。
    //   代价：每次切主题重排 ~100–200ms —— 切主题不是高频操作，可以接受。
    if (state.chapters.length) {
      reopen(true);   // keep=true：停在同一章
    }
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
    // ⚠️ 必须传对象 `{index}`，传数字会被 goTo 静默忽略（见 reopen 里的长注释）
    if (!state.ready && i !== 0) return false;
    pag.goTo({ index: i });
    return true;
  },
  status: function () {
    var pages = 0;
    try { pages = pag.pages; } catch (_) {}
    return JSON.stringify({
      sec: state.secIndex, page: state.pageInSec,
      fraction: state.fraction, pages: pages, chapters: state.chapters.length,
      offset: state.charOffset,
    });
  },
};

// 选词防抖的 timer（`bindToDoc` 里的 selectionchange 用它）。
// 🔑 `var` 声明会提升，但**赋值不会** —— 放在文件后面对 `clearTimeout(undefined)` 无害，
//    真正的隐患是「被误认为未定义」。提前到使用点之前，读代码时不用来回找。
var __selTimer = 0;

/// 当前可见范围**起点**在「正文纯文本」里的字符偏移。
///
/// # 🔴 口径（必须与 `_textToHtml` 一致，否则偏移系统性错位且**不会报错**）
/// - 只算正文段落，**不含章节标题**（标题是 `<h2 class="ch-title">`，从这里跳过）
/// - 段落之间**不含分隔符**（`Range.toString()` 天然不加）
function charOffsetOf(doc, range) {
  if (!doc || !range) return 0;
  try {
    var pre = doc.createRange();
    pre.selectNodeContents(doc.body);
    var title = doc.querySelector('.ch-title');
    if (title) pre.setStartAfter(title);
    pre.setEnd(range.startContainer, range.startOffset);
    var n = pre.toString().length;
    return n < 0 ? 0 : n;
  } catch (_) { return 0; }
}

/// 正文纯文本总长（与 `charOffsetOf` 同口径），供上层算章内百分比。
function docTextLength(doc) {
  if (!doc) return 0;
  try {
    var r = doc.createRange();
    r.selectNodeContents(doc.body);
    var title = doc.querySelector('.ch-title');
    if (title) r.setStartAfter(title);
    return r.toString().length;
  } catch (_) { return 0; }
}

function onPagRelocate(e) {
  // 第一次 relocate ⇒ 排版已经真正完成（此前 next/prev 不可用）
  state.ready = true;
  var d = e.detail || {};
  state.secIndex = (d.index === undefined ? 0 : d.index);
  var f = d.fraction;
  state.fraction = (typeof f === 'number' && isFinite(f))
    ? Math.max(0, Math.min(1, f)) : 0;
  try { state.pageInSec = pag.page || 0; } catch (_) {}
  // 🆕 v6：字符偏移 —— 翻页阅读器的**原生坐标**（每页起点本来就是字符位置）
  state.charOffset = charOffsetOf(__doc, d.range);
  __post({ type: 'relocate', sec: state.secIndex,
           page: state.pageInSec, fraction: state.fraction,
           offset: state.charOffset,
           total: docTextLength(__doc) });
}

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
var __doc = null;

/// 把 `load` / `relocate` 绑到**某个** paginator 元素上。
///
/// 🔑 必须抽成函数：`newPaginator()` 每次会**换一个新元素**（原因见那边），
///    新元素不带旧监听 ⇒ 不重绑就会「翻页没反应 / tap 没反应 / 划词没反应」。
function bindPaginator(el) {
  el.addEventListener('load', onPagLoad);
  el.addEventListener('relocate', onPagRelocate);
}

function onPagLoad(e) {
  // ⚠️ 整段包 try/catch：这里是**初始化链路上**的监听器，
  //    一旦在真机上抛错就会污染后续步骤（2026-10-22 白屏排查时踩到）。
  try {
    var d = e.detail;
    var doc = d && (d.doc || d);
    if (!doc) return;
    __doc = doc;   // 供 setTheme 直接改颜色用
    if (typeof doc.addEventListener !== 'function') return;
    if (doc.__coevoSelBound) return;
    doc.__coevoSelBound = true;
    bindToDoc(doc);

    // 🔍 字体是否**真的加载成功**（2026-10-23：白哥问「字体还没统一对吧」）。
    //    `font-display: swap` 会在失败时**静默回退**系统衬线 ⇒ 光看字形很难判断，
    //    尤其在不等宽字体上。这里直接把 `document.fonts.check()` 的结果报给 Flutter。
    try {
      if (doc.fonts && doc.fonts.ready) {
        doc.fonts.ready.then(function () {
          var okLit = doc.fonts.check('16px Literata');
          var okCjk = doc.fonts.check('16px NotoSansSC');
          __post({ type: 'fonts',
                   detail: 'Literata=' + (okLit ? 'OK' : 'MISS') +
                           ' NotoCJK=' + (okCjk ? 'OK' : 'MISS') +
                           ' count=' + doc.fonts.size });
        });
      }
    } catch (_) {}
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
}

// 初次绑定（之后每次 newPaginator 都会重新调 bindPaginator）
bindPaginator(pag);

// 🔴 2026-10-22 真机：**点击屏幕召唤不出顶栏**。
//   根因：正文在 **iframe 里**，点击事件**不会跨文档冒泡**到顶层 document
//   ⇒ 监听顶层 `document` 的 click 永远收不到（和 touch 守卫同一个坑）。
//   ⇒ 挪进 `load` 回调，注册到 **iframe 的 doc** 上（见下面的 bindToDoc）。
function bindToDoc(doc) {
  if (!doc || doc.__coevoTapBound) return;
  doc.__coevoTapBound = true;

  // 🔕 长按选词时 iOS 会弹系统菜单（Copy / Look Up / Translate）——
  //    我们在 Flutter 层另画了自己的 `SelectionMenu`。这里先拦一道 contextmenu，
  //    能挡掉一部分平台；挡不掉的部分会被 Flutter 的浮层**盖在上面**（Stack 层级更高）。
  doc.addEventListener('contextmenu', function (ev) { ev.preventDefault(); }, true);

  // 🔴 选区变化**必须绑在这个 doc 上**（正文在 iframe 里，顶层 document 收不到）。
  doc.addEventListener('selectionchange', function () {
    clearTimeout(__selTimer);
    __selTimer = setTimeout(function () {
      var sel = doc.getSelection ? doc.getSelection() : null;
      var text = (sel && sel.toString ? sel.toString() : '').trim();
      if (!text) {
        __post({ type: 'select', text: '' });   // 清空 ⇒ Flutter 收起菜单
        return;
      }
      var r = null;
      try { r = sel.getRangeAt(0).getBoundingClientRect(); } catch (_) {}
      __post({ type: 'select', text: text,
               x: r ? r.left : 0, y: r ? r.top : 0,
               w: r ? r.width : 0, h: r ? r.height : 0 });
    }, 260);
  });
  doc.addEventListener('click', function () {
    var sel = doc.getSelection ? doc.getSelection() : null;
    if (sel && sel.toString().trim()) return;   // 选词时不算「单击」
    __post({ type: 'tap' });
  }, false);
}

// 🔴🔴 2026-10-23 真机：**长按选词后只有系统菜单，我们的菜单不出现**。
//
// 根因（**第三次踩同一个坑**）：`selectionchange` 监听的还是**顶层 document**，
//   而正文在 **iframe 里** —— 选区变化**不跨文档冒泡**（同 click / touch 那两次）。
//   ⇒ 事件没到、`select` 消息没发、`controller.selection` 一直是 null、菜单不渲染。
//
// ⇒ 已挪进 `bindToDoc(doc)`，注册到 **iframe 的 doc** 上。
// 📌 判据（该固化了）：**凡是「发生在正文里」的事件（click / touch / selectionchange），
//    一律绑 iframe 的 doc，不要绑顶层 document**。

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
    # 🔴 2026-10-23：`newPaginator()` 换元素后，**旧元素的 ResizeObserver 还在**，
    #    它触发的 `render()` 会读到已被销毁的 iframe（`document` = null）并抛
    #    `Cannot read properties of null (reading 'documentElement')`。
    #    ⚠️ 不影响新元素渲染（内容正常），但会在 `#err` 里刷错误、也会进 Flutter 日志。
    #    ⇒ 在 `View.render` 开头加一道 null 守卫：**元素被换掉后就不再渲染**（语义正确）。
    _OLD_RENDER = "    render(layout) {\n        if (!layout) return"
    _NEW_RENDER = ("    render(layout) {\n"
                   "        if (!layout) return\n"
                   "        if (!this.document) return  // 元素已被替换/销毁（newPaginator）")
    if _OLD_RENDER not in js:
        raise SystemExit('❌ vendor 里找不到 `render(layout)` 的开头，null 守卫 patch 失效')
    js = js.replace(_OLD_RENDER, _NEW_RENDER, 1)

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

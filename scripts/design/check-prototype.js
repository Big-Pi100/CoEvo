#!/usr/bin/env node
/**
 * 设计原型页校验 —— CoEvo 项目版
 *
 * 用法：node scripts/design/check-prototype.js
 * 退出码：0 = 全绿，1 = 有失败
 *
 * # 🔴 为什么这个文件在**项目里**，而不是直接用 skill 里的脚本
 *
 * skill `design-prototype-page` 的 `scripts/check-prototype.js` 是**模板**，
 * 它的「配置区」是**硬编码**的（顶层直接 `checkPage(...)`，不读命令行参数）。
 * ⇒ 传文件路径给它**不会生效**，它照样检查它自己写死的那个文件，
 *   而且**退出码是 0（全绿）** —— 你以为验了 A，实际验的是 B。
 *
 * 2026-09-29 实测踩到：改完 `profile-redesign-*.html` 后跑
 * `node .../check-prototype.js docs/design/profile-redesign-...html` →
 * 输出里赫然是 `=== visual-clay-spec-2026-09-25.html ===`，而我当时没细看。
 * 📄 判据：「**工具用法错 → 静默给假结论**」（脚本跑成功、全绿，但验错了对象）
 *
 * ✅ 所以：**把模板拷进项目、把断言写死在这里**。好处有三个 ——
 *   ① 参数不会被静默忽略；② 断言可以带**本项目专有的**约束；
 *   ③ 项目自己持有断言，不随 skill 更新而漂移。
 *   ⚠️ 代价：skill 的 `checkPage` 若修了 bug，本文件**不会自动跟上** → 需手工同步。
 *      来源：skill `design-prototype-page` / `scripts/check-prototype.js`（2026-09-29 版）
 */
const fs = require('fs');
const path = require('path');

let fail = 0;
const ok = (c, m) => { if (!c) { console.log('FAIL  ' + m); fail++; } else console.log('PASS  ' + m); };

/**
 * 剥掉**两种**注释 —— 做「这一块渲染出来有没有 X」类检查前必须调用。
 *
 * 🔴 **两种都要剥，缺一不可**（都是 2026-09-29 实测踩到的）：
 * · **HTML 注释**（小于号 叹号 双减号 形式）—— 搬迁说明里写「『X』已移入 Y 页」，
 *   `forbidden: ['X']` 就命中了 X；
 * · **CSS 块注释**（斜杠星号开头的那种）—— 同一份搬迁说明也写在 CSS 段里，又命中一次。
 *
 * 🔑 判据：注释**不渲染**，而这类检查问的是「渲染结果」⇒ 必须剥。
 * ⚠️ 但「文件里还有没有 X 的**痕迹**」类断言（`mustNotHave`）**不该剥** ——
 *    注释里提到也算语义残留。
 *
 * ⚠️ 本注释**刻意不写出那两种定界符的字面形式** —— 写了会让这个块注释**提前结束**
 *    （2026-09-29 真踩过：块注释里写字面结束符 → 后面全变代码 → SyntaxError）。
 *    同族：HTML 注释结尾少写一个字符 → 浏览器把后面一大段吞掉。
 *    📌 一般判据：**注释里别写字面定界符**。
 */
const stripComments = (s) => s
  .replace(/<!--[\s\S]*?-->/g, '')
  .replace(/\/\*[\s\S]*?\*\//g, '');

function checkPage(file, opts = {}) {
  console.log('\n=== ' + path.basename(file) + ' ===');

  if (!fs.existsSync(file)) { ok(false, '文件不存在: ' + file); return; }
  const src = fs.readFileSync(file, 'utf8');

  // 1. 结构完整性
  ['<!DOCTYPE html>', '<html', '</html>', '<head', '</head>', '<body', '</body>']
    .forEach(t => ok(src.includes(t), '含 ' + t));

  // 1b. 标签开闭平衡 —— 🔑 **修改既有原型（加屏 / 插区块）后必查**
  //     大段 HTML 用字符串替换插入时最容易漏一个 `</div>`，
  //     而浏览器会「尽力渲染」（自动补闭合）→ **页面看着正常**，
  //     但后续所有兄弟节点被吞进错误的父容器里 → 布局静默错位。
  [['div', /<div\b/g, /<\/div>/g]].forEach(([tag, reO, reC]) => {
    const o = (src.match(reO) || []).length;
    const c = (src.match(reC) || []).length;
    ok(o === c, '<' + tag + '> 开闭平衡 (' + o + '/' + c + ')');
  });

  // 1c. 🆕 HTML 注释开闭平衡（本项目补加）
  //     🔴 实测踩过：把注释结尾误写成 `——>`（不是合法结束符）→
  //        浏览器会**继续往后找** `-->`，把中间一大段 HTML 全当成注释**吞掉**。
  const co = (src.match(/<!--/g) || []).length;
  const cc = (src.match(/-->/g) || []).length;
  ok(co === cc, 'HTML 注释开闭平衡 (' + co + '/' + cc + ')');

  // 2. JS 语法（能捕获真正的语法错误）
  const ms = [...src.matchAll(/<script>([\s\S]*?)<\/script>/g)];
  ok(ms.length === (opts.scripts ?? ms.length), 'script 块数量 (' + ms.length + ')');
  ms.forEach((m, i) => {
    try { new Function(m[1]); ok(true, 'script[' + i + '] JS 可解析'); }
    catch (e) { ok(false, 'script[' + i + '] JS 语法错误: ' + e.message); }
  });

  // 3. 字体：引入的 CDN 包
  const pkgs = [...src.matchAll(/@fontsource\/([a-z0-9-]+)@/g)].map(m => m[1]);
  console.log('   CDN 字体包: ' + [...new Set(pkgs)].join(', '));
  (opts.fonts || []).forEach(f => ok(pkgs.includes(f), 'CDN 引入 ' + f));

  // 3b. 已知不完整的包（分包缺关键字符 → 会静默回退）
  (opts.incompletePkgs || []).forEach(f => {
    ok(!pkgs.includes(f), '无已知不完整字体包 ' + f + '（其分包缺关键字符 → 会静默回退）');
  });

  // 3c. 本地 @font-face
  const faces = [...src.matchAll(/@font-face\{font-family:'([^']+)';src:url\('([^']+)'\)([^}]*)\}/g)];
  (opts.localFaces || []).forEach(ff => {
    const hit = faces.find(x => x[1] === ff.family);
    ok(!!hit, '声明了本地 @font-face: ' + ff.family);
    if (hit) {
      const fp = path.resolve(path.dirname(file), hit[2]);
      ok(fs.existsSync(fp), '  字体文件存在: ' + hit[2]);
      ok(fs.statSync(fp).size > 1000, '  字体文件非空: ' + hit[2]);
      ok(src.includes("'" + ff.family + "'"), '  字族被引用: ' + ff.family);
      if (ff.needFallback) {
        ok(/format\('truetype'\)/.test(hit[3] || ''), '  有 CDN 兜底: ' + ff.family);
      }
    }
  });

  // 3d. 不应引用「裸字族名」
  (opts.noBareFamilies || []).forEach(f => {
    ok(!new RegExp("'" + f + "'").test(src), "无裸字族名引用 '" + f + "'（会静默回退）");
  });

  // 4. 主题 token 齐全 + 5. 签名互异
  const themeRe = (t, flags) => new RegExp(
    '(?:\\.theme-' + t + '\\s*,\\s*)?\\[data-theme="' + t + '"\\]\\s*\\{([\\s\\S]*?)\\}', flags);

  if (opts.themes) {
    const { names, required } = opts.themes;
    names.forEach(t => {
      const m = src.match(themeRe(t));
      ok(!!m, '主题 ' + t + ' 的 token 块存在');
      if (m) {
        const miss = required.filter(k => !m[1].includes(k));
        ok(miss.length === 0,
           '主题 ' + t + ' token 齐全 (' + (required.length - miss.length) + '/' + required.length + ')' +
           (miss.length ? ' — 缺: ' + miss.join(', ') : ''));
      }
    });

    const sigOf = t => {
      const m = src.match(themeRe(t));
      return m ? m[1].replace(/\s+/g, '') : '';
    };
    const sigs = names.map(sigOf);
    ok(new Set(sigs.filter(Boolean)).size === names.length,
       'N 个主题的 token 签名互不相同 (' + new Set(sigs.filter(Boolean)).size + '/' + names.length + ')');

    // 6. 无后代选择器做主题覆盖（会破坏并排对比）
    const legacy = names.flatMap(t =>
      [' .tk', ' .card', ' .clay', '.btn', ' .pill'].map(el => '.theme-' + t + el));
    const found = legacy.filter(s => src.includes(s));
    ok(found.length === 0, '无后代选择器做主题覆盖' + (found.length ? ' — 发现: ' + found.join(', ') : ''));
  }

  // 7. 无外部 build 依赖（单文件可打开）
  ok(!src.includes('<script src="http') || src.includes('cdn.jsdelivr.net') || src.includes('cdnjs.cloudflare.com'),
     '外部脚本来自允许的 CDN');

  // 8. 字号白名单（🆕 2026-09-29）
  //
  // 🔴 **为什么必须是「白名单」而不是「禁止某些值」**：
  //    黑名单（`forbidden: ['font-size:13px']`）只能挡住**已知的坏值** ——
  //    将来有人写 `15px` 就漏了。白名单要求「区间内每一个 font-size 都在允许清单里」。
  //
  // 🔴 **为什么单独一个选项（而不是塞进 containerChecks）**：
  //    字号定义在 `<style>` 里，而 `<style>` 与用它的 `<div>` **不在同一段文本** ——
  //    用 `id="about"` 那种 HTML 锚点切出来的区间**根本扫不到 CSS**。
  //    2026-09-29 实测：我第一版正是这么写的，**永远通过 = 假绿**。
  //    → 所以字号检查**必须单独给一个 CSS 段的锚点**。
  //
  // 🔑 锚点惯例：CSS 段以 `/* ── <页面名>（` 开头（本项目各段都有这种标题注释）。
  (opts.fontSizeWhitelists || []).forEach(({ label, from, to, allowed }) => {
    const a = src.indexOf(from);
    const b = to ? src.indexOf(to, a) : src.length;
    if (a < 0 || b < a) { ok(false, label + ': 找不到区块'); return; }
    const block = stripComments(src.slice(a, b));
    const found = [...block.matchAll(/font-size:\s*([\d.]+)px/g)].map(m => m[1]);
    const uniq = [...new Set(found)];

    // 🔴 自检：区间里**确实有**字号声明 —— 否则「没有违规」只是「什么都没扫到」
    ok(found.length > 0,
       label + ': 区间内扫到字号声明 (' + found.length + ' 处 · 档位 ' + uniq.join('/') + ')');

    const bad = uniq.filter(v => !allowed.includes(v));
    ok(bad.length === 0,
       label + ' —— 允许 [' + allowed.join(', ') + ']' +
       (bad.length ? ' · 🔴 违规档位: ' + bad.join(', ') : ''));
  });

  // 9. 自定义断言
  (opts.mustHave || []).forEach(t => ok(src.includes(t), '含「' + t + '」'));
  (opts.mustNotHave || []).forEach(t => ok(!src.includes(t), '不含「' + t + '」'));

  // 10. 专项：某区块内不应出现某类名
  //
  // # 🔴 `from` / `to` 必须用「**只在该区块出现**」的锚点
  //
  // 2026-09-29 实测：`from: '⑥ 关于页'` 首次出现在**前面的说明文字**里
  // → 区间从说明文字一直延伸到结尾（22697 字符，含全部 6 屏）
  // → 一条**假红**（报「关于页有粘土」，实际是别的屏有）；
  //    另一条 `from: '② 改后'` 到 `to: '⑤ 登录页'` 则两锚点都在说明文字里
  // → 区间只有一小段、**根本没覆盖到 mockup** → **假绿**（什么也没检查到）。
  //
  // 🔑 判据：**切片式断言必须验证「区间本身是否合理」** ——
  //    否则区间过大 = 假红，区间过小 = 假绿，两者都**不会报错**。
  // ✅ 本文件的对策：① 锚点一律用 mock 的 `id`；② `sanity` 打印区间字符数，
  //    过小（< 200）即失败 —— 让「区间没覆盖到」变成显式错误。
  //
  // # 🔴 检查前**必须剥掉 HTML 注释**
  //
  // 同样 2026-09-29 踩到：三屏里各留了一条「『联系工作人员』已移入关于页」的
  // **搬迁注释**，而 forbidden 用的是字符串包含 → **注释把自己的断言弄红了**。
  //
  // 🔑 语义上：`containerChecks` 问的是「**这一块渲染出来**有没有 X」，
  //    而 HTML 注释**不渲染** → 必须先剥。
  //    ⚠️ 与 `mustNotHave`（第 8 项）**故意不同**：那条问的是「文件里还有没有 X 的痕迹」，
  //        **注释里提到也算语义残留** → 那条**不剥**。
  (opts.containerChecks || []).forEach(({ label, from, to, forbidden, sanity }) => {
    const a = src.indexOf(from);
    const b = to ? src.indexOf(to, a) : src.length;
    if (a < 0 || b < a) { ok(false, label + ': 找不到区块'); return; }
    const block = src.slice(a, b);
    const rendered = stripComments(block);
    const hit = forbidden.filter(f => rendered.includes(f));
    ok(hit.length === 0, label + (hit.length ? ' — 违规: ' + hit.join(', ') : ''));

    // 区间合理性（防「切片没覆盖到内容」的假绿）
    if (sanity !== false) {
      ok(block.length >= 200,
         label + ': 区间长度合理 (' + block.length + ' 字符 · 判据 ≥200)');
    }
  });
}

// ============ 配置区 ============
// 🔑 相对路径（不是硬编码盘符）—— 换机器 / 换目录都能跑。
//    （判据「跨工具传路径只用绝对/可解析路径」；`__dirname` 解析出的就是绝对路径）
const D = path.join(__dirname, '..', '..', 'docs', 'design') + path.sep;

// 已知不完整的 @fontsource 包（分包只有部分 IPA 字符 → 会静默回退）
const INCOMPLETE_FONTS = ['charis-sil', 'andika', 'gentium-book-plus', 'noto-sans', 'noto-serif'];

// ── ① 视觉系统规格原型（组件实时渲染 · 三主题可切）──
checkPage(D + 'visual-clay-spec-2026-09-25.html', {
  fonts: ['literata', 'inter'],
  incompletePkgs: INCOMPLETE_FONTS,
  localFaces: [
    { family: 'Charis SIL IPA', needFallback: true },
  ],
  noBareFamilies: ['Charis SIL'],
  scripts: 1,
  themes: {
    names: ['ink', 'grid', 'night'],
    required: [
      '--page', '--read', '--card', '--ink', '--ink2', '--ink3',
      '--accent', '--accent-ink', '--cl-out', '--cl-shade', '--cl-light',
      '--tk-n-bg', '--tk-n-bd', '--tk-n-fg',
      '--tk-m-bg', '--tk-m-bd', '--tk-m-fg',
      '--tk-d-bg', '--tk-d-bd', '--tk-d-fg',
      '--read-lh', '--cl-radius',
    ],
  },
  mustHave: ['切换主题', '阅读界面 · 零粘土'],
  containerChecks: [
    { label: '阅读界面内零粘土', from: 'id="flat"', to: '</section>', forbidden: ['clay'] },
  ],
});

// ── ② 「我的」页重设计对照图（6 屏 · 含关于页）──
checkPage(D + 'profile-redesign-2026-09-29.html', {
  fonts: ['literata'],
  incompletePkgs: INCOMPLETE_FONTS,
  // 本页**无**本地 @font-face：正文用系统中文栈（Noto Sans SC → PingFang SC → 微软雅黑），
  // 只有拉丁衬线 Literata 走 CDN —— 有意为之，不是漏了。
  localFaces: [],
  noBareFamilies: [],
  scripts: 1,
  themes: {
    names: ['ink', 'grid', 'night'],
    required: [
      '--page', '--read', '--card', '--ink', '--ink2', '--ink3',
      '--accent', '--accent-bright', '--accent-ink', '--accent-out',
      '--line', '--sunken',
      '--clay-radius', '--clay-radius-sm',
      '--clay-out', '--clay-shade', '--clay-light',
      '--clay-o1', '--clay-i1', '--clay-i2',
      '--clay-o1-sm', '--clay-i1-sm', '--clay-i2-sm',
    ],
  },
  mustHave: [
    '并排对比 · 左＝现状',
    // 🔴 防「加了屏但忘了改说明」—— 本轮就把「五屏」改成了「六屏」，靠这条锁住。
    //    若将来再加屏，这里会红，提醒同步标题里的数字。
    '共 6 屏',
    '六屏：',
    // 6 个屏的标题都在
    '① 现状', '② 改后', '③ 改后 · 未登录态', '④ 改后 · 夜档', '⑤ 登录页', '⑥ 关于页',
    // 本轮搬迁的入口（应在关于页出现）
    '联系工作人员',
  ],
  containerChecks: [
    {
      // spec §〇 规则 1「有体积的只可能是**可点**的东西」——
      // 关于页自身不可点 → 全平面，一个粘土块都不该有。
      // 🔑 锚点用 `id`（唯一）而不是屏标题文案 —— 标题文案在说明文字里也出现（见 checkPage §9 注释）。
      label: '关于页内零粘土（本页全平面）',
      from: 'id="about"',
      // 到「示例数据说明」为止 —— 那是 rail section 的尾部，不含任何 mock
      to: '<div class="note warn">',
      forbidden: ['class="clay"'],
    },
    {
      // 🔴 2026-09-29：「联系工作人员」已**移入关于页**（白哥定）。
      //    区间覆盖 ②③④ 三屏（都是「我的」页）→ 它们都不该再有这个入口。
      //    ⚠️ 「搬迁」= 从 A 删掉 + 在 B 加上；只做一半（两处都有）是最常见的错法。
      //    这里守「A 侧已删净」，上方 mustHave 守「B 侧已加上」。
      label: '「我的」页三屏均不再有「联系工作人员」（搬迁要搬净）',
      from: 'id="mine-logged"',
      to: 'id="login-page"',
      forbidden: ['联系工作人员'],
    },
    {
      // 🔴 同轮：**同一信息不得重复呈现** + **不放产品简介**。
      //    「App 名 22px 品牌头」与「应用名称 / 版本」两行完全重复 —— 「前前后后」的真因。
      //    白哥：「在关于里不用产品简介」。
      //    🔑 锚点用 **HTML** 段（`id="about"`）—— 这两样都是**元素**，不是样式。
      label: '关于页无重复品牌头（agapp）· 无产品简介',
      from: 'id="about"',
      to: '<div class="note warn">',
      forbidden: ['agapp', '英语学习应用'],
    },
    {
      // 同一件事的 **CSS 侧**：`.agapp` 的样式定义也必须是死的（删块不等于删样式）
      label: '关于页 CSS 段无已删块（.agapp / .agtx）',
      from: '/* ── 关于页（',
      to: '.aggo{',
      forbidden: ['agapp', '.agtx{'],
    },
  ],

  // ── 字号白名单 ──
  //
  // 🔴 锚点必须是 **CSS 段**（`/* ── 关于页（` → `.aggo{`）——
  //    字号定义在 `<style>` 里，用 HTML 锚点切出来的区间**扫不到**。
  fontSizeWhitelists: [
    {
      label: '关于页 CSS 段：正文字号只允许 12 / 14',
      from: '/* ── 关于页（',
      // 停在 `.aggo{` 之前 —— 那一行是**箭头图标**（16px），不是文字
      to: '.aggo{',
      // 12 = 顶栏「返回」（页面级）· 14 = 正文唯一档
      allowed: ['12', '14'],
    },
  ],
});

console.log('\n' + (fail === 0 ? '=== 全部通过 ===' : '=== ' + fail + ' 项失败 ==='));
process.exit(fail === 0 ? 0 : 1);

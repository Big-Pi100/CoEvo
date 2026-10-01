#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CoEvo 英语 App 设计文档一致性检查（2026-09-25 定制版）

输出：
  ① 跨文档关键事实比对（同事实多值 → 不一致）
  ② 悬空引用（文件路径 + 章节引用）
  ③ 被推翻决策的残留扫描
  ④ 零命中盲区
"""
import os
import re
import glob
from collections import defaultdict

ROOT = r'E:\CoEvo'
DOCS_DIR = os.path.join(ROOT, 'docs')

DOCS = [
    # ── 核心现行（design/ 顶层）──
    'design/english-app-implementation-plan-v2-2026-09-25.md',
    'design/subscription-model-assessment-2026-09-25.md',
    'design/design-system-spec-2026-09-25.md',
    'design/ui-ux-refactor-assessment-2026-09-25.md',
    'design/ebook-import-assessment-2026-09-25.md',
    'design/word-database-design-2026-09-25.md',
    'design/cefrj-license-and-lemmatization-2026-09-25.md',
    'design/content-source-strategy-evaluation-2026-09-25.md',
    'design/ugc-comments-feasibility-2026-09-25.md',
    'design/ios-only-personal-entity-reassessment-2026-09-25.md',
    # ── 运维（operations/）──
    'operations/qualification-startup-2026-09-25.md',
    'operations/ios-filing-and-adsdk-package-2026-09-25.md',
    # ── 归档（_archive/，仅作历史快照，不参与一致性比对）──
    'design/_archive/ad-monetization-and-flutter-assessment-2026-09-25.md',
    'design/_archive/android-platform-impact-2026-09-25.md',
    'design/_archive/article-vocab-count-design-2026-09-25.md',
    'design/_archive/membership-benefits-plan-2026-09-25.md',
    'design/_archive/overseas-ad-platform-assessment-2026-09-25.md',
    'design/_archive/paid-app-model-assessment-2026-09-25.md',
    'design/_archive/visual-direction-exploration-2026-09-25.md',
]

# 已归档文档 —— 不参与「跨文档事实比对」与「残留扫描」（它们是历史快照）
ARCHIVED_PREFIX = 'design/_archive/'

# 关键事实：同一事实应该全案一致。值为「容许同时出现的集合」——
# 若同一事实命中了集合外的值，或命中多个互斥值，即为可疑。
FACTS = {
    '月付价': [r'¥9\.9(?!\d)'],
    '年付价': [r'¥78(?!\d)', r'¥99(?!\d)', r'¥68(?!\d)'],
    '买断价（应已作废）': [r'¥38(?!\d)'],
    # ⛔「免费层生词上限」条目已于 2026-10-01 移除 —— 该上限已取消，
    #    它不再是「应当一致的事实」，而是一个**被推翻的决策** → 移入 REVERSED。
    'churn 平衡线': [r'26\s*%', r'28\s*%'],
    '加权月到手': [r'¥7\.85', r'¥7\.26'],
    '稳态订阅数(月入5千)': [r'~?637', r'~?689'],
    'LTV(churn10%)': [r'¥79', r'¥73'],
    '词库条数': [r'12,791', r'12,871', r'12,839', r'11,900', r'11,585'],
    '语音包条数': [r'63,048', r'63,048 条'],
    '语音包体积': [r'290\s*MB', r'297\.6\s*MB', r'405\s*MB'],
    '语音包成本': [r'¥48\.7'],
    '词形还原条数': [r'34,724'],
    'Dart:html 依赖文件数': [r'14\s*个?\s*文件', r'14 文件'],
    '总可删行数': [r'24,250', r'20,400'],
    'app_admin 行数': [r'9,224', r'~5,700', r'5,700 行'],
    'admin 整块行数': [r'14,946', r'11,400'],
    'app/lib 实测行数': [r'29,354', r'29,244'],
    '删除后 app/lib': [r'14,328', r'14,300', r'17,800'],
    '在线TTS月成本': [r'¥2,976', r'¥2,752'],
    '年付折扣': [r'34%', r'43%', r'16\.7%'],
    # ── 三档主题强调色（2026-09-25 方案甲：统一色相）──
    '格档强调色（应已统一为朱砂）': [r'#B4432C', r'#00A87A', r'#00C08B'],
    '夜档强调色（应已统一为深底版朱砂）': [r'#DB7E6B', r'#FF8A45', r'#FF9E68'],
    'accent-out token（新增）': [r'--accent-out', r'rgba\(180,67,44,\.40\)', r'rgba\(219,126,107,\.40\)'],
}

# 被推翻的决策 → 搜索「仍把它当现行方案」的残留
REVERSED = {
    '广告变现': r'广告变现|ATT 授权|激励视频|穿山甲|优量汇|eCPM',
    '海外区': r'海外区|AdMob',
    '¥38 一次性买断': r'¥38|一次性解锁|买断',
    '¥99 年付': r'¥99',
    '语音包作为订阅权益': r'订阅.{0,12}完整语音包|完整语音包.{0,12}订阅',
    '「N 个生词」标识': r'N 个生词|cefr_band_counts',
    '自由文本 UGC': r'自由文本 UGC|用户发帖',
    'Android': r'安卓商店|Android 上架|鸿蒙',
    'plan / 精读课程': r'精读课程|prebuilt_plans',
    'trial 流程': r'trial 流程|试用期',
    'Admin 后台': r'app_admin|admin 端',
    # 🆕 2026-10-01：免费层生词本 200 词上限已取消（免费可全量使用）
    #    → 仍把它当现行方案的表述即为残留。
    #    📄 docs/review/free-tier-limit-removal-assessment-2026-10-01.md
    '免费层 200 词上限': r'200\s*词上限|免费层.{0,12}上限|生词本上限|免费层.{0,6}200',
}

TOPICS = {
    '登录方式': r'登录方式|Sign in with Apple|Apple 登录|邮箱密码',
    '界面语言/i18n': r'国际化|i18n|界面语言|多语言|localization',
    '目标用户定义': r'目标用户|目标人群|用户画像',
    '测试策略': r'测试策略|测试计划|单元测试|集成测试',
    '无障碍': r'无障碍|accessibility|VoiceOver',
    '上架区域': r'中国区',
    '存量数据处置': r'迁移|存量数据|旧表',
    '版本节奏': r'发版|灰度|TestFlight',
    '性能指标': r'毫秒|性能指标|ms 级',
    '隐私政策页': r'隐私政策',
    '恢复购买': r'恢复购买',
    '自动续费披露': r'自动续费|自动续期',
    '降级策略': r'降级',
    'DRM': r'DRM',
    '日志上报/崩溃监控': r'崩溃|Crashlytics|Sentry|日志上报',
    '数据导出': r'数据导出|导出',
    '多端同步': r'多端|云同步|同步',
    '订阅状态回调': r'Server Notifications|订阅状态回调',
}

PATH_RE = re.compile(
    r'`((?:backend|app|data|scripts|docs)'
    r'[\w/\.\-]*\.(?:rs|dart|json|sql|py|md|html|yaml|ttf|woff2|toml))`'
)
SEC_RE = re.compile(r'§\s*([0-9]+(?:\.[0-9]+)*)')

# 已作废的强调色（不应再出现在现行文档与原型页中，除「修复前对照」外）
DEPRECATED_COLORS = {
    '#00A87A': '格档旧青绿 → 方案甲已改为 #B4432C',
    '#00C08B': '格档旧亮青绿 → 已改为 #C4533A',
    '#FF8A45': '夜档旧暖橙 → 已改为 #DB7E6B',
    '#FF9E68': '夜档旧亮暖橙 → 已改为 #E89B8C',
}

# 原型页（CSS 变量一致性检查）
ASSETS = glob.glob(os.path.join(DOCS_DIR, 'design', '*.html'))


def load(doc):
    p = os.path.join(DOCS_DIR, doc)
    try:
        with open(p, encoding='utf-8') as f:
            return f.read()
    except Exception:
        return None


# 裸文件名（不含路径分隔符）在这些目录下搜索
_BARE_SEARCH = [
    os.path.join(ROOT, 'app', 'lib'),
    os.path.join(ROOT, 'app'),
    os.path.join(ROOT, 'docs'),
    os.path.join(ROOT, 'docs', 'design'),
    os.path.join(ROOT, 'docs', 'operations'),
    os.path.join(ROOT, 'backend', 'crates'),
    os.path.join(ROOT, 'scripts'),
]

_BARE_CACHE = {}


def _ref_exists(ref):
    """引用路径是否存在。支持全路径与裸文件名两种写法。"""
    # ① 全路径形式
    for cand in (os.path.join(ROOT, ref), os.path.join(DOCS_DIR, ref)):
        if os.path.exists(cand):
            return True

    # ② 裸文件名 —— 在常见目录下搜索
    if '/' not in ref and '\\' not in ref:
        if ref in _BARE_CACHE:
            return _BARE_CACHE[ref]
        found = False
        for base in _BARE_SEARCH:
            if not os.path.isdir(base):
                continue
            for _root, _dirs, files in os.walk(base):
                if ref in files:
                    found = True
                    break
            if found:
                break
        _BARE_CACHE[ref] = found
        return found

    # ③ 归档文档内部引用：检查同目录（历史原貌，允许指向旧位置）
    return False


def main():
    texts = {}
    for d in DOCS:
        t = load(d)
        if t is None:
            print(f'!! 无法读取: {d}')
        else:
            texts[d] = t

    # 只有现行文档参与「事实比对」与「残留扫描」
    active = {d: t for d, t in texts.items() if not d.startswith(ARCHIVED_PREFIX)}
    print(f'（现行文档 {len(active)} 份 / 归档 {len(texts) - len(active)} 份）')
    print('（归档文档只参与悬空引用检查，不参与事实比对与残留扫描）')

    # ---------- ① 关键事实比对 ----------
    print('\n' + '=' * 70)
    print('① 跨文档关键事实比对')
    print('=' * 70)
    for fact, pats in FACTS.items():
        hits = defaultdict(list)
        for d, t in active.items():
            for p in pats:
                n = len(re.findall(p, t))
                if n:
                    hits[p].append((d, n))
        if not hits:
            print(f'\n🔴 [零命中] {fact}')
            continue
        if len(hits) > 1:
            print(f'\n🟠 [多值并存] {fact}')
            for p, ds in hits.items():
                print(f'   模式 {p}  → ' + ', '.join(
                    f'{os.path.basename(d)}({n})' for d, n in ds[:6]))
        else:
            p = list(hits)[0]
            total = sum(n for _, n in hits[p])
            print(f'\n✅ {fact}: {p}  (共 {total} 处 / {len(hits[p])} 文档)')

    # ---------- ② 悬空引用 ----------
    print('\n' + '=' * 70)
    print('② 悬空引用')
    print('=' * 70)
    missing = defaultdict(list)
    for d, t in texts.items():
        for m in PATH_RE.finditer(t):
            ref = m.group(1)
            if _ref_exists(ref):
                continue
            missing[ref.replace('/', os.sep)].append(d)
    if missing:
        archived_only = all(
            all(dd.startswith(ARCHIVED_PREFIX) for dd in ds)
            for ds in missing.values()
        )
        print(f'\n🟠 悬空文件引用 {len(missing)} 个：')
        for ref, ds in sorted(missing.items()):
            tag = '（仅归档文档内部引用 · 按规则保留原貌）' \
                if all(x.startswith(ARCHIVED_PREFIX) for x in ds) else ''
            print(f'   {ref}{tag}')
            for d in ds[:4]:
                print(f'      ← {d}')
        if archived_only:
            print('\n✅ 现行文档无悬空引用（上述全部来自归档文档）')
    else:
        print('\n✅ 无悬空文件引用')

    # 章节引用：对同文档内的 §X 检查是否存在对应标题
    print('\n--- 章节引用抽样（同文档内）---')
    sec_issues = []
    for d, t in active.items():
        headings = set()
        for h in re.finditer(r'^#{1,6}\s+([\d\.]+)', t, re.M):
            headings.add(h.group(1).rstrip('.'))
        for m in SEC_RE.finditer(t):
            sec = m.group(1)
            if sec.count('.') >= 1 and sec not in headings:
                top = sec.split('.')[0]
                if top in headings or any(h.startswith(sec) for h in headings):
                    continue
                sec_issues.append((d, sec))
    if sec_issues:
        uniq = sorted(set(sec_issues))
        print(f'🟠 可疑章节引用 {len(uniq)} 处（可能指向其他文档，需人工确认）：')
        for d, s in uniq[:25]:
            print(f'   {os.path.basename(d)} → §{s}')
    else:
        print('✅ 未发现可疑章节引用')

    # ---------- ③ 被推翻决策残留 ----------
    print('\n' + '=' * 70)
    print('③ 被推翻决策的残留扫描（含「作废」字样的行视为已标注）')
    print('=' * 70)
    for name, pat in REVERSED.items():
        print(f'\n--- {name} ---')
        total = 0
        for d, t in active.items():
            lines = t.split('\n')
            bad = []
            for i, ln in enumerate(lines):
                if re.search(pat, ln):
                    total += 1
                    if not re.search(r'作废|已取消|~~|⛔|❌|不 做|不做|仅 iOS|已放弃', ln):
                        bad.append((i + 1, ln.strip()[:110]))
            if bad:
                print(f'  🟠 {os.path.basename(d)}: {len(bad)} 行未标注')
                for ln, txt in bad[:3]:
                    print(f'      L{ln}: {txt}')
        if total == 0:
            print('  ✅ 零命中')
        else:
            print(f'  （总命中 {total} 处）')

    # ---------- ④ 原型页 CSS 一致性 ----------
    print('\n' + '=' * 70)
    print('④ 原型页 CSS 一致性（强调色 / 变量定义 / 自引用）')
    print('=' * 70)
    css_issues = 0
    for a in sorted(ASSETS):
        name = os.path.basename(a)
        try:
            with open(a, encoding='utf-8') as f:
                t = f.read()
        except Exception:
            continue
        # 已作废颜色残留
        stale = [c for c in DEPRECATED_COLORS if c in t]
        # 自引用
        selfref = re.findall(r'(--[\w-]+)\s*:\s*var\(\1\)', t)
        # 引用方未定义
        defs = set(re.findall(r'(--[\w-]+)\s*:', t))
        undef = sorted(set(re.findall(r'var\((--[\w-]+)', t)) - defs)
        if stale or selfref or undef:
            css_issues += 1
            print(f'  🟠 {name}')
            if stale:
                for c in stale:
                    print(f'      残留旧色 {c} —— {DEPRECATED_COLORS[c]}')
            if selfref:
                print(f'      自引用: {selfref}')
            if undef:
                print(f'      未定义变量: {undef}')
    if css_issues == 0:
        print(f'  ✅ {len(ASSETS)} 个原型页全部一致（无旧色残留 / 无自引用 / 无未定义变量）')

    # ---------- ⑤ 零命中盲区 ----------
    print('\n' + '=' * 70)
    print('⑤ 零命中盲区')
    print('=' * 70)
    for topic, pat in TOPICS.items():
        n_files = sum(1 for t in active.values() if re.search(pat, t))
        if n_files == 0:
            print(f'🔴 {topic}: 全案 0 命中')
        elif n_files <= 2:
            print(f'🟡 {topic}: 仅 {n_files} 份文档提及')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""补 `word_form` 的**不规则变形**缺口（2026-09-29 · 白哥「执行」第 4 项）。

# 为什么需要

端侧 `word_query_service.analyzeForm()` 是 **`WHERE form = ?` 精确匹配** →
查不到就返回 `null` → 上层走「词库外」流程（LLM 制卡）。
所以缺一条变形，用户划到那个词就会**多花一次 LLM 调用**、且**多等一次网络往返**。

实测缺口（2026-09-29）：`buried`(bury) · `leaves`(leaf) · `shrank`(shrink) ·
`leapt`(leap) · `freshmen`(freshman) · `grandchildren`(grandchild) · `underwent`(undergo) ·
`withdrew`(withdraw) · `retold`(retell) · `outgrown`(outgrow) · `vertebrae`(vertebra) …
**全都不在表里**。

# 为什么不用旧 `word_form.json`

它是**纯规则穷举**（36,856 条），两个致命问题：
1. **不含任何不规则变形**（`shrank`/`underwent`/`withdrew` 都不在里面）—— 正是要补的那批
2. **大量规则误加**（`abandoneded` · `abilitying` · `abolitioning`）—— 就是 09-26 删掉的 9,401 条噪音

→ 所以只能**自建不规则表**。

# 四条判据（缺一不可）
#
# | # | 判据 | 为什么 |
# |---|---|---|
# | 1 | `base` 在 `word` 表 | 还原后必须**能拿到卡片**，否则还原到空气 |
# | 2 | `form` **不在** `word` 表 | 端侧先按 spelling 精确匹配 → form 自己是词条时，这条映射**永不触发**（死数据） |
# | 3 | `form` 不在 `word_form` 表 | 不重复 |
# | 4 | `form != base` | 同形映射无意义 |
#
# 🔴 **为什么不用「form 在 cefr_catalog 里」做过滤**（第一版用了，是错的）：
#    CEFR-J 是**学习词表**，不是完整词典 —— 它既不收英式变体
#    （`learnt` · `spelt` · `spilt` · `learnt` · `labelling`），
#    也不收常见变形（`overthrew` · `woken` · `shrunk`）。
#    **而我们的内容源含 BBC（英式拼写）** → 按它过滤会把真变形挡在门外（实测挡掉 46 条）。
#    `fill_word_form_gap.py` 当年需要它，是因为那个源是**规则穷举**（会造
#    `abolitioning` 这类垃圾）；本脚本的源是**人工核对的不规则表**，无此风险。
#
# 🔑 语料实证仍**保留为信息**（`--verbose` 显示哪些 form 在语料里出现过），
#    但**不作为过滤条件** —— 过滤条件只保留「可判定的结构约束」。

# 用法

```bash
python scripts/fill_word_form_irregular.py --dry-run          # 只报告
python scripts/fill_word_form_irregular.py                    # 写入
python scripts/fill_word_form_irregular.py --dry-run --db <副本>
```
"""

import argparse
import json
import os
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORD_DB = os.path.join(ROOT, 'data', 'word.db')
CEFR = os.path.join(ROOT, 'backend', 'cefr_catalog.json')

# ══════════════════════════════════════════════════════════════════════
# 不规则变形表 —— **只列与「规则推导结果不同」的形式**
#
# 🔑 为什么只列不规则的：规则形式（`buries`/`burying`）由 `build_word_form.py`
#    的规则机制覆盖；重复列只会掩盖真正的缺口。
# 🔑 类别名对齐 `build_word_form.py` 的 `RULES`（plural/past/past_participle/ing）。
# ══════════════════════════════════════════════════════════════════════
IRREGULAR = {
    # ── 动词：past / past_participle / ing（双写）／第三人称 ──
    'be':        {'past': ['was', 'were'], 'past_participle': ['been'], 'present': ['am', 'is', 'are']},
    'bear':      {'past': ['bore'], 'past_participle': ['borne', 'born'], 'ing': ['bearing']},
    'beat':      {'past': ['beat'], 'past_participle': ['beaten', 'beat'], 'ing': ['beating']},
    'become':    {'past': ['became'], 'past_participle': ['become'], 'ing': ['becoming']},
    'begin':     {'past': ['began'], 'past_participle': ['begun'], 'ing': ['beginning']},
    'bend':      {'past': ['bent'], 'past_participle': ['bent']},
    'bet':       {'past': ['bet'], 'past_participle': ['bet']},
    'bind':      {'past': ['bound'], 'past_participle': ['bound']},
    'bite':      {'past': ['bit'], 'past_participle': ['bitten'], 'ing': ['biting']},
    'bleed':     {'past': ['bled'], 'past_participle': ['bled']},
    'blow':      {'past': ['blew'], 'past_participle': ['blown']},
    'break':     {'past': ['broke'], 'past_participle': ['broken'], 'ing': ['breaking']},
    'breed':     {'past': ['bred'], 'past_participle': ['bred']},
    'bring':     {'past': ['brought'], 'past_participle': ['brought']},
    'broadcast': {'past': ['broadcast'], 'past_participle': ['broadcast'], 'ing': ['broadcasting']},
    'build':     {'past': ['built'], 'past_participle': ['built']},
    'burn':      {'past': ['burnt', 'burned'], 'past_participle': ['burnt', 'burned']},
    'burst':     {'past': ['burst'], 'past_participle': ['burst'], 'ing': ['bursting']},
    'buy':       {'past': ['bought'], 'past_participle': ['bought']},
    'catch':     {'past': ['caught'], 'past_participle': ['caught']},
    'choose':    {'past': ['chose'], 'past_participle': ['chosen'], 'ing': ['choosing']},
    'cling':     {'past': ['clung'], 'past_participle': ['clung']},
    'come':      {'past': ['came'], 'past_participle': ['come'], 'ing': ['coming']},
    'cost':      {'past': ['cost'], 'past_participle': ['cost'], 'ing': ['costing']},
    'creep':     {'past': ['crept'], 'past_participle': ['crept']},
    'cut':       {'past': ['cut'], 'past_participle': ['cut'], 'ing': ['cutting']},
    'deal':      {'past': ['dealt'], 'past_participle': ['dealt']},
    'dig':       {'past': ['dug'], 'past_participle': ['dug'], 'ing': ['digging']},
    'do':        {'past': ['did'], 'past_participle': ['done'], 'present': ['does'], 'ing': ['doing']},
    'draw':      {'past': ['drew'], 'past_participle': ['drawn']},
    'dream':     {'past': ['dreamt', 'dreamed'], 'past_participle': ['dreamt', 'dreamed']},
    'drink':     {'past': ['drank'], 'past_participle': ['drunk'], 'ing': ['drinking']},
    'drive':     {'past': ['drove'], 'past_participle': ['driven'], 'ing': ['driving']},
    'eat':       {'past': ['ate'], 'past_participle': ['eaten'], 'ing': ['eating']},
    'fall':      {'past': ['fell'], 'past_participle': ['fallen']},
    'feed':      {'past': ['fed'], 'past_participle': ['fed']},
    'feel':      {'past': ['felt'], 'past_participle': ['felt']},
    'fight':     {'past': ['fought'], 'past_participle': ['fought']},
    'find':      {'past': ['found'], 'past_participle': ['found']},
    'flee':      {'past': ['fled'], 'past_participle': ['fled'], 'ing': ['fleeing']},
    'fling':     {'past': ['flung'], 'past_participle': ['flung']},
    'fly':       {'past': ['flew'], 'past_participle': ['flown'], 'plural': ['flies']},
    'forbid':    {'past': ['forbade', 'forbad'], 'past_participle': ['forbidden'], 'ing': ['forbidding']},
    'forget':    {'past': ['forgot'], 'past_participle': ['forgotten'], 'ing': ['forgetting']},
    'forgive':   {'past': ['forgave'], 'past_participle': ['forgiven'], 'ing': ['forgiving']},
    'freeze':    {'past': ['froze'], 'past_participle': ['frozen'], 'ing': ['freezing']},
    'get':       {'past': ['got'], 'past_participle': ['got', 'gotten'], 'ing': ['getting']},
    'give':      {'past': ['gave'], 'past_participle': ['given'], 'ing': ['giving']},
    'go':        {'past': ['went'], 'past_participle': ['gone'], 'present': ['goes'], 'ing': ['going']},
    'grind':     {'past': ['ground'], 'past_participle': ['ground']},
    'grow':      {'past': ['grew'], 'past_participle': ['grown']},
    'hang':      {'past': ['hung', 'hanged'], 'past_participle': ['hung', 'hanged']},
    'have':      {'past': ['had'], 'past_participle': ['had'], 'present': ['has'], 'ing': ['having']},
    'hear':      {'past': ['heard'], 'past_participle': ['heard']},
    'hide':      {'past': ['hid'], 'past_participle': ['hidden'], 'ing': ['hiding']},
    'hit':       {'past': ['hit'], 'past_participle': ['hit'], 'ing': ['hitting']},
    'hold':      {'past': ['held'], 'past_participle': ['held']},
    'hurt':      {'past': ['hurt'], 'past_participle': ['hurt'], 'ing': ['hurting']},
    'keep':      {'past': ['kept'], 'past_participle': ['kept']},
    'kneel':     {'past': ['knelt', 'kneeled'], 'past_participle': ['knelt', 'kneeled']},
    'know':      {'past': ['knew'], 'past_participle': ['known']},
    'lay':       {'past': ['laid'], 'past_participle': ['laid']},
    'lead':      {'past': ['led'], 'past_participle': ['led']},
    'lean':      {'past': ['leant', 'leaned'], 'past_participle': ['leant', 'leaned']},
    'leap':      {'past': ['leapt', 'leaped'], 'past_participle': ['leapt', 'leaped']},
    'learn':     {'past': ['learnt', 'learned'], 'past_participle': ['learnt', 'learned']},
    'leave':     {'past': ['left'], 'past_participle': ['left'], 'ing': ['leaving']},
    'lend':      {'past': ['lent'], 'past_participle': ['lent']},
    'let':       {'past': ['let'], 'past_participle': ['let'], 'ing': ['letting']},
    'lie':       {'past': ['lay'], 'past_participle': ['lain'], 'ing': ['lying']},
    'light':     {'past': ['lit', 'lighted'], 'past_participle': ['lit', 'lighted']},
    'lose':      {'past': ['lost'], 'past_participle': ['lost'], 'ing': ['losing']},
    'make':      {'past': ['made'], 'past_participle': ['made'], 'ing': ['making']},
    'mean':      {'past': ['meant'], 'past_participle': ['meant']},
    'meet':      {'past': ['met'], 'past_participle': ['met']},
    'mistake':   {'past': ['mistook'], 'past_participle': ['mistaken'], 'ing': ['mistaking']},
    'overcome':  {'past': ['overcame'], 'past_participle': ['overcome'], 'ing': ['overcoming']},
    'overpay':   {'past': ['overpaid'], 'past_participle': ['overpaid']},
    'overtake':  {'past': ['overtook'], 'past_participle': ['overtaken'], 'ing': ['overtaking']},
    'overthrow': {'past': ['overthrew'], 'past_participle': ['overthrown']},
    'pay':       {'past': ['paid'], 'past_participle': ['paid']},
    'put':       {'past': ['put'], 'past_participle': ['put'], 'ing': ['putting']},
    'quit':      {'past': ['quit', 'quitted'], 'past_participle': ['quit', 'quitted'], 'ing': ['quitting']},
    'read':      {'past': ['read'], 'past_participle': ['read'], 'ing': ['reading']},
    'rebuild':   {'past': ['rebuilt'], 'past_participle': ['rebuilt']},
    'redo':      {'past': ['redid'], 'past_participle': ['redone'], 'ing': ['redoing']},
    'retell':    {'past': ['retold'], 'past_participle': ['retold']},
    'rewrite':   {'past': ['rewrote'], 'past_participle': ['rewritten'], 'ing': ['rewriting']},
    'rid':       {'past': ['rid', 'ridded'], 'past_participle': ['rid', 'ridded'], 'ing': ['ridding']},
    'ride':      {'past': ['rode'], 'past_participle': ['ridden'], 'ing': ['riding']},
    'ring':      {'past': ['rang'], 'past_participle': ['rung'], 'ing': ['ringing']},
    'rise':      {'past': ['rose'], 'past_participle': ['risen'], 'ing': ['rising']},
    'run':       {'past': ['ran'], 'past_participle': ['run'], 'ing': ['running']},
    'saw':       {'past': ['sawed'], 'past_participle': ['sawn', 'sawed']},
    'say':       {'past': ['said'], 'past_participle': ['said']},
    'see':       {'past': ['saw'], 'past_participle': ['seen'], 'ing': ['seeing']},
    'seek':      {'past': ['sought'], 'past_participle': ['sought']},
    'sell':      {'past': ['sold'], 'past_participle': ['sold']},
    'send':      {'past': ['sent'], 'past_participle': ['sent']},
    'set':       {'past': ['set'], 'past_participle': ['set'], 'ing': ['setting']},
    'sew':       {'past': ['sewed'], 'past_participle': ['sewn', 'sewed']},
    'shake':     {'past': ['shook'], 'past_participle': ['shaken'], 'ing': ['shaking']},
    'shed':      {'past': ['shed'], 'past_participle': ['shed'], 'ing': ['shedding']},
    'shine':     {'past': ['shone', 'shined'], 'past_participle': ['shone', 'shined'], 'ing': ['shining']},
    'shoot':     {'past': ['shot'], 'past_participle': ['shot']},
    'show':      {'past': ['showed'], 'past_participle': ['shown', 'showed']},
    'shrink':    {'past': ['shrank', 'shrunk'], 'past_participle': ['shrunk', 'shrunken'], 'ing': ['shrinking']},
    'shut':      {'past': ['shut'], 'past_participle': ['shut'], 'ing': ['shutting']},
    'sing':      {'past': ['sang'], 'past_participle': ['sung'], 'ing': ['singing']},
    'sink':      {'past': ['sank'], 'past_participle': ['sunk'], 'ing': ['sinking']},
    'sit':       {'past': ['sat'], 'past_participle': ['sat'], 'ing': ['sitting']},
    'sleep':     {'past': ['slept'], 'past_participle': ['slept']},
    'slide':     {'past': ['slid'], 'past_participle': ['slid'], 'ing': ['sliding']},
    'smell':     {'past': ['smelt', 'smelled'], 'past_participle': ['smelt', 'smelled']},
    'speak':     {'past': ['spoke'], 'past_participle': ['spoken'], 'ing': ['speaking']},
    'speed':     {'past': ['sped', 'speeded'], 'past_participle': ['sped', 'speeded']},
    'spell':     {'past': ['spelt', 'spelled'], 'past_participle': ['spelt', 'spelled']},
    'spend':     {'past': ['spent'], 'past_participle': ['spent']},
    'spill':     {'past': ['spilt', 'spilled'], 'past_participle': ['spilt', 'spilled']},
    'spin':      {'past': ['spun'], 'past_participle': ['spun'], 'ing': ['spinning']},
    'spit':      {'past': ['spat', 'spit'], 'past_participle': ['spat', 'spit'], 'ing': ['spitting']},
    'split':     {'past': ['split'], 'past_participle': ['split'], 'ing': ['splitting']},
    'spoil':     {'past': ['spoilt', 'spoiled'], 'past_participle': ['spoilt', 'spoiled']},
    'spread':    {'past': ['spread'], 'past_participle': ['spread'], 'ing': ['spreading']},
    'spring':    {'past': ['sprang'], 'past_participle': ['sprung'], 'ing': ['springing']},
    'stand':     {'past': ['stood'], 'past_participle': ['stood']},
    'steal':     {'past': ['stole'], 'past_participle': ['stolen'], 'ing': ['stealing']},
    'stick':     {'past': ['stuck'], 'past_participle': ['stuck']},
    'sting':     {'past': ['stung'], 'past_participle': ['stung']},
    'stink':     {'past': ['stank', 'stunk'], 'past_participle': ['stunk'], 'ing': ['stinking']},
    'strike':    {'past': ['struck'], 'past_participle': ['struck', 'stricken'], 'ing': ['striking']},
    'swear':     {'past': ['swore'], 'past_participle': ['sworn']},
    'sweep':     {'past': ['swept'], 'past_participle': ['swept']},
    'swim':      {'past': ['swam'], 'past_participle': ['swum'], 'ing': ['swimming']},
    'swing':     {'past': ['swung'], 'past_participle': ['swung']},
    'take':      {'past': ['took'], 'past_participle': ['taken'], 'ing': ['taking']},
    'teach':     {'past': ['taught'], 'past_participle': ['taught']},
    'tear':      {'past': ['tore'], 'past_participle': ['torn'], 'ing': ['tearing']},
    'tell':      {'past': ['told'], 'past_participle': ['told']},
    'think':     {'past': ['thought'], 'past_participle': ['thought']},
    'throw':     {'past': ['threw'], 'past_participle': ['thrown']},
    'thrust':    {'past': ['thrust'], 'past_participle': ['thrust'], 'ing': ['thrusting']},
    'understand': {'past': ['understood'], 'past_participle': ['understood']},
    'undergo':   {'past': ['underwent'], 'past_participle': ['undergone'], 'ing': ['undergoing']},
    'undertake': {'past': ['undertook'], 'past_participle': ['undertaken'], 'ing': ['undertaking']},
    'undo':      {'past': ['undid'], 'past_participle': ['undone'], 'ing': ['undoing']},
    'upset':     {'past': ['upset'], 'past_participle': ['upset'], 'ing': ['upsetting']},
    'wake':      {'past': ['woke'], 'past_participle': ['woken'], 'ing': ['waking']},
    'wear':      {'past': ['wore'], 'past_participle': ['worn']},
    'weave':     {'past': ['wove'], 'past_participle': ['woven'], 'ing': ['weaving']},
    'weep':      {'past': ['wept'], 'past_participle': ['wept']},
    'win':       {'past': ['won'], 'past_participle': ['won'], 'ing': ['winning']},
    'wind':      {'past': ['wound'], 'past_participle': ['wound']},
    'withdraw':  {'past': ['withdrew'], 'past_participle': ['withdrawn']},
    'withhold':  {'past': ['withheld'], 'past_participle': ['withheld']},
    'write':     {'past': ['wrote'], 'past_participle': ['written'], 'ing': ['writing']},

    # ── 名词：不规则复数 ──
    'analysis':   {'plural': ['analyses']},
    'axis':       {'plural': ['axes']},
    'basis':      {'plural': ['bases']},
    'child':      {'plural': ['children']},
    'crisis':     {'plural': ['crises']},
    'criterion':  {'plural': ['criteria']},
    'datum':      {'plural': ['data']},
    'deer':       {'plural': ['deer']},
    'diagnosis':  {'plural': ['diagnoses']},
    'ellipsis':   {'plural': ['ellipses']},
    'fish':       {'plural': ['fish', 'fishes']},
    'focus':      {'plural': ['foci', 'focuses']},
    'foot':       {'plural': ['feet']},
    'formula':    {'plural': ['formulae', 'formulas']},
    'fungus':     {'plural': ['fungi', 'funguses']},
    'goose':      {'plural': ['geese']},
    'hypothesis': {'plural': ['hypotheses']},
    'index':      {'plural': ['indices', 'indexes']},
    'leaf':       {'plural': ['leaves']},
    'loaf':       {'plural': ['loaves']},
    'man':        {'plural': ['men']},
    'medium':     {'plural': ['media', 'mediums']},
    'mouse':      {'plural': ['mice']},
    'nucleus':    {'plural': ['nuclei', 'nucleuses']},
    'oasis':      {'plural': ['oases']},
    'ox':         {'plural': ['oxen']},
    'phenomenon': {'plural': ['phenomena']},
    'radius':     {'plural': ['radii', 'radiuses']},
    'sheep':      {'plural': ['sheep']},
    'shelf':      {'plural': ['shelves']},
    'stimulus':   {'plural': ['stimuli']},
    'thesis':     {'plural': ['theses']},
    'thief':      {'plural': ['thieves']},
    'tooth':      {'plural': ['teeth']},
    'vertebra':   {'plural': ['vertebrae']},
    'wife':       {'plural': ['wives']},
    'wolf':       {'plural': ['wolves']},
    'woman':      {'plural': ['women']},

    # ── 形容词：不规则比较级 / 最高级 ──
    'bad':      {'comparative': ['worse'], 'superlative': ['worst']},
    'far':      {'comparative': ['farther', 'further'], 'superlative': ['farthest', 'furthest']},
    'good':     {'comparative': ['better'], 'superlative': ['best']},
    'little':   {'comparative': ['less'], 'superlative': ['least']},
    'many':     {'comparative': ['more'], 'superlative': ['most']},
    'much':     {'comparative': ['more'], 'superlative': ['most']},
    'well':     {'comparative': ['better'], 'superlative': ['best']},

    # ── 特殊：`-f/-fe` → `-ves`（规则可推，但常被漏）──
    'half':     {'plural': ['halves']},
    'knife':    {'plural': ['knives']},
    'life':     {'plural': ['lives']},
    'self':     {'plural': ['selves']},
    'calf':     {'plural': ['calves']},
    'elf':      {'plural': ['elves']},
    'scarf':    {'plural': ['scarves', 'scarfs']},

    # ── 派生词的 ing / past（规则可推，但 LLM 判定常漏）──
    'make':     {'ing': ['making']},
    'bury':     {'past': ['buried'], 'past_participle': ['buried'], 'plural': ['buries']},
    'fry':      {'plural': ['fries']},
    'dry':      {'plural': ['dries'], 'comparative': ['drier'], 'superlative': ['driest']},
    'try':      {'plural': ['tries']},
    'carry':    {'plural': ['carries']},
    'study':    {'plural': ['studies']},
    'apply':    {'plural': ['applies']},
    'rely':     {'plural': ['relies']},
    'occur':    {'past': ['occurred'], 'past_participle': ['occurred'], 'ing': ['occurring']},
    'refer':    {'past': ['referred'], 'past_participle': ['referred'], 'ing': ['referring']},
    'prefer':   {'past': ['preferred'], 'past_participle': ['preferred'], 'ing': ['preferring']},
    'admit':    {'past': ['admitted'], 'past_participle': ['admitted'], 'ing': ['admitting']},
    'permit':   {'past': ['permitted'], 'past_participle': ['permitted'], 'ing': ['permitting']},
    'commit':   {'past': ['committed'], 'past_participle': ['committed'], 'ing': ['committing']},
    'submit':   {'past': ['submitted'], 'past_participle': ['submitted'], 'ing': ['submitting']},
    'omit':     {'past': ['omitted'], 'past_participle': ['omitted'], 'ing': ['omitting']},
    'equip':    {'past': ['equipped'], 'past_participle': ['equipped'], 'ing': ['equipping']},
    'travel':   {'past': ['travelled', 'traveled'], 'past_participle': ['travelled', 'traveled'], 'ing': ['travelling', 'traveling']},
    'cancel':   {'past': ['cancelled', 'canceled'], 'past_participle': ['cancelled', 'canceled'], 'ing': ['cancelling', 'canceling']},
    'label':    {'past': ['labelled', 'labeled'], 'past_participle': ['labelled', 'labeled'], 'ing': ['labelling', 'labeling']},
    'model':    {'past': ['modelled', 'modeled'], 'past_participle': ['modelled', 'modeled'], 'ing': ['modelling', 'modeling']},
    'signal':   {'past': ['signalled', 'signaled'], 'past_participle': ['signalled', 'signaled'], 'ing': ['signalling', 'signaling']},
    'total':    {'past': ['totalled', 'totaled'], 'past_participle': ['totalled', 'totaled'], 'ing': ['totalling', 'totaling']},
    'level':    {'past': ['levelled', 'leveled'], 'past_participle': ['levelled', 'leveled'], 'ing': ['levelling', 'leveling']},
    'marvel':   {'past': ['marvelled', 'marveled'], 'past_participle': ['marvelled', 'marveled'], 'ing': ['marvelling', 'marveling']},
    'fulfil':   {'past': ['fulfilled'], 'past_participle': ['fulfilled'], 'ing': ['fulfilling']},
    'instal':   {'past': ['installed'], 'past_participle': ['installed'], 'ing': ['installing']},
}

#: 屈折类 → `kind`（与 `fill_word_form_gap.py` 口径一致）
INFLECTION = ('plural', 'past', 'past_participle', 'ing', 'comparative', 'superlative')


def load_cefr(path):
    """`cefr_catalog.json` 的全部拼写（小写）—— 语料实证源。

    🔴 结构是 **`{拼写: {pos, ipa, ...}}`** —— **键才是拼写**。
       第一版遍历 `values()` 去捞字符串 → 全是 dict → 返回 **0 个拼写**
       → 每条都被判「不在语料里」→ 待补 **0**（假幂等，最危险的那种静默失败）。
       正解：取 `keys()`；同时保留对 list / 其它形状的兜底。
    """
    raw = json.load(open(path, encoding='utf-8'))
    out = set()
    if isinstance(raw, dict):
        # 主路径：键即拼写（本项目 cefr_catalog 的形状）
        out.update(k.lower() for k in raw if isinstance(k, str))
        for k, v in raw.items():                   # 兜底：值里也可能藏拼写
            if isinstance(v, str) and v.strip():
                out.add(v.lower())
            elif isinstance(v, dict):
                for key in ('spelling', 'word', 'form', 'original'):
                    if isinstance(v.get(key), str):
                        out.add(v[key].lower())
    elif isinstance(raw, list):
        for x in raw:
            if isinstance(x, str):
                out.add(x.lower())
            elif isinstance(x, dict):
                for k in ('spelling', 'word', 'form', 'original'):
                    if isinstance(x.get(k), str):
                        out.add(x[k].lower())
    return out


def build_plan(con, cefr):
    words = {r[0].lower(): r[0] for r in con.execute('SELECT spelling FROM word')}
    have = {r[0].lower() for r in con.execute('SELECT form FROM word_form')}
    plan, miss_base, own_entry, already, no_corpus = [], [], [], 0, []
    seen = set()                                    # (form, base) 去重
    for base, cats in IRREGULAR.items():
        if base not in words:
            miss_base.append(base)
            continue
        for cat, val in cats.items():
            for form in ([val] if isinstance(val, str) else val):
                f = form.lower()
                if f == base:
                    continue                       # 判据 4
                if f in words:
                    own_entry.append((f, base))    # 判据 2：自己就是词条 → 死数据
                    continue
                if f in have:
                    already += 1
                    continue                       # 判据 3
                # 🔴 `word_form` 的主键是 **`(form, base)`**，不是 `form` ——
                #    同一个 form 会在多个类别里出现（`dreamt` 既是 past 又是 past_participle）
                #    → 不去重就会 `IntegrityError: UNIQUE constraint failed`。
                #    （同 `fill_word_form_gap.py` 记载的坑，本轮又踩了一次。）
                if (f, base) in seen:
                    continue
                seen.add((f, base))
                if f not in cefr:
                    no_corpus.append((f, base))    # 仅记录，**不过滤**
                plan.append((f, base, cat))
    return plan, miss_base, own_entry, already, no_corpus, words


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', default=WORD_DB)
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    for p in (args.db, CEFR):
        if not os.path.exists(p):
            sys.exit(f'🔴 找不到 {p}')

    cefr = load_cefr(CEFR)
    con = sqlite3.connect(args.db)
    con.execute('PRAGMA foreign_keys=ON')
    plan, miss_base, own_entry, already, no_corpus, words = build_plan(con, cefr)

    print(f'不规则表: {len(IRREGULAR)} 词 · 语料参考 cefr_catalog: {len(cefr):,} 拼写（仅参考，不过滤）')
    print(f'  ⏭️ base 不在 word 表（跳过）: {len(miss_base)} → {sorted(miss_base)}')
    print(f'  ⏭️ form 自己就是词条（跳过，死数据）: {len(own_entry)} → {sorted(x[0] for x in own_entry)}')
    print(f'  ✅ 已在表中（无需补）: {already}')
    print(f'  ➕ 待补: {len(plan)} 条'
          f'（其中 {len(no_corpus)} 条不在 CEFR-J 词表里，如英式变体 —— 仍补，因内容源含 BBC）')

    if not plan:
        print('\n（无待补项 → 幂等通过）')
        con.close()
        return 0

    # 幂等复核：待补里不应有已存在的 form
    dup = [p for p in plan if con.execute(
        'SELECT 1 FROM word_form WHERE form=? LIMIT 1', (p[0],)).fetchone()]
    if dup:
        con.close()
        sys.exit(f'🔴 幂等断言失败：待补里有已存在的 form {dup[:5]}')

    print(f'\n{"form":22s} {"base":14s} category')
    for f, b, cat in sorted(plan)[:70]:
        print(f'  {f:20s} {b:12s} {cat}')
    if len(plan) > 70:
        print(f'  … 其余 {len(plan) - 70} 条')

    if args.dry_run:
        con.close()
        print('\n（dry-run：没有写。去掉 --dry-run 才写入）')
        return 0

    # ── 备份（写库规范第 2 条）──
    import shutil
    import time as _t
    bak_dir = os.path.join(ROOT, 'data', 'backups')
    os.makedirs(bak_dir, exist_ok=True)
    bak = os.path.join(bak_dir, f'word.db.bak-wordform-{_t.strftime("%Y%m%d-%H%M%S")}')
    shutil.copy2(args.db, bak)
    assert os.path.exists(bak) and os.path.getsize(bak) > 0
    print(f'\n✅ 备份: {bak}')

    before = con.execute('SELECT COUNT(*) FROM word_form').fetchone()[0]
    n = 0
    with con:                                       # 事务
        for f, b, cat in sorted(plan):
            wid = con.execute('SELECT id FROM word WHERE lower(spelling)=?', (b,)).fetchone()
            if not wid:
                raise RuntimeError(f'🔴 `{b}` 在 word 表查不到 id')
            kind = 'inflection' if cat in INFLECTION else 'derivation'
            con.execute(
                'INSERT INTO word_form (form,base,rule,kind,anchor,anchor_id,depth,in_vocab,action) '
                'VALUES (?,?,?,?,?,?,?,?,?)',
                (f, b, cat, kind, b, wid[0], 1, 0, 'keep'))
            n += 1
        # 读回断言放在事务内 —— 失败整体回滚
        bad = [f for f, _b, _c in plan
               if not con.execute('SELECT 1 FROM word_form WHERE form=?', (f,)).fetchone()]
        if bad:
            raise RuntimeError(f'读回失败: {bad[:8]}')
        # 🔑 断言「每个 base 都有 anchor_id」（还原后必须能定位到词条）
        orphan = con.execute(
            'SELECT COUNT(*) FROM word_form WHERE anchor_id IS NULL').fetchone()[0]
        if orphan:
            raise RuntimeError(f'有 {orphan} 行 anchor_id 为空')
    tot = con.execute('SELECT COUNT(*) FROM word_form').fetchone()[0]
    con.close()
    print(f'✅ 补入 {n} 条 · word_form {before:,} → {tot:,} 行 · 读回断言全过')
    return 0


if __name__ == '__main__':
    sys.exit(main())

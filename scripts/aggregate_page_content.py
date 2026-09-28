"""`aggregate_page.content` 的**唯一产出点**。

# 为什么要有这个模块

同一个结构（聚合页 content）原本由**两个脚本各自拼装**：

| 脚本 | 用途 | 原格式 |
|---|---|---|
| `load_llm_results.py` | 全库批量重建 | `{'front':…, 'sections':[{'type':'cognate_list','source':…,'items':[…]}]}` |
| `incremental_clustering.py` | 新词按需入库 | `{'members':[…]}` 🔴 **与上面完全不同** |

🔴 **后者写出的页，端侧读不出来** —— 端侧（`word_query_service.aggregatePageOf`）读的是
`d['sections'][0]['source']` 与 `items[].gloss`：

```dart
final sections = d['sections'];            // ← 'members' 版本没有这个键 → 走不进分支
source = AggregateSource.fromMap(s0['source']);
for (final it in items) { glosses[wid] = it['gloss']; }
```

→ `members` 版本的新页在端侧表现为 **`source = null`**（页头的大字/语种/含义全空）
**+ 所有成员无释义**，而且**不报错**（端侧那层 `try/catch` 是**故意静默**的：
注释写「一条坏数据不该让整个界面渲染不出来」）→ **典型静默失效**。

# 🔑 修法：消灭分叉，而不是挪分叉

⚠️ **不是**「把 `incremental_clustering` 的格式改成 `load_llm_results` 的样子」——
那只是把分叉重写一次，**下次改一边还会再分**。
正解是让**双方都调这里**：**结构只有一处定义**（与「同一件事的口径只能有一处权威」同一条判据）。

> 本条已是项目判据：**「组件自测通过」≠「与下游能对接」**。
> `incremental_clustering` 当时**34 项验收全过**，但**没有一项验「下游能不能读出来」**。

# 排序口径（曾经也是分叉）

| 来源 | 原排序 |
|---|---|
| `load_llm_results` | 拼写**字母序**（`items.sort(key=word)`） |
| `incremental_clustering` | 库内 `sort_seq` |

→ **即使格式修好，成员顺序也不一致 → 两条路产出不同的库**。
本模块统一为**字母序** —— 因为那是**现网 1,777 个聚合页的实际顺序**（既有事实，不能改）。

# 两种 `source` 形状（不同 page_type）

```python
# root 型（词根族）
{'form': 'act', 'type': 'root', 'origin': 'Latin', 'meaning': '做，行动'}
# etymon 型（词源族）—— 有 aliases、无 type/origin
{'form': 'facere', 'aliases': [], 'language': 'Latin', 'meaning': '做，制造'}
```
用 `root_source()` / `etymon_source()` 构造，别手写 dict。

# 自给自足（不依赖已退役的 coevo.db）

`items[].gloss` = **该词自身的中文释义**（实测：与 `card.content` 的 `definition.zh` 逐字符一致）。
原先 `load_llm_results` 从 `coevo.db` 的 `definitions[].chinese` 取，
但**该库已于 2026-09-29 退役** → 改用 `zh_from_card_content()` **从词自己的卡里读**。
"""

import json

#: `items[].gloss` 的截断长度 —— 与 `load_llm_results` 原口径一致（`[:30]`）。
#: ⚠️ 改它会改变现网 1,777 个页的 content 字节 → **不要动**（除非全库重建）。
GLOSS_MAX = 30

#: 两个 page_type 共用的 section 类型（实测现网 `root`/`etymon` 都只有这一种）。
SECTION_TYPE = 'cognate_list'


# ─────────────────────────────────────────────────────────────
# source 构造（两种形状）
# ─────────────────────────────────────────────────────────────
def root_source(form, origin, meaning):
    """root 型（词根族）的 `section.source`。键顺序与现网一致。"""
    return {
        'form': form or '',
        'type': 'root',
        'origin': origin or '',
        'meaning': meaning or '',
    }


def etymon_source(form, aliases, language, meaning):
    """etymon 型（词源族）的 `section.source`。

    `aliases` 来自 `etymon.note`（用 `/` 分隔的别名），由调用方切好再传入 ——
    因为「切几个、怎么切」是**取数逻辑**，不是**结构**。
    """
    return {
        'form': form or '',
        'aliases': list(aliases or []),
        'language': language or '',
        'meaning': meaning or '',
    }


# ─────────────────────────────────────────────────────────────
# 标题与别名（🔑 也是分叉点之一：原先两处各拼一份 label）
# ─────────────────────────────────────────────────────────────
def root_label(form, origin):
    """root 型（词根族）的页标题。

    口径与 `load_llm_results` / `incremental_clustering` 原文一致：
    有 origin 就带括号，否则不带。
    """
    return f'{form} 词根族' + (f'（{origin}）' if origin else '')


def etymon_aliases(note, limit=2):
    """从 `etymon.note` 切出别名列表（`/` 分隔，最多 `limit` 个）。

    🔑 为什么需要别名：归一化后的 canonical 往往是**不好认的古拼法**
       （`weorc` 才是古英语正确源词，但用户不认识）→ 标题里要带上 `work`。
    """
    return [x.strip() for x in (note or '').split('/') if x.strip()][:limit]


def etymon_label(form, aliases, language, meaning):
    """etymon 型（词源族）的页标题 —— 复刻 `load_llm_results` 的「带别名」口径。

    形如：`facere（Latin·做，制造）词源族` · `weorc / work（Old English·工作）词源族`
    """
    disp = ' / '.join([form] + list(aliases or []))
    return f'{disp}（{language}{"·" + meaning if meaning else ""}）词源族'


# ─────────────────────────────────────────────────────────────
# 结构产出
# ─────────────────────────────────────────────────────────────
def sort_items(items):
    """统一排序：拼写**字母序**。

    🔑 这是 `load_llm_results` 的既有口径，也就是**现网 1,777 个聚合页的实际顺序**。
       增量路径必须跟它，否则两条路产出的库不一致（原分叉点之一）。
    """
    return sorted(items, key=lambda x: x.get('word') or '')


def make_item(word, word_id, gloss):
    """一个成员项。键顺序 `word → word_id → gloss` 与现网一致（json 保序）。"""
    return {
        'word': word,
        'word_id': word_id,
        'gloss': (gloss or '')[:GLOSS_MAX],
    }


def content_object(label, source, items):
    """返回 **dict**（便于断言：不受 json 键顺序影响）。

    要写库请用 `dump_content()` —— 它保证 `ensure_ascii=False` 口径统一。
    """
    return {
        'front': label,
        'sections': [{
            'type': SECTION_TYPE,
            'source': source,
            'items': sort_items(items),
        }],
    }


def dump_content(label, source, items):
    """返回**要写进 `aggregate_page.content` 的字符串**（唯一序列化口径）。"""
    return json.dumps(content_object(label, source, items), ensure_ascii=False)


# ─────────────────────────────────────────────────────────────
# 从「词自己的卡」读中文释义 —— 自给自足，不依赖外部源
# ─────────────────────────────────────────────────────────────
def zh_from_card_content(content_json):
    """从 `card.content` 读该词的中文释义（首个 `definition` 段的 `zh`）。

    🔑 **为什么自给自足**：原先 `load_llm_results` 的 `word_zh()` 依赖
       `coevo.db` 的 `definitions[].chinese`；该库**已于 2026-09-29 退役**
       （`prebuilt_language_cards` 表被清）。而**词自己的卡里就带着释义** →
       从卡里读，**不再依赖任何外部源**（回流场景下新词也只有自己的卡）。

    ⚠️ 坏 JSON / 缺段一律返回 `''`（**不抛**）—— 与端侧同一取向：
       「一条坏数据不该让整个聚合页建不出来」。
    """
    if not content_json:
        return ''
    try:
        d = json.loads(content_json)
    except (ValueError, TypeError):
        return ''
    if not isinstance(d, dict):
        return ''
    for s in (d.get('sections') or []):
        if isinstance(s, dict) and s.get('type') == 'definition':
            zh = s.get('zh')
            if isinstance(zh, str) and zh.strip():
                return zh.strip()[:GLOSS_MAX]
    return ''


# ─────────────────────────────────────────────────────────────
# 端侧「能不能读出来」—— 供验收脚本直接断言（本模块不含端侧代码的副本）
# ─────────────────────────────────────────────────────────────
def read_back(content_json):
    """按**端侧的逻辑**把 content 读回来。

    端侧 `word_query_service.aggregatePageOf` 的读法是：
      `front` → 页面标题 · `sections[0].source` → 页头大字 · `items[].gloss` → 成员行释义

    本函数复刻这三个取值点，**供验收断言「下游能读到」**。
    返回 `(front, source, glosses)`；读不出时对应位置为 `''` / `None` / `{}`。

    🔑 为什么放在产出模块里：**它就是这条契约的另一半** ——
       产出格式与读取方式是同一件事的两面，分开放必然漂移。
    """
    if not content_json:
        return '', None, {}
    try:
        d = json.loads(content_json)
    except (ValueError, TypeError):
        return '', None, {}
    if not isinstance(d, dict):
        return '', None, {}

    front = d.get('front') or ''
    source, glosses = None, {}
    sections = d.get('sections')
    if isinstance(sections, list) and sections:
        s0 = sections[0]
        if isinstance(s0, dict):
            if isinstance(s0.get('source'), dict):
                source = s0['source']
            items = s0.get('items')
            if isinstance(items, list):
                for it in items:
                    if not isinstance(it, dict):
                        continue
                    wid, g = it.get('word_id'), it.get('gloss')
                    if isinstance(wid, str) and isinstance(g, str) and g:
                        glosses[wid] = g
    return front, source, glosses

"""将误分到 language 域的 nursery_rhyme/narrative/poem 卡片迁移到 literature 域，
保留 full_text/translation/author/genre 等文学卡片字段。"""
import json, os, copy

V4 = r"E:\CoEvo\data\curriculum\v4"
V3 = r"E:\CoEvo\data\curriculum\v3"

LIT_TYPES = {'nursery_rhyme', 'narrative', 'poem'}

# 1. 加载 V4 Language 数据
def load_json(path):
    with open(path, 'r', encoding='utf-8') as f:
        return json.load(f)

def save_json(path, data):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

# 加载 V4 数据
pc_lang = load_json(os.path.join(V4, 'cards', 'language', 'prebuilt_cards.json'))
sub_lang = load_json(os.path.join(V4, 'cards', 'language', 'prebuilt_language_cards.json'))

# 加载 V4 Literature 数据
pc_lit = load_json(os.path.join(V4, 'cards', 'literature', 'prebuilt_cards.json'))
sub_lit = load_json(os.path.join(V4, 'cards', 'literature', 'prebuilt_literature_cards.json'))

# 加载 V3 数据
v3_data = load_json(os.path.join(V3, 'cards', 'english.json'))
v3_cards = v3_data['cards']
v3_map = {c['id']: c for c in v3_cards if isinstance(c, dict) and 'id' in c}

# 2. 找出需要迁移的卡片
to_move_pc = [c for c in pc_lang if c.get('card_type') in LIT_TYPES]
to_move_ids = {c['id'] for c in to_move_pc}
print(f"需要迁移的卡片: {len(to_move_pc)}")

moved = 0
for c in to_move_pc:
    cid = c['id']
    if cid not in v3_map:
        print(f"  跳过 {cid[:20]}... (V3 未找到)")
        continue
    
    v3_card = v3_map[cid]
    v3_back = v3_card.get('back', '{}')
    
    # 解析 V3 back JSON
    try:
        back_data = json.loads(v3_back) if isinstance(v3_back, str) else v3_back
    except json.JSONDecodeError:
        back_data = {}
    
    # 构建 literature 子表条目
    lit_entry = {
        "id": cid,
        "full_text": back_data.get("full_text", ""),
        "translation": back_data.get("translation", ""),
        "author": back_data.get("author", c.get("author", "")),
        "genre": c.get("card_type", "poem"),
    }
    
    # 更新 prebuilt_cards 条目：domain -> literature
    pc_entry = copy.deepcopy(c)
    pc_entry["domain"] = "literature"
    
    pc_lit.append(pc_entry)
    sub_lit.append(lit_entry)
    moved += 1

# 3. 从 language 域删除已迁移的卡片
pc_lang = [c for c in pc_lang if c['id'] not in to_move_ids]
sub_lang = [c for c in sub_lang if c['id'] not in to_move_ids]

# 4. 保存
save_json(os.path.join(V4, 'cards', 'language', 'prebuilt_cards.json'), pc_lang)
save_json(os.path.join(V4, 'cards', 'language', 'prebuilt_language_cards.json'), sub_lang)
save_json(os.path.join(V4, 'cards', 'literature', 'prebuilt_cards.json'), pc_lit)
save_json(os.path.join(V4, 'cards', 'literature', 'prebuilt_literature_cards.json'), sub_lit)

print(f"迁移完成: {moved} 张卡片从 language -> literature")
print(f"Language 域: {len(pc_lang)} 张主卡, {len(sub_lang)} 张子卡")
print(f"Literature 域: {len(pc_lit)} 张主卡, {len(sub_lit)} 张子卡")

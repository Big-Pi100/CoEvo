"""
Reconstruct the exact messages array sent to the LLM for each turn
of trial_033ee893's conversation, matching ws.rs logic exactly.
"""
import sqlite3
import re

DB_PATH = r"E:\CoEvo\backend\data\coevo.db"
PROMPT_DIR = r"E:\CoEvo\backend\prompts"
CONV_ID = "conv_1782310928747"

def resolve_includes(text, base_dir):
    """Resolve {include:...} references, same as Rust resolve_includes()"""
    result = text
    for _ in range(10):
        before = result
        def replacer(m):
            path = m.group(1)
            full_path = f"{base_dir}/{path}"
            try:
                with open(full_path, "r", encoding="utf-8") as f:
                    return f.read()
            except:
                return f"<!-- include {path} not found -->"
        result = re.sub(r"\{include:([^}]+)\}", replacer, result)
        if result == before:
            break
    return result

def load_system_prompt():
    """Load the free mode system prompt exactly like prompt_loader.rs"""
    base_dir = PROMPT_DIR
    
    # Main: chat/general/free.md
    with open(f"{PROMPT_DIR}/chat/general/free.md", "r", encoding="utf-8") as f:
        main = f.read()
    
    # Signal: chat/general/signal/free.md
    signal_path = f"{PROMPT_DIR}/chat/general/signal/free.md"
    signal = ""
    try:
        with open(signal_path, "r", encoding="utf-8") as f:
            s = f.read().strip()
            if s:
                signal = resolve_includes(s, base_dir)
    except:
        pass
    
    # Format: chat/general/format/free.md -> includes latex.md + graph.md + plan-marker.md
    format_path = f"{PROMPT_DIR}/chat/general/format/free.md"
    fmt = ""
    try:
        with open(format_path, "r", encoding="utf-8") as f:
            raw = f.read().strip()
            if raw:
                fmt = resolve_includes(raw, base_dir)
    except:
        pass
    
    # Combine: main + signal + format (same order as read_signal_or_flat)
    parts = []
    if main: parts.append(main)
    if signal: parts.append(signal)
    if fmt: parts.append(fmt)
    return "\n\n".join(parts)

def reconstruct():
    system_prompt = load_system_prompt()
    print(f"=== System Prompt ===")
    print(f"Length: {len(system_prompt)} chars")
    print(f"Content preview: {system_prompt[:150]}...")
    print(f"Content last 100: ...{system_prompt[-100:]}")
    print()
    
    # Get all turns
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(
        "SELECT role, content FROM conversation_turns WHERE conversation_id = ? ORDER BY created_at ASC",
        (CONV_ID,)
    )
    all_turns = cursor.fetchall()
    conn.close()
    
    print(f"=== All Turns ({len(all_turns)} total) ===")
    for i, (role, content) in enumerate(all_turns):
        print(f"  Turn {i}: role={role}, chars={len(content)}, preview={content[:80]}...")
    print()
    
    # Reconstruct messages for EACH turn (what was sent to LLM at that point)
    MAX_TURNS = 10
    MAX_CHARS = 5000  # OLD value (code changes not compiled!)
    
    for turn_idx in range(len(all_turns)):
        # Simulate what history would look like at this turn
        # All turns up to and including current are in DB
        # When the LLM processes this turn, the current user message is in DB already
        turns_up_to = all_turns[:turn_idx + 1]
        
        print(f"{'='*60}")
        print(f"=== Turn {turn_idx}: LLM Messages Context ===")
        print(f"{'='*60}")
        
        # Build history_turns the same way as ws.rs
        if len(turns_up_to) > 1:
            context = turns_up_to[:-1]  # exclude current message
            char_total = 0
            turn_count = 0
            for role, content in reversed(context):
                if turn_count >= MAX_TURNS:
                    break
                next_total = char_total + len(content)
                if next_total > MAX_CHARS:
                    break
                char_total = next_total
                turn_count += 1
            
            recent = list(reversed(context))[:turn_count]
            history_turns = list(reversed(recent))
        else:
            history_turns = []
        
        current_message = turns_up_to[-1][1] if turns_up_to else ""
        
        # Calculate message sizes
        msg_sizes = []
        msg_sizes.append(("system", len(system_prompt), system_prompt[:80]))
        for role, content in history_turns:
            msg_sizes.append((role, len(content), content[:80]))
        msg_sizes.append(("user (current)", len(current_message), current_message[:80]))
        
        print(f"  history_turns count: {len(history_turns)}")
        print(f"  current_message: {repr(current_message[:80])}")
        print(f"  System prompt: {len(system_prompt)} chars")
        print()
        
        print(f"  Messages structure:")
        for role, size, preview in msg_sizes:
            print(f"    [{role}] {size} chars: {repr(preview)}")
        
        if history_turns:
            print()
            print(f"  === Full content of history_turns ===")
            for i, (role, content) in enumerate(history_turns):
                print(f"  --- history[{i}] role={role} ({len(content)} chars) ---")
                print(f"  {content[:200]}")
                if len(content) > 200:
                    print(f"  ...({len(content) - 200} more chars)...")
                    print(f"  {content[-150:]}")
            print()
        
        print(f"  === Current user message ===")
        print(f"  {current_message[:200]}")
        print()
        print()

reconstruct()

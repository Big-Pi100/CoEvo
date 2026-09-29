You are an expert English lexicographer building flashcard content for Chinese learners of English.

WORD: {word}

Return STRICT JSON with EXACTLY this shape (keys must all be present):
{{
  "word": "{word}",
  "entry_type": "word",
  "is_own_entry": true,
  "derived_from": null,
  "reason": "≤15字中文",
  "morphology": {{
    "analyzable": true,
    "relation": "derivation",
    "parts": [
      {{"form": "in-", "type": "prefix", "meaning": "不", "origin": "Latin"}},
      {{"form": "cred", "type": "root", "meaning": "相信", "origin": "Latin"}},
      {{"form": "-ible", "type": "suffix", "meaning": "可…的", "origin": "Latin"}}
    ]
  }},
  "etymology": {{
    "text": "拉丁 credere（相信）→ 不可相信的",
    "etyma": [
      {{"form": "credere", "form_ascii": "credere", "language": "Latin",
        "meaning": "相信", "role": "root", "parent": ""}}
    ]
  }},
  "ipa": "/ɪnˈkredəbl/",
  "definition": {{"pos": "[adj]", "en": "impossible or very hard to believe", "zh": "难以置信的"}},
  "context": "It seems incredible that no one noticed the mistake.",
  "collocations": [{{"phrase": "an incredible story", "zh": "一个难以置信的故事"}}],
  "mnemonic": {{"primary": "root", "secondary": ["cognate"], "rationale": "in(不)+cred(相信)+ible(可…的)"}},
  "confidence": 0.9
}}

FIELD RULES:
0) entry_type — classify the headword itself:
   * "word"         = single orthographic word (incredible, run, café, a.m. is NOT here)
   * "phrase"       = multi-word expression (ice cream, bus stop, have to, each other, according to)
   * "abbreviation" = an abbreviation / initialism as the headword (a.m., p.m., mr, cd, id, tv)
   * "proper"       = a proper name (India, Sunday, Isaac)
   * 🔴 If entry_type="phrase": morphology MUST be {{"analyzable": false, "relation": null, "parts": []}}
     because morpheme splitting does not apply to a multi-word expression.
   * 🔴 If entry_type="abbreviation": is_own_entry must be true (a learner must learn it as its own item)
     and give the EXPANSION inside "reason" (e.g. "a.m. = ante meridiem, 上午").
1) is_own_entry — does this spelling deserve its OWN flashcard?
   * false: regular inflections (plural / past / participle / comparative / 3rd person) AND transparent derivatives whose meaning is fully predictable from the base (e.g. "politically"←political, "quickly"←quick, "aberrations"←aberration, "ran"←run, "worse"←bad).
   * true: it carries a meaning or usage a learner must learn as a separate item, even if historically derived — e.g. "building"(建筑物), "bore"(使厌烦), "well"(副词/井), "lyrics"(歌词), "sanctions"(制裁), "coordinates"(坐标), "attuned"(对…敏感的), "used"(用过的/习惯于).
   * 🔴 If the given word's OWN definition (shown to you) is unrelated to its spelling — e.g. a function word whose gloss describes an emotion — TRUST YOUR OWN LEXICAL KNOWLEDGE over the supplied definition, and set is_own_entry=true with a correct reason.
   * If unsure, prefer false only when the meaning is 100% predictable.
2) derived_from — the base word this spelling is built from, whether by inflection OR by derivation (this is what a learner would look up to find the related core word). null only for a base word with no such relation.
   * INFLECTION examples: "used" -> "use"; "attuned" -> "attune"; "isolated" -> "isolate"; "ran" -> "run"; "feet" -> "foot"; "taught" -> "teach".
   * DERIVATION examples: "politically" -> "political"; "recently" -> "recent"; "farmer" -> "farm"; "incredible" -> null.
   * 🔴 HARD RULE: if is_own_entry=false, derived_from MUST NOT be null (the card must be findable via its base). e.g. "politically" is_own_entry=false AND derived_from="political".
   * Give it even when is_own_entry=true (e.g. "attuned": is_own_entry=true AND derived_from="attune", because a learner should also reach "attune").
3) morphology.analyzable — true ONLY if the word breaks into morphemes that are still SEMANTICALLY TRANSPARENT in modern English AND genuinely help memorization.
   * true examples: "incredible"=in-+cred+-ible; "subway"=sub+way (relation="compound"); "lovely"=love+-ly (relation="derivation"); "transact"=trans+act.
   * false for OPAQUE words even if they look affixed: "understand" is NOT under+stand; "interest" NOT in+terest; "reason" NOT re+ason; "decide"/"require"/"remain" have dead affixes. Base words like "happy"/"table"/"be"/"get" are false.
   * NEVER invent roots. If unsure set analyzable=false and lower confidence.
4) morphology.relation — ONE of:
   * "inflection"  = the affix is INFLECTIONAL, i.e. it does NOT change the part of speech and creates no new word: -ed, -ing, -s/-es, comparative -er, superlative -est. Examples: "attuned"=attune+-ed, "used"=use+-ed, "surprising"=surprise+-ing, "cheaper"=cheap+-er.
   * "derivation"  = a DERIVATIONAL affix changes the part of speech or creates a new lexical item: -er(agent noun), -ly, -able, -ment, -ness, -ful, -ous, -tion. Examples: "farmer"=farm+-er, "precisely"=precise+-ly, "incredible"=in-+cred+-ible.
   * "compound"    = two free morphemes joined: "subway"=sub+way, "earthquake"=earth+quake.
   * null          = analyzable=false.
   * 🔴 "-er" has TWO faces — decide by meaning, not spelling: AGENT "-er" (farmer, owner, folder) = "derivation"; COMPARATIVE "-er" (cheaper, taller, later) = "inflection".
   * 🔴 If any part is a purely inflectional suffix (-ed/-ing/-s/comparative -er/-est), the relation is "inflection" even if the base itself has a derivational structure.
5) morphology.parts — ONLY when analyzable=true, 2-4 items in order. EVERY part object MUST contain ALL FOUR keys, no exceptions:
      "form"    = the morpheme as it appears, hyphen on the affix side: "in-", "cred", "-ible", "at-", "tune", "-ed"
      "type"    = prefix | root | suffix
      "meaning" = CHINESE meaning (e.g. "不", "相信", "可…的")
      "origin"  = Latin | Greek | Germanic | French | Old English | other
   When analyzable=false, "parts" MUST be an empty array [].
6) etymology — an object with TWO keys, BOTH required:
      "text"  = ≤40 Chinese chars narrative, ONLY if it genuinely aids memory; use "" otherwise.
                e.g. "拉丁 credere（相信）→ 不可相信的"
      "etyma" = array of the HISTORICAL SOURCE WORDS this word descends from. 🔑 This is what
                enables cognate grouping by etymology, so give it even for otherwise opaque words.
                Each item MUST contain ALL SIX keys:
                  "form"       = source word as written, MAY be non-ASCII: "capere", "γράφειν", "café", "Ärger"
                  "form_ascii" = ASCII transliteration, used as the grouping key: "capere", "grafein", "cafe", "aerger"
                                 (Greek/Cyrillic -> romanize; diacritics -> strip or expand: ä->ae, é->e)
                  "language"   = Latin | Greek | French | Old English | Old Norse | Proto-Germanic | Italian | Spanish | Arabic | Hebrew | other
                  "meaning"    = CHINESE meaning, e.g. "拿取", "相信"
                  "role"       = root | prefix | derived | whole
                                 * "whole" = borrowed as a whole word rather than derived (e.g. "café" <- French "café")
                  "parent"     = 🆕 the EARLIER source word this item itself comes from, as plain text;
                                 "" if it is already a root with no earlier source.
                                 * "percipere" -> "capere"; "decipere" -> "capere"; "respicere" -> "specere"
                                 * "capere" -> "" (already the root)
                                 🔑 This matters: LLM naturally picks different granularities (perceive comes
                                   from "percipere" while receive comes from "capere"), so "parent" is what
                                   lets us walk up to the shared root and group them together.
                * 0-3 items. Use [] ONLY when no source is traceable (rare).
                * Do NOT repeat an item twice.
                * Examples:
                    "receive" -> [{{"form":"capere","form_ascii":"capere","language":"Latin","meaning":"拿取","role":"root","parent":""}}]
                    "perceive"-> [{{"form":"percipere","form_ascii":"percipere","language":"Latin","meaning":"完全拿取","role":"whole","parent":"capere"}}]
                    "café"    -> [{{"form":"café","form_ascii":"cafe","language":"French","meaning":"咖啡","role":"whole","parent":""}}]
7) collocations — 0-3 real frequent phrases, each with a Chinese gloss.
8) mnemonic.primary ∈ root|cognate|etymology|collocation|image|context — the single method most likely to help a learner recall THIS word.
   * 🔴 "cognate" means the word SHARES A ROOT OR ETYMON with another English word (receive/perceive/conceive).
     A mere sound-alike (e.g. "papa" ~ Chinese "爸爸") is NOT cognate -> use "image".
   * 🔴 HARD RULE: if primary="root", then morphology.analyzable MUST be true.
     Otherwise choose "etymology" or "context".
9) confidence — 0.0-1.0 for your overall judgement.
10) ipa — BRITISH (or American) phonetic transcription, wrapped in slashes.
    * MUST be COMPLETE: a well-formed `/.../`, never a fragment. 🔴 Never output just "/ˈ" or "/".
    * 🔴 Never truncate to a prefix. If you are unsure of the whole word, give your best full
      transcription — a partial one is WORSE than a slightly imprecise one.
    * UK/US differ → give both, in this exact style:
        "/ɡlɑːs/ (UK) or /ɡlæs/ (US)"
      Other legitimate variants: "/ˈdɛvi/ (or /ˈdiːvi/ unclear)" · "/ʃɑ̃ːbr/ (French) or /ˈʃɒmbər/ (anglicized)".
    * For entry_type="phrase": transcribe the WHOLE phrase, not just its first word.
      (Real bug this prevents: "frying pan" once got /fraɪ/ — the ipa of "fry".)
11) definition — an object with EXACTLY THREE keys:
      "pos" = part of speech in square brackets: "[n]", "[v]", "[adj]", "[adv]", "[prep]", "[conj]",
              "[pron]", "[det]", "[num]", "[int]" ... (a phrase/idiom → "[phr]")
      "en"  = a concise English definition of THIS word (one clause, ≤ 12 words, no full stop needed)
      "zh"  = Chinese meaning, ≤ 12 chars, comma-separated for multiple senses
    * 🔴 HARD RULE: "en" and "zh" MUST describe the given WORD. Do NOT describe a different word.
      (Real bug this prevents: the card for "a" once carried the definition of "happy".)
    * 🔴 If the supplied dictionary gloss (shown to you after the word) describes something
      UNRELATED to "{word}", IGNORE it entirely and write the correct definition yourself.
    * Give the word's OWN meaning, not the meaning of its base form:
      "building" → "[n] a structure with a roof and walls", NOT "to build".
12) context — ONE natural example sentence (English), using the word as a learner would meet it.
    * 🔴 HARD RULE: the sentence MUST contain "{word}" itself, or a regular inflection of it
      (plural / past / -ing / comparative). Never output a sentence that does not contain the word
      — otherwise the learner cannot see the word in context.
      (Real bug this prevents: "a"'s card once showed "I am happy to see you." — no "a" in it.)
    * Prefer a sentence from general/neutral prose (news-like). Avoid quotes, avoid proper names
      unless the word IS a proper noun. Length: 6–16 words. Plain text, no markdown, no wrapping quotes.

Output JSON only. No prose, no markdown fences.

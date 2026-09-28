# 卡片字段修正候选 —— LLM（契约 v6）复核结果

> 生成：2026-09-29 02:28:23 ｜ 模型 `deepseek-flash` ｜ **只生成，未写库**
> 输入：`card_field_candidates.json`（196 条可疑项，由 5 个信号筛出）
> 成本 **¥1.2807**（in 640,049 / out 71,250 token）· 耗时 0s · 并发 12

## 一、结论：三档 + 建议写入

| 档位 | 条数 | 含义 |
|---|---:|---|
| **🔴 确定要修** | **35** | 有**硬证据**（见 §二）：现状确实错 |
| 🟠 疑似 | 157 | 封闭字段与 v6 不同，**有一方错**，需人眼 |
| ✅ 无问题 | 4 | 现状没查出问题（信号**误报**） |
| — 失败 | 0 | 调用失败，未判定 |

### 🔑 建议写入 `word.db`：**68** 条卡（按字段）

| 字段 | 条数 | 允许覆盖的**前提**（每个字段须有自己的硬证据） |
|---|---:|---|
| `ipa` | 60 | 残缺 / 未覆盖全词组 / 疑截断（S2）/ 与 v6 不同（封闭字段） |
| `context` | 18 | 例句**不含该词**（词形还原后） |
| `definition` | 1 | **仅**：现状为空，或已证实**整卡污染**（见 §五） |

> 🔴 **不整条覆盖** —— `definition` 是开放式字段，「与 v6 不同」绝大多数只是
> 措辞 / 大小写 / 句末句号差异（实测 `bulletin` 现状比 v6 更详细）→
> 按「不同」覆盖会造成大面积无谓改动（见 §五）。

## 二、硬证据分布（「确定要修」的原因）

| 硬证据 | 条数 |
|---|---:|
| 例句不含该词 | 18 |
| ipa 未覆盖全词组 | 10 |
| ipa 疑截断 | 9 |
| ipa 残缺 | 7 |

> 🔑 `ipa 残缺` = 连一个完整的 `/.../` 都没有（`/ˈ`）·
>    `ipa 未覆盖全词组` = 多词词组只给了第一个词的音标（`frying pan` → `/fraɪ/`）·
>    `ipa 疑截断` = 格式合法但实质字符/拼写字母 < 0.45（`abortive` → `/viː/`）·
>    `例句不含该词` = 词形还原（见 §五）后仍找不到该词。

## 三、按信号看（判据的命中率）

| 信号组合 | 总数 | 确定要修 | 命中率 |
|---|---:|---:|---:|
| `S3b` | 79 | 1 | 1% |
| `S4` | 62 | 8 | 13% |
| `S3a` | 28 | 0 | 0% |
| `S2 + S4` | 7 | 7 | 100% |
| `S1` | 7 | 7 | 100% |
| `S2 + S3b` | 6 | 6 | 100% |
| `S2` | 4 | 4 | 100% |
| `S3b + S4` | 2 | 1 | 50% |
| `S2 + S3b + S4` | 1 | 1 | 100% |

### ⚠️ 但 S3a / S3b 的「0% / 1%」**不是「信号错了」** —— 是本表的硬证据判据**抓不到那一类**

| 信号 | 它要抓什么 | 本表能判吗 |
|---|---|---|
| `S1` `S2` | ipa **残缺 / 截断**（段数不够、格式不完整） | ✅ **能**（纯格式，机械可判） |
| `S4` | 例句**不含该词** | ✅ **能**（查词形还原即可） |
| `S3a` `S3b` | ipa 是**另一个词**的音标（段数够、格式也合法） | 🔴 **不能** |

🔑 为什么不能：`air conditioning` 的现状 ipa 是 `/ˈɛr fɔːrs/` —— **两段、格式合法**，
机械判据（段数 ≥ 词数）**完全通过**；要知道它是 `air force` 的音标，
必须**懂语义**。这正是 LLM 复核不可替代的地方。

## 四、🔴 建议写入 —— 逐条（现状 → v6）

| 词 | 写 | 信号 | 硬证据 | 现状 → v6 |
|---|---|---|---|---|
| `a` | context+definition+ipa | S3b·S4 | 例句不含该词 | **ipa**: `/ˈhæpi/` → `/ə/ (weak) or /eɪ/ (strong)`<br>**例句**: "I am happy to see you." → "She bought a new car yesterday."<br>**释义**: "feeling or showing pleasure or contentment." → "one, some, any" （整卡污染 ← `happy`） |
| `abortive` | ipa | S2 | ipa 疑截断 | **ipa**: `/viː/` → `/əˈbɔːtɪv/ (UK) or /əˈbɔːrtɪv/ (US)` |
| `air conditioning` | ipa | S3a |  | **ipa**: `/ˈɛr fɔːrs/` → `/ˈeə kənˌdɪʃənɪŋ/ (UK) or /ˈer kənˌdɪʃənɪŋ/ (US)` |
| `bank account` | context+ipa | S2·S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/bæn/` → `/ˈbæŋk əˌkaʊnt/`<br>**例句**: "The government banned smoking in public places." → "She opened a new bank account at the local branch." |
| `bulletin` | ipa | S2·S3b | ipa 疑截断 | **ipa**: `/bʊl/` → `/ˈbʊlətɪn/` |
| `bully` | ipa | S3b |  | **ipa**: `/bʊl/` → `/ˈbʊli/` |
| `bus station` | ipa | S3a |  | **ipa**: `/ˈbʌs ˌstɒp/` → `/ˈbʌs ˌsteɪʃn/` |
| `capital letter` | context+ipa | S2·S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/kæp/` → `/ˌkæpɪtl ˈletə/ (UK) or /ˌkæpɪtl ˈletər/ (US)`<br>**例句**: "He wore a baseball cap." → "Every sentence should begin with a capital letter." |
| `carbon dioxide` | ipa | S3a |  | **ipa**: `/ˈkɑːbən məˈnɒksaɪd/` → `/ˌkɑːbən daɪˈɒksaɪd/ (UK) or /ˌkɑːrbən daɪˈɑːksaɪd/ (US)` |
| `carbon footprint` | ipa | S3a |  | **ipa**: `/ˈkɑːbən məˈnɒksaɪd/` → `/ˈkɑːbən ˈfʊtprɪnt/` |
| `check-in counter` | ipa | S3a |  | **ipa**: `/ˌtʃekɪn ˈdɛsk/` → `/ˈtʃek ɪn ˌkaʊntə/ (UK) or /ˈtʃek ɪn ˌkaʊntər/ (US)` |
| `chewing gum` | context+ipa | S2·S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/tʃuː/` → `/ˈtʃuːɪŋ ɡʌm/`<br>**例句**: "She chewed her food slowly." → "She always carries a pack of chewing gum in her bag." |
| `civilization` | ipa | S4 |  | **ipa**: `/ˌsɪvɪlaɪˈzeɪʃən/` → `/ˌsɪvəlaɪˈzeɪʃn/` |
| `classical music` | ipa | S2 | ipa 未覆盖全词组 | **ipa**: `/klɑːs/` → `/ˈklæsɪkl ˈmjuːzɪk/` |
| `de facto` | ipa | S3a |  | **ipa**: `/diː ˈfæktoʊ/` → `/deɪ ˈfæktəʊ/ (UK) or /deɪ ˈfæktoʊ/ (US)` |
| `debit card` | ipa | S3a |  | **ipa**: `/diː ˈfæktoʊ/` → `/ˈdebɪt kɑːd/ (UK) or /ˈdebɪt kɑːrd/ (US)` |
| `diffusion` | ipa | S3b |  | **ipa**: `/daɪ/ (abbreviation of diameter)` → `/dɪˈfjuːʒn/` |
| `enver` | ipa | S2·S3b | ipa 疑截断 | **ipa**: `/ɛn/` → `/ˈɛnvər/` |
| `environmentally friendly` | context+ipa | S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/ɪnˌvaɪrənˈmentl/` → `/ɪnˌvaɪrənˈmentəli ˈfrendli/`<br>**例句**: "Environmental protection is a global issue." → "Many companies are now trying to use environmentally friendly packaging." |
| `eugene` | ipa | S2·S3b | ipa 疑截断 | **ipa**: `/ɛn/` → `/juːˈdʒiːn/` |
| `exemplify` | ipa | S4 |  | **ipa**: `/ɪɡˈzæmplɪfaɪ/` → `/ɪɡˈzemplɪfaɪ/` |
| `fact` | ipa | S1 | ipa 残缺 | **ipa**: `/fækt` → `/fækt/` |
| `fire brigade` | ipa | S3a |  | **ipa**: `/ˈfaɪə ˌsteɪʃən/` → `/ˈfaɪə brɪˌɡeɪd/ (UK) or /ˈfaɪər brɪˌɡeɪd/ (US)` |
| `first floor` | ipa | S3a |  | **ipa**: `/fɜːst ˈpɜːsən/` → `/ˌfɜːst ˈflɔː/ (UK) or /ˌfɜːrst ˈflɔːr/ (US)` |
| `first lady` | ipa | S3a |  | **ipa**: `/fɜːst ˈpɜːsən/` → `/ˌfɜːst ˈleɪdi/ (UK) or /ˌfɜːrst ˈleɪdi/ (US)` |
| `first language` | ipa | S3a |  | **ipa**: `/fɜːst ˈpɜːsən/` → `/ˌfɜːst ˈlæŋɡwɪdʒ/ (UK) or /ˌfɜːrst ˈlæŋɡwɪdʒ/ (US)` |
| `frying pan` | context+ipa | S2·S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/fraɪ/` → `/ˈfraɪɪŋ pæn/`<br>**例句**: "She fried the eggs in butter." → "She heated some oil in the frying pan before adding the eggs." |
| `funk` | context | S4 | 例句不含该词 | **例句**: "The band played a funky tune that made everyone dance." → "After the party, the room had a strange funk of stale beer and sweat." |
| `generalisation` | context | S4 | 例句不含该词 | **例句**: "This is a" → "The report was criticized for making a broad generalisation about young people." |
| `good afternoon` | ipa | S3a |  | **ipa**: `/ɡʊd ˈnaɪt/` → `/ˌɡʊd ɑːftəˈnuːn/ (UK) or /ˌɡʊd æftərˈnuːn/ (US)` |
| `good morning` | ipa | S3a |  | **ipa**: `/ɡʊd ˈnaɪt/` → `/ˌɡʊd ˈmɔːnɪŋ/` |
| `health care` | context+ipa | S2·S3b·S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/hiːl/` → `/ˈhelθ keər/ (UK) or /ˈhelθ ker/ (US)`<br>**例句**: "The cut healed within a week." → "The government plans to invest more in health care this year." |
| `hr` | ipa | S3b |  | **ipa**: `/ˌeɪtʃ ˈɑː(r)/ (abbreviation)` → `/ˈaʊə(r)/` |
| `humphrey` | ipa | S3b |  | **ipa**: `/ˌeɪtʃ ˈɑː(r)/ (abbreviation)` → `/ˈhʌmfri/` |
| `hysterical` | ipa | S2 | ipa 疑截断 | **ipa**: `/hɪs/` → `/hɪˈsterɪkl/` |
| `ice hockey` | ipa | S3a |  | **ipa**: `/ˈaɪs skeɪtɪŋ/` → `/ˈaɪs ˌhɒki/ (UK) or /ˈaɪs ˌhɑːki/ (US)` |
| `il` | context | S4 | 例句不含该词 | **例句**: "The rules are illegal." → "The word 'illegal' begins with the prefix il- meaning not." |
| `india` | ipa | S1 | ipa 残缺 | **ipa**: `/` → `/ˈɪndiə/` |
| `janice` | ipa | S3b |  | **ipa**: `/dʒæn/` → `/ˈdʒænɪs/` |
| `janssen` | ipa | S3b |  | **ipa**: `/dʒæn/` → `/ˈjænsən/` |
| `literally` | ipa | S1 | ipa 残缺 | **ipa**: `/ˈlɪtər` → `/ˈlɪtərəli/` |
| `marriage` | context | S4 | 例句不含该词 | **例句**: "They celebrated their 25th wedding anniversary." → "Their marriage has lasted for over thirty years." |
| `meet` | ipa | S3b |  | **ipa**: `/miː/` → `/miːt/` |
| `message board` | context+ipa | S2·S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/mɛs/` → `/ˈmesɪdʒ bɔːd/ (UK) or /ˈmesɪdʒ bɔːrd/ (US)`<br>**例句**: "The room was a complete mess after the party." → "She posted a question on the message board and got helpful replies." |
| `mink` | ipa | S3b |  | **ipa**: `/mɪn/` → `/mɪŋk/` |
| `minneapolis` | ipa | S2·S3b | ipa 疑截断 | **ipa**: `/mɪn/` → `/ˌmɪniˈæpəlɪs/` |
| `mixing bowl` | context+ipa | S2·S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/mɪks/` → `/ˈmɪksɪŋ bəʊl/ (UK) or /ˈmɪksɪŋ boʊl/ (US)`<br>**例句**: "Mix the flour and eggs together." → "She poured the flour into a large mixing bowl." |
| `mosk` | context | S3b | 例句不含该词 | **例句**: "None" → "The author, Mr. Mosk, signed copies of his book at the store." |
| `neal` | ipa | S3b |  | **ipa**: `/ˌen ˈiː/` → `/niːl/` |
| `nebraska` | ipa | S3b |  | **ipa**: `/ˌen ˈiː/` → `/nəˈbræskə/` |
| `ns` | ipa | S3b |  | **ipa**: `/ˌnɒnˈsɪŋɡjʊlə/` → `/ˌnænoʊˈsekəndz/` |
| `pasha` | ipa | S3b |  | **ipa**: `/pɑː/` → `/ˈpæʃə/ (UK) or /ˈpɑːʃə/ (US)` |
| `past` | context | S4 | 例句不含该词 | **例句**: "I" → "In the past, people wrote letters by hand." |
| `penniless` | ipa | S1 | ipa 残缺 | **ipa**: `/ˈ` → `/ˈpeniləs/` |
| `police officer` | ipa | S3a |  | **ipa**: `/pəˈliːs ˌsteɪʃən/` → `/pəˈliːs ˌɒfɪsə/ (UK) or /pəˈliːs ˌɔːfɪsər/ (US)` |
| `rigged` | ipa | S3b |  | **ipa**: `/rɪɡ/` → `/rɪɡd/` |
| `rigorous` | ipa | S2·S3b | ipa 疑截断 | **ipa**: `/rɪɡ/` → `/ˈrɪɡərəs/` |
| `secondary school` | ipa | S3a |  | **ipa**: `/ˈsɛkənd ˈpɜːrsən/` → `/ˈsekəndri skuːl/ (UK) or /ˈsekənderi skuːl/ (US)` |
| `simulated` | ipa | S1 | ipa 残缺 | **ipa**: `/` → `/ˈsɪmjʊleɪtɪd/` |
| `steering wheel` | context+ipa | S2·S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/stɪə/` → `/ˈstɪərɪŋ wiːl/ (UK) or /ˈstɪrɪŋ wiːl/ (US)`<br>**例句**: "She steered the car carefully around the icy bend." → "She gripped the steering wheel tightly as the car turned." |
| `subsection` | ipa | S2 | ipa 疑截断 | **ipa**: `/sʌb/` → `/ˈsʌbsekʃn/` |
| `swimming costume` | ipa | S3a |  | **ipa**: `/ˈswɪmɪŋ puːl/` → `/ˈswɪmɪŋ ˌkɒstjuːm/ (UK) or /ˈswɪmɪŋ ˌkɑːstuːm/ (US)` |
| `teamwork` | context | S4 | 例句不含该词 | **例句**: "The project succeeded thanks to" → "Good teamwork is essential for the success of any project." |
| `tethered` | ipa | S1 | ipa 残缺 | **ipa**: `/ˈ` → `/ˈteðəd/ (UK) or /ˈteðərd/ (US)` |
| `turpentine` | context | S4 | 例句不含该词 | **例句**: "The artist cleaned his brushes with turpent" → "The artist cleaned her brushes with turpentine after finishing the oil painting." |
| `unification` | ipa | S1 | ipa 残缺 | **ipa**: `/ˌ` → `/ˌjuːnɪfɪˈkeɪʃn/` |
| `white` | ipa | S2·S3b | ipa 疑截断 | **ipa**: `/aɪ/` → `/waɪt/` |
| `with` | ipa | S3b |  | **ipa**: `/ɪt/` → `/wɪð/ (UK) or /wɪθ/ (US)` |

## 五、判据说明（🔑 为什么不能只看「是否相同」）

| 字段 | 性质 | 「现状错」的判据 | 允许覆盖的字段 |
|---|---|---|---|
| `ipa` | **封闭**（一个词的正确音标有限） | 残缺 / 未覆盖全 / 疑截断 / 与 v6 不同 | ✅ `ipa` |
| `pos` | **近似封闭** | 与 v6 不同 → 有一方错（**须人眼**） | ❌ 不自动写 |
| `definition` | **开放式**（同义表述很多） | 现状**为空**；或已证实**整卡污染** | ⚠️ 仅上述两种 |
| `context` | **开放式**（例句无穷多） | **不含该词**（词形还原后） | ✅ `context` |

### ⚠️ 教训一：`word_form` 表**只收规则变形** —— 拿它当唯一依据会大面积误报

实测（2026-09-29）：`base=bury` 只有 burial/buries/burying（**没有 buried**）·
`base=leaf` 只有 leafed/leafing/leafs（**没有 leaves**）·
`base=shrink` 只有 shrinked/shrinking/shrinks（**没有 shrank**）。
→ 靠它判「例句是否含该词」，会把不规则变形**全部误判为「不含」**。

本表改为**自造规则变形 + 补不规则/拼写变体 + 复合词判定**（见 `surface_forms`）。
结果：S4 命中里 **55 条**是判据误差（例句其实是合法的），已从「确定要修」中剔除：

- `a.m.`: "The meeting is at 10 a.m."
- `alumnus`: "She is an alumna of Harvard University."
- `anta`: "The temple's porch is flanked by antae."
- `bring up`: "She brought up three children on her own."
- `bury`: "They buried him in the local churchyard."
- `calenda`: "The Calends were a day of settling debts and religious observance."
- `civilization`: "The rise of civilisation transformed human life."
- `crystallise`: "The sugar solution crystallized as it cooled."
- `dc`: "She lives in Washington, D.C."
- `dissatisfy`: "The poor service dissatisfied many customers."
- `dr.`: "I have an appointment with Dr. Lee."
- `esquire`: "The envelope was addressed to Jonathan Smith, Esq."
- `exemplify`: "This painting exemplifies the artist's early style."
- `freshman`: "The freshmen attended an orientation session on campus."
- `grandchild`: "They have three grandchildren."
- `intensify`: "The storm intensified overnight."
- `jan`: "My birthday is in January, the first month of the year."
- `leaf`: "The leaves turn brown in autumn."
- `leap`: "The deer leapt over the fence effortlessly."
- `lied`: "Schubert’s lieder are world‑renowned."
- `loom`: "She worked at a handloom."
- `make up`: "He made up an excuse for being late."
- `maker`: "The watchmaker is a skilled craftsman."
- `mimic`: "He mimicked the teacher’s accent perfectly."
- `mr.`: "Mr. Smith will see you now."
- `mrs.`: "Mrs. Brown has just arrived."
- `ms.`: "Ms. Garcia is on the phone."
- `noel`: "The choir sang “The First Nowell” at the service."
- `outgrow`: "He has outgrown his school uniform."
- `outshine`: "Her performance outshone everyone else’s."
- `overpay`: "I think I overpaid for this car."
- `overtake`: "The red car overtook the lorry on the motorway."
- `overthrow`: "The rebels overthrew the dictator."
- `p.m.`: "The meeting is at 3 p.m."
- `petrify`: "The wood had petrified over centuries."
- `ramify`: "The river ramifies into several smaller streams."
- `ratify`: "The Senate ratified the treaty by a wide margin."
- `reader`: "The book has attracted a wide readership."
- `redundancy`: "The company announced 200 redundancies last week."
- `retell`: "He retold the ancient legend with modern twists."
- `reunify`: "The two states were reunified after decades of separation."
- `rewrite`: "She rewrote the first chapter to make it more engaging."
- `sanctify`: "The priest sanctified the water before the ceremony."
- `schoolchild`: "The bus was full of schoolchildren."
- `seventy`: "She celebrated her seventieth birthday."
- `shrink`: "The sweater shrank in the wash."
- `therapy`: "He is undergoing chemotherapy for cancer."
- `transfuse`: "The patient needed a transfusion after the accident."
- `undergo`: "She underwent surgery last month."
- `undo`: "He undid his tie."
- `vertebra`: "The human spine consists of 33 vertebrae."
- `wax`: "The candle was made of beeswax."
- `withdraw`: "She withdrew £200 from her account."
- `withhold`: "The company withheld his salary for two months."
- `work out`: "She works out at the gym every morning."

### 🔑 教训二：`definition` 的「不同」大多是**措辞差异**，不是错

`definition` 是**开放式**字段（同义表述无穷多），且 LLM 与人工的书写习惯不同
（大小写、句末句号、详略）。实测 `bulletin` 现状 "A short official notice or report
giving news or information to many people." 比 v6 "a short official notice or news
report" **更详细** —— 覆盖它是**净损失**。

唯一例外是**整卡污染**（内容来自另一个词），此时释义必须一起换：

| 词 | 内容来自 | 现状 ipa | 现状例句 |
|---|---|---|---|
| `a` | `happy` | `/ˈhæpi/` | "I am happy to see you." |

## 六、v6 产出质量自查

| 检查 | 结果 |
|---|---|
| v6 产出的 `ipa` 残缺 / 未覆盖全词组 / 疑截断 | **0** |
| v6 产出的例句「不含该词」 | 0（多为判据残余误差：缩写带点 / 不规则变形） |

---

*本报告**只生成候选，未写 `word.db`**。写库由 `scripts/apply_card_field_fixes.py` 执行（需单独批准）。*

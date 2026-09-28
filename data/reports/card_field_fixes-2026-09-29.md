# 卡片字段修正候选 —— LLM（契约 v6）复核结果

> 生成：2026-09-29 02:28:23 ｜ 模型 `deepseek-flash` ｜ **只生成，未写库**
> 输入：`card_field_candidates.json`（196 条可疑项，由 5 个信号筛出）
> 成本 **¥1.2807**（in 640,049 / out 71,250 token）· 耗时 0s · 并发 12

## 一、结论：三档

| 档位 | 条数 | 含义 |
|---|---:|---|
| **🔴 确定要修** | **72** | 有**硬证据**（见 §二）：现状确实错 |
| 🟠 疑似 | 123 | 封闭字段与 v6 不同，**有一方错**，需人眼 |
| ✅ 无问题 | 1 | 现状没查出问题（信号**误报**） |
| — 失败 | 0 | 调用失败，未判定 |

> 🔑 **本表的判据是「字段性质」，不是「与原值是否相同」** —— 见 §五。
>    第一版用「与现状不同」判错，得到「196/196 全部不同」的**假象**：
>    例句是开放式生成，换个说法**不等于**原句错。

## 二、硬证据分布（「确定要修」的原因）

| 硬证据 | 条数 |
|---|---:|
| 例句不含该词 | 64 |
| ipa 未覆盖全词组 | 10 |
| ipa 残缺 | 7 |

> 🔑 `ipa 残缺` = 连一个完整的 `/.../` 都没有（`/ˈ`）；
>    `ipa 未覆盖全词组` = 多词词组只给了第一个词的音标（`frying pan` → `/fraɪ/`）；
>    `例句不含该词` = 用 **`word_form` 词形还原**后仍找不到该词。

## 三、按信号看（判据的命中率）

| 信号组合 | 总数 | 确定要修 | 命中率 |
|---|---:|---:|---:|
| `S3b` | 79 | 1 | 1% |
| `S4` | 62 | 54 | 87% |
| `S3a` | 28 | 0 | 0% |
| `S2 + S4` | 7 | 7 | 100% |
| `S1` | 7 | 7 | 100% |
| `S2 + S3b` | 6 | 0 | 0% |
| `S2` | 4 | 1 | 25% |
| `S3b + S4` | 2 | 1 | 50% |
| `S2 + S3b + S4` | 1 | 1 | 100% |

### ⚠️ 但 S3a / S3b 的「0% / 1%」**不是「信号错了**」—— 是本表的硬证据判据**抓不到那一类**

| 信号 | 它要抓什么 | 本表能判吗 |
|---|---|---|
| `S1` `S2` | ipa **残缺 / 截断**（段数不够、格式不完整） | ✅ **能**（纯格式，机械可判） |
| `S4` | 例句**不含该词** | ✅ **能**（查词形表即可） |
| `S3a` `S3b` | ipa 是**另一个词**的音标（段数够、格式也合法） | 🔴 **不能** |

🔑 为什么不能：`air conditioning` 的现状 ipa 是 `/ˈɛr fɔːrs/` —— **两段、格式合法**，
机械判据（段数 ≥ 词数）**完全通过**；要知道它是 `air force` 的音标，
必须**懂语义**。这正是 LLM 复核不可替代的地方。

📌 所以本表三档的准确含义是：
- **🔴 确定要修** = 机械判据**能证实**的错（72 条）
- **🟠 疑似** = 机械判据**判不了**、只有 LLM 给了不同值的（123 条，其中 S3a 28 + S3b 78）
  → **不是「可能没错」，是「本表没有能力证明它错」** <- 这两句意思完全不同

## 四、🔴 确定要修 —— 逐条（现状 → v6）

| 词 | 信号 | 硬证据 | 现状 → v6 |
|---|---|---|---|
| `a` | S3b·S4 | 例句不含该词 | **例句**: "I am happy to see you." → "She bought a new car yesterday." |
| `alumnus` | S4 | 例句不含该词 | **例句**: "She is an alumna of Harvard University." → "He is a proud alumnus of the university and often returns to give lectures." |
| `anta` | S4 | 例句不含该词 | **例句**: "The temple's porch is flanked by antae." → "The antae of the temple were decorated with elaborate carvings." |
| `bank account` | S2·S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/bæn/` → `/ˈbæŋk əˌkaʊnt/`<br>**例句**: "The government banned smoking in public places." → "She opened a new bank account at the local branch." |
| `bury` | S4 | 例句不含该词 | **例句**: "They buried him in the local churchyard." → "The dog likes to bury bones in the garden." |
| `calenda` | S4 | 例句不含该词 | **例句**: "The Calends were a day of settling debts and religious observance." → "The Roman calendar marked the calenda as the first day of each month." |
| `capital letter` | S2·S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/kæp/` → `/ˌkæpɪtl ˈletə/ (UK) or /ˌkæpɪtl ˈletər/ (US)`<br>**例句**: "He wore a baseball cap." → "Every sentence should begin with a capital letter." |
| `chewing gum` | S2·S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/tʃuː/` → `/ˈtʃuːɪŋ ɡʌm/`<br>**例句**: "She chewed her food slowly." → "She always carries a pack of chewing gum in her bag." |
| `civilization` | S4 | 例句不含该词 | **例句**: "The rise of civilisation transformed human life." → "Ancient civilizations built impressive monuments that still stand today." |
| `classical music` | S2 | ipa 未覆盖全词组 | **ipa**: `/klɑːs/` → `/ˈklæsɪkl ˈmjuːzɪk/` |
| `crystallise` | S4 | 例句不含该词 | **例句**: "The sugar solution crystallized as it cooled." → "The solution began to crystallise as it cooled." |
| `dc` | S4 | 例句不含该词 | **例句**: "She lives in Washington, D.C." → "She moved to DC to work for a government agency." |
| `dissatisfy` | S4 | 例句不含该词 | **例句**: "The poor service dissatisfied many customers." → "The poor service dissatisfied many customers." |
| `environmentally friendly` | S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/ɪnˌvaɪrənˈmentl/` → `/ɪnˌvaɪrənˈmentəli ˈfrendli/`<br>**例句**: "Environmental protection is a global issue." → "Many companies are now trying to use environmentally friendly packaging." |
| `esquire` | S4 | 例句不含该词 | **例句**: "The envelope was addressed to Jonathan Smith, Esq." → "The letter was addressed to John Smith, Esquire." |
| `exemplify` | S4 | 例句不含该词 | **例句**: "This painting exemplifies the artist's early style." → "Her paintings exemplify the style of the period." |
| `fact` | S1 | ipa 残缺 | **ipa**: `/fækt` → `/fækt/` |
| `freshman` | S4 | 例句不含该词 | **例句**: "The freshmen attended an orientation session on campus." → "She was nervous on her first day as a freshman at college." |
| `frying pan` | S2·S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/fraɪ/` → `/ˈfraɪɪŋ pæn/`<br>**例句**: "She fried the eggs in butter." → "She heated some oil in the frying pan before adding the eggs." |
| `funk` | S4 | 例句不含该词 | **例句**: "The band played a funky tune that made everyone dance." → "After the party, the room had a strange funk of stale beer and sweat." |
| `generalisation` | S4 | 例句不含该词 | **例句**: "This is a" → "The report was criticized for making a broad generalisation about young people." |
| `grandchild` | S4 | 例句不含该词 | **例句**: "They have three grandchildren." → "She loves spending time with her grandchild every weekend." |
| `health care` | S2·S3b·S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/hiːl/` → `/ˈhelθ keər/ (UK) or /ˈhelθ ker/ (US)`<br>**例句**: "The cut healed within a week." → "The government plans to invest more in health care this year." |
| `il` | S4 | 例句不含该词 | **例句**: "The rules are illegal." → "The word 'illegal' begins with the prefix il- meaning not." |
| `india` | S1 | ipa 残缺 | **ipa**: `/` → `/ˈɪndiə/` |
| `intensify` | S4 | 例句不含该词 | **例句**: "The storm intensified overnight." → "The government decided to intensify its efforts to reduce pollution." |
| `jan` | S4 | 例句不含该词 | **例句**: "My birthday is in January, the first month of the year." → "The new term begins in Jan and ends in May." |
| `leaf` | S4 | 例句不含该词 | **例句**: "The leaves turn brown in autumn." → "The leaves on the trees turn red and gold in autumn." |
| `leap` | S4 | 例句不含该词 | **例句**: "The deer leapt over the fence effortlessly." → "The athlete leaped over the high bar with ease." |
| `lied` | S4 | 例句不含该词 | **例句**: "Schubert’s lieder are world‑renowned." → "Schubert composed many famous lieder for voice and piano." |
| `literally` | S1 | ipa 残缺 | **ipa**: `/ˈlɪtər` → `/ˈlɪtərəli/` |
| `loom` | S4 | 例句不含该词 | **例句**: "She worked at a handloom." → "The weaver used a loom to make cloth." |
| `maker` | S4 | 例句不含该词 | **例句**: "The watchmaker is a skilled craftsman." → "The company is a leading maker of electric cars." |
| `marriage` | S4 | 例句不含该词 | **例句**: "They celebrated their 25th wedding anniversary." → "Their marriage has lasted for over thirty years." |
| `message board` | S2·S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/mɛs/` → `/ˈmesɪdʒ bɔːd/ (UK) or /ˈmesɪdʒ bɔːrd/ (US)`<br>**例句**: "The room was a complete mess after the party." → "She posted a question on the message board and got helpful replies." |
| `mimic` | S4 | 例句不含该词 | **例句**: "He mimicked the teacher’s accent perfectly." → "Children often mimic their parents' gestures and speech." |
| `mixing bowl` | S2·S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/mɪks/` → `/ˈmɪksɪŋ bəʊl/ (UK) or /ˈmɪksɪŋ boʊl/ (US)`<br>**例句**: "Mix the flour and eggs together." → "She poured the flour into a large mixing bowl." |
| `mosk` | S3b | 例句不含该词 | **例句**: "None" → "The author, Mr. Mosk, signed copies of his book at the store." |
| `noel` | S4 | 例句不含该词 | **例句**: "The choir sang “The First Nowell” at the service." → "The choir sang a joyful noel at the Christmas concert." |
| `outgrow` | S4 | 例句不含该词 | **例句**: "He has outgrown his school uniform." → "Children outgrow their clothes quickly." |
| `outshine` | S4 | 例句不含该词 | **例句**: "Her performance outshone everyone else’s." → "She outshines all her classmates in mathematics." |
| `overpay` | S4 | 例句不含该词 | **例句**: "I think I overpaid for this car." → "Customers often overpay for products they don't really need." |
| `overtake` | S4 | 例句不含该词 | **例句**: "The red car overtook the lorry on the motorway." → "The red car accelerated to overtake the truck on the highway." |
| `overthrow` | S4 | 例句不含该词 | **例句**: "The rebels overthrew the dictator." → "The rebels tried to overthrow the government last year." |
| `past` | S4 | 例句不含该词 | **例句**: "I" → "In the past, people wrote letters by hand." |
| `penniless` | S1 | ipa 残缺 | **ipa**: `/ˈ` → `/ˈpeniləs/` |
| `petrify` | S4 | 例句不含该词 | **例句**: "The wood had petrified over centuries." → "The sudden noise petrified the small child." |
| `ramify` | S4 | 例句不含该词 | **例句**: "The river ramifies into several smaller streams." → "The river ramifies into many small streams near the delta." |
| `ratify` | S4 | 例句不含该词 | **例句**: "The Senate ratified the treaty by a wide margin." → "Parliament will ratify the treaty next week." |
| `reader` | S4 | 例句不含该词 | **例句**: "The book has attracted a wide readership." → "The newspaper invited its readers to share their opinions on the new policy." |
| `redundancy` | S4 | 例句不含该词 | **例句**: "The company announced 200 redundancies last week." → "The company announced redundancies as part of its restructuring plan." |
| `retell` | S4 | 例句不含该词 | **例句**: "He retold the ancient legend with modern twists." → "She asked the students to retell the story in their own words." |
| `reunify` | S4 | 例句不含该词 | **例句**: "The two states were reunified after decades of separation." → "The two countries agreed to reunify after decades of division." |
| `rewrite` | S4 | 例句不含该词 | **例句**: "She rewrote the first chapter to make it more engaging." → "The teacher asked us to rewrite the essay after correcting the grammar mistakes." |
| `sanctify` | S4 | 例句不含该词 | **例句**: "The priest sanctified the water before the ceremony." → "The priest sanctified the new church with a special ceremony." |
| `schoolchild` | S4 | 例句不含该词 | **例句**: "The bus was full of schoolchildren." → "Every schoolchild in the district receives a free lunch." |
| `seventy` | S4 | 例句不含该词 | **例句**: "She celebrated her seventieth birthday." → "She has lived in this city for seventy years." |
| `shrink` | S4 | 例句不含该词 | **例句**: "The sweater shrank in the wash." → "The company's profits shrank by ten percent last year." |
| `simulated` | S1 | ipa 残缺 | **ipa**: `/` → `/ˈsɪmjʊleɪtɪd/` |
| `steering wheel` | S2·S4 | ipa 未覆盖全词组,例句不含该词 | **ipa**: `/stɪə/` → `/ˈstɪərɪŋ wiːl/ (UK) or /ˈstɪrɪŋ wiːl/ (US)`<br>**例句**: "She steered the car carefully around the icy bend." → "She gripped the steering wheel tightly as the car turned." |
| `teamwork` | S4 | 例句不含该词 | **例句**: "The project succeeded thanks to" → "Good teamwork is essential for the success of any project." |
| `tethered` | S1 | ipa 残缺 | **ipa**: `/ˈ` → `/ˈteðəd/ (UK) or /ˈteðərd/ (US)` |
| `therapy` | S4 | 例句不含该词 | **例句**: "He is undergoing chemotherapy for cancer." → "She has been in therapy for depression for two years." |
| `transfuse` | S4 | 例句不含该词 | **例句**: "The patient needed a transfusion after the accident." → "The doctor decided to transfuse two units of blood during the surgery." |
| `turpentine` | S4 | 例句不含该词 | **例句**: "The artist cleaned his brushes with turpent" → "The artist cleaned her brushes with turpentine after finishing the oil painting." |
| `undergo` | S4 | 例句不含该词 | **例句**: "She underwent surgery last month." → "The company will undergo major changes next year." |
| `undo` | S4 | 例句不含该词 | **例句**: "He undid his tie." → "You can undo your last change by pressing this button." |
| `unification` | S1 | ipa 残缺 | **ipa**: `/ˌ` → `/ˌjuːnɪfɪˈkeɪʃn/` |
| `vertebra` | S4 | 例句不含该词 | **例句**: "The human spine consists of 33 vertebrae." → "A slipped disc occurs when the soft cushion between each vertebra is damaged." |
| `wax` | S4 | 例句不含该词 | **例句**: "The candle was made of beeswax." → "The candle is made of wax and burns slowly." |
| `withdraw` | S4 | 例句不含该词 | **例句**: "She withdrew £200 from her account." → "She decided to withdraw some money from her bank account." |
| `withhold` | S4 | 例句不含该词 | **例句**: "The company withheld his salary for two months." → "The company decided to withhold the payment until the work was completed." |

## 五、判据说明（🔑 为什么不能只看「是否相同」）

| 字段 | 性质 | 「现状错」的判据 |
|---|---|---|
| `ipa` | **封闭**（一个词的正确音标有限） | 格式残缺 / 多词未覆盖全 / 与 v6 不同（有一方错） |
| `pos` | **近似封闭** | 与 v6 不同 → 有一方错 |
| `definition` | **开放式**（同义表述很多） | 现状**为空**才是硬证据 |
| `context` | **开放式**（例句无穷多） | **不含该词**（词形还原后）→ 确定错 |

⚠️ 实测教训：**「例句是否含该词」必须用 `word_form` 表还原**。
用「词干截断」会把 `brought`(bring) · `leaves`(leaf) · `shrank`(shrink) ·
`t-shirt`（连字符被分词切开）**全部误判为「不含」** ——
第一版因此把 v6 的 52 条合法 ipa 与 8 条正确例句误报为「违规」。

## 六、v6 产出质量自查

| 检查 | 结果 |
|---|---|
| v6 产出的 `ipa` 残缺 / 未覆盖全词组 | **0** |
| v6 产出的例句「不含该词」 | 10（多为判据残余误差：缩写带点 / 不规则变形） |

需人眼确认的 v6 例句：
- `anta`: "The antae of the temple were decorated with elaborate carvings."
- `dissatisfy`: "The poor service dissatisfied many customers."
- `leaf`: "The leaves on the trees turn red and gold in autumn."
- `lied`: "Schubert composed many famous lieder for voice and piano."
- `outshine`: "She outshines all her classmates in mathematics."
- `petrify`: "The sudden noise petrified the small child."
- `ramify`: "The river ramifies into many small streams near the delta."
- `redundancy`: "The company announced redundancies as part of its restructuring plan."
- `sanctify`: "The priest sanctified the new church with a special ceremony."
- `shrink`: "The company's profits shrank by ten percent last year."

---

*本报告**只生成候选，未写 `word.db`**。写库需单独批准（改生产数据资产）。*

# 卡片字段修正候选 —— LLM（契约 v6）复核结果

> 生成：2026-09-29 08:56:09 ｜ 模型 `deepseek-flash` ｜ **只生成，未写库**
> 输入：`wf_mapping_candidates.json`（48 条可疑项）
> 成本 **¥0.3115**（in 154,209 / out 17,821 token）· 耗时 8s · 并发 12

## 一、结论：三档 + 建议写入

| 档位 | 条数 | 含义 |
|---|---:|---|
| **🔴 确定要修** | **48** | 有**硬证据**（见 §二）：现状确实错 |
| 🟠 疑似 | 0 | 封闭字段与 v6 不同，**有一方错**，需人眼 |
| ✅ 无问题 | 0 | 现状没查出问题（信号**误报**） |
| — 失败 | 0 | 调用失败，未判定 |

### 🔑 建议写入 `word.db`：**48** 条卡（按字段）

| 字段 | 条数 | 允许覆盖的**前提**（每个字段须有自己的硬证据） |
|---|---:|---|
| `ipa` | 48 | 残缺 / 未覆盖全词组 / 疑截断（S2）/ 与 v6 不同（封闭字段） |
| `context` | 48 | 例句**不含该词**（词形还原后） |
| `definition` | 48 | **仅**：现状为空，或已证实**整卡污染**（见 §五） |

> 🔴 **不整条覆盖** —— `definition` 是开放式字段，「与 v6 不同」绝大多数只是
> 措辞 / 大小写 / 句末句号差异（实测 `bulletin` 现状比 v6 更详细）→
> 按「不同」覆盖会造成大面积无谓改动（见 §五）。

## 二、硬证据分布（「确定要修」的原因）

| 硬证据 | 条数 |
|---|---:|
| ipa 残缺 | 48 |
| 释义为空 | 48 |
| 例句不含该词 | 48 |

> 🔑 `ipa 残缺` = 连一个完整的 `/.../` 都没有（`/ˈ`）·
>    `ipa 未覆盖全词组` = 多词词组只给了第一个词的音标（`frying pan` → `/fraɪ/`）·
>    `ipa 疑截断` = 格式合法但实质字符/拼写字母 < 0.45（`abortive` → `/viː/`）·
>    `例句不含该词` = 词形还原（见 §五）后仍找不到该词。

## 三、按信号看（判据的命中率）

| 信号组合 | 总数 | 确定要修 | 命中率 |
|---|---:|---:|---:|
| `M1` | 48 | 48 | 100% |

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
| `amped` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/æmpt/`<br>**例句**: "None" → "The fans were amped for the concert to start."<br>**释义**: "None" → "very excited or eager"  |
| `amping` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈæmpɪŋ/`<br>**例句**: "None" → "The crowd was amping up the players with loud cheers."<br>**释义**: "None" → "making someone excited or full of energy"  |
| `bearded` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈbɪədɪd/ (UK) or /ˈbɪrdɪd/ (US)`<br>**例句**: "None" → "The bearded man sat quietly in the corner of the café."<br>**释义**: "None" → "having a beard"  |
| `bearding` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈbɪədɪŋ/ (UK) or /ˈbɪrdɪŋ/ (US)`<br>**例句**: "None" → "He is bearding the lion in its den by criticizing the boss openly."<br>**释义**: "None" → "growing a beard; boldly confronting someone"  |
| `beded` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈbiːdɪd/`<br>**例句**: "None" → "In the old poem, the hermit beded for the sailors' safe return."<br>**释义**: "None" → "prayed or asked earnestly (archaic)"  |
| `beding` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/bɪˈdiːɪŋ/`<br>**例句**: "None" → "She was beding for forgiveness when the storm finally passed."<br>**释义**: "None" → "praying; asking earnestly"  |
| `breathed` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/briːðd/`<br>**例句**: "None" → "She breathed deeply and then began her speech."<br>**释义**: "None" → "took air into and out of the lungs"  |
| `breathing` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈbriːðɪŋ/`<br>**例句**: "None" → "Deep breathing can help reduce stress and anxiety."<br>**释义**: "None" → "the act or process of taking air into and expelling it from the lungs"  |
| `buried` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈberid/`<br>**例句**: "None" → "The treasure was buried deep under the old oak tree."<br>**释义**: "None" → "placed a dead body in the ground, or hidden deeply"  |
| `caned` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/keɪnd/`<br>**例句**: "None" → "In some countries, students were caned for breaking school rules."<br>**释义**: "None" → "hit someone with a cane as punishment"  |
| `caning` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈkeɪnɪŋ/`<br>**例句**: "None" → "The school abolished caning as a form of punishment."<br>**释义**: "None" → "punishment of being hit with a cane"  |
| `cometed` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈkɒmɪtɪd/ (UK) or /ˈkɑːmɪtɪd/ (US)`<br>**例句**: "None" → "The racing car cometed down the straight and disappeared from view."<br>**释义**: "None" → "moved swiftly like a comet"  |
| `cometing` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈkɒmɪtɪŋ/ (UK) or /ˈkɑːmɪtɪŋ/ (US)`<br>**例句**: "None" → "The racing car came cometing down the straight at incredible speed."<br>**释义**: "None" → "moving swiftly like a comet"  |
| `domed` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/dəʊmd/ (UK) or /doʊmd/ (US)`<br>**例句**: "None" → "The domed roof of the cathedral gleamed in the morning sun."<br>**释义**: "None" → "having a rounded roof or shape like a dome"  |
| `doming` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈdəʊmɪŋ/ (UK) or /ˈdoʊmɪŋ/ (US)`<br>**例句**: "None" → "The hot air balloon was doming above the field as it filled."<br>**释义**: "None" → "forming or rising into a rounded shape like a dome"  |
| `dosed` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/dəʊst/`<br>**例句**: "None" → "The nurse dosed the patient with antibiotics every eight hours."<br>**释义**: "None" → "gave a measured amount of medicine to"  |
| `dosing` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈdəʊsɪŋ/ (UK) or /ˈdoʊsɪŋ/ (US)`<br>**例句**: "None" → "The nurse is dosing the patient carefully according to the chart."<br>**释义**: "None" → "the act of giving a measured amount of medicine"  |
| `doved` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/dʌvd/`<br>**例句**: "None" → "The swimmer doved into the pool and surfaced near the far end."<br>**释义**: "None" → "dived; plunged headfirst into water"  |
| `doving` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈdʌvɪŋ/`<br>**例句**: "None" → "Her doving manner made everyone feel instantly at ease."<br>**释义**: "None" → "resembling or characteristic of a dove; gentle and innocent"  |
| `fines` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/faɪnz/`<br>**例句**: "None" → "The company had to pay heavy fines for breaking environmental laws."<br>**释义**: "None" → "sums of money paid as penalties"  |
| `havened` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈheɪvənd/`<br>**例句**: "None" → "The small fishing village, havened by the cliffs, survived the storm."<br>**释义**: "None" → "sheltered or provided with a haven; safe"  |
| `havening` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈheɪvənɪŋ/`<br>**例句**: "None" → "The therapist used havening to help the patient calm down."<br>**释义**: "None" → "a psychotherapeutic technique using touch to reduce stress"  |
| `jointed` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈdʒɔɪntɪd/`<br>**例句**: "None" → "The doll has jointed arms and legs that can bend."<br>**释义**: "None" → "having joints or connected by joints"  |
| `lieued` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ljuːd/`<br>**例句**: "None" → "The document was lieued in the archive for future reference."<br>**释义**: "None" → "having a lieu or position; placed"  |
| `lieuing` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈlaɪuɪŋ/`<br>**例句**: "None" → "The word lieuing appears in some old manuscripts as a variant spelling."<br>**释义**: "None" → "a nonstandard spelling variant, possibly of lying or lieu"  |
| `marines` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/məˈriːnz/`<br>**例句**: "None" → "The marines landed on the beach before dawn."<br>**释义**: "None" → "soldiers trained to serve at sea and on land"  |
| `mines` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/maɪnz/`<br>**例句**: "None" → "The soldiers carefully cleared the mines from the field."<br>**释义**: "None" → "excavations for minerals; explosive devices"  |
| `pales` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/peɪlz/`<br>**例句**: "None" → "Her achievements pale in comparison to his."<br>**释义**: "None" → "becomes less important or impressive compared to something else"  |
| `passed` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/pɑːst/ (UK) or /pæst/ (US)`<br>**例句**: "None" → "She passed the exam with the highest score in her class."<br>**释义**: "None" → "went past; succeeded in a test; handed over"  |
| `passing` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈpɑːsɪŋ/ (UK) or /ˈpæsɪŋ/ (US)`<br>**例句**: "None" → "She made only a passing reference to the incident."<br>**释义**: "None" → "lasting only a short time; casual or brief"  |
| `pasted` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈpeɪstɪd/`<br>**例句**: "None" → "She pasted the photo into her scrapbook."<br>**释义**: "None" → "stuck or attached with paste; copied and inserted into a document"  |
| `pasting` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈpeɪstɪŋ/`<br>**例句**: "None" → "She was pasting photos into her scrapbook all afternoon."<br>**释义**: "None" → "the act of sticking something with paste; a severe beating"  |
| `pickled` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈpɪkld/`<br>**例句**: "None" → "She added pickled onions to the salad for extra flavor."<br>**释义**: "None" → "preserved in vinegar or salt water"  |
| `pickling` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈpɪklɪŋ/`<br>**例句**: "None" → "Pickling cucumbers is a traditional way to preserve them for winter."<br>**释义**: "None" → "the process of preserving food in vinegar or brine"  |
| `putted` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈpʌtɪd/`<br>**例句**: "None" → "She putted the ball gently and it rolled into the hole."<br>**释义**: "None" → "hit a golf ball gently into the hole"  |
| `ridged` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/rɪdʒd/`<br>**例句**: "None" → "The ridged surface of the tire provides better grip on wet roads."<br>**释义**: "None" → "having raised lines or ridges"  |
| `ridging` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈrɪdʒɪŋ/`<br>**例句**: "None" → "The ridging on the metal roof helps channel rainwater away."<br>**释义**: "None" → "the formation of raised narrow crests or ridges"  |
| `sanes` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/seɪnz/`<br>**例句**: "None" → "Despite the pressure, she remained sanes and made a sensible decision."<br>**释义**: "None" → "having a healthy mind; reasonable and sensible"  |
| `seeded` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈsiːdɪd/`<br>**例句**: "None" → "The top-seeded player won the tournament easily."<br>**释义**: "None" → "having seeds removed, or ranked as a seed player"  |
| `seeding` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈsiːdɪŋ/`<br>**例句**: "None" → "The seeding of the fields begins in early spring."<br>**释义**: "None" → "the act of planting seeds; also a seeded player in a tournament"  |
| `singled` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈsɪŋɡld/`<br>**例句**: "None" → "The teacher singled out one student for special praise."<br>**释义**: "None" → "picked out or chose one person or thing"  |
| `singling` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈsɪŋɡlɪŋ/`<br>**例句**: "None" → "The teacher is singling out the best students for praise."<br>**释义**: "None" → "selecting or picking out one person or thing"  |
| `spited` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈspaɪtɪd/`<br>**例句**: "None" → "She spited her rival by spreading rumors about the promotion."<br>**释义**: "None" → "acted with malice or annoyance toward someone"  |
| `spiting` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈspaɪtɪŋ/`<br>**例句**: "None" → "She kept spiting her brother by hiding his keys."<br>**释义**: "None" → "annoying or hurting someone out of resentment"  |
| `stingied` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈstɪndʒid/`<br>**例句**: "None" → "He was too stingied to buy a round of drinks for his friends."<br>**释义**: "None" → "very unwilling to spend or give money"  |
| `stingying` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈstɪŋjiɪŋ/`<br>**例句**: "None" → "The stingying sensation in her fingers warned her of the cold."<br>**释义**: "None" → "having a sharp, tingling, or stinging quality"  |
| `wearied` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈwɪərid/ (UK) or /ˈwɪrid/ (US)`<br>**例句**: "None" → "The long journey wearied the travelers before they reached the city."<br>**释义**: "None" → "made or became very tired"  |
| `wearying` | context+definition+ipa | M1 | ipa 残缺,释义为空,例句不含该词 | **ipa**: `None` → `/ˈwɪəriɪŋ/ (UK) or /ˈwɪriɪŋ/ (US)`<br>**例句**: "None" → "The endless meetings were wearying for everyone involved."<br>**释义**: "None" → "making you feel tired and bored"  |

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
结果：S4 命中里 **0 条**是判据误差（例句其实是合法的），已从「确定要修」中剔除：


### 🔑 教训二：`definition` 的「不同」大多是**措辞差异**，不是错

`definition` 是**开放式**字段（同义表述无穷多），且 LLM 与人工的书写习惯不同
（大小写、句末句号、详略）。实测 `bulletin` 现状 "A short official notice or report
giving news or information to many people." 比 v6 "a short official notice or news
report" **更详细** —— 覆盖它是**净损失**。

唯一例外是**整卡污染**（内容来自另一个词），此时释义必须一起换：

（本次未发现）

## 六、v6 产出质量自查

| 检查 | 结果 |
|---|---|
| v6 产出的 `ipa` 残缺 / 未覆盖全词组 / 疑截断 | **0** |
| v6 产出的例句「不含该词」 | 1（多为判据残余误差：缩写带点 / 不规则变形） |

需人眼确认的 v6 例句：
- `pales`: "Her achievements pale in comparison to his."

---

*本报告**只生成候选，未写 `word.db`**。写库由 `scripts/apply_card_field_fixes.py` 执行（需单独批准）。*

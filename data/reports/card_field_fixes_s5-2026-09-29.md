# 卡片字段修正候选 —— LLM（契约 v6）复核结果

> 生成：2026-09-29 08:01:35 ｜ 模型 `deepseek-flash` ｜ **只生成，未写库**
> 输入：`card_field_candidates_s5_todo.json`（161 条可疑项）
> 成本 **¥1.0412**（in 525,498 / out 56,220 token）· 耗时 34s · 并发 12

## 一、结论：三档 + 建议写入

| 档位 | 条数 | 含义 |
|---|---:|---|
| **🔴 确定要修** | **1** | 有**硬证据**（见 §二）：现状确实错 |
| 🟠 疑似 | 158 | 封闭字段与 v6 不同，**有一方错**，需人眼 |
| ✅ 无问题 | 2 | 现状没查出问题（信号**误报**） |
| — 失败 | 0 | 调用失败，未判定 |

### 🔑 建议写入 `word.db`：**47** 条卡（按字段）

| 字段 | 条数 | 允许覆盖的**前提**（每个字段须有自己的硬证据） |
|---|---:|---|
| `ipa` | 46 | 残缺 / 未覆盖全词组 / 疑截断（S2）/ 与 v6 不同（封闭字段） |
| `context` | 1 | 例句**不含该词**（词形还原后） |
| `definition` | 0 | **仅**：现状为空，或已证实**整卡污染**（见 §五） |

> 🔴 **不整条覆盖** —— `definition` 是开放式字段，「与 v6 不同」绝大多数只是
> 措辞 / 大小写 / 句末句号差异（实测 `bulletin` 现状比 v6 更详细）→
> 按「不同」覆盖会造成大面积无谓改动（见 §五）。

## 二、硬证据分布（「确定要修」的原因）

| 硬证据 | 条数 |
|---|---:|
| 例句不含该词 | 1 |

> 🔑 `ipa 残缺` = 连一个完整的 `/.../` 都没有（`/ˈ`）·
>    `ipa 未覆盖全词组` = 多词词组只给了第一个词的音标（`frying pan` → `/fraɪ/`）·
>    `ipa 疑截断` = 格式合法但实质字符/拼写字母 < 0.45（`abortive` → `/viː/`）·
>    `例句不含该词` = 词形还原（见 §五）后仍找不到该词。

## 三、按信号看（判据的命中率）

| 信号组合 | 总数 | 确定要修 | 命中率 |
|---|---:|---:|---:|
| `S5c` | 109 | 1 | 1% |
| `S5a` | 25 | 0 | 0% |
| `S5b` | 23 | 0 | 0% |
| `S5b + S5c` | 4 | 0 | 0% |

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
| `bristles` | ipa | S5c |  | **ipa**: `/ˈbrɪsəl/` → `/ˈbrɪsəlz/` |
| `bullet` | ipa | S5b |  | **ipa**: `/bʊl/` → `/ˈbʊlɪt/` |
| `bus` | ipa | S5a |  | **ipa**: `/ˈbʌs ˌstɒp/` → `/bʌs/` |
| `capital` | ipa | S5a |  | **ipa**: `/ˈkæpɪtl ˈlɛtər/` → `/ˈkæpɪtl/` |
| `cd` | ipa | S5a |  | **ipa**: `/siː ˈdiː ˌpleɪər/` → `/ˌsiː ˈdiː/` |
| `chat` | ipa | S5a |  | **ipa**: `/ˈtʃæt ʃəʊ/` → `/tʃæt/` |
| `consider` | ipa | S5b |  | **ipa**: `/kənˌsɪdəˈreɪʃən/` → `/kənˈsɪdə/ (UK) or /kənˈsɪdər/ (US)` |
| `credit` | ipa | S5a |  | **ipa**: `/ˈkred.ɪt ˌkɑːrd/` → `/ˈkredɪt/` |
| `debit` | ipa | S5a |  | **ipa**: `/ˈdebɪt kɑːrd/` → `/ˈdebɪt/` |
| `definite` | ipa | S5a |  | **ipa**: `/ˈdɛfɪnɪt ˈɑːrtɪkl/` → `/ˈdefɪnət/` |
| `eat` | ipa | S5c |  | **ipa**: `/æt/ (unstressed /ət/)` → `/iːt/` |
| `en` | ipa | S5b |  | **ipa**: `/ˈɛlən/` → `/ɛn/` |
| `exchange` | ipa | S5a |  | **ipa**: `/ɪksˈtʃeɪndʒ reɪt/` → `/ɪksˈtʃeɪndʒ/` |
| `howe` | context | S5c | 例句不含该词 | **例句**: "None" → "The old farm sits at the foot of a grassy howe." |
| `id` | ipa | S5a |  | **ipa**: `/ˌaɪ ˈdiː ˌkɑːd/` → `/ˌaɪ ˈdiː/` |
| `identity` | ipa | S5a |  | **ipa**: `/aɪˈdentəti kɑːd/` → `/aɪˈdentəti/` |
| `israeli` | ipa | S5c |  | **ipa**: `/ˈɪzreɪl/` → `/ɪzˈreɪli/` |
| `logo` | ipa | S5c |  | **ipa**: `/lɒɡ/` → `/ˈləʊɡəʊ/ (UK) or /ˈloʊɡoʊ/ (US)` |
| `marshall` | ipa | S5c |  | **ipa**: `/ˈmɑːrʃəl/` → `/ˈmɑːʃl/` |
| `marvel` | ipa | S5b |  | **ipa**: `/mɑː/` → `/ˈmɑːvl/ (UK) or /ˈmɑːrvl/ (US)` |
| `modal` | ipa | S5a |  | **ipa**: `/ˈməʊdəl vɜːb/` → `/ˈməʊdl/ (UK) or /ˈmoʊdl/ (US)` |
| `navy` | ipa | S5a |  | **ipa**: `/ˌneɪvi ˈbluː/` → `/ˈneɪvi/` |
| `nazis` | ipa | S5c |  | **ipa**: `/ˈnɑːtsi/` → `/ˈnɑːtsiːz/` |
| `omelette` | ipa | S5b |  | **ipa**: `/ˈɒmlɪt/` → `/ˈɒmlət/ (UK) or /ˈɑːmlət/ (US)` |
| `owing` | ipa | S5a |  | **ipa**: `/ˈəʊɪŋ tuː/` → `/ˈəʊɪŋ/ (UK) or /ˈoʊɪŋ/ (US)` |
| `paso` | ipa | S5b·S5c |  | **ipa**: `/pɑː/` → `/ˈpæsoʊ/ (US) or /ˈpɑːsəʊ/ (UK)` |
| `police` | ipa | S5a |  | **ipa**: `/pəˈliːs ˌsteɪʃən/` → `/pəˈliːs/` |
| `primary` | ipa | S5a |  | **ipa**: `/ˈpraɪməri skuːl/` → `/ˈpraɪməri/ (UK) or /ˈpraɪmeri/ (US)` |
| `prime` | ipa | S5a |  | **ipa**: `/ˌpraɪm ˈmɪnɪstə(r)/` → `/praɪm/` |
| `rush` | ipa | S5a |  | **ipa**: `/ˈrʌʃ ˌaʊə/` → `/rʌʃ/` |
| `secondary` | ipa | S5a |  | **ipa**: `/ˈsɛkəndɛri skuːl/` → `/ˈsekəndri/ (UK) or /ˈsekənderi/ (US)` |
| `shall` | ipa | S5c |  | **ipa**: `/hɔːl/` → `/ʃæl/ (UK) or /ʃəl/ (US)` |
| `stock` | ipa | S5a |  | **ipa**: `/ˈstɒk ˌmɑːkɪt/` → `/stɒk/ (UK) or /stɑːk/ (US)` |
| `swimming` | ipa | S5a |  | **ipa**: `/ˈswɪmɪŋ puːl/` → `/ˈswɪmɪŋ/` |
| `tap` | ipa | S5c |  | **ipa**: `/tap/` → `/tæp/` |
| `tape` | ipa | S5c |  | **ipa**: `/tap/` → `/teɪp/` |
| `tart` | ipa | S5b·S5c |  | **ipa**: `/tɑːr/` → `/tɑːt/ (UK) or /tɑːrt/ (US)` |
| `tartuffe` | ipa | S5b |  | **ipa**: `/tɑːr/` → `/tɑːˈtʊf/ (UK) or /tɑːrˈtʊf/ (US)` |
| `text` | ipa | S5a |  | **ipa**: `/ˈtekst ˌmesɪdʒ/` → `/tekst/` |
| `th` | ipa | S5b |  | **ipa**: `/pɑːθ/` → `/θ/` |
| `traffic` | ipa | S5a |  | **ipa**: `/ˈtræfɪk ˌlaɪt/` → `/ˈtræfɪk/` |
| `tropical` | ipa | S5b |  | **ipa**: `/ˈtrɒpɪk/` → `/ˈtrɒpɪkəl/ (UK) or /ˈtrɑːpɪkəl/ (US)` |
| `vice` | ipa | S5a |  | **ipa**: `/ˌvaɪs ˈprezɪdənt/` → `/vaɪs/` |
| `virtual` | ipa | S5a |  | **ipa**: `/ˌvɜːtʃuəl riˈæləti/` → `/ˈvɜːtʃuəl/` |
| `web` | ipa | S5a |  | **ipa**: `/ˈwɛb peɪdʒ/` → `/web/` |
| `whigs` | ipa | S5c |  | **ipa**: `/wɪɡ/` → `/wɪɡz/` |
| `yugoslavia` | ipa | S5b |  | **ipa**: `/ˈjuːɡəʊslɑːv/` → `/ˌjuːɡəˈslɑːviə/` |

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
| v6 产出的例句「不含该词」 | 2（多为判据残余误差：缩写带点 / 不规则变形） |

需人眼确认的 v6 例句：
- `marshall`: "The marshal led the parade through the city streets."
- `th`: "She finished fourth in the race, just missing a medal."

---

*本报告**只生成候选，未写 `word.db`**。写库由 `scripts/apply_card_field_fixes.py` 执行（需单独批准）。*

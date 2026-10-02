
## Gemini 4 Argon Wins 12 of 18 Benchmarks\. Code Isn't One\.

Google just dropped [Gemini 4 Argon](https://blog.google/innovation-and-ai/models-and-research/gemini-models/gemini-4-argon/), and the numbers are hard to argue with\. The model leads 12 of 18 published benchmarks against GPT-6 Astra and Claude Opus 5\.5 -- scoring 77\.9% on DeepSWE v1\.1, 91\.7% on LVBench video understanding, and landing the number one slot on LMArena Text Arena with 1,525 points\. It ships a 1-million-token output window \(up from 64K\), hallucinates at a 15% rate where Astra hits 51%, and during its introductory period costs one-fifth what GPT-6 Astra charges\.

> 📖 [Read the full version with charts and embedded sources on ComputeLeap →](https://www.computeleap.com/blog/gemini-4-argon-benchmarks-not-code)

But there is one column where Argon quietly underperforms: code\. On [Code Arena WebDev](https://the-decoder.com/google-gemini-4-argon-closes-the-gap-with-openai-and-anthropic-but-doesnt-take-a-clear-lead/), it ranks 8th with 1,679 points -- trailing GPT-6\.1 Sol \(3rd, 1,759\) by 80 points\. On FrontierSWE v2, it scores 55\.0% against Astra's 65\.5%\. On Terminal-bench 4\.0, it finishes last among frontier models at 57\.4%, nine points behind Claude Opus 5\.5\.

That is not a bug\. That is a strategy\.

## The Benchmark Sweep: Where Argon Dominates

The raw numbers paint an impressive picture\. Here is how Argon stacks up against the other two frontier heavyweights across [the benchmarks Google published](https://venturebeat.com/technology/google-unveils-gemini-4-argon-retaking-benchmark-lead-over-openai-and-anthropic-but-in-limited-release):


| Benchmark | Argon | GPT-6 Astra | Claude Opus 5\.5 | Winner |
| --------- | ----- | ----------- | ---------------- | ------ |
| DeepSWE v1\.1 | **77\.9%** | 74\.1% | 74\.2% | Argon |
| AutomationBench-AA | **77\.5%** | 41\.4% | 42\.5% | Argon |
| GraphWalks | **84\.2%** | 71\.8% | 66\.8% | Argon |
| LVBench \(video\) | **91\.7%** | 87\.5% | 83\.7% | Argon |
| Vals Finance Agent v2 | **65\.4%** | 53\.5% | 58\.6% | Argon |
| Harvey Legal Agent | **19\.6%** | 5\.4% | 3\.8% | Argon |
| CWE-bench v1 | 68% | **68%** | 67% | Tied |
| FrontierSWE v2 | 55\.0% | **65\.5%** | 62\.1% | Astra |
| Terminal-bench 4\.0 | 57\.4% | 62\.1% | **66\.4%** | Opus 5\.5 |
| Code Arena WebDev | \#8 \(1679\) | - | - | Sol \#3 |

The pattern is clear\. On reasoning-heavy, knowledge-intensive, and multimodal benchmarks, Argon wins decisively\. On AutomationBench -- which tests end-to-end business function execution -- it outscores both competitors by 35\+ percentage points\. On GraphWalks, it leads by 12-17 points\. On long video understanding, it is the best model ever tested\.

> **ℹ️** Argon leads the LMArena Text Arena at 1,525 points, 20 points ahead of Claude Opus 4\.6 \(High\) in second\. On the Artificial Analysis Intelligence Index, it scores 53 -- tied with GPT-6 Astra and Claude Fable 5\.1, though Claude Opus 5\.5 still leads at 58\.

But notice what is missing from that top cluster: from-scratch software engineering\.

*[View full article on VentureBeat →](https://venturebeat.com/technology/google-unveils-gemini-4-argon-retaking-benchmark-lead-over-openai-and-anthropic-but-in-limited-release)*

## The Coding Gap Nobody at Google Is Talking About

Code Arena WebDev is the benchmark that matters most to the developers actually reading this\. It tests whether a model can build a real web application from a prompt -- not solve an isolated coding puzzle, but produce a working project\. Argon lands in [8th place with 1,679 points](https://the-decoder.com/google-gemini-4-argon-closes-the-gap-with-openai-and-anthropic-but-doesnt-take-a-clear-lead/), a 96-point improvement over Gemini 3\.8 Flash \(which sat at 29th\), but still trailing the leaders by a meaningful margin\.

The gap shows up elsewhere too:

- **FrontierSWE v2**: Argon scores 55\.0% against Astra's 65\.5% -- a 10\.5 percentage point deficit on from-scratch project construction
- **Terminal-bench 4\.0**: Argon finishes last among frontier models at 57\.4%, nine points behind Opus 5\.5 \(66\.4%\)
- **Terminal-bench Science 0\.1**: Argon hits 57\.6% while Astra reaches 68\.1%

This is not a minor variance\. On the benchmarks that matter most to working developers -- building software end-to-end -- Argon consistently trails by 9-10 points\.

*[View original post on X →](https://x.com/cHHillee/status/2096327109618868333)*

> **⚠️ Contrarian Corner:** Google chose to publish 18 benchmarks, and Argon happens to lead on the 12 they selected\. As AI researcher Horace He \(@cHHillee\) noted, \"Everyone knows that labs can benchmaxx: optimize the model to look good on the leaderboard\. Sometimes forgotten is that benchmarks can benchmaxx-maxx: optimize the benchmark to make its leaderboard look good\.\" The benchmarks where Argon struggles -- the ones closest to what developers actually do -- are worth watching more closely than the ones it wins\.

## The 1-Million-Token Output Window: Impressive, but Expensive

Argon's headline feature beyond benchmarks is its industry-first 1-million-token output capability\. Previous models capped at 64K output tokens\. Argon can now produce responses 15x longer, using a \"Long Decode Continuation\" API that pauses and resumes across calls\.

The internal examples are legitimately impressive: processing 800K\+ lines of the Fuchsia Zircon kernel, replacing 32,000 lines of SIMD code in the libgav1 video decoder \(resulting in a 2\.7x speed improvement\), and identifying memory optimizations projected to free 300\+ TiB across Google data centers\.

But there is a hidden cost\.

[Analysis from The Decoder and Artificial Analysis](https://the-decoder.com/google-gemini-4-argon-closes-the-gap-with-openai-and-anthropic-but-doesnt-take-a-clear-lead/) reveals that Argon averages **62,000 output tokens per task** compared to GPT-6 Astra's 27,000\. That is 2\.3x more tokens consumed per task\. At introductory pricing \($2/$10 per 1M tokens\), Argon costs $1\.99 per Intelligence Index task versus Astra's $3\.26 -- a genuine savings\. But at regular pricing \($4/$20\), that advantage narrows significantly\. And the token verbosity raises a question: is Argon genuinely reasoning deeper, or is it just more verbose?

## The Pricing Play: Undercutting on Cost, Not Efficiency

Google's pricing strategy is aggressive and deliberate:


| Model | Input/1M | Output/1M | Cache Read/1M |
| ----- | -------- | --------- | ------------- |
| Argon \(intro\) | $2 | $10 | $0\.10 |
| Argon \(regular\) | $4 | $20 | $0\.20 |
| Claude Opus 5\.5 | $4 | $20 | $0\.20 |
| GPT-6 Astra | $10 | $50 | $1\.00 |

At promotional rates, Argon is one-fifth the price of Astra and half the price of Opus 5\.5\. The 95% cache read discount \($0\.10 vs\. $0\.20 for Opus\) makes it particularly attractive for workloads with heavy context reuse\.

But this is sticker-price competition, not efficiency competition\. When you factor in Argon's 2\.3x token consumption per task, the real-world cost comparison tightens\. A developer running 1,000 tasks would pay roughly $1,990 with Argon versus $3,260 with Astra -- but at regular pricing, the gap closes to roughly $3,980 versus $3,260, actually making Astra cheaper per task\.

> **💡 For practitioners:** if your workload involves long-context analysis, document processing, or agentic knowledge work, Argon's promotional pricing is a genuine bargain\. But if you are running high-volume coding tasks, the per-task economics favor Claude or Astra due to Argon's higher token consumption\.

## The Hallucination Tradeoff Nobody Mentions

Argon's hallucination rate is outstanding: 15% on the AA-Omniscience benchmark, compared to GPT-6 Astra's 51%\. That is 3\.4x better\. On the Gray Swan indirect prompt-injection test, attacks succeed against Argon just 0\.7% of the time, versus 1\.0% for Opus 5\.5 and 8\.5% for Astra\.

But [Latent Space's analysis](https://www.latent.space/p/ainews-gemini-4-argon-gdms-answer) spotted an important tradeoff: Argon's accuracy on the same AA-Omniscience benchmark is 50%, compared to Astra's 63%\. Argon hallucinates less -- but it also knows less\. It is choosing to say \"I don't know\" more often, which improves the hallucination metric at the cost of overall accuracy\.

*[View full analysis on Latent Space →](https://www.latent.space/p/ainews-gemini-4-argon-gdms-answer)*

That is arguably the right engineering choice for enterprise deployments where a wrong answer is more dangerous than no answer\. But it is worth understanding the mechanism: this is not a model that is both more accurate and less hallucinatory\. It is a model that traded accuracy for reliability\.

## What the Community Is Saying

The [Hacker News thread](https://news.ycombinator.com/item?id=49913571) on Argon's announcement hit 1,592 points with 1,061 comments -- the largest AI model discussion on HN this quarter\. The top comment captures the moment:

> \"The important take away here: the leapfrogging we've seen this year doesn't seem to be a temporary thing\. The famous theory of Dario Amodei was that AI was this winner-takes-all field where the first team to get a head start would never cede ground back\.\"

*[View full discussion on Hacker News →](https://news.ycombinator.com/item?id=49913571)*

The community is split between genuine excitement about the benchmark numbers and skepticism about a model you cannot actually use yet\. Hugging Face's Merve Noyan captured the mood of Google's supporters in two words:

*[View original post on X →](https://x.com/mervenoyann/status/2105405920503103912)*

But one of the most upvoted HN comments points out the elephant in the room: \"Gemini not beating the 'can't release a model' allegations\.\"

The [prediction markets](https://defirate.com/prediction-markets/best-ai-model-odds-this-year/) tell an interesting story too\. Polymarket has Anthropic at 74% to have the best AI model at end of 2026, with Google at just 9\.5%\. The market is not fully buying the benchmark narrative without GA access\.

*[View original post on X →](https://x.com/karpathy/status/2083749667410727319)*

Karpathy's broader observation about LLM evaluation resonates here: \"We're starting to leave the territory where you'd test an LLM by e\.g\. 'create an svg of pelican on a bicycle\.'\" The benchmarks are getting more sophisticated, but the gap between benchmark performance and real-world developer experience remains wide\.

## Google's Strategic Bet: Win Everything Except Code

Step back from the benchmark tables and Argon's positioning becomes clear\. Google is making a deliberate choice about where to compete:

**Win:** Reasoning, knowledge work, multimodal understanding, video, agentic business tasks, hallucination resistance, pricing\.

**Concede:** From-scratch software engineering, terminal-based coding, web app construction\.

This maps directly to what Sundar Pichai said on the Q2 2026 earnings call: Google is \"a bit behind\" in coding and agentic coding, and Gemini 4 was supposed to close that gap\. Argon closes some of it -- the jump from 29th to 8th on Code Arena is real progress -- but the gap to the leaders remains substantial\.

The strategic logic is sound\. Google's competitive advantage is in non-code AI applications: Search, Workspace, Cloud, Android, YouTube\. Making Argon the best model for knowledge work, document understanding, and business automation serves those products\. Code is where Anthropic \(Claude Code, SWE-bench dominance\) and OpenAI \(Codex lineage, developer ecosystem\) have structural advantages Google cannot easily replicate\.

> **ℹ️** Google's internal validation supports this read\. Argon's showcase results -- the Fuchsia kernel migration, the libgav1 rewrite, the data center memory optimization -- are all large-scale code *comprehension* and migration tasks, not greenfield development\. Argon excels at understanding and transforming existing code\. Building new software from scratch is a different capability\.

## The Not-GA Problem

There is a pattern in AI launches: the more impressive the benchmarks, the longer the wait for general availability\. Argon is currently available only through Google's [Fairwind Program](https://blog.google/innovation-and-ai/models-and-research/gemini-models/gemini-4-argon/) for \"trusted cyber defenders\" and is participating in the U\.S\. government's voluntary pre-release access process\.

Google's stated timeline is \"as soon as possible\" for developers, enterprises, and consumers, \"beginning with paid API customers and Google AI Ultra subscribers\.\" No date\. No waitlist\. No API preview\.

This matters for two reasons\. First, benchmarks without access are marketing, not shipping\. The AI industry has learned this lesson repeatedly\. Second, by the time Argon reaches general availability, Anthropic and OpenAI will have had weeks or months to respond\. The [frontier release war](https://www.computeleap.com/blog/48-hour-frontier-release-war-opus-class-benchmarks-2026) moves fast -- a model that is not available is a model that is not competing\.

## What This Means for Builders

Here is the practical guidance:

**If you are building with AI for code generation and software engineering:** Stay with Claude \(Opus 5\.5 or Sonnet 5\.5\) or GPT-6\.1 Sol\. Argon's coding gap is real and measurable\. The [best coding assistants](https://www.computeleap.com/blog/best-ai-coding-assistants-compared-2026) remain Anthropic and OpenAI models\. Do not migrate your coding pipeline based on Argon's benchmark wins in other categories\.

**If you are building knowledge-work applications, RAG systems, or document processing:** Argon is the model to watch\. Its benchmark leads on AutomationBench \(77\.5%\), GraphWalks \(84\.2%\), and the finance/legal agent tasks are substantial\. When it reaches GA with promotional pricing, it will be the cost-efficiency leader for these workloads\.

**If you are building with long video or multimodal inputs:** Argon at 91\.7% LVBench is meaningfully ahead\. Its 1M output token window opens use cases that were previously impossible in a single inference call\.

**If hallucination risk is your primary concern:** Argon's 15% vs\. Astra's 51% on AA-Omniscience is the most dramatic gap in the entire benchmark table\. For enterprise deployments where wrong answers carry real cost -- legal, medical, financial -- this alone could justify switching\. But verify the accuracy tradeoff for your specific use case first\.

**For everyone:** do not make decisions based on benchmarks of a model you cannot access\. Wait for GA, run your own evals, and compare on the tasks that matter to your product\. The [prediction markets](https://www.computeleap.com/blog/claude-opus-5-5-price-cut-polymarket-money-moved-2026) are pricing in uncertainty for a reason\.

## The Bottom Line

Gemini 4 Argon is Google's strongest model ever and a genuine frontier contender\. Its benchmark sweep across reasoning, knowledge work, and multimodal tasks is not hype -- the numbers are real, and across multiple independent benchmarks, Argon leads\.

But the two things that matter most to the developer community reading this -- writing code and actually using the model -- are exactly where Argon falls short\. 8th in Code Arena\. Not generally available\.

Google has built an exceptional intelligence engine\. The question is whether intelligence without code fluency, and benchmarks without access, are enough to shift the market\. Polymarket says probably not\. But with pricing at half of Opus and one-fifth of Astra, the moment Argon goes GA, it will be impossible to ignore for non-code workloads\.

The frontier just got a third serious contender\. But the race has three lanes now, and Google picked the two that are not code\.

*Originally published at [ComputeLeap](https://www.computeleap.com/blog/gemini-4-argon-benchmarks-not-code)*
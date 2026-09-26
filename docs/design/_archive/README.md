# 归档文档（历史快照 · 勿作现行依据）

> **现行文档请看上一级目录** → `docs/design/README.md`（文档地图）

## 为什么保留

这些文档**含有当时的实测数据与推理过程** —— 例如：

- iTunes Search API 扫描 1342 个中国区 App 的原始结果
- 广告聚合平台的官方 FAQ 原文与选型对比
- 判例检索（自动续费提醒被判「难谓显著」）
- 成本核算的完整算式

删掉会**丢失可复查性**（日后想验证某个数字怎么来的就查不到了）。

## 归档规则

| 规则 | 说明 |
|---|---|
| **单向引用** | 核心文档可以引用归档文档（路径带 `_archive/`）；**归档文档内部引用保持历史原貌，不同步更新** |
| **必须带状态横幅** | 每份归档文档顶部都有 `⛔` / `⚠️` 状态说明，写清「哪里作废、现行是什么」 |
| **不参与一致性检查** | 归档文档是历史快照，与现行文档的差异**不是矛盾** |

## 清单

| 文档 | 作废/过期原因 | 现行替代 |
|---|---|---|
| `ad-monetization-and-flutter-assessment-2026-09-25.md` | 取消费广告变现（个人主体平台层走不通） | `subscription-model-assessment` |
| `membership-benefits-plan-2026-09-25.md` | 第 2 版（广告 + 会员去广告） | 同上 |
| `paid-app-model-assessment-2026-09-25.md` | 第 3 版（¥38 一次性买断） | 同上 |
| `overseas-ad-platform-assessment-2026-09-25.md` | 路径 C 作废（产品与市场不匹配） | 主方案 §1.5.4c |
| `article-vocab-count-design-2026-09-25.md` | 「N 个生词」功能已否决 | `word-database-design` + `cefrj-license-and-lemmatization` |
| `visual-direction-exploration-2026-09-25.md` / `.html` | 框架被修正（「三选一」→「三档全做」） | `design-system-spec` |
| `visual-clay-direction-2026-09-25.html` | 早期方向稿 | `visual-clay-spec-2026-09-25.html` |
| `android-platform-impact-2026-09-25.md` | Android 暂时放弃 | 保留供未来重启 |

## ⚠️ 仍然有效的部分

归档 ≠ 全部无效。以下内容**依然可参考**：

| 文档 | 仍有效的部分 |
|---|---|
| `ad-monetization-and-flutter-assessment` | 聚合平台的官方规则原文、`gtads` 只是封装层这一纠正 |
| `paid-app-model-assessment` | 国务院令 810 号的角色定义（Apple = 平台企业）、ICP 备案 vs APP 备案的区分、税务定性 |
| `overseas-ad-platform-assessment` | AdMob 的技术事实（注册地不可更改、要求已上架、W-8BEN） |
| `ios-only-personal-entity…`（**未归档**，仍在上一级） | 「个人 + 中国区 + 变现」三层论证 —— 主方案直接依赖它 |
| `android-platform-impact` | 未来做 Android 时的资质清单与时间线 |

---

*归档时间：2026-09-25*

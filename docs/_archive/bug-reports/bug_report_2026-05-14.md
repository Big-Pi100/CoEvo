# CoEvo 完整数据流分析 + Bug 报告
## 日期：2026-05-14

---

## 一、系统数据流总览

```
┌──────────────────────────────────────────────────────────┐
│                    客户端 (Android/Mobile)                 │
└──────────┬──────────────────────────┬────────────────────┘
           │ WebSocket /ws            │ REST POST /api/chat
           ▼                          ▼
┌──────────────────────┐   ┌──────────────────────┐
│   ws::handle_ws()    │   │ routes::chat_handler  │
│  (HotPath + ColdPath)│   │  (同步, 无流式)       │
└──────────┬───────────┘   └──────────┬───────────┘
           │                          │
           ▼                          ▼
┌──────────────────────────────────────────────────────────┐
│                    LLM Caller (DeepSeek/Qwen)              │
│   stream_generate() — 流式SSE  │  generate() — 非流式     │
└──────────┬──────────────────────┬─────────────────────────┘
           │                      │
           ▼                      ▼
┌──────────────────────┐  ┌──────────────────────────┐
│  概念提取器 (ColdPath)│  │  概念提取器 (同步后置)    │
│  extract_concepts()  │  │  extract_concepts()      │
│  + word_bank 匹配    │  │  + word_bank 匹配        │
└──────────┬───────────┘  └──────────┬───────────────┘
           │                         │
           ▼                         ▼
┌──────────────────────────────────────────────────────────┐
│              Card Engine → FSRS Scheduler                 │
│         (制卡入库 / 复习调度 / streak 管理)               │
└──────────────────────────────────────────────────────────┘
```

## 二、核心双通道设计 (ws.rs)

| 通道 | 职责 | 关键约束 |
|------|------|---------|
| **HotPath** | LLM 流式回复 → 解析 plan_update → 保存 DB → 发 `done` | 主循环 select! 的分支，不阻塞消息接收 |
| **ColdPath** | `tokio::spawn` 后台概念提取 → `mpsc::channel` 回传结果 | 按 `BTreeMap<turn, candidates>` 有序输出 |

## 三、Bug 清单

### 🔴 Critical (4个)

#### Bug 1 — ColdPath 失败导致候选结果永久阻塞
**文件**: `ws.rs` lines 449-468, 487-499  
**症状**: 如果 ColdPath 任务中任何一个 DB 查询失败（`conn.prepare` 返回 `Err`），代码执行 `return` 退出 async block，**不向 `cold_tx` 发送任何消息**。`BTreeMap` 中该 turn 永远缺失，`next_turn_to_show` 永远无法越过这个空洞，所有后续轮次的 candidates 都被阻塞在 `pending_candidates` 中。
**影响**: 一次 ColdPath DB 错误 → 该 WebSocket 连接后续所有概念提取全部卡死。
**修复**: 错误时也向 `cold_tx` 发送空结果 `(cold_turn, vec![])`，让轮次正常推进。

#### Bug 2 — 成就写入存在 TOCTOU 竞态条件
**文件**: `ws.rs` lines 352-393 + lines 549-562  
**症状**: `write_achievement()` 先 `SELECT` 检查存在，再 `INSERT`。两者不在同一事务内。
**影响**: 重复成就插入失败被静默忽略。
**修复**: 使用 `INSERT OR IGNORE` 替代 `SELECT + INSERT`。

#### Bug 3 — REST chat_handler 完全缺失 plan_update 处理
**文件**: `routes.rs` lines 246-278  
**症状**: WebSocket 路径有完整的 `<plan_update>` XML 解析、学习计划创建/更新、成就检测逻辑，但 REST 路径完全没有。
**影响**: REST API 用户无法使用学习计划功能。
**修复**: 将 plan_update 解析逻辑提取为共享函数，REST 和 WS 共用。

#### Bug 4 — `pending_candidates` BTreeMap 无界增长
**文件**: `ws.rs` lines 28, 489  
**症状**: `pending_candidates` 没有容量上限。
**影响**: 长时间运行的 WebSocket 连接可能因内存泄漏崩溃。
**修复**: 添加容量上限（如 100 个 turn），超出后跳过最旧的未完成 turn。

### 🟡 Medium (5个)

#### Bug 5 — ColdPath 无超时/健康检查机制
**文件**: `ws.rs` lines 445-483  
**修复**: 用 `tokio::time::timeout` 包裹 `extract_concepts` 调用。

#### Bug 6 — plan_update 匹配过于宽泛
**文件**: `ws.rs` line 258  
**修复**: 检查是否在 markdown 代码块外。

#### Bug 7 — db_pool::get_conn() panic 风险
**文件**: `db_pool.rs` line 57  
**修复**: 增加超时时间到 10 秒。

#### Bug 8 — 订阅检查基于字符串日期比较
**文件**: `ws.rs` lines 89-93  
**修复**: 改用 timestamp 比较。

#### Bug 9 — concept_extractor 每次 ColdPath 额外 LLM 调用
**文件**: `concept_extractor.rs` lines 83-106  
**修复**: 将 word_bank LLM 调用设为可配置，允许跳过。

### 🟢 Low (3个)

#### Bug 10 — `tx` sender 未显式 drop
**文件**: `ws.rs` lines 122, 213  
**修复**: 在 clone 后显式 `drop(tx)`。

#### Bug 11 — final_reply 在 plan_update 解析期间被多次突变
**文件**: `ws.rs` lines 265, 296, 400, 404  
**修复**: 重构为单一赋值点。

#### Bug 12 — verify_token_no_db 是安全漏洞
**文件**: `auth.rs` lines 124-126  
**修复**: 删除此函数。

## 四、修复优先级

| 优先级 | Bug | 修复工作量 | 风险 |
|--------|-----|-----------|------|
| P0 | Bug 1 — ColdPath 失败阻塞 | 小 | 高 |
| P0 | Bug 2 — 成就竞态 | 小 | 中 |
| P1 | Bug 4 — BTreeMap 内存泄漏 | 小 | 中 |
| P1 | Bug 3 — REST 缺失 plan_update | 中 | 中 |
| P2 | Bug 5 — ColdPath 无超时 | 小 | 中 |
| P2 | Bug 7 — db_pool panic | 小 | 低 |
| P2 | Bug 12 — 删除不安全函数 | 小 | 低 |
| P3 | Bug 6/8/9/10/11 | 小 | 低 |

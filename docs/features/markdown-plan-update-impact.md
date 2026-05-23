# Markdown 渲染对 `<plan_update>` 解析的影响评估

> 日期: 2026-05-17

---

## 结论：零影响 ✅

**Markdown 前端渲染不影响 `<plan_update>` 的解析**。两者运行在不同层：

```
┌─ 后端 ─────────────────────────────────────────┐
│                                                  │
│  LLM 原始回复                                     │
│    │                                              │
│    ├─ handle_plan_update()                        │
│    │    ├─ 查找 <plan_update>...</plan_update>    │
│    │    ├─ 提取 JSON → 更新 DB                     │
│    │    └─ 删除 plan_update 块 → 返回 cleaned_reply │
│    │                                              │
│    └─ cleaned_reply (不含 plan_update 标签)        │
│         │                                         │
│         ▼ 通过 WS 发送到前端                        │
└──────────────────────────────────────────────────┘
          │
          ▼
┌─ 前端 ─────────────────────────────────────────┐
│                                                  │
│  cleaned_reply (纯 Markdown + 公式 + <graph>)     │
│    │                                              │
│    └─ ChatMessageBubble → Markdown 渲染            │
│         ├─ ### 标题 → 渲染为标题                   │
│         ├─ **粗体** → 渲染为粗体                    │
│         ├─ \(公式\) → 渲染为 LaTeX                  │
│         └─ <graph>JSON</graph> → 渲染为图表        │
│                                                  │
└──────────────────────────────────────────────────┘
```

---

## 逐点验证

### 1. `<plan_update>` 到达前端前已被剥离

`plan_handler.rs:46`：
```rust
final_reply.replace_range(start..block_start + end + 14, "");
```

`cleaned_reply` 中 `<plan_update>` 整个块被删除。前端永远不会看到这个标签。

### 2. 计划渲染输出是纯 Markdown

`render_plan()` (plan_handler.rs:526) 输出的内容格式：

```markdown
好的！我来为你制定一个学习计划 📋

**目标：一元二次方程**

### 🔄 阶段一：基础巩固
- 🔄 **任务1.1：完全平方公式**
  掌握 (a±b)² 的展开

### ✅ 阶段二：配方法
- ✅ **任务2.1：系数为1的配方**
```

这正是 Markdown 渲染器原生支持的格式，无需任何特殊处理。

### 3. `<plan_update>` 与 `<graph>` 无冲突

两者是不同的标签，由不同模块处理：
- `<plan_update>` → 后端 `handle_plan_update` 解析 → 剥离
- `<graph>` → 前端 `ChatMessageBubble` 解析 → 渲染

不存在同层竞争；即使 LLM 在同一回复中同时输出两者，也互不干扰。

### 4. Markdown 代码块内的 `<plan_update>` 会被错误解析吗？

**会，但这是现有行为，非 Markdown 渲染引入的新问题。**

如果 LLM 在代码块内嵌入 `<plan_update>`：
```
```json
<plan_update>
{"is_new_plan": true}
</plan_update>
```
```

`handle_plan_update` 的查找逻辑是纯文本匹配 `find("<plan_update")`，不感知 Markdown 上下文。会错误地将代码块内的标签当作真实的计划更新来解析。

**但这与 Markdown 前端渲染无关** — `handle_plan_update` 运行在渲染之前，且 LLM 在实际使用中不会在代码块内输出 plan_update（测试和双智能体对话验证均未出现此情况）。

### 5. `plan_context` 注入的 Markdown 兼容性

`build_plan_context()` 输出的 `plan_context` 格式：

```
### 学习计划
长期目标: 一元二次方程

#### 🔄 阶段一：基础巩固
- 🔄 任务1.1：完全平方公式——掌握 (a±b)² 的展开
-   任务1.2：因式分解复习
```

这是注入到 LLM system prompt 中的，不经过前端渲染。**不受影响**。

---

## 总结

| 检查项 | 状态 |
|--------|:--:|
| `<plan_update>` 后端剥离时机 | 在 Markdown 渲染之前 ✅ |
| `render_plan()` 输出格式 | 原生 Markdown ✅ |
| `<graph>` 与 `<plan_update>` 标签冲突 | 不同层处理 ✅ |
| `plan_context` 注入兼容性 | 不经过前端 ✅ |
| 代码块内误解析 | 现有行为，非新问题 |
| **综合评价** | **零影响，放心实施** |

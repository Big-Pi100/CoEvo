# Prompt 架构重构：signal/format 拆分交付报告

**日期**: 2026-06-13
**涉及文件**: 21 个 format 共享模板 + 28 组 signal/format 拆分文件 + prompt_loader.rs + ws.rs + Cargo.toml

---

## 交付内容

### 1. 共享格式池 `prompts/format/`
21 个可复用的格式模板，按用途组织：

| 类别 | 文件 | 用途 |
|------|------|------|
| `shared/` | `json-only.md`, `json-array.md`, `pass-fail.md` | 最通用的输出格式指令 |
| `chat/` | `graph.md`, `latex.md`, `plan-marker.md` | `<graph>`渲染、LaTeX公式、学习计划创建标记 |
| `plan/` | `creation.md`, `analysis.md`, `signal.md` | 学习计划各阶段的JSON schema |
| `quiz/` | `generate.md`, `judge.md`, `grill.md` | 考核各环节的输出格式 |
| `concept/` | `general.md`, `science.md`, `language.md`, `literature.md`, `humanities.md`, `direct.md` | 各领域卡片字段schema |
| `verify/` | `translation.md`, `usage.md` | 翻译验证和用法验证的输出格式 |
| `routing/` | `subject.md` | 学科路由JSON |

### 2. 新增 signal/format 拆分文件（28 组）

| 分类 | 已有 signal/format 的科目 |
|------|--------------------------|
| chat | `general`(free+structured), `math`, `chemistry` |
| concept | `general`, `science`, `language`, `literature`, `humanities` (extract+direct) |
| plan/general | `creation`, `analysis`, `signal` |
| quiz/general | `generate`, `judge`, `grill` |
| verify/general | `translation`, `usage` |
| routing/general | `subject` |

### 3. Rust 代码变更

**`prompt_loader.rs`**（核心变更）：
- 新增 `resolve_includes()` — 递归展开 `{include:format/xxx/yyy.md}` 引用
- 新增 `read_signal_or_flat()` — 优先加载 `signal/{type}.md + format/{type}.md`，合并后返回；失败则回退到旧式 `{type}.md`
- 所有 `load_*_dir()` 和 `load_*_dir_with_fallback()` 函数已更新为新逻辑
- `scan_subject_dirs()` 改用 `Path::join` 确保跨平台路径正确
- `init()` 使用绝对路径而非 `canonicalize()` 避免 Windows 路径混用
- `VerifyTemplates` 新增 `usage` 字段

**`ws.rs`**（最小变更）：
- `verify_usage` 加载从 `std::fs::read_to_string("prompts/verify/verify_usage.md")` 改为 `get_verify("general").usage`

**`Cargo.toml`**：
- chat_engine 新增 `regex = "1"` 依赖

### 4. 已删除的旧文件（18 个，被 signal/format 替代）
```
plan/general/{creation,analysis,signal}.md
quiz/general/{generate,judge,grill}.md
concept/general/{extract,direct}.md
concept/{science,language,literature,humanities}/extract.md
chat/general/{free,structured}.md
chat/{math,chemistry}/structured.md
verify/verify_usage.md
verify/general/translation.md
routing/general/subject.md
```

---

## 测试结果

| 测试范围 | 结果 |
|---------|------|
| `cargo check` (全 workspace) | ✅ 零 error 零 warning |
| `cargo test -p chat_engine` prompt_loader (9 tests) | ✅ 全部通过 |
| `cargo test --workspace --lib` (共 54 tests) | ✅ 全部通过 |
| `cargo test --workspace` (含集成测试) | ✅ 28+17+9+9 tests 全部通过 |
| e2e 测试 (需 LLM API) | ⏭️ 被忽略（与变更无关） |

---

## 架构设计要点

### 加载流程
```
init("prompts") 
  → scan_subject_dirs("chat")
    → for general/: load_chat_dir
      → read_signal_or_flat("chat/general", "free", "prompts", "")
        → 1. 尝试 chat/general/signal/free.md + format/free.md
        → 2. 解析 signal 和 format 中的 {include:...} 引用
        → 3. 合并为 "signal\n\nformat" 字符串
        → 4. 存储到 ChatTemplates.free
    → for math/: load_chat_dir_with_fallback(..., &general)
      → math/signal/free.md → 有 → 用 math 的
      → math/signal/grill.md → 无 → math/grill.md → 无 → fallback 到 general
```

### 引用语法
- `{include:format/quiz/generate.md}` — 从 `prompts/format/quiz/generate.md` 读取并嵌入
- 支持递归嵌套（include 中的 include）
- 在 `init()` 时一次性解析完毕，运行时零开销

### 后向兼容
- 未创建 signal/format 子目录的科目（如 art, biology, 所有 reading 等）仍使用旧式 flat 文件
- 无 flat 文件的科目自动 fallback 到 general 的 signal/format
- 所有公共 API (`get_chat()`, `get_concept()`, `get_plan()`, `get_quiz()`, `get_verify()`, `get_routing()`) 签名不变

---

## 下一步建议

1. **迁移剩余科目**：逐步将 art/biology/geography 等 10 个科目的 duplicate `structured.md` 删除，让它们 fallback 到 general 的 signal/format
2. **迁移 reading prompts**：`chinese/reading-*.md`、`japanese/reading-*.md` 等包含大量重叠内容，可提取共享 format
3. **管理后台**：配合 `config_admin.rs` 的 prompt 模板编辑 API 使用

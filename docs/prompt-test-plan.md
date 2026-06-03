# Prompt 测试规划

> 2026-06-02 | 基于 prompts/ 目录结构

---

## 目录结构

```
prompts/
├── chat/ (17 科目)  ← 5 文件: free, structured, reading, reading-nursery, reading-primary, reading-secondary
├── concept/ (17)    ← 2 文件: extract, direct
├── plan/ (1)        ← 3 文件: creation, analysis, signal
├── quiz/ (17)       ← 3 文件: generate, grill, judge
├── routing/ (1)     ← 1 文件: subject
├── test/ (1)        ← 1 文件: student
└── verify/ (1)      ← 1 文件: translation
```

## 建议的测试

| 测试文件 | 测试目标 | 覆盖 prompt | 每轮 LLM 调用 |
|---------|---------|------------|-------------|
| `e2e_prompt_concept.rs` | CP1 概念提取精准率/召回率 | concept/extract.md | 学生1 + 教师1 + CP1 提取1 = 3 |
| `e2e_prompt_signal.rs` | CP2 信号检测 | plan/signal.md | 教师1 + CP2 检测1 = 2 |
| `e2e_prompt_plan.rs` | CP2 计划创建 + 分析 | plan/creation.md + analysis.md | 教师1 + CP2 创建1 + CP2 分析1 = 3 |
| `e2e_prompt_chat.rs` | 教师对话风格 + 教学 | chat/{free,structured,reading}.md | 学生1 + 教师1 = 2 |
| `e2e_prompt_quiz.rs` | 出题质量 + 判题 | quiz/{generate,judge}.md | 教师1 + 出题1 + 判题1 = 3 |
| `e2e_prompt_verify.rs` | 复习验证 | verify/translation.md | 验证1 = 1 |

## 测试模式

每个测试：
1. 建立最小 DB（用户 + 会话 + 预制对话历史）
2. 调用目标 prompt 对应的 LLM
3. 断言输出格式正确、内容合理
4. 输出质量报告（JSON）

示例（`e2e_prompt_concept`）：
```
1. 插入教师回复 "勾股定理是..."
2. 调用 extract_concepts() 
3. 断言 candidates 非空
4. 检查 front/back/source_sentence 格式
5. 记录精准率/召回率基线
```

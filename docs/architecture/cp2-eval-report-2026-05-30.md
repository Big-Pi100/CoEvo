# CP2 重构评估报告

**日期**: 2026-05-30  
**版本**: Production Hotfix 4 (CP2 per-round detection + 3 bug fixes)  
**测试模式**: 语文 g1-2 阅读教学（双智能体）

---

## TL;DR

CP2 进度检测从"每 5 轮"改为"每轮"，输入从 20 轮对话历史改为单轮教师回复。  
3 个生产 Bug 被修复（UTF-8 切片 panic / task_status 未注入 / stage 状态默认值）。  
修复后 CP2 能正确检测教师完成信号并推进学习计划。

---

## 变更内容

### 架构变化

```
之前:
  用户 → Teacher LLM → final_reply → HotPath(XML标签) → 成功则更新
                                    → CP2(每5轮,20轮历史,独立LLM) → 兜底

现在:
  用户 → Teacher LLM → final_reply → HotPath(XML标签) → 成功则更新、跳过CP2
                                    → CP2(每轮,单轮final_reply,轻量LLM) → 兜底
```

### 核心改动

| 文件 | 改动 |
|:---|:---|
| `plan_handler.rs` | 新增 `analyze_turn_progress()` — 单轮 LLM 分析 |
| `plan_handler.rs` | `build_plan_context()` — reading 模式追加"下一课"名 |
| `plan_handler.rs` | `apply_plan_mutations()` — 注入 task_status 到 task |
| `plan_handler.rs` | `apply_plan_mutations()` — stage 状态默认 pending |
| `ws.rs` | CP2 触发从间隔检测改为每轮检测 |

---

## 生产 Bug 修复

### Bug 1: UTF-8 字节切片 Panic

**症状**: `final_reply[..final_reply.len().min(80)]` 在中文文本中 panic  
**原因**: 中文字符 3 字节，`min(80)` 在第 80 字节处落在一个字符中间  
**修复**: 改用 `final_reply.chars().take(80).collect::<String>()`  
**影响**: CP2 后台任务崩溃，后续所有检测失效

### Bug 2: `plan_content` 的 task 无 status 字段

**症状**: `apply_plan_mutations` 找不到 "in_progress" 任务，计划永不推进  
**原因**: `plan_content` 的 task JSON 没有 `status` 字段（状态只存在 `plan_json.task_status` 中）  
**修复**: 在 `apply_plan_mutations` 中注入 `task_status` 到每个 task 对象  
**影响**: 即使 CP2 正确检测到完成信号，计划也无法更新

### Bug 3: stage 也无 status 字段

**症状**: 修复 Bug 2 后仍不推进——`stage["status"] == "in_progress"` 返回 false  
**原因**: stage JSON 同样没有 `status` 字段，默认返回 `Value::Null`  
**修复**: 用 `stage["status"].as_str().unwrap_or("pending")` 做默认值

---

## CP2 检测验证

### 日志样本（生产环境）

```
CP2 complete_task: reason=教师明确说'这一课《我是中国人》——你学成啦！'并引出下一课内容
CP2 complete_task: reason=教师明确表示'这一课你已经学成啦！'并引出下一课内容
CP2 complete_task: reason=教师说'全对通过'并引出下一课，表示当前任务已完成
CP2 complete_task: reason=教师用'对啦'表示肯定，并引出下一个学习内容
CP2 complete_task: reason=教师做了总结性陈述并引出下一个学习内容
```

### 计划推进验证（最终测试）

```
Stage1: 2完成 1进行中 1待办
完成: ['我是中国人', '我爱我们的祖国']
进行中: ['我是小学生']
```

CP2 正确检测完成信号 → 调用 handle_plan_update → 写入 plan_json → 推进任务。

---

## 教学评估

### 教师 LLM 教学水平

**评分: 9.5/10**

| 维度 | 评分 | 说明 |
|:---|:---:|:---|
| 课堂节奏 | 10/10 | 拍手、踏脚、身体动作引导，节奏感强 |
| 鼓励机制 | 10/10 | 小红花、掌声、竖大拇指、"太棒啦！" |
| 教学内容 | 9/10 | 从《我是中国人》到《我爱我们的祖国》连贯递进 |
| 适龄性 | 10/10 | 短句、重复、动作指令，完美适合 g1-2 |
| 考核设计 | 9/10 | 跟读→复述→完整背诵→考核，循序渐进 |

**教学风格**: 儿歌教学 + 身体律动 + 形象比喻  
**示例**: "长江像大波浪，黄河像弯弯的龙" → 视觉化 + 动作化

### 学生模拟质量

**评分: 8/10**

| 维度 | 评分 | 说明 |
|:---|:---:|:---|
| 语气自然度 | 9/10 | "老师老师！"、"棒不棒？" 语气贴近低年级 |
| 互动参与 | 8/10 | 会跟着老师拍手、做动作 |
| 知识理解 | 8/10 | 能复述课文内容并用比喻理解 |
| 自主性 | 7/10 | 有时过于主动背诵（现实学生可能更慢） |

### CP2 进度推进评估

| 维度 | 状态 | 说明 |
|:---|:---:|:---:|
| 检测准确性 | ✅ | 正确识别"学完了"、"通过"、"过关"等信号 |
| 检测及时性 | ✅ | 每轮检测，教师完成信号后立即处理 |
| 计划更新 | ✅ | 标记任务 done，激活下一任务 |
| 无计划创建 | ✅ | 初始化后已存在 plan，CP2 正确跳过创建 |
| 误判率 | 低 | 未发现"完成"信号误判（生成本不需要推进的检测） |
| HotPath 冲突 | ✅ | `plan_updated` 守卫机制正常工作 |

---

## 结论

CP2 重构达到预期目标：
1. **每轮检测** —— 消除教学进度空洞期
2. **单轮输入** —— LLM 调用成本降至原来的 1/20
3. **浅显的 teacher 语言也能触发** —— 自然语言信号（"过关啦"、"通过"）稳定触发
4. **3 个生产 Bug 已全部修复** —— UTF-8 切片 / task_status 注入 / stage 默认值
5. **计划推进正常** —— handle_plan_update → apply_plan_mutations → DB 更新链路完整

**下一步建议**:
- 增加 CP2 检测覆盖更多自然语言信号模式
- 考虑对学生模拟增加"不理解"、"答错"等场景
- 监控 production CP2 命中率与计划更新成功率

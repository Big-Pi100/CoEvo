# CoEvo 管线 E2E 测试报告
> 运行 ID: pipeline-20260521_032925 | 2026-05-21 03:31:37

## Phase 1: 计划创建 + 路由测试
| 指标 | 值 |
|------|-----|
| 状态 | ✅ 通过 |
| 耗时 | 37s |
| domain 准确率 | 3/3 |

| domain | 实际 | 期望 | 匹配 | 创建 | stages |
|--------|------|------|:----:|:----:|:------:|
|  | history |  | ✅ | ✅ | ✅ |
| language | language | language | ✅ | ✅ | ✅ |
| math | math | math | ✅ | ✅ | ✅ |

## Phase 2: 计划推进测试
| 指标 | 值 |
|------|-----|
| 状态 | ✅ 通过 |
| 耗时 | 1m34s |
| 对话轮次 | 6 |
| plan_update | 1 次 |
| task_complete | 0 次 |
| stage_advance | 0 次 |
| 学生自动生成 | 6 次 |
| pipeline | history |

---

## 汇总
| 项目 | 值 |
|------|-----|
| LLM 调用次数 | 9 |
| 错误数 | 0 |
| Phase 1 耗时 | 37s |
| Phase 2 耗时 | 1m34s |
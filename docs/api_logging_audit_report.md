# API Endpoint Logging Coverage Audit Report

审计时间: 2026-06-08

## 概览

| 源文件 | 总 Handlers | 有日志 | 无日志 | 覆盖率 |
|:--|:--:|:--:|:--:|:--:|
| `routes.rs` | 39 | 37 | 2 | 94.9% |
| `admin_handlers.rs` | 39 | 0 | 39 | 0% |
| `k12_quiz_api.rs` | 1 | 0 | 1 | 0% |
| **总计** | **79** | **37** | **42** | **46.8%** |

---

## routes.rs — 非 Admin 端点 (39 handlers)

### ✅ 有 `tracing::info!` 日志 (37)

| 端点 | 行号 | 日志内容 |
|:--|:--:|:--|
| `GET /health` | 150 | — (无日志，但可接受) |
| `POST /api/auth/register` | 170 | `auth_register: user_id={}` |
| `POST /api/auth/login` | 199 | `auth_login: user_id={}` |
| `POST /api/auth/verify` | 231 | `auth_verify: user_id={}` |
| `GET /api/review/due` | 255 | `review_due_handler: user_id={}` |
| `POST /api/review/submit` | 292 | `review_submit_handler: user_id={}` |
| `POST /api/review/verify` | 347 | `review_verify_handler: user_id={}` |
| `POST /api/review/judge` | 450 | `review_judge_handler: user_id={}` |
| `PATCH /api/cards/status` | 640 | `cards_status_handler: user_id={}` |
| `PATCH /api/cards/batch-status` | 657 | `cards_batch_status_handler: user_id={}` |
| `GET /api/cards/all` | 697 | `cards_all_handler: user_id={}` |
| `GET /api/cards/by-plan` | 827 | `cards_by_plan_handler: user_id={}` |
| `GET /api/cards/search` | 964 | `cards_search_handler: user_id={}, q={}` |
| `GET /api/cards/{card_id}/last-review` | 1057 | `cards_last_review_handler: card_id={}, user_id={}` |
| `GET /api/history` | 1099 | `history_handler: user_id={}` |
| `DELETE /api/conversations/{conv_id}` | 1202 | `conversation_delete_handler: conv_id={}` |
| `POST /api/conversations/{conv_id}/restore` | 1227 | `conversation_restore_handler: conv_id={}` |
| `DELETE /api/conversations/{conv_id}/permanent` | 1251 | `conversation_permanent_delete_handler: conv_id={}` |
| `GET /api/user/{user_id}/profile` | 1277 | `profile_handler: user_id={}` |
| `PUT /api/user/{user_id}/profile` | 991(ah) | — (在 admin_handlers.rs) |
| `POST /api/user/{user_id}/display-name` | 1606 | `update_display_name_handler: user_id={}` |
| `POST/GET /api/user/{user_id}/avatar` | 1684/1712 | `avatar_upload_handler: user_id={}` / `avatar_get_handler: user_id={}` |
| `GET /api/user/{user_id}/achievements-all` | 1406 | `achievements_all_handler: user_id={}` |
| `GET/PUT /api/user/{user_id}/preferences` | 1629/1648 | `preferences_get_handler: user_id={}` / `preferences_put_handler: user_id={}` |
| `POST /api/user/bind-lookup` | 979(ah) | — (在 admin_handlers.rs) |
| `GET /api/plans` | 1728 | — (无 `tracing::info!`，但有 `eprintln!`) |
| `GET /api/user/{user_id}/learning-report` | 1822 | `learning_report_handler: user_id={}` |
| `GET /api/user/{user_id}/activity` | 1975 | `activity_handler: user_id={}` |
| `GET /api/user/{user_id}/weekly-report` | 2045 | `weekly_report_handler: user_id={}` |
| `POST /api/k12/init` | 2113 | `[K12-INIT] start: user={}, subject={}, grade_band={}` |
| `GET /api/k12/progress` | 2391 | `k12_progress_handler: user_id={}` |
| `GET /api/k12/reading/{conv_id}/current-card` | 2256 | `k12_reading_current_card_handler: user_id={}` |
| `POST /api/verify-translation` | 590 | `verify_translation_handler` |
| `WS /ws` (upgrade) | 672-674 | — (仅升级，WS 内部可能有日志) |

### ❌ 缺少 `tracing::info!` 日志 (2)

| 端点 | 行号 | 严重程度 | 备注 |
|:--|:--:|:--:|:--|
| `GET /api/review/cards-by-progress` | 509 | **中** | 频繁调用的数据查询端点，缺日志难以排查问题 |
| `GET /health` | 150 | **低** | 健康检查，高频自动调用，缺日志可接受 |

---

## admin_handlers.rs — Admin 端点 (39 handlers)

### ❌ 全部缺少 `tracing::info!` 日志 (39/39)

| # | 端点 | 行号 | 严重程度 |
|:--:|:--|:--:|:--:|
| 1 | `POST /api/admin/login` | 114 | **高** | 
| 2 | `POST /api/admin/register` | 139 | 低（已禁用） |
| 3 | `GET /api/admin/dashboard` | 1103 | **中** |
| 4 | `GET /api/admin/users` | 145 | **高** |
| 5 | `GET /api/admin/users/expiring` | 1144 | 低 |
| 6 | `GET /api/admin/users/export` | 1170 | 低 |
| 7 | `POST /api/admin/users/batch-subscription` | 450 | **高** |
| 8 | `GET /api/admin/users/{user_id}` | 221 | **高** |
| 9 | `DELETE /api/admin/users/{user_id}` | 238 | **高** |
| 10 | `DELETE /api/admin/users/{user_id}/hard-delete` | 265 | **高** |
| 11 | `POST /api/admin/users/{user_id}/restore` | 250 | **高** |
| 12 | `POST /api/admin/users/{user_id}/reveal-phone` | 344 | **高**（已有审计日志，缺 tracing） |
| 13 | `PUT /api/admin/users/{user_id}/subscription` | 382 | **高** |
| 14 | `POST /api/admin/users/{user_id}/quick-extend` | 406 | **高** |
| 15 | `POST /api/admin/subscription-requests` | 439 | **高** |
| 16 | `GET /api/admin/subscription-requests` | 466 | 低 |
| 17 | `POST /api/admin/subscription-requests/{req_id}/approve` | 480 | **高** |
| 18 | `POST /api/admin/subscription-requests/{req_id}/reject` | 481 | **高** |
| 19 | `GET /api/admin/admins` | 524 | 低 |
| 20 | `POST /api/admin/admins` | 615 | **高** |
| 21 | `POST /api/admin/admins/{admin_id}/approve` | 545 | **高** |
| 22 | `POST /api/admin/admins/{admin_id}/reject` | 588 | **高** |
| 23 | `POST /api/admin/admins/{admin_id}/password` | 637 | **高** |
| 24 | `PUT /api/admin/admins/{admin_id}/permissions` | 647 | **高** |
| 25 | `DELETE /api/admin/admins/{admin_id}/disable` | 602 | **高** |
| 26 | `POST /api/admin/admins/{admin_id}/enable` | 608 | **高** |
| 27 | `GET /api/admin/audit-log` | 660 | 低 |
| 28 | `GET /api/admin/guardian/students` | 690 | 低 |
| 29 | `GET /api/admin/guardian/students/{student_id}/cards` | 769 | 低 |
| 30 | `GET /api/admin/guardian/students/{student_id}/conversations` | 778 | 低 |
| 31 | `GET /api/admin/guardian/students/{student_id}/conversations/{conv_id}` | 799 | 低 |
| 32 | `GET /api/admin/guardian/students/{student_id}/learning-summary` | 810 | 低 |
| 33 | `POST /api/admin/guardian/bind` | 739 | **高** |
| 34 | `POST /api/admin/guardian/reveal-phone/{admin_id}` | 752 | **高** |
| 35 | `GET/POST /api/admin/guardian/assignments` | 1037/1067 | **中** |
| 36 | `DELETE /api/admin/guardian/assignments/{assignment_id}` | 1095 | **中** |
| 37 | `POST /api/user/{user_id}/profile` (PUT) | 991 | **高** |
| 38 | `POST /api/user/bind-lookup` | 979 | **高**（有限流但无日志） |
| 39 | `GET /api/admin/users/{user_id}` (已有) | 221 | 重复 |

---

## k12_quiz_api.rs

### ❌ 缺少 `tracing::info!` 日志 (1/1)

| 端点 | 行号 | 严重程度 |
|:--|:--:|:--:|
| `POST /api/k12/quiz/submit` | 32 | **高** |

---

## 总结

| 严重等级 | 数量 | 说明 |
|:--:|:--:|:--|
| **高** | ~25 | 管理端增删改查、鉴权操作，缺日志无法追踪异常请求和操作记录 |
| **中** | ~4 | 数据查询端点，缺日志影响调试效率 |
| **低** | ~13 | 只读查询或健康检查，影响较小 |

### 建议修复优先级

1. **P0**: admin_handlers.rs 中所有涉及数据修改和鉴权的 handler（约 25 个），建议在 entry 点加 `tracing::info!("handler_name: param1={}", val1)`
2. **P1**: `review_cards_by_progress_handler` 和 `k12_quiz_api.rs::quiz_submit_handler` 增加 entry 日志
3. **P2**: 其他只读查询型 admin handler 逐步补充

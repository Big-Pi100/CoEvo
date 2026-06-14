# 调试日志 + 配置管理 — 实施完成（含修复补丁）

## 最终状态 ✅ 全部完成

### 后端
| 文件 | 类型 | 状态 |
|------|------|------|
| `debug_logger.rs` | 新增 | ✅ JSONL 文件日志模块 |
| `app_config_cache.rs` | 新增 | ✅ 运行时配置双缓存 |
| `debug_trackers_cache.rs` | 新增 | ✅ 用户跟踪内存缓存 |
| `config_admin.rs` | 新增 | ✅ 8 个 API handler |
| `ws.rs` | 修改 | ✅ 13 处 debug_log 埋点 + app_config 动态读取 |
| `plan_handler.rs` | 修改 | ✅ 2 处 debug_log 埋点 |
| `routes.rs` | 修改 | ✅ 注册所有新路由 |
| `main.rs` | 修改 | ✅ 3 张新表 + 缓存初始化 |
| `concept_extractor.rs` | 修改 | ✅ 硬编码上限 → 动态配置 |
| `e2e_pipeline_test.rs` | 修改 | ✅ 补上缺失参数 |

### 前端
| 文件 | 类型 | 状态 |
|------|------|------|
| `config_page.dart` | 新增 | ✅ 配置编辑 + 模板编辑 |
| `debug_logs_page.dart` | 新增 | ✅ 日志查询 + 跟踪管理 |
| `admin_screen.dart` | 修改 | ✅ 2 个新 Tab + 用户跟踪按钮 |
| `user_detail_screen.dart` | 修改 | ✅ 跟踪状态显示 |

### 编译验证
- 后端 `cargo check` — ✅ 零 error 零 warning
- 前端 `flutter analyze` — ✅ 零 error
- 5 项缺失补丁全部完成，文档-实现 100% 对齐

### 启用配置项（5 项，读 app_config 动态生效）
| key | 默认值 | 说明 |
|-----|--------|------|
| `prompt.history_max_chars` | 5000 | 对话历史截断字数 |
| `prompt.history_max_turns` | 10 | 对话历史保留轮次 |
| `prompt.concept_extract_max` | 5 | 概念提取最多数量 |
| `debug_log.enabled` | true | 是否启用调试日志 |
| `debug_log.retention_days` | 7 | 调试日志保留天数 |

### 阶段二未启动
- Prompt 拆分（signal/format 目录）计划在阶段二实施

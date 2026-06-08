# K12 与 Reading 模式合并方案

## 最终结论
删除所有 Reading 模式专属代码，语文作为普通科目统一走 K12 路径。

---

## 删除清单

### 后端

| 文件 | 内容 | 原因 |
|------|------|------|
| `routes.rs` | `k12_reading_init_handler` 整个函数（~180 行） | Reading 专属 init，由 K12 init 替代 |
| `routes.rs` | 路由 `.route("/api/k12/reading/init", ...)` | 前端改调 `k12Init` |
| `plan_handler.rs` | `<reading_update>` 解析代码（~50 行） | 废弃，统一用 `**task ✅ 已完成` badge |
| `plan_handler.rs` | 注释中"reading 等模式"提法 | 清理文案 |

### 前端

| 文件 | 内容 | 原因 |
|------|------|------|
| `chat_client.dart` | `k12ReadingInit()` 方法 | 前端改调 `k12Init` |
| `home_screen.dart` | `_isReadingSubject` 判断 + `k12ReadingInit` 调用 | 所有科目统一走 `k12Init` |
| `home_screen.dart` | 年级选项中 `g10`/`g11-12` → 合并为 `g10-12` | 与 JSON 的 `grade_band` 对齐 |

### Prompt 文件

| 文件 | 内容 | 原因 |
|------|------|------|
| `prompts/chat/chinese/reading-*.md` | — | ✅ 保留，JSON 的 `prompt_mode` 自动路由加载（用户手动改 prompt） |

### handle_plan_update

| 文件 | 内容 | 原因 |
|------|------|------|
| `plan_handler.rs` | `<reading_update>` 解析代码（~50行） | ❌ 删除，prompt 不再输出此标签 |

### 测试

| 文件 | 内容 | 原因 |
|------|------|------|
| `e2e_api_lifecycle.rs` | `e2e_api_reading` 测试场景 | Reading init 已删除，无可测内容 |

---

## 保留清单

| 文件 | 内容 | 原因 |
|------|------|------|
| `routes.rs` | `k12_reading_current_card_handler` | 独立数据查询 API，与 init 无关 |
| `routes.rs` | 路由 `/api/k12/reading/{id}/current-card` | 同上 |
| `plan_handler.rs` | `cards/reading/` 目录查找 | `copy_prebuilt_card` 需要读取 poem 卡片 |
| `ws.rs` | reading-primary/secondary prompt 路由 | `build_plan_context` 按 `prompt_mode` 自动加载 |

---

## 实施顺序

```
① 前端：合并年级选项 g10/g11-12 → g10-12
② 前端：删除 _isReadingSubject，全部走 k12Init
③ 前端：删除 chat_client.dart 的 k12ReadingInit
④ 后端：删除 k12_reading_init_handler + 路由
⑤ 后端：删除 <reading_update> 解析代码
⑥ prompt：更新 reading-*.md，改用 badge
⑦ 测试：删除 e2e_api_reading
⑧ 删库重建，全量测试验证
```

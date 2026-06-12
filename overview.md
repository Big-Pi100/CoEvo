# P0 修复完成：文件原子写入 + DB 错误传播

## 修复项

| 问题 | 文件 | 变更 |
|------|------|------|
| 原子写入 | `curriculum_admin.rs` | 新增 `atomic_write`（tmp+rename），替换 3 处 `std::fs::write` |
| 原子写入 | `curriculum_loader.rs` | `pending_backfills` 写回改为 tmp+rename |
| DB 错误吞没 | `curriculum_loader.rs` | 5 处 `.ok()` → `.map_err()?`（3 DELETE + 1 INSERT stage + 1 INSERT task） |

## QA 结果
- **`cargo check`**: ✅ 0 error
- **`cargo test -p api_server`**: ✅ 28/28 通过
- **新增 warning**: 0（仅 pre-existing test warnings）

## 回归分析
两个修复均为错误路径加固，不改变业务逻辑。新加的 `?` 使失败不再被静默吞掉而是向上传播，行为更安全。

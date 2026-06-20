# 活动创建失败 — 调查报告

**日期**: 2026-06-19  
**调查人**: 齐活林  
**状态**: 📋 待审批修复

---

## 症状

用户在管理后台点击「新建活动」→ 填写表单 → 点击「保存」→ 对话框关闭 → **活动列表为空**，无法看到刚创建的活动。  
前端未显示错误提示（因为 POST 返回的是 200）。

---

## 验证结果

| 测试 | 结果 | 说明 |
|------|------|------|
| `POST /api/admin/campaigns` | ✅ **200 OK** | INSERT 成功，数据已写入数据库 |
| `GET /api/admin/campaigns` | ❌ 返回 `{"campaigns":[]}` | 列表为空 |
| `GET /api/admin/campaigns/{id}` | ❌ 返回 404 `campaign_not_found` | 详情找不到 |
| 直接查 DB | ✅ 数据存在 | `sqlite3` SELECT 验证记录已写入 |

---

## 根因分析

### P0 — `map_campaign_row` 列索引错位（列表/详情接口崩溃）

`map_campaign_row`（`campaign_handler.rs:477-502`）使用 `SELECT *` 的列索引读取字段。  
但**实际数据库**比**代码定义的 CREATE TABLE** 多了一列 `llm_prompt_hint`，导致索引 10 以后全部偏移 1 位。

**代码中定义的列顺序**（21列）：
```
0:id → 1:name → 2:campaign_type → 3:description → 4:status → 5:rewards → 6:trigger_event → 7:target_roles → 8:push_trigger → 9:push_cron → 10:attribution_window → 11:valid_from → 12:valid_until → 13:participant_limit → 14:per_user_limit → 15:qr_code_url → 16:created_by → 17:created_at → 18:updated_by → 19:updated_at → 20:poster_prompt
```

**实际数据库列顺序**（22列，多了 `llm_prompt_hint`）：
```
0:id → 1:name → 2:campaign_type → 3:description → 4:status → 5:rewards → 6:trigger_event → 7:target_roles → 8:push_trigger → 9:push_cron → 10:llm_prompt_hint ← 多出来的列！→ 11:attribution_window → 12:valid_from → 13:valid_until → 14:participant_limit → 15:per_user_limit → 16:qr_code_url → 17:created_by → 18:created_at → 19:updated_by → 20:updated_at → 21:poster_prompt
```

**后果**：
- 代码读 `attribution_window` 时（index 10）实际读到了 `llm_prompt_hint`（TEXT 列）
- 代码读 `valid_until` 时（index 13）实际读到了 `participant_limit`（INTEGER→TEXT 类型不匹配）
- 当 rusqlite 遇到类型转换失败时，`map_campaign_row` 返回 `Err`
- `list` 的 `filter_map(|r| r.ok())` 静默过滤掉所有错误行 → 永远返回空数组
- `get` 的 `query_row` + `Err(_)` → 返回 404

### P1 — 重复的 `poster_prompt` 键（仅影响 JSON 输出）

`campaign_handler.rs:499-500` 有两个 `"poster_prompt"` 键：
```rust
"poster_prompt": row.get::<_, Option<String>>(20)?,
"poster_prompt": row.get::<_, Option<String>>(21)?,
```
第二个会覆盖第一个，但这不是列表为空的原因（因为 P0 的列偏移就已导致失败）。

### P2 — `llm_prompt_hint` 列不在 schema 定义中

`DISTRIBUTION_SCHEMA_SQL` 的 CREATE TABLE 中缺少 `llm_prompt_hint` 列，  
也未在迁移中补充。该列是之前开发会话中通过手动 SQL 添加的，现代码已丢失。

---

## 影响范围

- **所有活动管理功能不可用**：列表、详情、编辑（因为编辑页依赖列表查询）
- **活动创建（INSERT）本身正常**：数据成功写入数据库
- **历史活动数据完好**：修复后即可正常显示

---

## 修复方案

### 方案 A（推荐 ✅）— 补充列 + 修正索引

1. 在 `DISTRIBUTION_SCHEMA_SQL` 的 `marketing_campaigns` CREATE TABLE 中补充 `llm_prompt_hint TEXT` 列
2. 在 `run_migrations_inner` 中添加迁移 `ALTER TABLE marketing_campaigns ADD COLUMN llm_prompt_hint TEXT DEFAULT NULL`
3. 修正 `map_campaign_row` 的列索引（更新全部 22 列，删除重复行）
4. 同步更新前端表单（如需要显示/编辑 `llm_prompt_hint`）

### 方案 B（最小改动）— 仅修正索引

1. 删除 `map_campaign_row` 中重复的 `"poster_prompt"` 行（行 500）
2. 更新全部列索引以匹配实际 DB（偏移 1）

但方案 B 没有解决根本问题：下次重建数据库会丢失 `llm_prompt_hint` 列。

---

## 待审批

请审阅上述分析和修复方案，确认后我开始实施修复。

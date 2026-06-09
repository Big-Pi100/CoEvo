# 数据库清理完成

## 问题
代码改完了所有 10+ 文件，但本地 `coevo.db` 从未重新初始化——旧表 `cards` (4967行)、`conversation_plans` (8行) 仍然存在，12 张新表全部缺失。

## 操作
1. 删除 `E:/CoEvo/backend/data/coevo.db`
2. 新增 `scripts/init_dev_db.py`—独立的 V4 DDL 初始化脚本
3. 重建数据库：31 张表，全部为新结构

## 验证
- `cargo test -p api_server --lib`: 26/26 ✅
- `cargo test -p card_engine --lib`: 17/17 ✅
- 旧表 `cards`/`conversation_plans`/`learning_plans` → 0 残留
- 新表 `user_cards`/`plan_runs`/`prebuilt_cards`/... → 12/12 ✅

## VPS 状态
测试服务器 `<OLD_VPS_IP>` 的 `/opt/coevo/data/coevo.db` (~10MB) 仍为旧结构。按部署策略，全量完成后再一次性切换，届时同步重建。

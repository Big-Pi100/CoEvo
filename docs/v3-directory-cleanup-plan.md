# v3 目录清理方案

## 现状分析

```
data/curriculum/v3/
├── plans/                  ✅ 运行时核心
├── cards/                  ✅ 运行时核心（但有 .bak 残留）
├── cards_new/              ❌ 临时构建产物
├── backup_20260608_*       ❌ 手工备份混入
├── *.py  (8 个脚本)        ❌ 应放在 scripts/
├── *.md  (3 个文档)        ❌ 应放在 docs/
├── *.sql (1 个)            ➡️ 种子数据
└── *.bak (5 个卡片备份)    ❌ 占用空间
```

## 清理方案

### 第一层：直接删除

| 文件/目录 | 原因 | 大小 |
|-----------|------|------|
| `cards_new/` | temp 构建产物，无人用 | ~45KB |
| `*.bak` (5 个) | 旧卡片备份，累计 ~11MB | v3 只保留当前版本 |

### 第二层：移动

| 当前路径 | 目标路径 |
|----------|---------|
| `v3/*.py` (8 个) | `scripts/` 已有 `scripts/english_rebuild/`, `scripts/gold/` 等，按内容分类移入 |
| `v3/*.md` (3 个) | `docs/` 或 `data/curriculum/english_rebuild/`（英语重建文档） |
| `backup_20260608_*` | `data/curriculum/backups/` 统一备份目录 |
| `seed_stage_grades.sql` | 保留在 v3 根（种子数据）或移入 `docs/schema/` |

### 第三层：保留不动

| 路径 | 理由 |
|------|------|
| `plans/` | 运行时读取 |
| `cards/` | 运行时读取 |
| `seed_stage_grades.sql` | 数据库初始化种子 |

## 清理后预期

```
data/curriculum/v3/
├── plans/          # 14 科 plan JSON
├── cards/          # 各科卡片 JSON
└── seed_stage_grades.sql  # 种子数据
```

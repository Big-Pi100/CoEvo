# 数据目录清理方案

## 当前结构（~425 个文件，~170MB 总计）

```
E:\CoEvo\
├── data/                          # 项目根 data
│   ├── coevo.db                   ❌ 空占位, 0B
│   ├── coevo.db.bak.20260601      ❌ 旧备份
│   ├── *.log  (9 个文件)          ❌ 构建日志
│   ├── k12/                       ❌ 废弃 (数学_g3-4.db, 数学_g5-6.db)
│   ├── cefr_j/                    ➡️ 挪到数据管线内
│   ├── english_rebuild/           ➡️ 挪到数据管线内
│   └── curriculum/                ✅ 活跃数据管线
│       ├── raw/                   ➡️ 中间产物 (可归档)
│       ├── cleaned/               ➡️ 中间产物 (可归档)
│       ├── gold/                  ➡️ 中间产物 (可归档)
│       ├── prebuilt/              ✅ 运行时读取
│       └── v3/                    ✅ 运行时读取 (核心)
│
├── backend/
│   ├── data/                      # 后端运行时目录
│   │   ├── coevo.db               ✅ 唯一活跃数据库 (~10MB)
│   │   ├── avatars/               ✅ 活跃
│   │   ├── logs/                  ✅ 运行时日志 (日轮转)
│   │   ├── deleted_users.ndjson   ✅ 审计
│   │   └── eval_runs/             ❌ 空目录
│   │
│   └── crates/api_server/data/
│       ├── coevo.db               ❌ 遗留副本 (~3.8MB)
│       ├── t_*.db  (5 个)         ❌ 测试遗留
│       ├── test_*.db (50+ 个)     ❌ 测试残留
│       └── eval_runs/             ❌ 测试报告 (27个子目录)
│
└── scripts/english_rebuild/       ✅ 英语重建脚本 (保留)
```

## 清理方案

### 第一层：直接删除（无害）

| 路径 | 原因 | 释放空间 |
|------|------|---------|
| `data/coevo.db` | 空文件，无代码引用 | ~0B |
| `data/coevo.db.bak.20260601` | 手动备份，无代码引用 | ~0B |
| `data/*.log` (9 文件) | 一次性脚本 stdout 捕获，无人读 | ~40KB |
| `data/k12/` | 废弃 SQLite，旧管线遗留 | ~156KB |
| `backend/data/eval_runs/` | 空目录 | 0 |
| `backend/crates/api_server/data/coevo.db` | 遗留副本，跟主库不同步 | ~3.8MB |
| `backend/crates/api_server/data/t_*.db` (5 个) | 测试固件 | ~240KB |
| `backend/crates/api_server/data/test_*.db` (50+ 个) | E2E 测试产物 | ~50MB |
| `backend/crates/api_server/data/test_*-shm` / `*-wal` | SQLite WAL 辅助文件 | ~16MB |
| `backend/crates/api_server/data/eval_runs/` (27 子目录) | E2E 测试报告 | ~3MB |

### 第二层：迁移（调整位置）

| 当前路径 | 目标路径 | 原因 |
|----------|---------|------|
| `data/cefr_j/` | `data/curriculum/prebuilt/cefr_j/` | 纳入课程数据管线，与 backend/cefr_catalog.json 区分 |
| `data/english_rebuild/` | `data/curriculum/english_rebuild/` | 属于课程重建产物，放在 curriculum 下 |
| `scripts/english_rebuild/` | 保留不动 | ✅ 已在对的位置 |

### 第三层：中间产物（不动，但意识别）

以下目录是构建管线中间步骤，有上下游依赖关系，**保留不动**：
- `data/curriculum/raw/` — 原始 PDF→MD（`clean_curriculum.py` 输入）
- `data/curriculum/cleaned/` — 清洗后（`extract_v3.py` / `extract_language.py` 输入）
- `data/curriculum/gold/` — 提取后（`build_plans_v3.py` 输入）
- `data/curriculum/prebuilt/` — 运行时读取

## 清理后结构（预期）

```
E:\CoEvo\
├── data/
│   └── curriculum/
│       ├── raw/              # 保留
│       ├── cleaned/          # 保留
│       ├── gold/             # 保留
│       ├── prebuilt/         # 活跃
│       │   └── cefr_j/       # ← 从 data/ 移入
│       ├── v3/               # 活跃 (运行时核心)
│       └── english_rebuild/  # ← 从 data/ 移入
│
├── backend/
│   └── data/
│       ├── coevo.db          # 唯一数据库
│       ├── avatars/          # 保留
│       ├── logs/             # 保留
│       └── deleted_users.ndjson
│
└── scripts/
    └── english_rebuild/      # 保留
```

## 执行步骤

1. 核对未运行后端 (已确认不在运行)
2. 直接删除废弃文件
3. 移动目录
4. 更新 `phase1_dedup.py` 中引用的 CEFR_J 路径（如需要）
5. 验证后端能正常启动

# Prebuilt 数据目录梳理

> 2026-05-29

## 目标

清理 `data/curriculum/prebuilt/` 下混合存放的文件，让 K12 课标数据、阅读管线数据、词库数据各自归位。

## 当前结构

```
prebuilt/
├── cards/                   ← K12课标卡片 + 阅读残留 + .bak 混放
│   ├── *.json               ← 13 科×2(初中/高中) = 26 个课标文件 ✅
│   ├── chinese_reading.json ← 208 张古诗卡（阅读管线，有 back 字段）
│   ├── chinese_reading_test.json ← 测试文件
│   ├── *.bak                ← 3 个旧的阅读卡片备份
│   └── reading/             ← 真正的阅读卡片（已移入）
├── plans/                   ← K12课标计划 + 无用文件
│   ├── *.json               ← 13 个课标计划 ✅
│   ├── chinese_poems_catalog.json           ← 被 SKIP（缺 stages）
│   └── chinese_reading_catalog_extended.json ← 被 SKIP（缺 stages）
├── plans_merged/            ← merge_plans.py 生成的合并计划（保留）
├── reading_plans/           ← 阅读管线计划（chinese.json）
└── vocab_enriched/          ← 词库（已富集，含中英日俄）
```

## 清理操作

| 操作 | 说明 |
|:----|------|
| ① 删除 `cards/*.bak` | 3个备份文件 |
| ② 删除 `cards/chinese_reading_test.json` | 测试文件 |
| ③ 移动 `cards/chinese_reading.json` → `cards/reading/` | 古诗卡归入阅读管线 |
| ④ 删除 `plans/chinese_poems_catalog.json` | 被 SKIP，无人用 |
| ⑤ 删除 `plans/chinese_reading_catalog_extended.json` | 被 SKIP，无人用 |

## 不会动的内容

- `cards/*_compulsory.json` / `cards/*_senior.json` — K12 课标卡片（含词卡），curriculum_loader 加载
- `plans/*.json`（13个学科） — K12 课标计划
- `reading_plans/` — 阅读计划，reading_loader 路径指向此处
- `vocab_enriched/` — 词库富集数据
- `cards/reading/` — 阅读卡片，reading_loader 已指向 `cards/reading`
- `cleaned/` — 原始课标数据（不受影响）

## 梳理后结构

```
prebuilt/
├── cards/
│   ├── biology_compulsory.json        ← K12 13学科课标卡
│   ├── biology_senior.json
│   ├── ...                            
│   └── reading/                       ← 阅读管线卡片
│       ├── chinese_reading_primary.json
│       ├── chinese_reading_extended.json
│       ├── chinese_reading_missing.json
│       └── chinese_reading.json        ← 208张古诗卡（移入）
├── plans/
│   ├── biology.json ...               ← K12 13学科计划
├── reading_plans/
│   └── chinese.json                   ← 阅读计划
└── vocab_enriched/                    ← 词库
```

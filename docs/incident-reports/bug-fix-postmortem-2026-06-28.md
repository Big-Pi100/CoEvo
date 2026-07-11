# 2026-06-28 Bug 修复复盘

## 1. 前端：路由不存在导致崩溃

| 项目 | 内容 |
|:-----|:------|
| **症状** | `home_screen.dart` 调用 `Navigator.of(context).pushReplacementNamed('/login')` → `Uncaught Error` |
| **根因** | `/login` 路由已被移除，但代码中残留了引用 |
| **修复** | 改为弹出登录/注册 `_AuthDialog` 弹窗，不跳转路由 |
| **教训** | 清理全局路由配置时，必须 grep 所有引用的调用点 |

## 2. 后端：活动删除 FK 约束失败

| 项目 | 内容 |
|:-----|:------|
| **症状** | `DELETE FROM marketing_campaigns` → `FOREIGN KEY constraint failed` |
| **根因** | `reward_fulfillments` 表有 5 条记录外键引用该活动 |
| **修复** | 先清理 4 张子表引用数据，再删除主表 |
| **教训** | 有 FK 约束的表不能直接 DELETE，必须考虑子表引用 |

## 3. 后端：SVG QR 路径提取索引错误

| 项目 | 内容 |
|:-----|:------|
| **症状** | `resvg` SVG 解析报错 `expected '"' not '<' at 19:3` |
| **根因** | 从 QR SVG 中提取 path 时，`from_d[..close]` 包含了 `d="` 前缀但未包含结尾 `"`，导致 XML 属性未闭合 |
| **修复** | `from_d[3..close]` 提取纯路径数据，再用 `d=\"{d_value}\"` 标准格式包裹 |
| **教训** | **字符串切片索引**：看清每个字符的位置，`d="` 是 3 字节，`d=\\"` 在 Rust 中代表 `d="` |

## 4. 后端：QR 代码坐标缺失 viewBox 导致缩放错误

| 项目 | 内容 |
|:-----|:------|
| **症状** | 二维码在 PNG 中小到不可见，只显示为微小色块 |
| **根因** | 只提取了 QR SVG 中的 `<path>`，丢弃了 `<svg viewBox="0 0 180 180">`。path 在模块坐标（0-25）下，放到 600×900 的主 SVG 中只有几像素 |
| **修复** | 改用完整 QR SVG 先渲染为 180×180 PNG，再以 `<image>` 元素嵌入海报 |
| **教训** | **嵌入 SVG 片段必须保留 viewBox**，否则坐标系统丢失。更稳健的做法是 rasterize 后再嵌入 |

## 5. 后端：QR 定位偏移（translate 索引 off-by-one）

| 项目 | 内容 |
|:-----|:------|
| **症状** | QR 码未居中，总在框的右下角 |
| **根因** | `from_d[4..close]` 跳过了 `d="`（3 字符）和 1 个路径数据字符，丢失了 `M` 命令 |
| **修复** | `from_d[3..close]` 正确跳过 `d="` |
| **教训** | **off-by-one**：`d="` 是 3 个字符（d = "），不要数成 4 |

## 6. 前端：分享按钮弹空白页

| 项目 | 内容 |
|:-----|:------|
| **症状** | 点"分享链接到微信" → 先 SnackBar 说"已复制"（实际没复制），再跳转空白页 |
| **根因** | 代码没调 `Clipboard.setData()`，SnackBar 是撒谎的；多余跳转页无意义 |
| **修复** | 加入 `Clipboard.setData(ClipboardData(text: fullUrl))`，去掉多余页面跳转 |
| **教训** | **不要撒谎给用户看**：SnackBar 说"已复制"但实际没复制。先确认功能实现再展示反馈 |

## 7. 后端：task_name 错配（biology × english）

| 项目 | 内容 |
|:-----|:------|
| **症状** | H5 中显示 `english·细胞的基本概念与观察`（英文科目 + 生物任务名） |
| **根因** | `SELECT name FROM prebuilt_tasks WHERE task_key = ?1` 中 task_key 是全局通用编号（01-01），但 `prebuilt_tasks` 只有 biology 课程的数据，所有科目都读到 biology 的任务名 |
| **修复** | 改为从 `plan_content` JSON 中按 `task_key` 查找对应 task name |
| **教训** | **别用全局编号查局部数据**：task_key 是课程内编号，必须搭配 plan_id 或从 plan_content 中查 |

## 8. 前端+后端：active_plans_summary 批量漏修

| 项目 | 内容 |
|:-----|:------|
| **症状** | H5 仍然显示多条记录（修复 poster 后 H5 没变） |
| **根因** | 同一逻辑在 `poster_template.rs` 和 `h5_template.rs` 各有一份，只修了前者 |
| **修复** | 所有修正在两处各改一次；最后抽取为共享函数 `build_user_plan_stats()` |
| **教训** | **重复代码是 bug 的温床**：相同逻辑出现 >1 次就该抽取共享。今天这个 bug 反复出现 3 次（poster → H5 → current_focus） |

## 9. 后端：plan 多行展开

| 项目 | 内容 |
|:-----|:------|
| **症状** | 一个 chemistry 计划显示 14 行 task |
| **根因** | `plan_runs JOIN user_plan_progress` 没有每 plan 只取最新一条的限制 |
| **修复** | 用 `AND upp.updated_at = (SELECT MAX(...) FROM user_plan_progress ...)` |
| **教训** | **JOIN 1:N 时谨慎**：确认每行语义，是否需要聚合或 LIMIT 1 |

## 10. 后端：pending 状态误算为当前 task

| 项目 | 内容 |
|:-----|:------|
| **症状** | 未开始的 chemistry 计划显示 `chemistry·科学探究方法概览` |
| **根因** | `COALESCE(in_progress, pending)` 逻辑：即使全是 pending 也取了第一个 |
| **修复** | 只查 `status = 'in_progress'`，pending 的不参与 |
| **教训** | **pending ≠ in_progress**：明确状态语义，不要混用 |

## 11. 后端：H5 按钮链接打不开 + campaign_id 丢失

| 项目 | 内容 |
|:-----|:------|
| **症状** | H5 页面按钮链接打不开，且注册无法关联活动 |
| **根因** | `register_url` 默认 `http://localhost:8080/app/auth`（后端端口，非 Flutter 端口）；且不含 `campaign_id` 参数 |
| **修复** | `register_url` 加入 `campaign_id`；`COEVO_BASE_URL` 环境变量配置正确的 Flutter 地址 |
| **教训** | **base_url 语义要清晰**：区分 API 地址和前端地址；营销链路参数要传完整 |

## 12. 后端：real_name 加密字段未解密

| 项目 | 内容 |
|:-----|:------|
| **症状** | 海报中 `{real_name}` 显示为 base64 乱码 |
| **根因** | `real_name` 在 DB 中 AES-256-GCM 加密，模板构建函数直接 `SELECT COALESCE(real_name, '')` 读了密文 |
| **修复** | 尚未修复（待重构） |
| **教训** | **加密字段读出来就是密文**：加密 ≠ 透明，必须显式解密 |

## 通用模式总结

### 反复出现的错误类型

| 模式 | 出现次数 | 典型例子 |
|:-----|:---------|:---------|
| **1. 重复代码漏修** | 3 | poster / H5 / current_focus 三处同一逻辑 |
| **2. 字符串索引 off-by-one** | 2 | `from_d[4..close]` 应为 `[3..close]` |
| **3. XML/SVG 属性未闭合** | 1 | path 的 `d` 属性缺少 `"` |
| **4. viewBox 丢失** | 1 | QR 路径坐标缩放失效 |
| **5. JOIN 1:N 未限制** | 1 | plan 多行展开 |
| **6. 状态语义混淆** | 1 | pending 当 in_progress 用 |
| **7. 加密字段未解密** | 1 | real_name 显示密文 |
| **8. 前端反馈不实** | 1 | SnackBar 说已复制但没复制 |
| **9. 营销参数传递断裂** | 1 | campaign_id 在链路中断开 |

### 预防清单

写代码前先问：

- [ ] **这个逻辑在别处也有吗？** → 抽取共享函数，避免重复
- [ ] **字符串/数组索引是 0-based 吗？** → 逐字符确认偏移量
- [ ] **XML/SVG 属性值有闭合引号吗？** → 检查生成的字符串
- [ ] **引用的子资源有独立的坐标系统吗？** → 需要 viewBox 或 rasterize
- [ ] **SQL JOIN 会产生多行吗？** → 需要聚合或 LIMIT 1
- [ ] **状态值语义和业务需求一致吗？** → 区分 pending / in_progress / done
- [ ] **DB 中这个字段加密了吗？** → 需要显式解密才能用
- [ ] **前端反馈前功能真的实现了？** → 先实现，再展示
- [ ] **URL 参数在整条链路中都传递了吗？** → ref、campaign_id 等一路传到底
- [ ] **base_url 指向的是前端还是后端？** → 区分 API 地址和页面地址

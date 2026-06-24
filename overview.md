# SEO + 免费试用方案修复完成

## 改动概览

针对 `docs/seo-and-landing-agent-plan.md` 中发现的 10 项缺失，逐项修复完成（仅本地，未部署）。

### ✅ 后端修复（2项）
| 改动 | 文件 | 内容 |
|:-----|:-----|:------|
| IP 防滥用 | `trial_handler.rs` + `schema.rs` | 同IP每日限3次trial创建，新增 `trial_ip_log` 表 |
| 定时清理 | `campaign_scheduler.rs` | 7天软删除 + 37天硬删除，含完整单元测试 |

### ✅ 前端修复（3项）
| 改动 | 文件 | 内容 |
|:-----|:-----|:------|
| 注册弹窗-聊天页 | `chat_screen.dart` | 首次进入 + task完成监听（30秒轮询） |
| 注册弹窗-个人页 | `profile_screen.dart` | 进入个人页时检测弹窗 |
| PC宽屏约束 | `app/lib/app.dart` | >768px时限制内容宽度≤1200px |

### ✅ SEO（1项）
| 改动 | 文件 | 内容 |
|:-----|:-----|:------|
| Title/Meta/FAQ | `app/web/index.html` | 标题、描述、FAQ Schema JSON-LD |

### ✅ 清理（1项）
| 改动 | 文件 | 内容 |
|:-----|:-----|:------|
| 删除landing目录 | `landing/` | 已删除，不再维护独立landing page |

## 验证结果
- **后端**: `cargo check` 零错误 / 7 个新增测试全部通过
- **前端**: `flutter analyze` 零新增 warnings（仅预存issues在其它文件）

## 待部署项（需用户确认后执行）
1. VPS Nginx 配置改为指向 Flutter Web 根路径
2. Flutter Web 构建（去掉 `--base-href /app/`）
3. VPS 后端替换（带 `trial_ip_log` 表）

//! 电子书文件存储 —— **对象存储抽象** + 本地盘实现
//!
//! # 为什么要抽象（而不是直接写盘）
//!
//! 书架上云的**文件本体**要在某处落地。候选有两种：
//!
//! | | 本地盘（VPS） | 对象存储（COS） |
//! |---|---|---|
//! | 配置 | **零** | 开通 + 密钥 + 签名 + CORS |
//! | 容量 | 现有 **31 GB 可用**（实测 40G 用 6.8G）| 无限 |
//! | 带宽 | 实测下行 **652 KB/s** / 上行 **1291 KB/s** | 按量付费、带宽充足 |
//! | 成本 | ¥0（磁盘已付）| 0.118 元/GB·月 + 0.5 元/GB 下行 |
//!
//! 📌 **2026-10-07 选本地盘**，理由：① **零配置** —— 不需要开通云服务、不需要密钥，
//!    当天即可端到端跑通；② 单本 1 MB ⇒ 下载 1.5 s，**换机全量 50 MB ≈ 77 s**
//!    （一次性动作，有进度条，可接受）；③ 现零用户，带宽竞争不存在。
//!
//! 🔴 **设计稿原写「VPS 只有 40 GB 且外网流量贵」—— 磁盘那半句与实测不符**
//!    （31 GB 可用 ⇒ 按 1 MB/本可存 3 万本）。**带宽**才是真实约束，已实测并接受。
//!    ⇒ 已回标 `docs/design/visual-cloud-bookshelf-2026-10-07.html`。
//!
//! 🔑 抽象的价值：切 COS 只需**新增一个 impl**（本文件加 ~150 行），
//!    端点与配额逻辑**一行不改**。⇒ 「先跑通、后可换」，不必现在就押注。
//!
//! # 🔴🔴 安全：路径穿越
//!
//! 对象键里含**客户端传来的** `user_id` / `content_hash` / `ext` 三段。
//! 若不校验，`content_hash = "../../etc/passwd"` 就能写到任意位置
//! —— 这是**真实的漏洞面**，不是理论风险。
//!
//! ⇒ 三层防御（见 [`safe_blob_path`]）：
//!   ① 各段**字符白名单**（`content_hash` 只允许十六进制）
//!   ② 拼出的路径**必须以 root 为前缀**
//!   ③ 拒绝任何含 `..` / 分隔符 / NUL 的段
//!
//! ⚠️ ① 就足以拦住绝大多数攻击，② 是**防御纵深**（防将来的重构把 ① 绕过）。

use std::path::{Path, PathBuf};

// ══════════════════════════════════════════════════════════════════════
// 纯校验函数（无 I/O ⇒ 可独立 `cargo test`）
// ══════════════════════════════════════════════════════════════════════

/// `content_hash` 的合法形态：**十六进制**，16–64 字符。
///
/// 🔑 为什么是十六进制而不是「非空字符串」：
///    它是**路径的一段**。十六进制集合里**不可能**出现 `/` · `\` · `.` · NUL
///    ⇒ 路径穿越在这一层就被堵死（而不是靠下游再检查一遍）。
///
/// ⚠️ 长度下限 16：v2 指纹（`sha256` 前 16 位十六进制）就是 16；
///    上限 64 覆盖完整 sha256。放宽到「任意长度」没有收益，只会给攻击者空间。
pub fn is_valid_content_hash(s: &str) -> bool {
    let n = s.len();
    (16..=64).contains(&n) && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// 允许的电子书扩展名（**白名单**，不是黑名单）。
///
/// 🔑 白名单而非黑名单：黑名单永远漏（`.php` `.jsp` `.so` … 而且我们不需要它们）。
///    本项目只导入 EPUB / TXT 两种 ⇒ 白名单让「能进磁盘的文件名」是**穷举的**。
pub fn is_valid_ext(s: &str) -> bool {
    matches!(s, "epub" | "txt")
}

/// `user_id` 的合法形态。
///
/// 端侧 `user_id` 是注册时生成的标识（当前形态：十六进制/数字串）。
/// 这里**从宽**（允许字母数字与 `-` `_`），因为它是既有数据、
/// 不能因为校验过严把老用户挡在门外 —— 但**仍然禁止**路径元字符。
pub fn is_valid_user_id(s: &str) -> bool {
    let n = s.len();
    (1..=64).contains(&n)
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

// ══════════════════════════════════════════════════════════════════════
// 存储抽象
// ══════════════════════════════════════════════════════════════════════

/// 电子书文件存储后端。
///
/// 全部方法返回 `Result<_, String>`：错误信息**直接进日志**（调用方只做映射），
/// 与 `tencent_sign::call` 同一取向。
pub trait BlobStore: Send + Sync {
    /// 写入（**覆盖式** —— 同一个 `content_hash` 就是同一本书）。
    fn put(&self, user_id: &str, content_hash: &str, ext: &str, data: &[u8]) -> Result<(), String>;

    /// 绝对路径（本地盘实现专用；将来 COS 实现不适用 ⇒ 用 `Option` 表达）。
    ///
    /// 🔑 下载端点在本地盘形态下需要它来开文件；抽象成 `Option` 是为了让
    ///    「换 COS 要改哪里」在**类型层面**就看得见，而不是运行时才发现。
    fn local_path(
        &self,
        user_id: &str,
        content_hash: &str,
        ext: &str,
    ) -> Result<Option<PathBuf>, String>;

    /// 删除该 `content_hash` 名下**所有**扩展名的文件。
    ///
    /// 🔑 签名**不收 `ext`**：端侧若传错扩展名就删不掉 ⇒ 文件残留、配额不退
    ///    （而用户以为自己删干净了 —— 典型的静默失效）。
    ///    扫目录匹配 `{hash}.*` 让「删」不依赖调用方传对参数。
    ///
    /// 返回**实际删掉的字节数**（0 = 本来就没有）。
    fn delete(&self, user_id: &str, content_hash: &str) -> Result<u64, String>;

    /// 该用户文件占用的**磁盘总量**（扫目录）。
    ///
    /// ⚠️ 与 `sync_book.blob_size` 之和是**两个独立判据**（见文件头「交叉验证」）：
    ///    请求路径用 SQL 求和（快），本函数用于**对账**（测试与巡检）。
    ///    两者不一致 ⇒ 有残留文件或记录漂移。
    fn disk_usage_of(&self, user_id: &str) -> Result<u64, String>;

    /// **删除该用户的全部文件**（注销账号用）。返回释放的字节数。
    ///
    /// 🔴 为什么必须有它：注销要求「数据删干净」（Apple 5.1.1(v) + 隐私政策 §2.1）。
    ///    只删数据库行**不够** —— 电子书文件还在磁盘上，
    ///    而书名/正文恰恰是最私人的内容。
    ///
    /// ⚠️ 与 `delete(hash)` 的区别：那个删**一本书**，这个删**一个人**。
    ///    换 COS 实现时要对应「按前缀列举 + 批量删除」。
    fn purge_user(&self, user_id: &str) -> Result<u64, String>;
}

/// 本地盘实现：`{root}/{user_id}/{content_hash}.{ext}`。
pub struct LocalDiskStore {
    root: PathBuf,
}

impl LocalDiskStore {
    /// `root` 缺省 = 环境变量 `COEVO_BLOB_DIR`，再缺省 = `data/book_blobs`
    /// （生产 `WorkingDirectory=/opt/coevo` ⇒ `/opt/coevo/data/book_blobs`，
    /// 与 `public_assets.rs` 同一相对路径口径）。
    pub fn from_env() -> Self {
        let root = std::env::var("COEVO_BLOB_DIR")
            .unwrap_or_else(|_| "data/book_blobs".to_string())
            .into();
        Self { root }
    }

    #[cfg(test)]
    pub fn with_root(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// 该用户的目录（**已校验** `user_id`）。
    fn user_dir(&self, user_id: &str) -> Result<PathBuf, String> {
        if !is_valid_user_id(user_id) {
            return Err(format!("非法 user_id：{:?}", user_id));
        }
        Ok(self.root.join(user_id))
    }
}

impl BlobStore for LocalDiskStore {
    fn put(&self, user_id: &str, content_hash: &str, ext: &str, data: &[u8]) -> Result<(), String> {
        let path = safe_blob_path(&self.root, user_id, content_hash, ext)?;
        let dir = path
            .parent()
            .ok_or_else(|| "路径没有父目录".to_string())?
            .to_path_buf();
        std::fs::create_dir_all(&dir).map_err(|e| format!("建目录失败 {}: {e}", dir.display()))?;
        // 先写临时文件再 rename：避免「读端拿到写了一半的文件」
        // （下载与上传可能并发；rename 在同一文件系统内是原子的）
        let tmp = path.with_extension("tmp-upload");
        std::fs::write(&tmp, data).map_err(|e| format!("写临时文件失败 {}: {e}", tmp.display()))?;
        std::fs::rename(&tmp, &path).map_err(|e| format!("落盘失败 {}: {e}", path.display()))?;
        Ok(())
    }

    fn local_path(
        &self,
        user_id: &str,
        content_hash: &str,
        ext: &str,
    ) -> Result<Option<PathBuf>, String> {
        let p = safe_blob_path(&self.root, user_id, content_hash, ext)?;
        Ok(if p.is_file() { Some(p) } else { None })
    }

    fn delete(&self, user_id: &str, content_hash: &str) -> Result<u64, String> {
        if !is_valid_content_hash(content_hash) {
            return Err(format!("非法 content_hash：{:?}", content_hash));
        }
        let dir = self.user_dir(user_id)?;
        let rd = match std::fs::read_dir(&dir) {
            Ok(rd) => rd,
            // 目录不存在 = 该用户从没上传过 ⇒ 「删成功、删了 0 字节」（幂等）
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(0),
            Err(e) => return Err(format!("读目录失败 {}: {e}", dir.display())),
        };
        let mut freed = 0u64;
        for ent in rd.flatten() {
            let name = ent.file_name();
            let Some(name) = name.to_str() else { continue };
            // 匹配 `{hash}` 或 `{hash}.{ext}` —— 只删这一个指纹的文件
            if name == content_hash || name.starts_with(&format!("{content_hash}.")) {
                if let Ok(md) = ent.metadata() {
                    freed += md.len();
                }
                std::fs::remove_file(ent.path())
                    .map_err(|e| format!("删文件失败 {}: {e}", ent.path().display()))?;
            }
        }
        Ok(freed)
    }

    fn disk_usage_of(&self, user_id: &str) -> Result<u64, String> {
        let dir = self.user_dir(user_id)?;
        let rd = match std::fs::read_dir(&dir) {
            Ok(rd) => rd,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(0),
            Err(e) => return Err(format!("读目录失败 {}: {e}", dir.display())),
        };
        let mut total = 0u64;
        for ent in rd.flatten() {
            // ⚠️ 临时文件（`.tmp-upload`）**不计入** —— 它是传输中间态，
            //    若计入则「上传中」会瞬时超配额（自己把自己堵死）。
            let is_tmp = ent
                .file_name()
                .to_str()
                .is_some_and(|n| n.ends_with(".tmp-upload"));
            if is_tmp {
                continue;
            }
            if let Ok(md) = ent.metadata() {
                if md.is_file() {
                    total += md.len();
                }
            }
        }
        Ok(total)
    }

    fn purge_user(&self, user_id: &str) -> Result<u64, String> {
        let dir = self.user_dir(user_id)?;
        // 先量再删（删完就量不到了）
        let freed = self.disk_usage_of(user_id)?;
        match std::fs::remove_dir_all(&dir) {
            Ok(()) => Ok(freed),
            // 目录不存在 = 该用户没有文件 ⇒ 幂等成功
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(0),
            Err(e) => Err(format!("删用户目录失败 {}: {e}", dir.display())),
        }
    }
}

/// 拼出对象键的绝对路径，**三层防御**（见文件头）。
///
/// 独立成公开函数是为了**可断言**：路径穿越是最该被钉死的一类缺陷，
/// 而它的判据（「拼出来的路径必须仍在 root 下」）用纯函数表达最清楚。
pub fn safe_blob_path(
    root: &Path,
    user_id: &str,
    content_hash: &str,
    ext: &str,
) -> Result<PathBuf, String> {
    // ① 各段白名单
    if !is_valid_user_id(user_id) {
        return Err(format!("非法 user_id：{:?}", user_id));
    }
    if !is_valid_content_hash(content_hash) {
        return Err(format!("非法 content_hash：{:?}", content_hash));
    }
    if !is_valid_ext(ext) {
        return Err(format!("不支持的扩展名：{:?}", ext));
    }

    // ② 拼接（此时三段已被证明不含任何路径元字符）
    let p = root.join(user_id).join(format!("{content_hash}.{ext}"));

    // ③ 防御纵深：结果必须仍在 root 之内
    //
    // 🔑 用**词法**前缀比较而不是 `canonicalize()`：后者要求路径已存在，
    //    而 `put` 时目标文件还不存在 ⇒ 会在第一次上传就失败。
    //    ⚠️ 词法比较**不能**正确处理符号链接 —— 但 ① 已保证拼不出 `..`/`/`，
    //       符号链接要由「root 目录只有服务进程可写」这一运维前提兜住。
    if !p.starts_with(root) {
        return Err(format!("路径逃逸出根目录：{}", p.display()));
    }

    Ok(p)
}

// ══════════════════════════════════════════════════════════════════════
// 配额
// ══════════════════════════════════════════════════════════════════════

/// 订阅用户的云端书架配额：**2 GB**（设计稿 `visual-cloud-bookshelf` §3 定）。
pub const CLOUD_BOOK_QUOTA_BYTES: i64 = 2 * 1024 * 1024 * 1024;

/// 单本书的体积上限：**32 MB**。
///
/// 🔑 取值的依据不是「随便定一个」：常见 EPUB（纯文字）0.3–2 MB、
///    带插图的小说 3–10 MB。32 MB 足够，且让「一次读进内存」的
///    下载实现（见 `book_blob_handler`）在并发下**不会打爆内存**
///    （VPS 约 460 MB 可用 ⇒ 32 MB × 10 并发 = 320 MB，仍在界内）。
pub const MAX_BOOK_BYTES: i64 = 32 * 1024 * 1024;

/// 配额判断（**纯函数** ⇒ 可断言边界）。
///
/// 返回 `Ok(())` 或一句**能直接展示给用户**的话。
///
/// 🔑 为什么把判断抽出来：它是「已用 + 新增 > 上限」这个简单不等式，
///    但**边界**（恰好等于上限时允许、超 1 字节时拒绝）最容易写错，
///    而写错的表现是「用户传不上去但不知道为什么」。
pub fn check_quota(used: i64, incoming: i64, quota: i64) -> Result<(), String> {
    if incoming > MAX_BOOK_BYTES {
        return Err(format!(
            "这本书超过单本上限（{} MB）",
            MAX_BOOK_BYTES / 1024 / 1024
        ));
    }
    // 恰好等于上限 ⇒ **允许**（用 `>` 而不是 `>=`）
    if used.saturating_add(incoming) > quota {
        return Err(format!(
            "云端空间不足（已用 {} MB / 共 {} MB）",
            used / 1024 / 1024,
            quota / 1024 / 1024
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const HASH: &str = "0123456789abcdef"; // 16 位十六进制

    // ══════════════════════════════════════════════════════════════
    // ① 路径穿越 —— 本文件最该钉死的一类
    // ══════════════════════════════════════════════════════════════

    /// **所有**已知的穿越手法都必须被拒。
    ///
    /// 🔑 期望值不是「跑一遍看看」—— 这些是**攻击载荷**，
    ///    它们**必须**被拒是由安全要求决定的，不是我实现的行为决定的。
    #[test]
    fn test_rejects_path_traversal_payloads() {
        let bad_hashes = [
            "../../etc/passwd",
            "..%2f..%2fetc",
            "....//....//etc",
            "/etc/passwd",
            "abc/def",
            "abc\\def",
            "abc.def",
            "abc\0def",
            "",                 // 空
            "0123456789abcde",  // 15 位（差一位，防「长度检查写松」）
            "GHIJKLMNOPQRSTUV", // 非十六进制
        ];
        for h in bad_hashes {
            assert!(
                !is_valid_content_hash(h),
                "🔴 非法 content_hash 必须被拒：{h:?}"
            );
            assert!(
                safe_blob_path(Path::new("/srv/blobs"), "u1", h, "epub").is_err(),
                "🔴 非法 content_hash 不应拼出路径：{h:?}"
            );
        }

        let bad_users = ["../u", "u/1", "u\\1", "", "u.1", "u 1", "u\0"];
        for u in bad_users {
            assert!(!is_valid_user_id(u), "🔴 非法 user_id 必须被拒：{u:?}");
            assert!(
                safe_blob_path(Path::new("/srv/blobs"), u, HASH, "epub").is_err(),
                "🔴 非法 user_id 不应拼出路径：{u:?}"
            );
        }

        let bad_exts = ["../epub", "epub/../../x", "sh", "exe", "", "EPUB"];
        for e in bad_exts {
            assert!(!is_valid_ext(e), "🔴 非白名单扩展名必须被拒：{e:?}");
            assert!(
                safe_blob_path(Path::new("/srv/blobs"), "u1", HASH, e).is_err(),
                "🔴 非白名单扩展名不应拼出路径：{e:?}"
            );
        }
    }

    /// 合法输入要能拼出**预期形状**的路径。
    ///
    /// 🔑 期望值是**手写的**路径串（不是调本函数得到的）——
    ///    否则只是「和我上次跑的一样」。
    #[test]
    fn test_accepts_valid_and_shapes_path() {
        let p = safe_blob_path(Path::new("/srv/blobs"), "u123", HASH, "epub").unwrap();
        assert_eq!(p, Path::new("/srv/blobs/u123/0123456789abcdef.epub"));

        // 64 位十六进制（完整 sha256）也要接受
        let long = "a".repeat(64);
        assert!(is_valid_content_hash(&long));
        assert!(safe_blob_path(Path::new("/srv/blobs"), "u1", &long, "txt").is_ok());

        // 大写十六进制：允许（hex 的大小写不承载信息）
        assert!(is_valid_content_hash("0123456789ABCDEF"));
    }

    // ══════════════════════════════════════════════════════════════
    // ② 配额边界（写到**恰好**与**差一字节**）
    // ══════════════════════════════════════════════════════════════

    #[test]
    fn test_quota_boundaries() {
        let q = 1000;
        // 恰好填满 ⇒ **允许**（`>` 不是 `>=`）
        assert!(check_quota(900, 100, q).is_ok(), "恰好等于上限应当允许");
        // 超 1 字节 ⇒ 拒绝
        assert!(check_quota(900, 101, q).is_err(), "超 1 字节应当拒绝");
        // 空账户 + 等于上限 ⇒ 允许
        assert!(check_quota(0, 1000, q).is_ok());
        // 已满 + 加 0 ⇒ 允许（幂等重传不该被拒）
        assert!(check_quota(1000, 0, q).is_ok());
        // 🔴 溢出安全：两个极大值不应 panic 也不应「绕过」
        assert!(
            check_quota(i64::MAX, i64::MAX, q).is_err(),
            "饱和加法必须拒绝而不是溢出成负数（溢出会变成「允许」）"
        );
    }

    #[test]
    fn test_single_book_size_limit() {
        assert!(
            check_quota(0, MAX_BOOK_BYTES, i64::MAX).is_ok(),
            "恰好 32MB"
        );
        assert!(
            check_quota(0, MAX_BOOK_BYTES + 1, i64::MAX).is_err(),
            "超 1 字节要拒"
        );
    }

    // ══════════════════════════════════════════════════════════════
    // ③ 本地盘往返（真文件系统 · 临时目录）
    // ══════════════════════════════════════════════════════════════

    fn tmp_store(tag: &str) -> (LocalDiskStore, PathBuf) {
        let dir =
            std::env::temp_dir().join(format!("coevo_blob_test_{tag}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        (LocalDiskStore::with_root(&dir), dir)
    }

    #[test]
    fn test_put_get_delete_roundtrip() {
        let (st, root) = tmp_store("rt");

        assert!(
            st.local_path("u1", HASH, "epub").unwrap().is_none(),
            "未上传时应当没有路径"
        );

        st.put("u1", HASH, "epub", b"EPUB-BYTES").unwrap();
        let p = st.local_path("u1", HASH, "epub").unwrap().expect("应存在");
        assert!(p.starts_with(&root), "必须落在 root 内：{}", p.display());
        assert_eq!(std::fs::read(&p).unwrap(), b"EPUB-BYTES");

        // 覆盖式写：同一 hash 再写 ⇒ 内容替换，不产生第二个文件
        st.put("u1", HASH, "epub", b"V2").unwrap();
        assert_eq!(std::fs::read(&p).unwrap(), b"V2");
        assert_eq!(st.disk_usage_of("u1").unwrap(), 2);

        // 删除：返回释放的字节数；再删一次 ⇒ 0（幂等）
        assert_eq!(st.delete("u1", HASH).unwrap(), 2);
        assert_eq!(st.delete("u1", HASH).unwrap(), 0, "重复删除必须幂等");
        assert!(st.local_path("u1", HASH, "epub").unwrap().is_none());
        assert_eq!(st.disk_usage_of("u1").unwrap(), 0);
    }

    /// 换扩展名后仍要能删掉（删只按 hash）。
    ///
    /// 🔑 这条守的是「端侧传错扩展名」这个**真实故障**：
    ///    若 `delete` 依赖调用方传对 ext，用户删书后文件会残留、配额不退。
    #[test]
    fn test_delete_ignores_ext() {
        let (st, _root) = tmp_store("delext");
        st.put("u1", HASH, "epub", b"AAA").unwrap();
        st.put("u1", HASH, "txt", b"BB").unwrap(); // 同一本书的另一种格式（异常但可能）
        assert_eq!(st.disk_usage_of("u1").unwrap(), 5);
        let freed = st.delete("u1", HASH).unwrap();
        assert_eq!(freed, 5, "两种扩展名都要删掉");
        assert_eq!(st.disk_usage_of("u1").unwrap(), 0);
    }

    /// **用户隔离**：别人的 hash 删不到我的文件。
    #[test]
    fn test_user_isolation() {
        let (st, _root) = tmp_store("iso");
        st.put("u1", HASH, "epub", b"MINE").unwrap();
        st.delete("u2", HASH).unwrap(); // u2 名下没有 ⇒ 幂等返回 0
        assert!(
            st.local_path("u1", HASH, "epub").unwrap().is_some(),
            "🔴 删 u2 的文件不该动到 u1"
        );
    }

    /// 不存在的用户 = 0 占用，不是错误（首次使用的正常路径）。
    #[test]
    fn test_missing_user_reads_as_zero() {
        let (st, _root) = tmp_store("missing");
        assert_eq!(st.disk_usage_of("nobody").unwrap(), 0);
        assert_eq!(st.delete("nobody", HASH).unwrap(), 0);
    }
}

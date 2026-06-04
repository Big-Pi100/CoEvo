//! E2E 管理后台全功能测试（纯 HTTP）
//!
//! 覆盖 ~25 个 admin API 端点:
//!   认证: POST /api/admin/login, /api/admin/register
//!   仪表盘: GET /api/admin/dashboard
//!   用户管理: GET/DELETE/POST/PUT/POST .../users/...
//!   管理员管理: GET/POST/PUT/DELETE/POST .../admins/...
//!   订阅管理: GET/POST .../subscription-requests/...
//!   审计日志: GET /api/admin/audit-log
//!   监护人: GET /api/admin/guardian/...

use serde_json::{json, Value};
use std::sync::OnceLock;

static INIT: OnceLock<()> = OnceLock::new();

async fn start_server() -> String {
    for p in &["../../.env", ".env", "../.env"] {
        let _ = dotenvy::from_filename(p);
    }
    INIT.get_or_init(|| {
        chat_engine::prompt_loader::init("../../prompts");
        let _ = std::fs::create_dir_all("data");
    });
    let db_path = format!("data/test_admin_{}.db", chrono::Utc::now().timestamp());
    let _ = std::fs::remove_file(&db_path);
    api_server::db_pool::init(&db_path).expect("init db");
    let conn = api_server::db_pool::get_conn();
    let sql = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/schema.sql"));
    conn.execute_batch(&sql).expect("schema init");
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS user_preferences (
            user_id TEXT NOT NULL, key TEXT NOT NULL,
            value TEXT NOT NULL, updated_at TEXT NOT NULL,
            PRIMARY KEY (user_id, key),
            FOREIGN KEY (user_id) REFERENCES users(id)
        );"
    ).expect("user_preferences table");
    let api_key = std::env::var("DEEPSEEK_API_KEY").expect("DEEPSEEK_API_KEY 未设置");
    let llm_config = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(&api_key);
    let app = api_server::routes::build_router(llm_config);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let base = format!("http://{}", addr);
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap(); });
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    base
}

async fn body_json(resp: reqwest::Response) -> Value {
    resp.json().await.unwrap_or(json!({"raw": "parse failed"}))
}

#[tokio::test]
#[ignore]
async fn e2e_admin_lifecycle() {
    println!("\n{}", "=".repeat(70));
    println!(" 🔐 Admin E2E test – full admin API coverage");
    println!("{}", "=".repeat(70));

    let base = start_server().await;
    let client = reqwest::Client::new();
    let mut calls = 0u32;

    // ── Step 1: Admin login (直接创建 admin 用户到 DB 然后登录) ──
    println!("\n--- Step 1: Admin setup & login ---");
    let admin_hash = bcrypt::hash("admin123!", bcrypt::DEFAULT_COST).unwrap();
    let admin_id = "super_admin";
    {
        let conn = api_server::db_pool::get_conn();
        conn.execute(
            "INSERT OR IGNORE INTO admin_users (id, username, password_hash, role, status, real_name, phone, created_at)
             VALUES (?1, 'superadmin', ?2, 'super', 'active', ?3, ?4, ?5)",
            rusqlite::params![admin_id, admin_hash, "超级管理员", "13800138000", chrono::Utc::now().timestamp()],
        ).expect("insert admin user");
    }

    let resp = client.post(format!("{}/api/admin/login", base))
        .json(&json!({"username": "superadmin", "password": "admin123!"}))
        .send().await.unwrap();
    let login: Value = body_json(resp).await;
    calls += 1;
    let admin_token = login["token"].as_str().expect("admin login token").to_string();
    println!("  admin_id: {}, role: {}, token: {}...",
        login["admin_id"].as_str().unwrap_or("?"),
        login["role"].as_str().unwrap_or("?"),
        &admin_token[..16]);

    // ── Step 2: Dashboard ──
    println!("\n--- Step 2: GET /api/admin/dashboard ---");
    let resp = client.get(format!("{}/api/admin/dashboard", base))
        .header("Authorization", format!("Bearer {}", admin_token))
        .send().await.unwrap();
    let dash: Value = body_json(resp).await;
    calls += 1;
    println!("  dashboard keys: {:?}", dash.as_object().map(|o| o.keys().cloned().collect::<Vec<_>>()).unwrap_or_default());
    assert!(dash.is_object(), "dashboard should return an object");

    // ── Step 3: Admin list (当前管理员) ──
    println!("\n--- Step 3: GET /api/admin/admins ---");
    let resp = client.get(format!("{}/api/admin/admins", base))
        .header("Authorization", format!("Bearer {}", admin_token))
        .send().await.unwrap();
    let admins: Value = body_json(resp).await;
    calls += 1;
    let admin_list = admins.as_array().unwrap_or(&vec![]).clone();
    println!("  admins: {} (super admins excluded from list)", admin_list.len());
    // 管理员列表排除 super 角色，所以新用户可能为 0
    if let Some(first) = admin_list.first() {
        println!("  first admin: id={}, username={}", 
            first["id"].as_str().unwrap_or("?"), first["username"].as_str().unwrap_or("?"));
    }

    // ── Step 4: 注册两个普通用户 ──
    println!("\n--- Step 4: Create test users ---");
    let resp = client.post(format!("{}/api/auth/register", base))
        .json(&json!({"username": "testusera", "password": "test123"}))
        .send().await.unwrap();
    let reg_a: Value = body_json(resp).await;
    calls += 1;
    let uid_a = reg_a["user_id"].as_str().expect("register uid_a").to_string();

    let resp = client.post(format!("{}/api/auth/register", base))
        .json(&json!({"username": "testuserb", "password": "test123"}))
        .send().await.unwrap();
    let reg_b: Value = body_json(resp).await;
    calls += 1;
    let uid_b = reg_b["user_id"].as_str().expect("register uid_b").to_string();
    println!("  created users: {} {}", uid_a, uid_b);

    // ── Step 5: GET /api/admin/users ──
    println!("\n--- Step 5: GET /api/admin/users ---");
    let resp = client.get(format!("{}/api/admin/users?q=&page=1", base))
        .header("Authorization", format!("Bearer {}", admin_token))
        .send().await.unwrap();
    let users_list: Value = body_json(resp).await;
    calls += 1;
    let users = users_list["users"].as_array().unwrap_or(&vec![]).clone();
    println!("  users: {} (page=1)", users.len());
    if users.len() < 2 {
        // Debug the raw response
        let resp2 = client.get(format!("{}/api/admin/users", base))
            .header("Authorization", format!("Bearer {}", admin_token))
            .send().await.unwrap();
        let status = resp2.status();
        let body_text = resp2.text().await.unwrap_or_default();
        println!("  DEBUG: status={}, body(200chars)={}", status, &body_text[..body_text.len().min(200)]);
    }
    assert!(users.len() >= 2, "should see test users, got {}", users.len());

    // ── Step 6: GET /api/admin/users/{uid} (user detail) ──
    println!("\n--- Step 6: GET /api/admin/users/{} (detail) ---", uid_a);
    let resp = client.get(format!("{}/api/admin/users/{}", base, uid_a))
        .header("Authorization", format!("Bearer {}", admin_token))
        .send().await.unwrap();
    let detail: Value = body_json(resp).await;
    calls += 1;
    println!("  user detail: id={}", detail["id"].as_str().unwrap_or("?"));

    // ── Step 7: DELETE /api/admin/users/{uid} (软删除) ──
    println!("\n--- Step 7: DELETE /api/admin/users/{} (disable) ---", uid_b);
    let resp = client.delete(format!("{}/api/admin/users/{}", base, uid_b))
        .header("Authorization", format!("Bearer {}", admin_token))
        .send().await.unwrap();
    let disable_resp: Value = body_json(resp).await;
    calls += 1;
    println!("  disable response: {:?}", disable_resp);
    let delete_ok = disable_resp.get("status").and_then(|s| s.as_str()) == Some("ok")
        || disable_resp.get("error").and_then(|e| e.as_str()) != Some("User not found");
    println!("  delete result: {}", if delete_ok { "ok" } else { "check error" });

    // ── Step 8: POST /api/admin/users/{uid}/restore (恢复) ──
    println!("\n--- Step 8: POST /api/admin/users/{}/restore ---", uid_b);
    let resp = client.post(format!("{}/api/admin/users/{}/restore", base, uid_b))
        .header("Authorization", format!("Bearer {}", admin_token))
        .send().await.unwrap();
    calls += 1;
    println!("  restore: {}", resp.status());

    // ── Step 9: PUT /api/admin/users/{uid}/subscription (设置订阅) ──
    println!("\n--- Step 9: PUT subscription for user {} ---", uid_a);
    let expires = format!("{}T00:00:00Z",
        (chrono::Utc::now() + chrono::Duration::days(90)).format("%Y-%m-%d"));
    let resp = client.put(format!("{}/api/admin/users/{}/subscription", base, uid_a))
        .header("Authorization", format!("Bearer {}", admin_token))
        .json(&json!({"subscription_expires": expires}))
        .send().await.unwrap();
    calls += 1;
    println!("  set subscription: {}", resp.status());

    // ── Step 10: POST /api/admin/users/batch-subscription (批量订阅) ──
    println!("\n--- Step 10: POST batch subscription ---");
    let resp = client.post(format!("{}/api/admin/users/batch-subscription", base))
        .header("Authorization", format!("Bearer {}", admin_token))
        .json(&json!({"user_ids": [uid_a], "days": 30}))
        .send().await.unwrap();
    calls += 1;
    println!("  batch subscription: {}", resp.status());

    // ── Step 11: GET /api/admin/users/expiring (到期待提醒用户) ──
    println!("\n--- Step 11: GET /api/admin/users/expiring ---");
    let resp = client.get(format!("{}/api/admin/users/expiring", base))
        .header("Authorization", format!("Bearer {}", admin_token))
        .send().await.unwrap();
    calls += 1;
    println!("  expiring: {}", resp.status());

    // ── Step 12: POST /api/admin/subscription-requests (创建订阅请求) ──
    println!("\n--- Step 12: POST subscription-requests ---");
    let resp = client.post(format!("{}/api/admin/subscription-requests", base))
        .header("Authorization", format!("Bearer {}", admin_token))
        .json(&json!({"target_user_id": uid_a, "package": "premium", "note": "test request"}))
        .send().await.unwrap();
    let req_resp: Value = body_json(resp).await;
    calls += 1;
    println!("  create request: {:?}", req_resp);
    let req_id = req_resp.get("id").and_then(|i| i.as_str()).unwrap_or("").to_string();

    // ── Step 13: GET /api/admin/subscription-requests (列表) ──
    println!("\n--- Step 13: GET subscription-requests ---");
    let resp = client.get(format!("{}/api/admin/subscription-requests", base))
        .header("Authorization", format!("Bearer {}", admin_token))
        .send().await.unwrap();
    let req_list: Value = body_json(resp).await;
    calls += 1;
    let reqs = req_list.as_array().unwrap_or(&vec![]).clone();
    println!("  requests: {}", reqs.len());

    // ── Step 14: POST approve subscription request ──
    if !req_id.is_empty() {
        println!("\n--- Step 14: POST approve request {} ---", req_id);
        let resp = client.post(format!("{}/api/admin/subscription-requests/{}/approve", base, req_id))
            .header("Authorization", format!("Bearer {}", admin_token))
            .send().await.unwrap();
        calls += 1;
        println!("  approve: {}", resp.status());
    }

    // ── Step 15: POST /api/admin/admins (创建新管理员) ──
    println!("\n--- Step 15: POST create sub-admin ---");
    let resp = client.post(format!("{}/api/admin/admins", base))
        .header("Authorization", format!("Bearer {}", admin_token))
        .json(&json!({"username": "subadmin1", "password": "subpass123", "real_name": "测试", "phone": "13900000001", "role": "service", "permissions": "users.read,users.write"}))
        .send().await.unwrap();
    let new_admin: Value = body_json(resp).await;
    calls += 1;
    println!("  create admin: {:?}", new_admin.get("admin_id"));
    let sub_admin_id = new_admin["admin_id"].as_str().unwrap_or("").to_string();

    // ── Step 16: PUT /api/admin/admins/{id}/permissions (修改权限) ──
    if !sub_admin_id.is_empty() {
        println!("\n--- Step 16: PUT admin permissions ---");
        let resp = client.put(format!("{}/api/admin/admins/{}/permissions", base, sub_admin_id))
            .header("Authorization", format!("Bearer {}", admin_token))
            .json(&json!({"permissions": "users.read"}))
            .send().await.unwrap();
        calls += 1;
        println!("  set permissions: {}", resp.status());

        // ── Step 17: DELETE disable admin ──
        println!("\n--- Step 17: DELETE disable admin ---");
        let resp = client.delete(format!("{}/api/admin/admins/{}/disable", base, sub_admin_id))
            .header("Authorization", format!("Bearer {}", admin_token))
            .send().await.unwrap();
        calls += 1;
        println!("  disable: {}", resp.status());

        // ── Step 18: POST enable admin ──
        println!("\n--- Step 18: POST enable admin ---");
        let resp = client.post(format!("{}/api/admin/admins/{}/enable", base, sub_admin_id))
            .header("Authorization", format!("Bearer {}", admin_token))
            .send().await.unwrap();
        calls += 1;
        println!("  enable: {}", resp.status());

        // ── Step 19: POST reset admin password ──
        println!("\n--- Step 19: POST reset admin password ---");
        let resp = client.post(format!("{}/api/admin/admins/{}/password", base, sub_admin_id))
            .header("Authorization", format!("Bearer {}", admin_token))
            .json(&json!({"password": "newpass456"}))
            .send().await.unwrap();
        calls += 1;
        println!("  reset password: {}", resp.status());

    // ── Test approve/reject routes with directly inserted pending admin ──
    println!("\n--- Step X: Test admin approve/reject routes ---");
    let pending_id = "pending_admin_test";
    {
        let conn = api_server::db_pool::get_conn();
        let hash = bcrypt::hash("pend123!", bcrypt::DEFAULT_COST).unwrap();
        conn.execute(
            "INSERT OR IGNORE INTO admin_users (id, username, password_hash, role, status, real_name, phone, created_at)
             VALUES (?1, 'pendingadmintest', ?2, 'tutor', 'pending', ?3, ?4, ?5)",
            rusqlite::params![pending_id, hash, "张待审", "13900000002", chrono::Utc::now().timestamp()],
        ).expect("insert pending admin");
    }

    // Approve
    println!("\n--- POST /api/admin/admins/{}/approve ---", pending_id);
    let resp = client.post(format!("{}/api/admin/admins/{}/approve", base, pending_id))
        .header("Authorization", format!("Bearer {}", admin_token))
        .send().await.unwrap();
    calls += 1;
    println!("  approve: {} {:?}", resp.status(), body_json(resp).await);

    // Create another pending then reject
    let reject_id = "reject_admin_test";
    {
        let conn = api_server::db_pool::get_conn();
        let hash = bcrypt::hash("rej123!", bcrypt::DEFAULT_COST).unwrap();
        conn.execute(
            "INSERT OR IGNORE INTO admin_users (id, username, password_hash, role, status, real_name, phone, created_at)
             VALUES (?1, 'rejectadmintest', ?2, 'tutor', 'pending', ?3, ?4, ?5)",
            rusqlite::params![reject_id, hash, "李拒绝", "13900000003", chrono::Utc::now().timestamp()],
        ).expect("insert reject admin");
    }

    println!("\n--- POST /api/admin/admins/{}/reject ---", reject_id);
    let resp = client.post(format!("{}/api/admin/admins/{}/reject", base, reject_id))
        .header("Authorization", format!("Bearer {}", admin_token))
        .json(&json!({"reject_reason": "资料不完整"}))
        .send().await.unwrap();
    calls += 1;
    println!("  reject: {} {:?}", resp.status(), body_json(resp).await);
    }

    // ── Step 20: GET /api/admin/audit-log ──
    println!("\n--- Step 20: GET /api/admin/audit-log ---");
    let resp = client.get(format!("{}/api/admin/audit-log", base))
        .header("Authorization", format!("Bearer {}", admin_token))
        .send().await.unwrap();
    let audit: Value = body_json(resp).await;
    calls += 1;
    let audit_entries = audit.as_array().map(|a| a.len()).unwrap_or(0);
    println!("  audit log entries: {}", audit_entries);

    // ── Step 21: GET /api/admin/guardian/students (监护学生) ──
    println!("\n--- Step 21: GET /api/admin/guardian/students ---");
    let resp = client.get(format!("{}/api/admin/guardian/students", base))
        .header("Authorization", format!("Bearer {}", admin_token))
        .send().await.unwrap();
    calls += 1;
    println!("  guardian/students: {}", resp.status());

    // ── Step 22: GET /api/admin/users/export (导出用户) ──
    println!("\n--- Step 22: GET /api/admin/users/export ---");
    let resp = client.get(format!("{}/api/admin/users/export?q=&page=1", base))
        .header("Authorization", format!("Bearer {}", admin_token))
        .send().await.unwrap();
    calls += 1;
    println!("  export: {}", resp.status());

    // ── Step 22: POST /api/admin/users/{uid}/quick-extend ──
    println!("\n--- Step 22: POST quick-extend for user {} ---", uid_a);
    let resp = client.post(format!("{}/api/admin/users/{}/quick-extend", base, uid_a))
        .header("Authorization", format!("Bearer {}", admin_token))
        .json(&json!({"subscription_expires": expires, "days": 30}))
        .send().await.unwrap();
    calls += 1;
    println!("  quick-extend: {}", resp.status());

    // ── Summary ──
    println!("\n{}", "=".repeat(70));
    println!(" 🔐 Admin E2E test passed – {} API calls (no LLM)", calls);
    println!("    覆盖 22 个 admin 端点的核心功能");
    println!("{}", "=".repeat(70));
}

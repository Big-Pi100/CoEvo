"""CoEvo V4 Schema Audit — 检查所有 SQL 查询的字段与 DB 表结构是否一致"""
import re, os, sqlite3, sys

BACKEND = r"E:\CoEvo\backend"
RUST_DIRS = [
    os.path.join(BACKEND, "crates", "api_server", "src"),
    os.path.join(BACKEND, "crates", "card_engine", "src"),
    os.path.join(BACKEND, "src"),
    os.path.join(BACKEND, "crates", "api_server", "tests"),
]

# ── 从 schema.rs 提取实际 DB 表结构 ──
def parse_schema_tables(schema_rs_path: str) -> dict:
    """解析 schema.rs 中的 CREATE TABLE 语句，返回 {table: {col: type}}"""
    tables = {}
    current_table = None
    columns = {}
    in_schema = False
    
    with open(schema_rs_path, 'r', encoding='utf-8') as f:
        for line in f:
            # Detect SCHEMA_SQL start
            if "pub const SCHEMA_SQL" in line or "ADMIN_SCHEMA_SQL" in line:
                in_schema = True
                continue
            if in_schema and ';"' in line and line.strip().endswith('";'):
                # SQL const ends with "#
                if current_table and columns:
                    tables[current_table] = dict(columns)
                current_table = None
                columns = {}
                in_schema = False
                continue
            if not in_schema:
                continue
            
            # Clean the line
            clean = line.strip()
            # Remove r#" / "#  etc
            clean = re.sub(r'^r#["#]', '', clean)
            clean = re.sub(r'"#$', '', clean)
            
            # Detect CREATE TABLE
            m = re.match(r'CREATE TABLE\s+(?:IF NOT EXISTS\s+)?(\w+)\s*\(', clean)
            if m:
                if current_table and columns:
                    tables[current_table] = dict(columns)
                current_table = m.group(1)
                columns = {}
                continue
            
            # Detect column definition
            if current_table:
                cm = re.match(r'\s*(\w+)\s+(\w+(?:\s*\([^)]*\))?)\s*(?:DEFAULT|NOT NULL|PRIMARY|REFERENCES|CHECK|,|$)', clean)
                if cm:
                    col_name = cm.group(1)
                    col_type = cm.group(2)
                    if col_name not in ('PRIMARY', 'FOREIGN', 'UNIQUE', 'CHECK', 'INDEX', 'CONSTRAINT'):
                        columns[col_name] = col_type
            
            # End of table
            if ');' in clean and current_table:
                tables[current_table] = dict(columns)
                current_table = None
                columns = {}
    
    return tables

# ── 从 Rust 文件提取 SQL 查询 ──
def extract_sql_queries(filepath: str) -> list:
    """从 Rust 源码中提取 SQL 字符串"""
    queries = []
    with open(filepath, 'r', encoding='utf-8') as f:
        try:
            content = f.read()
        except:
            return queries
    
    # Find all SQL strings (in double quotes or raw strings)
    # Patterns: "SELECT ...", r"SELECT ...", r#"SELECT ..."#
    patterns = [
        r'(?:"(SELECT\s+.+?;\s*?)")',
        r'(?:r"(SELECT\s+.+?;\s*?)")',
        r'(?:r#"(SELECT\s+.+?;\s*?)"#)',
        r'(?:r##"(SELECT\s+.+?;\s*?)"##)',
        r'(?:"(INSERT\s+(?:OR\s+\w+\s+)?INTO\s+.+?;\s*?)")',
        r'(?:r"(INSERT\s+(?:OR\s+\w+\s+)?INTO\s+.+?;\s*?)")',
        r'(?:r#"(INSERT\s+(?:OR\s+\w+\s+)?INTO\s+.+?;\s*?)"#)',
        r'(?:"(UPDATE\s+.+?;\s*?)")',
        r'(?:r"(UPDATE\s+.+?;\s*?)")',
        r'(?:r#"(UPDATE\s+.+?;\s*?)"#)',
        r'(?:"(DELETE\s+.+?;\s*?)")',
        r'(?:r"(DELETE\s+.+?;\s*?)")',
        r'(?:r#"(DELETE\s+.+?;\s*?)"#)',
    ]
    
    for pat in patterns:
        for m in re.finditer(pat, content, re.IGNORECASE | re.DOTALL):
            sql = m.group(1).strip()
            if len(sql) > 10 and any(kw in sql.upper() for kw in ['SELECT', 'INSERT', 'UPDATE', 'DELETE']):
                queries.append(sql)
    
    return queries

# ── 验证查询 ──
def verify_query(sql: str, tables: dict) -> list:
    """验证 SQL 查询中的表和列是否在 schema 中"""
    issues = []
    sql_upper = sql.upper()
    
    # Extract table names
    table_refs = re.findall(r'(?:FROM|JOIN|INTO|UPDATE)\s+(\w+)', sql, re.IGNORECASE)
    
    for tbl in table_refs:
        if tbl.upper() in ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'WHERE', 'SET', 'VALUES', 'ON', 'AS', 'ORDER', 'GROUP', 'LIMIT', 'HAVING', 'DISTINCT'):
            continue
        if tbl in ['?1', '?2', '?3', '?4', '?5', '?6', '?7', '?8', '?9', '?10', '?11', '?12']:
            continue
        if tbl.startswith('idx_'):
            continue
            
        if tbl not in tables:
            issues.append(f"❌ 表 {tbl} 不存在于 schema")
            continue
        
        # Extract column references for this table
        # Find col refs after the table reference
        col_pattern = re.compile(rf'(?:(?<=\s)|(?<=,)|(?<=\()){tbl}\.(\w+)', re.IGNORECASE)
        for cm in col_pattern.finditer(sql):
            col = cm.group(1)
            if col.upper() in ('AS', 'ON', 'WHERE', 'AND', 'OR', 'IN', 'NOT', 'NULL', 'IS', 'BETWEEN', 'LIKE', 'ORDER', 'BY', 'GROUP', 'LIMIT', 'HAVING', 'DISTINCT', 'COUNT', 'SUM', 'AVG', 'MIN', 'MAX', 'COALESCE', 'CAST', 'CASE', 'WHEN', 'THEN', 'ELSE', 'END'):
                continue
            if col not in tables[tbl]:
                issues.append(f"❌ {tbl}.{col} 不存在 (表有: {list(tables[tbl].keys())[:10]}...)")
    
    # Also check bare column refs in SELECT
    if sql_upper.startswith('SELECT'):
        # Extract column list from SELECT
        select_match = re.match(r'SELECT\s+(.+?)\s+FROM', sql, re.IGNORECASE | re.DOTALL)
        if select_match:
            select_clause = select_match.group(1)
            # Find column references without table prefix
            bare_cols = re.findall(r'(?:^|,)["`]?(\w+)["`]?(?:\s+AS\s+|,|\s*$)', select_clause, re.IGNORECASE)
            # These need context to verify - skip for now
    
    return issues

# ── Main ──
def main():
    schema_path = os.path.join(BACKEND, "crates", "api_server", "src", "schema.rs")
    tables = parse_schema_tables(schema_path)
    
    print("=" * 70)
    print("CoEvo V4 Schema Audit — 表结构")
    print("=" * 70)
    for tbl, cols in sorted(tables.items()):
        print(f"  {tbl}: {len(cols)} columns — {', '.join(cols.keys())}")
    
    print()
    print("=" * 70)
    print("SQL 查询字段级审计")
    print("=" * 70)
    
    all_issues = []
    processed_files = []
    
    for dir_path in RUST_DIRS:
        if not os.path.exists(dir_path):
            continue
        for root, _, files in os.walk(dir_path):
            for fname in files:
                if not fname.endswith('.rs'):
                    continue
                fpath = os.path.join(root, fname)
                relpath = os.path.relpath(fpath, BACKEND)
                queries = extract_sql_queries(fpath)
                if not queries:
                    continue
                processed_files.append((relpath, len(queries)))
                for sql in queries:
                    issues = verify_query(sql, tables)
                    for i in issues:
                        all_issues.append((relpath, sql[:100], i))
    
    print(f"\n扫描了 {len(processed_files)} 个含 SQL 的文件，发现 {len(all_issues)} 个问题:\n")
    
    if not all_issues:
        print("  ✅ 零问题")
    else:
        for fpath, sql, issue in sorted(all_issues):
            print(f"  [{fpath}]")
            print(f"    SQL: {sql}...")
            print(f"    {issue}")
            print()
    
    # Summary
    print("=" * 70)
    print("汇总")
    print("=" * 70)
    for fpath, count in sorted(processed_files, key=lambda x: -x[1]):
        print(f"  {fpath}: {count} 条 SQL")
    print(f"\n总计: {sum(c for _, c in processed_files)} 条 SQL 查询")

if __name__ == '__main__':
    main()

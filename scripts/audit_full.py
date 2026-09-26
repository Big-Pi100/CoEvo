"""CoEvo V4 数据读写全面审计 — 检查所有 SQL 查询与 DB 表结构的一致性"""

import re, os, sys, glob

BACKEND = r"E:\CoEvo\backend"

# ── 从 schema.rs 解析表结构 ──
def parse_tables(schema_rs: str) -> dict:
    tables = {}
    with open(schema_rs, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # 找到所有 SQL 常量中的 CREATE TABLE
    # 提取 SCHEMA_SQL 和 ADMIN_SCHEMA_SQL
    sql_sections = []
    for const_name in ['SCHEMA_SQL', 'ADMIN_SCHEMA_SQL']:
        # Find const definition
        idx = content.find(f'pub const {const_name}')
        if idx < 0:
            continue
        # Find the start of the string (r#" or "...)
        str_start = content.find('r#"', idx)
        if str_start < 0:
            str_start = content.find('"', idx)
            if str_start < 0: continue
        # Find the end
        str_end = content.find('"#', str_start + 3)
        if str_end < 0:
            str_end = content.find('";', str_start + 1)
        if str_end > str_start:
            sql_sections.append(content[str_start:str_end+2])
    
    for section in sql_sections:
        # Clean up raw string markers
        clean = section.replace('r#"', '').replace('"#', '')
        
        # Split into individual SQL statements
        statements = re.split(r';\s*', clean)
        for stmt in statements:
            stmt = stmt.strip()
            if not stmt: continue
            
            # Match: CREATE TABLE [IF NOT EXISTS] tablename ( ... )
            m = re.match(
                r'CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s*\((.*)',
                stmt, re.IGNORECASE | re.DOTALL
            )
            if not m:
                continue
            tbl_name = m.group(1)
            col_text = m.group(2).strip()
            
            cols = {}
            # Split by commas, handling nested parens
            depth = 0
            current = []
            for ch in col_text:
                if ch == '(':
                    depth += 1
                    current.append(ch)
                elif ch == ')':
                    depth -= 1
                    current.append(ch)
                elif ch == ',' and depth == 0:
                    field = ''.join(current).strip()
                    if field:
                        cm = re.match(r'(\w+)\s+(\w+(?:\s*\([^)]*\))?)', field)
                        if cm and cm.group(1) not in ('PRIMARY', 'FOREIGN', 'UNIQUE', 'CHECK', 'CONSTRAINT', 'INDEX'):
                            cols[cm.group(1)] = cm.group(2)
                    current = []
                else:
                    current.append(ch)
            # Last field
            field = ''.join(current).strip()
            if field:
                cm = re.match(r'(\w+)\s+(\w+(?:\s*\([^)]*\))?)', field)
                if cm and cm.group(1) not in ('PRIMARY', 'FOREIGN', 'UNIQUE', 'CHECK', 'CONSTRAINT', 'INDEX'):
                    cols[cm.group(1)] = cm.group(2)
            
            if cols:
                tables[tbl_name] = cols
    
    return tables


# ── 从 Rust 源文件提取 SQL 查询 ──
def extract_sql_queries(filepath: str) -> list:
    """Extract SQL queries from Rust source files, handling various string formats."""
    queries = []
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except:
        return queries
    
    # Patterns for SQL strings in Rust
    # Match "SELECT ... ", r"SELECT ... ", r#"SELECT ... "#, r##"..."##
    patterns = [
        # Raw strings: r#"..."# or r##"..."##
        (r'r#+"([^"]*(?:""[^"]*)*)"\s*#+', True),
        # Regular strings: "..." 
        (r'"((?:[^"\\]|\\.)*)"', True),
    ]
    
    for pattern, check_sql in patterns:
        for m in re.finditer(pattern, content):
            sql = m.group(1).strip()
            if not sql or len(sql) < 10:
                continue
            upper = sql.upper()
            # Must contain SQL keywords
            if any(kw in upper for kw in ['SELECT ', 'INSERT ', 'UPDATE ', 'DELETE ', 'CREATE ', 'ALTER ']):
                # Clean up
                sql = sql.replace('\\n', '\n').replace('\\"', '"').replace('\\t', '\t')
                queries.append(sql)
    
    return queries


# ── 验证 SQL 中的表和列引用 ──
def extract_tables_from_sql(sql: str) -> list:
    """Extract table names referenced in a SQL query."""
    upper = sql.upper()
    tables = set()
    
    # FROM table, JOIN table, INTO table, UPDATE table
    for kw in ['FROM', 'JOIN', 'INTO', 'UPDATE', 'TABLE']:
        idx = 0
        while True:
            pos = upper.find(kw, idx)
            if pos < 0:
                break
            after_kw = sql[pos+len(kw):].strip()
            # Next word is the table name
            m2 = re.match(r'(\w+)', after_kw)
            if m2:
                name = m2.group(1)
                skip_words = {'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'WHERE', 'SET', 'VALUES', 'ON', 
                            'AS', 'ORDER', 'GROUP', 'LIMIT', 'HAVING', 'DISTINCT', 'COUNT', 'SUM',
                            'AVG', 'MIN', 'MAX', 'COALESCE', 'CAST', 'CASE', 'WHEN', 'THEN', 'ELSE',
                            'END', 'AND', 'OR', 'NOT', 'IN', 'IS', 'NULL', 'LIKE', 'BETWEEN',
                            'EXISTS', 'UNION', 'ALL', 'LEFT', 'RIGHT', 'INNER', 'OUTER', 'CROSS',
                            'INDEX', 'BY', 'DESC', 'ASC', 'PRAGMA'}
                if name.upper() not in skip_words and not name.startswith('idx_') and not name.startswith('?'):
                    tables.add(name)
            idx = pos + len(kw)
    
    return list(tables)


def extract_col_refs(sql: str) -> list:
    """Extract table.column references from SQL."""
    refs = []
    # Pattern: table.col or table."col"
    for m in re.finditer(r'(\w+)\.(\w+)', sql):
        refs.append((m.group(1), m.group(2)))
    return refs


# ── 类型兼容性检查 ──
TEXT_TYPES = {'TEXT', 'TEXT(', 'VARCHAR', 'CHAR'}
INT_TYPES = {'INTEGER', 'INT', 'BIGINT', 'SMALLINT', 'TINYINT', 'REAL', 'FLOAT', 'DOUBLE', 'NUMERIC', 'DECIMAL'}

def is_type_mismatch(rust_type: str, sql_type: str) -> bool:
    """Check if reading a SQL column as a Rust type might fail."""
    sql_type_upper = sql_type.upper().split('(')[0].strip()
    
    if rust_type == 'i64' and sql_type_upper in TEXT_TYPES:
        return True  # TEXT column read as i64 — will fail for datetime strings
    if rust_type == 'String' and sql_type_upper in INT_TYPES:
        return False  # String can read anything
    return False


# ── 主审计 ──
def main():
    schema_path = os.path.join(BACKEND, "crates", "api_server", "src", "schema.rs")
    tables = parse_tables(schema_path)
    
    print("=" * 72)
    print("CoEvo V4 数据读写全面审计报告")
    print("=" * 72)
    print(f"扫描到 {len(tables)} 张表\n")
    
    # Collect all .rs files
    rs_files = []
    for root, dirs, files in os.walk(BACKEND):
        # Skip target and .git
        if 'target' in root or '.git' in root:
            continue
        for f in files:
            if f.endswith('.rs'):
                rs_files.append(os.path.join(root, f))
    
    print(f"扫描 {len(rs_files)} 个 .rs 文件...\n")
    
    type_issues = []
    old_table_refs = []
    field_mismatches = []
    ok_count = 0
    file_sql_count = {}
    
    for fpath in sorted(rs_files):
        relpath = os.path.relpath(fpath, BACKEND)
        queries = extract_sql_queries(fpath)
        if not queries:
            continue
        file_sql_count[relpath] = len(queries)
        
        for sql in queries:
            # 1. Check for old table names
            upper = sql.upper()
            for old_tbl in ['CARDS ', 'CONVERSATION_PLANS ', 'LEARNING_PLANS ']:
                if old_tbl in upper and 'DROP' not in upper:
                    # Exclude DROP TABLE statements
                    if f'DROP TABLE {old_tbl}' not in upper:
                        old_table_refs.append((relpath, sql[:80]))
            
            # 2. Extract tables and columns
            sql_tables = extract_tables_from_sql(sql)
            col_refs = extract_col_refs(sql)
            
            for tname in sql_tables:
                if tname.startswith('idx_') or tname.upper() in ('IF', 'NOT', 'EXISTS', 'PRAGMA'):
                    continue
                if tname not in tables:
                    # Check if it's a known non-table name
                    skip = {'EXISTS', 'NOT', 'IF', 'TABLE', 'PRIMARY', 'KEY', 'FOREIGN', 'REFERENCES',
                           'UNIQUE', 'CHECK', 'DEFAULT', 'ON', 'DELETE', 'CASCADE', 'SET', 'NULL',
                           'RENAME', 'TO', 'ADD', 'COLUMN', 'DROP', 'INTEGER', 'TEXT', 'REAL', 'BLOB'}
                    if tname.upper() not in skip:
                        field_mismatches.append((relpath, f"❌ 表 '{tname}' 不存在", sql[:60]))
            
            # 3. Check for i64 reads on TEXT columns (type mismatch)
            for tbl, col in col_refs:
                if tbl in tables and col in tables[tbl]:
                    col_type = tables[tbl][col]
                    # Look for row.get::<_, i64>(N) patterns near this SQL
                    pass  # Handled in next step
        
        # 4. Check row.get type patterns
        with open(fpath, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Find row.get patterns that reference created_at/updated_at
        # Look at the SQL context first, then check row.get near it
        for m in re.finditer(r'row\.get::<_,\s*(i64|i32|f64|String)>\s*\((\d+)\)', content):
            rust_type = m.group(1)
            idx = int(m.group(2))
            pos = m.start()
            
            # Look backwards for the SQL string containing column names
            # Find the nearest "SELECT" or "INSERT" before this position
            sql_chunk = content[max(0, pos-500):pos]
            
            # Try to find column names from the SELECT list
            # This is approximate
            if 'created_at' in sql_chunk or 'updated_at' in sql_chunk:
                if rust_type == 'i64':
                    # Determine which table - look for FROM clause
                    from_match = re.search(r'FROM\s+(\w+)', sql_chunk, re.IGNORECASE)
                    tbl_name = from_match.group(1) if from_match else '?'
                    type_issues.append((relpath, f"⚠️ {tbl_name}.created_at 读为 i64（应为 String）"))
    
    # ── 报告 ──
    
    # Old table references
    print("--- 一、旧表名引用 ---")
    if old_table_refs:
        for f, sql in old_table_refs:
            print(f"  ❌ [{f}] {sql}...")
    else:
        print("  ✅ 零残留\n")
    
    # Type mismatches
    print("\n--- 二、类型不匹配（TEXT 列读为 i64）---")
    if type_issues:
        for f, issue in sorted(set(type_issues)):
            print(f"  ❌ [{f}] {issue}")
    else:
        print("  ✅ 无类型不匹配\n")
    
    # Table not found
    print("\n--- 三、引用了不存在的表 ---")
    real_issues = [(f, msg, sql) for f, msg, sql in field_mismatches 
                   if msg.startswith("❌") and not any(k in sql.upper() for k in ['PRAGMA', 'DROP', 'ALTER'])]
    if real_issues:
        for f, msg, sql in real_issues:
            print(f"  ❌ [{f}] {msg}")
            print(f"      SQL: {sql}")
    else:
        print("  ✅ 零错误\n")
    
    # File SQL count summary
    print("\n--- 四、各文件 SQL 查询数量 ---")
    for f, cnt in sorted(file_sql_count.items(), key=lambda x: -x[1])[:20]:
        print(f"  {f}: {cnt} 条")
    print(f"\n  总计: {sum(file_sql_count.values())} 条 SQL 查询\n")
    
    # Overall
    total_issues = len(old_table_refs) + len(type_issues) + len(real_issues)
    print("=" * 72)
    print(f"总体: {'❌ 发现 ' + str(total_issues) + ' 个问题' if total_issues else '✅ 全部通过，零问题'}")
    print("=" * 72)


if __name__ == '__main__':
    main()

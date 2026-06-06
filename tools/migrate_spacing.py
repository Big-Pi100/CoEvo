"""Migrate hardcoded spacing values to AppTheme.spacing* constants."""
import re
import os

SPACING_MAP = {
    '4': 'AppTheme.spacingXs',
    '8': 'AppTheme.spacingSm',
    '12': 'AppTheme.spacingMd',
    '16': 'AppTheme.spacingLg',
    '20': 'AppTheme.spacingXl',
    '24': 'AppTheme.spacingXxl',
    '32': 'AppTheme.spacingXxxl',
    '48': 'AppTheme.spacingXxxxl',
}

# Import paths relative to screen files
IMPORT_FROM_SCREENS = "import '../theme/app_theme.dart';"
IMPORT_FROM_SCREENS_CHAT = "import '../../theme/app_theme.dart';"

def has_spacing_value(line):
    """Check if line has a spacing value (4,8,12,16,20,24,32,48) that could be in an EdgeInsets/SizedBox context."""
    # Quick check: does it have one of our numbers?
    for num_str in SPACING_MAP:
        if re.search(r'\b' + num_str + r'\b', line):
            return True
    return False

def replace_edgeinset_numbers(line):
    """Replace numbers in EdgeInsets/SizedBox context."""
    # Only process if line contains EdgeInsets or SizedBox
    if 'EdgeInsets' not in line and 'SizedBox' not in line:
        return line
    
    def num_replacer(m):
        """Replace a captured number with spacing constant if in map."""
        name = m.group(1)
        num = m.group(2)
        if num in SPACING_MAP:
            return name + SPACING_MAP[num]
        return m.group(0)
    
    def all_replacer(m):
        """EdgeInsets.all(N) → EdgeInsets.all(AppTheme.spacingXxx)"""
        num = m.group(1)
        if num in SPACING_MAP:
            return f'EdgeInsets.all({SPACING_MAP[num]})'
        return m.group(0)
    
    def ltrb_replacer(m):
        """EdgeInsets.fromLTRB(N1, N2, N3, N4) → replace each if in map"""
        nums = [m.group(i) for i in range(1, 5)]
        new_nums = [SPACING_MAP.get(n, n) for n in nums]
        const_prefix = 'const ' if 'const ' in m.group(0) else ''
        return f'{const_prefix}EdgeInsets.fromLTRB({", ".join(new_nums)})'
    
    # 1. EdgeInsets.all(N) → EdgeInsets.all(AppTheme.spacingXxx)
    line = re.sub(r'EdgeInsets\.all\((\d+)\)', all_replacer, line)
    
    # 2. EdgeInsets.fromLTRB(N1, N2, N3, N4)
    line = re.sub(
        r'(?:const\s+)?EdgeInsets\.fromLTRB\((\d+),\s*(\d+),\s*(\d+),\s*(\d+)\)',
        ltrb_replacer, line
    )
    
    # 3. Named params: (keyword: N) where keyword is width/height/horizontal/vertical/left/right/top/bottom/all
    pattern = r'((?:width|height|horizontal|vertical|left|right|top|bottom|all):\s*)(\d+)\b'
    line = re.sub(pattern, num_replacer, line)
    
    return line

def process_file(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    original = content
    lines = content.split('\n')
    modified = False
    
    # Process each line
    new_lines = []
    for line in lines:
        new_lines.append(replace_edgeinset_numbers(line))
    
    content = '\n'.join(new_lines)
    
    if content != original:
        modified = True
    
    # Add import if needed and if file was modified
    import_line = IMPORT_FROM_SCREENS_CHAT if '/chat/' in filepath.replace('\\', '/') else IMPORT_FROM_SCREENS
    if modified and import_line not in content:
        # Find the last import line
        import_lines = [i for i, line in enumerate(new_lines) if line.strip().startswith('import ')]
        if import_lines:
            last_idx = import_lines[-1]
            new_lines.insert(last_idx + 1, import_line)
            content = '\n'.join(new_lines)
    
    if modified:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f"  MODIFIED: {filepath}")
        return 1
    else:
        print(f"  SKIPPED: {filepath} (no changes)")
        return 0

def main():
    screens_dir = os.path.join('E:', os.sep, 'CoEvo', 'app', 'lib', 'screens')
    files = []
    for root, dirs, filenames in os.walk(screens_dir):
        for f in filenames:
            if f.endswith('.dart'):
                files.append(os.path.join(root, f))
    
    files.sort()
    total = 0
    for f in files:
        total += process_file(f)
    
    print(f"\nDone. {total}/{len(files)} files modified.")

if __name__ == '__main__':
    main()

// ignore_for_file: unused_element, unused_local_variable
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import '../api/api_config.dart';
import 'user_detail_screen.dart';
import '../theme/app_theme.dart';
import 'curriculum_plans_page.dart';
import 'curriculum_cards_page.dart';
import 'config_page.dart';
import 'debug_logs_page.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> with TickerProviderStateMixin {
  // ── Theme access ──
  ColorScheme get _cs => Theme.of(context).colorScheme;
  TextTheme get _tt => Theme.of(context).textTheme;

  // Auth
  String? _adminKey; // super admin uses X-Admin-Key
  String? _token;    // other admins use Bearer token
  String? _role;
  // Token / Key auth
  final _keyCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  // User search
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _users = [];
  bool _loading = false;
  int _userPage = 0; // pages loaded so far
  int _userTotal = 0;
  bool _includeDeleted = false;
  bool _userEndReached = false;

  // Tabs & sub-tabs
  late TabController _mainTabCtrl;
  late TabController _curriculumSubTabCtrl;
  int _mainTab = 0;
  String _reqFilter = 'pending';
  List<Map<String, dynamic>> _requests = [];
  List<Map<String, dynamic>> _admins = [];
  String _adminRoleFilter = 'all'; // all | service | guardian | tutor
  List<Map<String, dynamic>> _logs = [];
  List<Map<String, dynamic>> _assignments = [];
  Map<String, dynamic>? _dashboard;
  bool _dashboardLoading = false;
  bool _selectMode = false;
  final Set<String> _selectedUserIds = {};
  final Set<String> _trackedUserIds = {};
  String _logFilter = '';
  final _logSearchCtrl = TextEditingController();
  String _logDateFrom = '';
  String _logDateTo = '';
  bool _logLoading = false;
  bool _logLoaded = false;

  // ── Curriculum tab (tree browser manages its own state) ──

  /// Index of the "运行时配置" tab (depends on role)
  int get _configTabIdx {
    int idx = 3; // after dashboard(0)+users(1)+curriculum(2)
    if (_role == 'super') idx++; // admin mgmt
    if (_role == 'super' || _role == 'service') idx++; // audit log
    return idx;
  }

  /// Index of the "调试日志" tab
  int get _debugTabIdx => _configTabIdx + 1;

  Map<String, String> _headers() {
    if (_adminKey != null) return {'X-Admin-Key': _adminKey!};
    if (_token != null) return {'Authorization': 'Bearer $_token'};
    return {};
  }

  void _onTabChanged() {
    final prev = _mainTab;
    _mainTab = _mainTabCtrl.index;
    if (prev == _mainTab) return;
    setState(() {});
    // Tab 0 = 仪表盘, Tab 1 = 用户管理+订阅（自动加载用户 + 申请列表）
    if (_mainTab == 1) {
      if (_users.isEmpty) { _loadUsersPage(1, replace: true); }
      if (_requests.isEmpty) _loadRequests('pending');
    }
    if (_role == 'super') {
      if (_mainTab == 3) { _loadAdmins(); _loadAssignments(); }
      else if (_mainTab == 4) { _loadLogs(); }
      else if (_mainTab == _configTabIdx) { setState(() {}); }
      else if (_mainTab == _debugTabIdx) { setState(() {}); }
    } else if (_role == 'service') {
      if (_mainTab == 3) _loadLogs();
      else if (_mainTab == _configTabIdx) { setState(() {}); }
      else if (_mainTab == _debugTabIdx) { setState(() {}); }
    }
  }

  @override
  void initState() {
    super.initState();
    _mainTabCtrl = TabController(length: _tabCount(), vsync: this);
    _mainTabCtrl.addListener(_onTabChanged);
    _curriculumSubTabCtrl = TabController(length: 2, vsync: this);
    _curriculumSubTabCtrl.addListener(() { if (mounted) setState(() {}); });
    _loadTrackedUsers();
  }

  int _tabCount() {
    int n = 1; // 仪表盘 always
    n++; // 用户管理+订阅 always
    n++; // 课程数据 always
    if (_role == 'super') n++; // 管理员管理（含分配管理）
    if (_role == 'super' || _role == 'service') n++; // 操作日志
    if (_role == 'super' || _role == 'service') n += 2; // 运行时配置 + 调试日志
    return n;
  }

  void _rebuildTabs() {
    _mainTabCtrl.removeListener(() {});
    _mainTabCtrl.dispose();
    _mainTabCtrl = TabController(length: _tabCount(), vsync: this);
    _mainTabCtrl.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _keyCtrl.dispose(); _passCtrl.dispose(); _searchCtrl.dispose();
    _mainTabCtrl.dispose();
    _curriculumSubTabCtrl.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _api(String method, String path, {Map<String, dynamic>? body}) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}$path');
    final h = _headers();
    final req = method == 'GET'
        ? http.get(uri, headers: h)
        : method == 'POST' ? http.post(uri, headers: {...h, 'Content-Type': 'application/json'}, body: jsonEncode(body ?? {}))
        : method == 'PUT' ? http.put(uri, headers: {...h, 'Content-Type': 'application/json'}, body: jsonEncode(body ?? {}))
        : http.delete(uri, headers: h);
    final resp = await req.timeout(const Duration(seconds: 10));
    try { return jsonDecode(resp.body) as Map<String, dynamic>; } catch (_) { return {'error': '${resp.statusCode}'}; }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // ── Login ──
  Future<void> _loginWithKey() async {
    final key = _keyCtrl.text.trim();
    if (key.isEmpty) return;
    final resp = await http.get(Uri.parse('${ApiConfig.baseUrl}/api/admin/users?q=test'), headers: {'X-Admin-Key': key}).timeout(const Duration(seconds: 5));
    if (resp.statusCode == 200) {
      _adminKey = key;
      _role = 'super';
      _rebuildTabs();
      setState(() { _loading = false; });
      _loadDashboard();
    } else {
      _snack('密钥无效');
    }
  }

  Future<void> _loginWithAccount() async {
    final resp = await _api('POST', '/api/admin/login', body: {'username': _keyCtrl.text.trim(), 'password': _passCtrl.text.trim()});
    if (resp.containsKey('token')) {
      final role = resp['role'] as String? ?? '';
      if (role == 'tutor' || role == 'guardian') {
        _snack('辅导老师/家长请从对应入口登录。正在跳转...');
        Future.delayed(const Duration(seconds: 1), () { if (mounted) context.go(role == 'tutor' ? '/teacher' : '/guardian'); });
        return;
      }
      _token = resp['token'];
      _role = role;
      _rebuildTabs();
      setState(() { _loading = false; });
      _loadDashboard();
    } else { _snack(resp['error'] ?? '登录失败'); }
  }

  // ── User Management ──
  Future<void> _search() async {
    final q = _searchCtrl.text.trim();
    setState(() => _loading = true);
    await _loadUsersPage(1, replace: true, q: q);
  }

  /// Load one page of users and append/replace _users list
  Future<void> _loadUsersPage(int page, {bool replace = false, String? q, bool append = false}) async {
    final params = <String>['page=$page', 'q=${Uri.encodeComponent(q ?? "")}'];
    if (_includeDeleted) params.add('include_deleted=true');
    if (page > 1 || (q ?? "").isEmpty) params.add('sort=expiring');
    final suffix = params.isEmpty ? '' : '?${params.join('&')}';
    final resp = await _api('GET', '/api/admin/users$suffix');
    final newUsers = (resp['users'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final total = resp['total'] as int? ?? 0;
    final totalPages = resp['total_pages'] as int? ?? 1;
    setState(() {
      if (replace) { _users = newUsers; _userPage = 1; _userTotal = total; }
      else if (append) { _users.addAll(newUsers); _userPage = page; }
      _userEndReached = page >= totalPages || newUsers.isEmpty;
      _loading = false;
    });
    _loadTrackedUsers();
  }

  Future<void> _loadTrackedUsers() async {
    try {
      final resp = await _api('GET', '/api/admin/debug/tracks');
      if (resp['tracks'] is List) {
        _trackedUserIds.clear();
        for (final t in resp['tracks']) {
          if (t is Map && t['user_id'] is String) {
            _trackedUserIds.add(t['user_id'] as String);
          }
        }
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  void _loadMoreUsers() {
    if (_userEndReached || _loading) return;
    _loadUsersPage(_userPage + 1, append: true);
  }

  Future<void> _revealPhone(String uid) async {
    // Step 1: reveal masked phone
    final resp1 = await _api('POST', '/api/admin/users/$uid/reveal-phone');
    if (resp1.containsKey('phone')) {
      final maskedPhone = resp1['phone'] as String;
      if (resp1['full'] == true) {
        // Already returned full (shouldn't happen on first call)
        if (!mounted) return;
        showDialog(context: context, builder: (ctx) => AlertDialog(
          title: const Text('手机号'),
          content: Text(maskedPhone),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
        ));
        return;
      }
      // Show masked phone with "查看完整号码" button
      if (!mounted) return;
      showDialog(context: context, builder: (ctx) => AlertDialog(
        title: const Text('手机号'),
        content: Text('已脱敏: $maskedPhone'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          FilledButton(onPressed: () async {
            Navigator.pop(ctx);
            // Step 2: reveal full phone
            final resp2 = await _api('POST', '/api/admin/users/$uid/reveal-phone?full=true');
            if (resp2.containsKey('phone')) {
              if (!mounted) return;
              showDialog(context: context, builder: (ctx2) => AlertDialog(
                title: const Text('完整手机号'),
                content: Text('${resp2['phone']}'),
                actions: [TextButton(onPressed: () => Navigator.pop(ctx2), child: const Text('关闭'))],
              ));
            } else {
              _snack(resp2['error'] ?? '获取失败');
            }
          }, child: const Text('查看完整号码')),
        ],
      ));
    } else { _snack(resp1['error'] ?? '失败'); }
  }

  Future<void> _revealName(String uid) async {
    // Name is already returned masked; for super admin it's already plain
    _snack('姓名已显示');
  }

  void _showSubDialog(Map<String, dynamic> user) {
    final uid = user['user_id'] as String;
    final ctrl = TextEditingController(text: user['subscription_expires'] as String? ?? '');
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('设置到期日'),
      content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: 'yyyy-mm-dd', isDense: true, border: OutlineInputBorder())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () { Navigator.pop(ctx); _api('PUT', '/api/admin/users/$uid/subscription', body: {'subscription_expires': ctrl.text.trim()}).then((r) {
          _snack(r.containsKey('request_id') ? '已提交设置申请，等待审批' : (r.containsKey('status') ? '已设置' : '失败'));
          _search();
        }); }, child: const Text('保存')),
      ],
    ));
  }

  Future<void> _quickExtend(String uid, int days) async {
    final now = DateTime.now();
    String? currentExpiry;
    try {
      final user = await _api('GET', '/api/admin/users/$uid');
      currentExpiry = user['subscription_expires'] as String?;
    } catch (_) {}
    final base = (currentExpiry != null && currentExpiry.isNotEmpty)
        ? (DateTime.tryParse(currentExpiry) ?? now)
        : now;
    final exp = DateTime(base.year, base.month, base.day).add(Duration(days: days));
    final dateStr = '${exp.year}-${exp.month.toString().padLeft(2, '0')}-${exp.day.toString().padLeft(2, '0')}';
    if (_role == 'super') {
      _api('PUT', '/api/admin/users/$uid/subscription', body: {'subscription_expires': dateStr}).then((r) {
        _snack(r.containsKey('status') ? '已延长 $days 天至 $dateStr' : '失败');
        _search();
      });
    } else {
      _api('POST', '/api/admin/users/$uid/quick-extend', body: {'subscription_expires': dateStr, 'days': days}).then((r) {
        if (r['status'] == 'ok') {
          _snack('已延期 ${days}d 至 $dateStr');
          _search();
        } else if (r.containsKey('request_id')) {
          _snack('已提交延期申请，等待审批');
        } else {
          _snack(r['error'] ?? '失败');
        }
      });
    }
  }

  void _toggleSelectMode() {
    setState(() { _selectMode = !_selectMode; if (!_selectMode) _selectedUserIds.clear(); });
  }

  void _toggleSelect(String uid) {
    setState(() {
      if (_selectedUserIds.contains(uid)) { _selectedUserIds.remove(uid); }
      else { _selectedUserIds.add(uid); }
    });
  }

  void _exitSelectMode() {
    setState(() { _selectMode = false; _selectedUserIds.clear(); });
  }

  void _onAction(String action) {
    final ids = _selectedUserIds.toList();
    if (ids.isEmpty) { _snack('请先选择用户'); return; }
    final isBatch = ids.length > 1;
    if (action == 'set_expiry') {
      if (isBatch) { _snack('批量设置到期日请逐个操作'); return; }
      final u = _users.firstWhere((u) => u['user_id'] == ids.first, orElse: () => <String, dynamic>{});
      if (u.isEmpty) { _snack('用户数据未加载'); return; }
      _showSubDialog(u);
    } else if (action == 'delete') {
      if (isBatch) { _snack('批量删除暂不支持'); return; }
      final u = _users.firstWhere((u) => u['user_id'] == ids.first, orElse: () => <String, dynamic>{});
      if (u.isEmpty) { _snack('用户数据未加载'); return; }
      final name = (u['display_name'] as String?) ?? u['username'] as String? ?? '';
      final deletedAt = u['deleted_at'] as String?;
      if (deletedAt != null && deletedAt.isNotEmpty) {
        _showRestoreUserDialog(ids.first, name);
      } else {
        _showDeleteUserDialog(ids.first, name);
      }
    } else if (action == 'hard_delete') {
      if (isBatch) { _snack('批量永久删除暂不支持'); return; }
      final u = _users.firstWhere((u) => u['user_id'] == ids.first, orElse: () => <String, dynamic>{});
      if (u.isEmpty) { _snack('用户数据未加载'); return; }
      final name = (u['display_name'] as String?) ?? u['username'] as String? ?? '';
      _showHardDeleteDialog(ids.first, name);
    } else if (action.startsWith('extend_')) {
      final days = int.tryParse(action.replaceFirst('extend_', '')) ?? 7;
      if (isBatch) {
        _batchExtend(days);
      } else {
        _quickExtend(ids.first, days);
      }
    }
  }

  Future<void> _batchExtend(int days) async {
    if (_selectedUserIds.isEmpty) { _snack('请先选择用户'); return; }
    _api('POST', '/api/admin/users/batch-subscription', body: {'user_ids': _selectedUserIds.toList(), 'days': days}).then((r) {
      final processed = r['processed'] ?? 0;
      _snack('已处理 $processed / ${_selectedUserIds.length} 个用户');
      setState(() { _selectMode = false; _selectedUserIds.clear(); });
      _search();
    });
  }

  void _exportCsv() {
    final q = _searchCtrl.text.trim();
    final url = '${ApiConfig.baseUrl}/api/admin/users/export?q=${Uri.encodeComponent(q)}';
    // For Flutter Web: open download URL via hidden anchor
    final anchor = html.AnchorElement(href: url)..click();
  }

  void _showCreateRequest(Map<String, dynamic> user) {
    String pkg = '365d'; String? channel; final noteCtrl = TextEditingController();
    showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) => AlertDialog(
      title: Text('为 ${user['display_name'] ?? user['username']} 申请开通'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField(value: pkg, items: const [
          DropdownMenuItem(value: '30d', child: Text('30 天')),
          DropdownMenuItem(value: '365d', child: Text('365 天')),
          DropdownMenuItem(value: 'lifetime', child: Text('终身')),
        ], onChanged: (v) => setSt(() => pkg = v!), decoration: const InputDecoration(isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: AppTheme.spacingMd),
        DropdownButtonFormField(value: channel, items: const [
          DropdownMenuItem(value: null, child: Text('（不选）')),
          DropdownMenuItem(value: '公开课', child: Text('公开课')),
          DropdownMenuItem(value: '转介绍', child: Text('转介绍')),
          DropdownMenuItem(value: '自然流量', child: Text('自然流量')),
        ], onChanged: (v) => setSt(() => channel = v), decoration: const InputDecoration(isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: AppTheme.spacingMd),
        TextField(controller: noteCtrl, decoration: const InputDecoration(hintText: '备注', isDense: true, border: OutlineInputBorder())),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () async {
          Navigator.pop(ctx);
          final resp = await _api('POST', '/api/admin/subscription-requests', body: {'target_user_id': user['user_id'], 'package': pkg, 'channel': channel, 'note': noteCtrl.text.trim()});
          _snack(resp.containsKey('request_id') ? '申请已提交' : (resp['error'] ?? '失败'));
        }, child: const Text('提交')),
      ],
    )));
  }

  // ── Requests ──
  Future<void> _loadRequests(String filter) async {
    final resp = await _api('GET', '/api/admin/subscription-requests?status=$filter');
    setState(() { _reqFilter = filter; _requests = (resp['requests'] as List?)?.cast<Map<String, dynamic>>() ?? []; });
  }

  Future<void> _approveReq(String id) async {
    await _api('POST', '/api/admin/subscription-requests/$id/approve');
    _loadRequests(_reqFilter);
  }

  void _rejectReqDialog(String id) {
    final ctrl = TextEditingController();
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('拒绝原因'),
      content: TextField(controller: ctrl, decoration: const InputDecoration(isDense: true, border: OutlineInputBorder())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () { Navigator.pop(ctx); _api('POST', '/api/admin/subscription-requests/$id/reject', body: {'reject_reason': ctrl.text}).then((_) => _loadRequests(_reqFilter)); }, child: const Text('拒绝')),
      ],
    ));
  }

  // ── Admins ──
  Future<void> _loadAdmins() async {
    final resp = await _api('GET', '/api/admin/admins');
    setState(() => _admins = (resp['admins'] as List?)?.cast<Map<String, dynamic>>() ?? []);
  }

  Future<void> _approveAdmin(String aid) async {
    await _api('POST', '/api/admin/admins/$aid/approve');
    _loadAdmins();
  }

  void _rejectAdminDialog(String aid) {
    final ctrl = TextEditingController();
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('拒绝原因'),
      content: TextField(controller: ctrl, decoration: const InputDecoration(isDense: true, border: OutlineInputBorder())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () { Navigator.pop(ctx); _api('POST', '/api/admin/admins/$aid/reject', body: {'reject_reason': ctrl.text}).then((_) => _loadAdmins()); }, child: const Text('拒绝')),
      ],
    ));
  }

  // ── Audit ──
  Future<void> _loadLogs({String? action, String? q, String? dateFrom, String? dateTo}) async {
    setState(() => _logLoading = true);
    final parts = <String>[];
    final af = action ?? _logFilter;
    final aq = q ?? _logSearchCtrl.text.trim();
    final adf = dateFrom ?? _logDateFrom;
    final adt = dateTo ?? _logDateTo;
    if (af.isNotEmpty) parts.add('action=$af');
    if (aq.isNotEmpty) parts.add('q=${Uri.encodeComponent(aq)}');
    if (adf.isNotEmpty) parts.add('date_from=$adf');
    if (adt.isNotEmpty) parts.add('date_to=$adt');
    final suffix = parts.isEmpty ? '' : '?${parts.join('&')}';
    final resp = await _api('GET', '/api/admin/audit-log$suffix');
    setState(() { _logs = (resp['logs'] as List?)?.cast<Map<String, dynamic>>() ?? []; _logLoading = false; });
  }

  // ── Dashboard ──
  Future<void> _loadDashboard() async {
    setState(() => _dashboardLoading = true);
    final resp = await _api('GET', '/api/admin/dashboard');
    setState(() { _dashboard = resp; _dashboardLoading = false; });
  }

  // ── Assignment Management ──
  Future<void> _loadAssignments() async {
    final resp = await _api('GET', '/api/admin/guardian/assignments');
    setState(() => _assignments = (resp['assignments'] as List?)?.cast<Map<String, dynamic>>() ?? []);
  }

  List<Widget> _buildStudentList(String adminId, String role) {
    final myAssignments = _assignments.where((a) =>
      a['guardian_admin_id'] == adminId && a['is_active'] == 1).toList();
    final students = myAssignments.map((a) {
      final studentName = a['student_display_name'] ?? a['student_real_name'] ?? a['student_user_id'] ?? '';
      return Row(children: [
        Icon(Icons.person, size: 12, color: role == 'guardian' ?  _cs.secondary :  _cs.tertiary),
        const SizedBox(width: AppTheme.spacingXs),
        Expanded(child: Text(studentName, style: _tt.labelSmall?.copyWith(color: role == 'guardian' ?  _cs.secondary :  _cs.tertiary))),
        TextButton(onPressed: () => _removeAssignment(a['id'] as String),
          style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(30, 24), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          child: Text('解除', style: TextStyle(fontSize: 10, color: _cs.errorContainer)),
        ),
      ]);
    }).toList();
    students.add(Row(children: [
      TextButton.icon(
        icon: const Icon(Icons.add, size: 12),
        onPressed: () => _showCreateAssignmentDialog(aid: adminId),
        label: Text(role == 'guardian' ? '绑定学生' : '绑定学生',
          style: TextStyle(fontSize: 10, color:  _cs.secondary)),
        style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(40, 24), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      ),
    ]));
    return students;
  }
  void _showCreateAssignmentDialog({String? aid}) {
    final searchCtrl = TextEditingController();
    List<Map<String, dynamic>> results = [];
    bool searching = false;
    Timer? debounce;
    showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) => AlertDialog(
      title: const Text('绑定学生'),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: searchCtrl,
            decoration: const InputDecoration(
              hintText: '搜索用户名/昵称',
              isDense: true, border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.search, size: 18),
            ),
            onChanged: (v) {
              debounce?.cancel();
              if (v.trim().isEmpty) { setSt(() { results = []; searching = false; }); return; }
              debounce = Timer(const Duration(milliseconds: 300), () async {
                setSt(() => searching = true);
                try {
                  final resp = await _api('GET', '/api/admin/users?page=1&q=${Uri.encodeComponent(v.trim())}&include_deleted=false');
                  setSt(() { results = (resp['users'] as List?)?.cast<Map<String, dynamic>>() ?? []; searching = false; });
                } catch (_) { setSt(() => searching = false); }
              });
            },
          ),
          const SizedBox(height: AppTheme.spacingSm),
          if (searching) const LinearProgressIndicator(),
          if (!searching && results.isEmpty && searchCtrl.text.trim().isNotEmpty)
            const Padding(padding: EdgeInsets.all(AppTheme.spacingSm), child: Text('未找到匹配的学生', style: TextStyle(fontSize: 12))),
          if (results.isNotEmpty)
            SizedBox(
              height: 200,
              child: ListView.builder(
                itemCount: results.length,
                itemBuilder: (_, i) {
                  final u = results[i];
                  final name = u['display_name'] ?? u['username'] ?? '';
                  final phone = u['phone_masked'] as String? ?? u['phone'] as String? ?? '';
                  return ListTile(
                    dense: true,
                    title: Text(name, style: const TextStyle(fontSize: 13)),
                    subtitle: Text('$phone  ·  ${u['user_id']}', style: const TextStyle(fontSize: 10)),
                    leading: const Icon(Icons.person_outline, size: 20),
                    onTap: () async {
                      Navigator.pop(ctx);
                      if (aid == null) { _snack('管理员ID为空'); return; }
                      final resp = await _api('POST', '/api/admin/guardian/assignments',
                        body: {'guardian_admin_id': aid, 'student_user_id': u['user_id']});
                      if (resp.containsKey('id')) {
                        _snack('已绑定 ${u['display_name'] ?? u['username'] ?? ''}');
                        _loadAssignments();
                      } else { _snack(resp['error'] ?? '绑定失败'); }
                    },
                  );
                },
              ),
            ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消'))],
    )));
  }

  void _removeAssignment(String id) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('确认解除'),
      content: const Text('确定解除此监护绑定？'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () {
          Navigator.pop(ctx);
          _api('DELETE', '/api/admin/guardian/assignments/$id').then((_) { _snack('已解除'); _loadAssignments(); });
        }, child: const Text('解除')),
      ],
    ));
  }

  // ═══ BUILD ═══
  @override
  Widget build(BuildContext context) {
    if (_adminKey == null && _token == null) return _buildLogin();

    final showAdminMgmt = _role == 'super';
    final showAudit = _role == 'super' || _role == 'service';
    final showConfigDebug = _role == 'super' || _role == 'service';
    var tabs = <Tab>[const Tab(text: '仪表盘'), const Tab(text: '用户管理'), const Tab(text: '课程数据'), const Tab(text: '套餐管理'), const Tab(text: '支付订单')];
    if (showAdminMgmt) tabs.add(const Tab(text: '管理员管理'));
    if (showAudit) tabs.add(const Tab(text: '操作日志'));
    if (showConfigDebug) tabs.add(const Tab(text: '运行时配置'));
    if (showConfigDebug) tabs.add(const Tab(text: '调试日志'));

    return Scaffold(
      appBar: AppBar(
        title: const Text('管理后台'),
        bottom: TabBar(controller: _mainTabCtrl, isScrollable: true, tabs: tabs),
      ),
      body: _buildBody(showAdminMgmt, showAudit),
    );
  }

  Widget _buildBody(bool showAdminMgmt, bool showAudit) {
    final showConfigDebug = _role == 'super' || _role == 'service';
    return IndexedStack(index: _mainTab, children: [
      _buildDashboardTab(),
      _buildUsersTab(),
      _buildCurriculumTab(),
      _buildPlansTab(),
      _buildOrdersTab(),
      if (showAdminMgmt) _buildAdminMgmtTab(),
      if (showAudit) _buildAuditTab(),
      if (showConfigDebug) _buildConfigTab(),
      if (showConfigDebug) _buildDebugTab(),
    ]);
  }

  Widget _buildLogin() {
    return Scaffold(
      appBar: AppBar(title: const Text('管理后台')),
      body: Center(child: Padding(
        padding: const EdgeInsets.all(AppTheme.spacingXxxl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.admin_panel_settings, size: 64, color: _cs.onSurfaceVariant),
          const SizedBox(height: AppTheme.spacingXxl),
          TextField(controller: _keyCtrl, decoration: const InputDecoration(labelText: '管理员密钥 或 用户名', border: OutlineInputBorder())),
          const SizedBox(height: AppTheme.spacingMd),
          TextField(controller: _passCtrl, obscureText: true, decoration: const InputDecoration(labelText: '密码（账号登录时必填）', border: OutlineInputBorder())),
          const SizedBox(height: AppTheme.spacingLg),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            FilledButton(onPressed: _loginWithKey, child: const Text('密钥登录')),
            FilledButton.tonal(onPressed: _loginWithAccount, child: const Text('账号登录')),
          ]),
        ]),
      )),
    );
  }

  // ── Dashboard Tab ──
  Widget _buildDashboardTab() {
    return _dashboard == null
      ? Center(child: _dashboardLoading ? const CircularProgressIndicator() : TextButton(onPressed: _loadDashboard, child: const Text('加载仪表盘')))
      : SingleChildScrollView(padding: const EdgeInsets.all(AppTheme.spacingLg), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 12, runSpacing: 12, children: [
          _statCard('今日新用户', '${_dashboard!['today_new_users'] ?? 0}', Icons.person_add),
          _statCard('今日活跃', '${_dashboard!['today_active_users'] ?? 0}', Icons.trending_up),
          _statCard('今日复习', '${_dashboard!['today_reviews'] ?? 0}', Icons.replay),
          _statCard('总用户', '${_dashboard!['total_users'] ?? 0}', Icons.people),
          _statCard('总卡片', '${_dashboard!['total_cards'] ?? 0}', Icons.style),
        ]),
        const SizedBox(height: AppTheme.spacingXxl),
        Text('即将到期（7天内）', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppTheme.spacingSm),
        if ((_dashboard!['expiring_soon'] as List?)?.isEmpty ?? true)
          Text('暂无', style: TextStyle(color: _cs.onSurfaceVariant))
        else
          ...(_dashboard!['expiring_soon'] as List).map((u) => ListTile(
            dense: true,
            title: Text(u['display_name'] ?? u['username'] ?? u['user_id'] ?? ''),
            subtitle: Text('到期: ${u['expires'] ?? ''}'),
          )),
      ]));
  }

  Widget _statCard(String label, String value, IconData icon) {
    return SizedBox(
      width: 150,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spacingLg),
          child: Column(children: [
            Icon(icon, size: 28, color: _cs.secondary),
            const SizedBox(height: AppTheme.spacingSm),
            Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            Text(label, style: _tt.bodySmall?.copyWith(color: _cs.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }

  // ── User Management Tab ──
  Widget _buildUsersTab() {
    final reqs = _requests;
    return Column(children: [
      // ── Search + refresh ──
      Padding(
        padding: const EdgeInsets.fromLTRB(AppTheme.spacingMd, AppTheme.spacingMd, AppTheme.spacingMd, AppTheme.spacingXs),
        child: Row(children: [
          Expanded(child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(hintText: '搜索用户名/ID', prefixIcon: const Icon(Icons.search, size: 20), isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(24))),
            onSubmitted: (_) => _search(),
          )),
          const SizedBox(width: AppTheme.spacingSm),
          FilledButton(onPressed: _search, child: const Text('查找')),
          const SizedBox(width: AppTheme.spacingXs),
          IconButton(icon: const Icon(Icons.download, size: 20), onPressed: _exportCsv, tooltip: '导出 CSV'),
        ]),
      ),
      // ── Result info ──
      if (_userTotal > 0)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          child:           Row(children: [
            Text('共 $_userTotal 人 · 显示 ${_users.length} 人', style: _tt.labelSmall?.copyWith(color:  _cs.onSurfaceVariant)),
            const Spacer(),
            // 用户状态切换：正常 / 已删除
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('正常用户', style: TextStyle(fontSize: 10))),
                ButtonSegment(value: true, label: Text('已删除', style: TextStyle(fontSize: 10))),
              ],
              selected: {_includeDeleted},
              onSelectionChanged: (v) { setState(() => _includeDeleted = v.first); _search(); },
              style: ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            ),
            if (_searchCtrl.text.trim().isNotEmpty) Text(' · 搜索模式', style: _tt.labelSmall?.copyWith(color: _cs.tertiary)),
          ]),
        ),
      // ── Action bar (fixed below search) ──
      Container(
        color: _selectedUserIds.isNotEmpty ? _cs.secondaryContainer : _cs.surfaceContainerHighest,
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd, vertical: 6),
        child: Row(children: [
          if (_selectedUserIds.isNotEmpty)
            Text('已选 ${_selectedUserIds.length} 人', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          if (_selectedUserIds.isEmpty)
            Text('选择用户后可操作', style: _tt.bodySmall?.copyWith(color:  _cs.outline)),
          const Spacer(),
          if (_role == 'super' || _role == 'service')
            FilledButton.tonal(
              onPressed: () => _onAction('set_expiry'),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingSm)),
              child: const Text('设置到期', style: TextStyle(fontSize: 11)),
            ),
          const SizedBox(width: AppTheme.spacingXs),
          ...[7, 30, 365].map((days) => Padding(
            padding: const EdgeInsets.only(left: AppTheme.spacingXs),
            child: FilledButton.tonal(
              onPressed: () => _onAction('extend_$days'),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingSm)),
              child: Text('+${days}d', style: _tt.labelSmall!),
            ),
          )),
          if (_role == 'super')
            TextButton(
              onPressed: () => _onAction('delete'),
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingXs), minimumSize: Size.zero),
              child: Icon(Icons.delete_outline, size: 18, color: _cs.errorContainer),
            ),
          if (_includeDeleted && _role == 'super')
            TextButton(
              onPressed: () => _onAction('hard_delete'),
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingXs), minimumSize: Size.zero),
              child: Icon(Icons.delete_forever, size: 18, color: _cs.error),
            ),
          if (_selectedUserIds.isNotEmpty)
            IconButton(icon: const Icon(Icons.close, size: 18), onPressed: _exitSelectMode),
        ]),
      ),
      const Divider(height: 1, thickness: 1),
      if (_loading) const LinearProgressIndicator(),
      // ── Scrollable: user results + subscription requests ──
      Expanded(child: _users.isEmpty && reqs.isEmpty
        ? Center(child: Text(_loading ? '' : _searchCtrl.text.isNotEmpty ? '未找到匹配用户' : '加载中...', style: TextStyle(color: _cs.outline)))
        : ListView(children: [
          // User results
          ..._users.map((u) => _buildUserCard(u)),
          // Load more button
          if (_searchCtrl.text.trim().isNotEmpty && !_userEndReached)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Center(child: TextButton(onPressed: _loadMoreUsers, child: Text('加载更多 (${_users.length}/$_userTotal)', style: _tt.bodySmall!))),
            ),
          // Subscription requests
          if (reqs.isNotEmpty) ...[
            const Divider(height: 24, thickness: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingLg, vertical: AppTheme.spacingXs),
              child: Row(children: [
                Text('订阅申请 (${reqs.length})', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _cs.primary)),
                const Spacer(),
                ...[
                  FilterChip(label: const Text('待审批', style: TextStyle(fontSize: 11)), selected: _reqFilter == 'pending', visualDensity: VisualDensity.compact, onSelected: (_) => _loadRequests('pending')),
                  const SizedBox(width: AppTheme.spacingXs),
                  FilterChip(label: const Text('已通过', style: TextStyle(fontSize: 11)), selected: _reqFilter == 'approved', visualDensity: VisualDensity.compact, onSelected: (_) => _loadRequests('approved')),
                  const SizedBox(width: AppTheme.spacingXs),
                  FilterChip(label: const Text('已拒绝', style: TextStyle(fontSize: 11)), selected: _reqFilter == 'rejected', visualDensity: VisualDensity.compact, onSelected: (_) => _loadRequests('rejected')),
                ],
              ]),
            ),
            ...reqs.map((r) => Card(
              margin: const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd, vertical: 3),
              child: ListTile(
                dense: true,
                title: Text('${r['target_username'] ?? r['target_user_id']} · ${r['package']}', style: const TextStyle(fontSize: 13)),
                subtitle: Text('${r['requester_name'] ?? r['requested_by']} · ${r['channel'] ?? ''} · ${(r['requested_at'] as String? ?? '').replaceAll(RegExp(r'T.*'), '')}', style: _tt.labelSmall!),
                trailing: r['status'] == 'pending'
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(icon: Icon(Icons.check_circle, color: _cs.primary, size: 20), onPressed: () => _approveReq(r['id'] as String)),
                      IconButton(icon: Icon(Icons.cancel, color: _cs.error, size: 20), onPressed: () => _rejectReqDialog(r['id'] as String)),
                    ])
                  : Chip(label: Text(r['status'] == 'approved' ? '已通过' : '已拒绝', style: _tt.labelSmall!)),
              ),
            )),
          ],
        ]),
      ),
    ]);
  }

  /// User result card with subscription + guardian info
  Widget _buildUserCard(Map<String, dynamic> u) {
    final phone = u['phone'] as String?;
    final phoneMasked = u['phone_masked'] as String? ?? phone ?? '—';
    final name = (u['real_name'] as String?) ?? u['real_name_masked'] as String? ?? '—';
    final isActive = u['subscription_expires'] != null && (u['subscription_expires'] as String).isNotEmpty;
    final expires = u['subscription_expires'] as String? ?? '';
    final deletedAt = u['deleted_at'] as String?;
    final isDeleted = deletedAt != null && deletedAt.isNotEmpty;

    final gName = u['guardian_name'] as String?;
    final gPhone = u['guardian_phone_masked'] as String?;
    final gId = u['guardian_id'] as String?;
    final tName = u['tutor_name'] as String?;
    final tPhone = u['tutor_phone_masked'] as String?;
    final tId = u['tutor_id'] as String?;
    final isExpiring = isActive && expires.isNotEmpty && _daysUntil(expires) <= 30;
    final borderColor = isExpiring ?  _cs.tertiary :  _cs.outlineVariant;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd, vertical: 3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: borderColor, width: isExpiring ? 1.5 : 1)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppTheme.spacingXs, AppTheme.spacingSm, 10, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Title row: checkbox + name + status + detail button
          Row(children: [
            Checkbox(
              value: _selectedUserIds.contains(u['user_id']),
              onChanged: (_) => _toggleSelect(u['user_id'] as String),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            Expanded(child: Text(
              u['display_name'] ?? u['username'] ?? '',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14,
                decoration: isDeleted ? TextDecoration.lineThrough : null,
                color: isDeleted ?  _cs.outline : null,
              ),
            )),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isDeleted ? _cs.error.withValues(alpha: 0.1) : (isExpiring ? _cs.tertiary.withValues(alpha: 0.1) : (isActive ? _cs.primary.withValues(alpha: 0.1) : _cs.onSurfaceVariant.withValues(alpha: 0.1))),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                isDeleted ? '已删除' : (isExpiring ? '${_daysUntil(expires)}d到期' : (isActive ? expires.replaceAll(RegExp(r'T.*'), '') : '未激活')),
                style: TextStyle(fontSize: 10, color: isDeleted ? _cs.error : (isExpiring ?  _cs.tertiary : (isActive ?  _cs.primary : _cs.onSurfaceVariant))),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 28, height: 28,
              child: IconButton(
                icon: const Icon(Icons.open_in_new, size: 14),
                padding: EdgeInsets.zero,
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => UserDetailScreen(userId: u['user_id'] as String, adminKey: _adminKey, token: _token, role: _role!))),
                tooltip: '详情',
              ),
            ),
            const SizedBox(width: 4),
            TextButton(
              onPressed: () async {
                final uid = u['user_id'] as String;
                try {
                  if (_trackedUserIds.contains(uid)) {
                    await _api('DELETE', '/api/admin/debug/track/$uid');
                    setState(() => _trackedUserIds.remove(uid));
                  } else {
                    final r = await _api('POST', '/api/admin/debug/track',
                        body: {'user_id': uid});
                    if (r['status'] == 'active' || r['id'] != null) {
                      setState(() => _trackedUserIds.add(uid));
                    }
                  }
                } catch (_) {}
              },
              style: TextButton.styleFrom(
                foregroundColor: _trackedUserIds.contains(u['user_id'])
                    ? Colors.red : Colors.blue,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                _trackedUserIds.contains(u['user_id']) ? '关闭跟踪' : '跟踪',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ]),
          // Info rows: stats + phone + guardian/tutor
          Padding(
            padding: const EdgeInsets.only(left: AppTheme.spacingXxxxl),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                '卡片:${u['card_count']} 复习:${u['review_count']} · ${u['streak_days'] ?? 0}天'
                '${gName != null ? " · 家长:$gName" : ""}'
                '${tName != null ? " · 老师:$tName" : ""}',
                style: _tt.labelSmall?.copyWith(color: _cs.onSurfaceVariant),
              ),
              const SizedBox(height: 3),
              // Phone row
              Text.rich(TextSpan(children: [
                TextSpan(text: phoneMasked, style: const TextStyle(fontSize: 13)),
                WidgetSpan(child: InkWell(
                  child: Padding(
                    padding: const EdgeInsets.only(left: AppTheme.spacingXs),
                    child: Icon(Icons.visibility_outlined, size: 14, color:  _cs.secondary),
                  ),
                  onTap: () => _revealPhone(u['user_id'] as String),
                )),
              ])),
              // Guardian
              if (gName != null) Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: '家长: $gName  $gPhone', style: _tt.bodySmall?.copyWith(color:  _cs.secondary)),
                  WidgetSpan(child: Padding(
                    padding: const EdgeInsets.only(left: 3),
                    child: InkWell(
                      child: Icon(Icons.visibility_outlined, size: 12, color:  _cs.secondary),
                      onTap: () => _revealAdminPhone(gId, '家长'),
                    ),
                  )),
                ])),
              ),
              // Tutor
              if (tName != null) Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: '老师: $tName  $tPhone', style: _tt.bodySmall?.copyWith(color:  _cs.tertiary)),
                  WidgetSpan(child: Padding(
                    padding: const EdgeInsets.only(left: 3),
                    child: InkWell(
                      child: Icon(Icons.visibility_outlined, size: 12, color:  _cs.tertiary),
                      onTap: () => _revealAdminPhone(tId, '老师'),
                    ),
                  )),
                ])),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  int _daysUntil(String dateStr) {
    try {
      final dt = DateTime.parse(dateStr);
      return dt.difference(DateTime.now()).inDays;
    } catch (_) { return 999; }
  }

  // ── Curriculum Tab ──
  Widget _buildCurriculumTab() {
    return Column(children: [
      TabBar(controller: _curriculumSubTabCtrl, tabs: const [
        Tab(text: '学习计划'),
        Tab(text: '卡片数据'),
      ]),
      Expanded(child: IndexedStack(index: _curriculumSubTabCtrl.index, children: [
        CurriculumPlansPage(adminKey: _adminKey, token: _token),
        CurriculumCardsPage(adminKey: _adminKey, token: _token),
      ])),
    ]);
  }

  // ── Plans Tab ──
  Widget _buildPlansTab() {
    return _AdminPlansPage(adminKey: _adminKey, token: _token);
  }

  // ── Orders Tab ──
  Widget _buildOrdersTab() {
    return _AdminOrdersPage(adminKey: _adminKey, token: _token);
  }

  // ── Admin Management Tab (super only) ──
  Widget _buildAdminMgmtTab() {
    final filtered = _adminRoleFilter == 'all'
      ? _admins
      : _admins.where((a) => a['role'] == _adminRoleFilter).toList();
    final counts = {'service': 0, 'guardian': 0, 'tutor': 0};
    for (final a in _admins) { counts[a['role']] = (counts[a['role']] ?? 0) + 1; }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(AppTheme.spacingMd, AppTheme.spacingMd, AppTheme.spacingMd, AppTheme.spacingXs),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('管理员 (${filtered.length})', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _cs.primary)),
          Row(children: [
            FilledButton.icon(icon: const Icon(Icons.add, size: 16), onPressed: _showCreateAdminDialog, label: const Text('新建', style: TextStyle(fontSize: 12))),
            const SizedBox(width: AppTheme.spacingSm),
            TextButton.icon(icon: const Icon(Icons.refresh, size: 16), onPressed: _loadAdmins, label: const Text('刷新', style: TextStyle(fontSize: 12))),
          ]),
        ]),
      ),
      // Role filter chips
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd),
        child: Row(children: [
          _roleChip('全部', 'all', counts.values.fold(0, (a,b)=>a+b)),
          const SizedBox(width: 6),
          _roleChip('服务人员', 'service', counts['service'] ?? 0),
          const SizedBox(width: 6),
          _roleChip('家长', 'guardian', counts['guardian'] ?? 0),
          const SizedBox(width: 6),
          _roleChip('辅导老师', 'tutor', counts['tutor'] ?? 0),
        ]),
      ),
      const SizedBox(height: AppTheme.spacingXs),
      Expanded(child: filtered.isEmpty
        ? Center(child: TextButton(onPressed: _loadAdmins, child: const Text('点击加载')))
        : ListView.builder(itemCount: filtered.length, itemBuilder: (_, i) {
        final a = filtered[i];
        final aid = a['id'] as String? ?? '';
        final role = a['role'] as String? ?? '';
        final status = a['status'] as String? ?? '';
        final perms = a['permissions'] as Map<String, dynamic>? ?? {};
        final canApprove = perms['can_approve'] == true;
        final isSelf = aid == _adminKey || aid == _token; // approximate
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd, vertical: 3),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd, vertical: AppTheme.spacingSm),
            child: Row(children: [
              // Name + info
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a['real_name'] ?? a['username'] ?? '', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text('${a['role']} · ${a['phone'] ?? ''} · ${a['created_at']?.toString().replaceAll(RegExp(r'T.*'), '') ?? ''}', style: _tt.labelSmall?.copyWith(color: _cs.onSurfaceVariant)),
                if (role == 'guardian' || role == 'tutor') ..._buildStudentList(aid, role),
              ])),
              // Actions
              Row(mainAxisSize: MainAxisSize.min, children: [
              if (role == 'service' && !isSelf)
                IconButton(
                  icon: Icon(Icons.admin_panel_settings, size: 18, color: _cs.secondary),
                  onPressed: () => _showPermissionDialog(aid, a['permissions'] as Map<String, dynamic>? ?? {}, perms),
                  tooltip: '权限设置',
                ),
              if (!isSelf) ...[
                IconButton(icon: Icon(Icons.lock_reset, size: 18, color: _cs.secondary), onPressed: () => _showResetPasswordDialog(aid), tooltip: '重置密码'),
                if (status != 'disabled')
                  IconButton(icon: Icon(Icons.block, size: 18, color: _cs.error), onPressed: () => _disableAdmin(aid), tooltip: '禁用'),
                if (status == 'disabled')
                  IconButton(icon: Icon(Icons.check_circle_outline, size: 18, color: _cs.primary), onPressed: () => _enableAdmin(aid), tooltip: '启用'),
              ],
              Chip(label: Text(status == 'disabled' ? '已禁用' : '正常', style: TextStyle(fontSize: 10, color: status == 'disabled' ? _cs.error : _cs.primary))),
            ]),
          ]),
        ),
      );
      })),
    ]);
  }

  Widget _roleChip(String label, String value, int count) {
    final selected = _adminRoleFilter == value;
    return FilterChip(
      label: Text('$label ($count)', style: _tt.labelSmall?.copyWith(color: selected ? _cs.surface : null)),
      selected: selected,
      onSelected: (_) => setState(() => _adminRoleFilter = value),
      visualDensity: VisualDensity.compact,
      selectedColor:  _cs.secondary,
      checkmarkColor: _cs.surface,
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingXs),
    );
  }

  void _showCreateAdminDialog() {
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    String role = 'service';
    showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) => AlertDialog(
      title: const Text('创建管理员'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: userCtrl, decoration: const InputDecoration(labelText: '用户名', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: AppTheme.spacingSm),
        TextField(controller: passCtrl, obscureText: true, decoration: const InputDecoration(labelText: '密码（6位以上）', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: AppTheme.spacingSm),
        TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '真实姓名', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: AppTheme.spacingSm),
        TextField(controller: phoneCtrl, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: '手机号', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: AppTheme.spacingSm),
        DropdownButtonFormField(value: role, items: const [
          DropdownMenuItem(value: 'service', child: Text('服务人员')),
          DropdownMenuItem(value: 'super', child: Text('超管')),
        ], onChanged: (v) => setSt(() => role = v!), decoration: const InputDecoration(labelText: '角色', isDense: true, border: OutlineInputBorder())),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () async {
          Navigator.pop(ctx);
          final resp = await _api('POST', '/api/admin/admins', body: {'username': userCtrl.text.trim(), 'password': passCtrl.text.trim(), 'real_name': nameCtrl.text.trim(), 'phone': phoneCtrl.text.trim(), 'role': role});
          _snack(resp.containsKey('admin_id') ? '创建成功' : (resp['error'] ?? '失败'));
          _loadAdmins();
        }, child: const Text('创建')),
      ],
    )));
  }

  void _showResetPasswordDialog(String aid) {
    final ctrl = TextEditingController();
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('重置密码'),
      content: TextField(controller: ctrl, obscureText: true, decoration: const InputDecoration(labelText: '新密码（6位以上）', isDense: true, border: OutlineInputBorder())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () async {
          Navigator.pop(ctx);
          final resp = await _api('POST', '/api/admin/admins/$aid/password', body: {'password': ctrl.text.trim()});
          _snack(resp.containsKey('status') ? '密码已更新' : (resp['error'] ?? '失败'));
        }, child: const Text('确认')),
      ],
    ));
  }

  Future<void> _revealAdminPhone(String? adminId, String label) async {
    if (adminId == null || adminId.isEmpty) { _snack('未找到该 $label 信息'); return; }
    final resp = await _api('POST', '/api/admin/guardian/reveal-phone/$adminId');
    if (resp.containsKey('phone')) {
      _snack('$label 完整手机号: ${resp['phone']}');
    } else { _snack(resp['error'] ?? '获取失败'); }
  }

  Future<void> _disableAdmin(String aid) async {
    final resp = await _api('DELETE', '/api/admin/admins/$aid/disable');
    _snack(resp.containsKey('status') ? '已禁用' : (resp['error'] ?? '失败'));
    _loadAdmins();
  }

  Future<void> _enableAdmin(String aid) async {
    final resp = await _api('POST', '/api/admin/admins/$aid/enable');
    _snack(resp.containsKey('status') ? '已启用' : (resp['error'] ?? '失败'));
    _loadAdmins();
  }

  void _showPermissionDialog(String aid, Map<String, dynamic> allPerms, Map<String, dynamic> currentPerms) {
    final perms = {
      'can_approve': currentPerms['can_approve'] == true,
      'set_expiry': currentPerms['set_expiry'] == true,
      'extend_7d': currentPerms['extend_7d'] == true,
      'extend_30d': currentPerms['extend_30d'] == true,
      'extend_365d': currentPerms['extend_365d'] == true,
    };
    final permLabels = {
      'can_approve': '审批订阅请求',
      'set_expiry': '设置到期日期',
      'extend_7d': '+7天延期',
      'extend_30d': '+30天延期',
      'extend_365d': '+365天延期',
    };
    showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) => AlertDialog(
      title: const Text('权限设置'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final e in perms.entries)
          CheckboxListTile(
            title: Text(permLabels[e.key] ?? e.key, style: const TextStyle(fontSize: 13)),
            value: e.value,
            dense: true,
            controlAffinity: ListTileControlAffinity.trailing,
            onChanged: (v) => setSt(() => perms[e.key] = v ?? false),
          ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () async {
          Navigator.pop(ctx);
          final resp = await _api('PUT', '/api/admin/admins/$aid/permissions', body: {'permissions': perms});
          _snack(resp.containsKey('status') ? '权限已更新' : (resp['error'] ?? '失败'));
          _loadAdmins();
        }, child: const Text('保存')),
      ],
    )));
  }

  Future<void> _toggleApprovePermission(String aid, bool enable) async {
    final perms = {'can_approve': enable};
    final resp = await _api('PUT', '/api/admin/admins/$aid/permissions', body: {'permissions': perms});
    _snack(enable ? '已授予此管理员订阅审批权限' : '已取消此管理员订阅审批权限');
    _loadAdmins();
  }

  void _showDeleteUserDialog(String uid, String name) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: Text('删除用户', style: TextStyle(color: _cs.error)),
      content: Text('确认删除用户 $name？\n\n普通删除：用户将被标记为已删除，可以恢复。\n${_role == 'super' ? '永久删除（仅超管）：彻底清库，不可恢复！' : ''}'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        if (_role == 'super')
          TextButton(
            style: TextButton.styleFrom(foregroundColor: _cs.error),
            onPressed: () async {
              Navigator.pop(ctx);
              final resp = await _api('DELETE', '/api/admin/users/$uid/hard-delete');
              _snack(resp.containsKey('archive_id') ? '用户已永久删除（已归档）' : (resp['error'] ?? '删除失败'));
              _search();
            },
            child: const Text('永久删除', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _cs.error),
          onPressed: () async {
            Navigator.pop(ctx);
            final resp = await _api('DELETE', '/api/admin/users/$uid');
            _snack(resp.containsKey('status') ? '用户已标记为删除' : (resp['error'] ?? '删除失败'));
            _search();
          },
          child: const Text('确认删除'),
        ),
      ],
    ));
  }

  void _showRestoreUserDialog(String uid, String name) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('恢复用户'),
      content: Text('确认恢复用户 $name？恢复后用户将重新出现在默认列表中。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          onPressed: () async {
            Navigator.pop(ctx);
            final resp = await _api('POST', '/api/admin/users/$uid/restore');
            _snack(resp.containsKey('status') ? '用户已恢复' : (resp['error'] ?? '恢复失败'));
            _search();
          },
          child: const Text('确认恢复'),
        ),
      ],
    ));
  }

  void _showHardDeleteDialog(String uid, String name) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: Text('永久删除用户', style: TextStyle(color: _cs.error)),
      content: Text('⚠️ 确认永久删除用户 $name？\n\n操作不可逆！该用户的所有数据（卡片、对话、学习记录等）将被完全清空。\n仅保留归档记录（用户名、手机号哈希、订阅信息等）。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _cs.error),
          onPressed: () async {
            Navigator.pop(ctx);
            final resp = await _api('DELETE', '/api/admin/users/$uid/hard-delete');
            _snack(resp.containsKey('archive_id') ? '用户已永久删除（已归档）' : (resp['error'] ?? '删除失败'));
            _search();
          },
          child: const Text('确认永久删除', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    ));
  }

  // ── Guardian Assignment Tab ──
  Widget _buildAssignmentTab() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(AppTheme.spacingMd),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('监护关系 (${_assignments.length})', style: Theme.of(context).textTheme.titleMedium),
          Row(children: [
            TextButton.icon(icon: const Icon(Icons.add, size: 18), onPressed: _showCreateAssignmentDialog, label: const Text('新建')),
            TextButton.icon(icon: const Icon(Icons.refresh, size: 18), onPressed: _loadAssignments, label: const Text('刷新')),
          ]),
        ]),
      ),
      Expanded(child: _assignments.isEmpty
        ? Center(child: TextButton(onPressed: _loadAssignments, child: const Text('点击加载')))
        : ListView.builder(itemCount: _assignments.length, itemBuilder: (_, i) {
        final a = _assignments[i];
        final active = a['is_active'] == 1;
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd, vertical: AppTheme.spacingXs),
          color: active ? null : _cs.surfaceContainerHighest,
          child: ListTile(
            title: Text('${a['guardian_name'] ?? a['guardian_admin_id']} → ${a['student_display_name'] ?? a['student_real_name'] ?? a['student_user_id']}', style: TextStyle(fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
            subtitle: Text('${a['assigned_at']?.toString().replaceAll(RegExp(r'T.*'), '') ?? ''}  ${active ? "有效" : "已解除"}'),
            trailing: active
              ? IconButton(icon: Icon(Icons.link_off, color: _cs.error, size: 20), onPressed: () => _removeAssignment(a['id'] as String))
              : null,
          ),
        );
      })),
    ]);
  }

  // ── Audit Tab ──
  Widget _buildAuditTab() {
    // Auto-load on first render
    WidgetsBinding.instance.addPostFrameCallback((_) { if (!_logLoaded) { _logLoaded = true; _loadLogs(); } });
    return Column(children: [
      // Search bar + filters
      Padding(
        padding: const EdgeInsets.fromLTRB(AppTheme.spacingMd, AppTheme.spacingMd, AppTheme.spacingMd, 0),
        child: Column(children: [
          // Search row
          Row(children: [
            Expanded(child: TextField(
              controller: _logSearchCtrl,
              decoration: InputDecoration(
                hintText: '搜索操作/人员/ID...',
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _logSearchCtrl.text.isNotEmpty
                  ? IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () { _logSearchCtrl.clear(); _loadLogs(); })
                  : null,
              ),
              style: const TextStyle(fontSize: 13),
              onSubmitted: (v) => _loadLogs(q: v),
            )),
            const SizedBox(width: AppTheme.spacingSm),
            IconButton(
              icon: Icon(Icons.refresh_rounded, size: 20, color:  _cs.secondary),
              onPressed: () => _loadLogs(),
            ),
          ]),
          const SizedBox(height: AppTheme.spacingSm),
          // Category filters
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
            _logFilterChip('全部', ''),
            _logFilterChip('查看号码', 'reveal_phone'),
            _logFilterChip('设置订阅', 'set_subscription'),
            _logFilterChip('审批', 'approve_request,reject_request'),
          ])),
          const SizedBox(height: AppTheme.spacingSm),
          // Date range
          Row(children: [
            Expanded(child: TextField(
              decoration: InputDecoration(
                labelText: '开始日期', isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                hintText: '2026-05-01', hintStyle: _tt.bodySmall!,
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: (v) => _logDateFrom = v.trim(),
            )),
            const SizedBox(width: AppTheme.spacingSm),
            Expanded(child: TextField(
              decoration: InputDecoration(
                labelText: '结束日期', isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                hintText: '2026-05-20', hintStyle: _tt.bodySmall!,
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: (v) => _logDateTo = v.trim(),
            )),
            const SizedBox(width: AppTheme.spacingSm),
            TextButton(
              onPressed: () => _loadLogs(dateFrom: _logDateFrom, dateTo: _logDateTo),
              child: const Text('筛选', style: TextStyle(fontSize: 13)),
            ),
          ]),
        ]),
      ),
      const SizedBox(height: AppTheme.spacingXs),
      // Result count
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(children: [
          Text('${_logs.length} 条记录', style: _tt.bodySmall?.copyWith(color:  _cs.onSurfaceVariant)),
        ]),
      ),
      // Log list
      Expanded(child: _logLoading
        ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
        : _logs.isEmpty
          ? const Center(child: Text('暂无日志'))
          : ListView.builder(itemCount: _logs.length, itemBuilder: (_, i) {
        final l = _logs[i];
        final action = l['action'] as String? ?? '';
        final actionLabel = _logActionLabel(action);
        final actionIcon = _logActionIcon(action);
        final detail = l['detail'] as String?;
        String detailText = '';
        if (detail != null && detail.isNotEmpty && detail != '{}') {
          try {
            final d = jsonDecode(detail) as Map<String, dynamic>;
            detailText = d['target'] ?? d['masked'] ?? detail;
          } catch (_) {
            detailText = detail;
          }
        }
        // Extract target name or use ID
        final targetLabel = (l['target_user_id'] as String?) ?? '';
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd, vertical: 3),
          decoration: BoxDecoration(
            color: _cs.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color:  _cs.outlineVariant),
          ),
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: Icon(actionIcon, size: 18, color:  _cs.secondary),
            title: Row(children: [
              Text(l['admin_name'] as String? ?? l['admin_id'] as String? ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              const SizedBox(width: AppTheme.spacingSm),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _cs.secondary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(actionLabel, style: TextStyle(fontSize: 10, color:  _cs.secondary)),
              ),
            ]),
            subtitle: Text('$targetLabel${detailText.isNotEmpty ? " · $detailText" : ""} · ${(l['created_at'] as String? ?? '').replaceAll(RegExp(r'T.*'), '')}', style: _tt.labelSmall?.copyWith(color: _cs.onSurfaceVariant)),
          ),
        );
      })),
    ]);
  }

  // ── Config Tab ──
  Widget _buildConfigTab() {
    return ConfigPage(adminKey: _adminKey, token: _token);
  }

  // ── Debug Tab ──
  Widget _buildDebugTab() {
    return DebugLogsPage(headers: _headers());
  }

  Widget _logFilterChip(String label, String filter) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingXs, vertical: 6),
    child: FilterChip(
      label: Text(label, style: _tt.bodySmall!),
      selected: _logFilter == filter,
      visualDensity: VisualDensity.compact,
      onSelected: (_) {
        _logFilter = filter;
        _loadLogs();
      },
    ),
  );

  String _logActionLabel(String action) {
    return switch (action) {
      'reveal_phone_full' => '查看完整号码',
      'reveal_phone_masked' => '查看脱敏号码',
      'reveal_guardian_phone' => '辅导老师看家长号码',
      'set_subscription' => '设置订阅',
      'batch_set_subscription' => '批量设置订阅',
      'create_request' => '提交订阅申请',
      'approve_request' => '通过订阅申请',
      'reject_request' => '拒绝订阅申请',
      _ => action,
    };
  }

  IconData _logActionIcon(String action) {
    return switch (action) {
      'reveal_phone_full' || 'reveal_phone_masked' || 'reveal_guardian_phone' => Icons.visibility_outlined,
      'set_subscription' || 'batch_set_subscription' => Icons.card_membership_outlined,
      'create_request' => Icons.send_outlined,
      'approve_request' => Icons.check_circle_outlined,
      'reject_request' => Icons.cancel_outlined,
      _ => Icons.info_outline,
    };
  }
}

/// 管理端套餐管理 — 完整 CRUD
class _AdminPlansPage extends StatefulWidget {
  final String? adminKey;
  final String? token;
  const _AdminPlansPage({this.adminKey, this.token});
  @override
  State<_AdminPlansPage> createState() => _AdminPlansPageState();
}

class _AdminPlansPageState extends State<_AdminPlansPage> {
  List<Map<String, dynamic>>? _plans;
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final headers = <String, String>{};
      if (widget.token != null) headers['Authorization'] = 'Bearer ${widget.token}';
      final resp = await http
          .get(Uri.parse('${ApiConfig.baseUrl}/api/admin/plans'), headers: headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        _plans = (jsonDecode(resp.body)['plans'] as List)
            .map((e) => e as Map<String, dynamic>).toList();
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  String _fmtPrice(int p) { final y = p / 100.0; return y == y.roundToDouble() ? '¥${y.toInt()}' : '¥${y.toStringAsFixed(2)}'; }
  String _durationText(int? d) { if (d == null) return ''; if (d >= 3650) return '永久'; if (d >= 365) return '${d ~/ 365}年'; return '$d天'; }

  void _showPlanDialog({Map<String, dynamic>? plan}) {
    final isEdit = plan != null;
    final idCtl = TextEditingController(text: isEdit ? plan['id'] as String? ?? '' : '');
    final nameCtl = TextEditingController(text: isEdit ? plan['name'] as String? ?? '' : '');
    final priceCtl = TextEditingController(text: isEdit ? '${plan['price']}' : '');
    final durCtl = TextEditingController(text: isEdit ? '${plan['duration_days']}' : '');
    final maxCtl = TextEditingController(text: isEdit ? '${plan['max_uses'] ?? ''}' : '');
    final sortCtl = TextEditingController(text: isEdit ? '${plan['sort_order'] ?? 0}' : '0');
    final onceCtl = TextEditingController(text: isEdit ? '${plan['once_per_user'] ?? 0}' : '0');
    final fromCtl = TextEditingController(text: isEdit ? (plan['available_from'] as String? ?? '') : '');
    final untilCtl = TextEditingController(text: isEdit ? (plan['available_until'] as String? ?? '') : '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEdit ? '编辑套餐' : '新建套餐'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!isEdit) TextField(controller: idCtl, decoration: const InputDecoration(labelText: 'ID (如 30d)', isDense: true), style: const TextStyle(fontSize: 13)),
            TextField(controller: nameCtl, decoration: const InputDecoration(labelText: '名称', isDense: true), style: const TextStyle(fontSize: 13)),
            TextField(controller: priceCtl, decoration: const InputDecoration(labelText: '价格(分)', isDense: true), keyboardType: TextInputType.number, style: const TextStyle(fontSize: 13)),
            TextField(controller: durCtl, decoration: const InputDecoration(labelText: '时长(天)', isDense: true), keyboardType: TextInputType.number, style: const TextStyle(fontSize: 13)),
            TextField(controller: maxCtl, decoration: const InputDecoration(labelText: '库存上限(空=不限)', isDense: true), keyboardType: TextInputType.number, style: const TextStyle(fontSize: 13)),
            TextField(controller: sortCtl, decoration: const InputDecoration(labelText: '排序', isDense: true), keyboardType: TextInputType.number, style: const TextStyle(fontSize: 13)),
            TextField(controller: onceCtl, decoration: const InputDecoration(labelText: '每人限购(0=不限)', isDense: true), keyboardType: TextInputType.number, style: const TextStyle(fontSize: 13)),
            TextField(controller: fromCtl, decoration: const InputDecoration(labelText: '上架时间(空=即时)', isDense: true), style: const TextStyle(fontSize: 13)),
            TextField(controller: untilCtl, decoration: const InputDecoration(labelText: '下架时间(空=不限)', isDense: true), style: const TextStyle(fontSize: 13)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final body = <String, dynamic>{
                'name': nameCtl.text,
                'price': int.tryParse(priceCtl.text) ?? 0,
                'duration_days': int.tryParse(durCtl.text),
                'max_uses': int.tryParse(maxCtl.text),
                'sort_order': int.tryParse(sortCtl.text) ?? 0,
                'once_per_user': int.tryParse(onceCtl.text) ?? 0,
                'available_from': fromCtl.text.isEmpty ? null : fromCtl.text,
                'available_until': untilCtl.text.isEmpty ? null : untilCtl.text,
              };
              if (!isEdit) body['id'] = idCtl.text;
              final headers = <String, String>{'Content-Type': 'application/json'};
              if (widget.token != null) headers['Authorization'] = 'Bearer ${widget.token}';
              final uri = Uri.parse('${ApiConfig.baseUrl}/api/admin/plans${isEdit ? '/${plan['id']}' : ''}');
              final resp = await (isEdit ? http.put : http.post)(uri, headers: headers, body: jsonEncode(body));
              if (mounted) { Navigator.pop(ctx); _load(); }
            },
            child: Text(isEdit ? '保存' : '创建'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_plans == null) return Center(child: Text('加载失败', style: TextStyle(color: cs.error)));
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          Text('共 ${_plans!.length} 个套餐', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          const Spacer(),
          FilledButton.icon(
            onPressed: () => _showPlanDialog(),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('新建套餐', style: TextStyle(fontSize: 12)),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
          ),
        ]),
      ),
      Expanded(child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        itemCount: _plans!.length,
        itemBuilder: (_, i) {
          final p = _plans![i];
          final active = p['is_active'] == 1;
          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${p['name']}  (${p['id']})', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  const SizedBox(height: 4),
                  Text('${_fmtPrice(p['price'] as int)} / ${_durationText(p['duration_days'] as int?)}',
                      style: TextStyle(color: cs.primary, fontWeight: FontWeight.w500, fontSize: 12)),
                  Text('已售 ${p['used_count']}${p['max_uses'] != null ? ' / ${p['max_uses']}' : ''}  排序${p['sort_order']}',
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                  Text('限购${(p['once_per_user'] as int? ?? 0) == 0 ? '不限' : p['once_per_user']}',
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                ])),
                Text(active ? '上架' : '下架', style: TextStyle(color: active ? Colors.green : cs.error, fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(width: 6),
                SizedBox(height: 28, child: FilledButton.tonal(
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                  onPressed: () => _showPlanDialog(plan: p),
                  child: const Icon(Icons.edit, size: 14),
                )),
                const SizedBox(width: 4),
                SizedBox(height: 28, child: FilledButton.tonal(
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                  onPressed: () async {
                    final headers = <String, String>{'Content-Type': 'application/json'};
                    if (widget.token != null) headers['Authorization'] = 'Bearer ${widget.token}';
                    await http.put(Uri.parse('${ApiConfig.baseUrl}/api/admin/plans/${p['id']}'), headers: headers, body: jsonEncode({'is_active': !active}));
                    _load();
                  },
                  child: Text(active ? '下架' : '上架', style: const TextStyle(fontSize: 11)),
                )),
              ]),
            ),
          );
        },
      )),
    ]);
  }
}

/// 管理端订单列表
class _AdminOrdersPage extends StatefulWidget {
  final String? adminKey;
  final String? token;
  const _AdminOrdersPage({this.adminKey, this.token});
  @override
  State<_AdminOrdersPage> createState() => _AdminOrdersPageState();
}

class _AdminOrdersPageState extends State<_AdminOrdersPage> {
  List<Map<String, dynamic>>? _orders;
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final headers = <String, String>{};
      if (widget.token != null) headers['Authorization'] = 'Bearer ${widget.token}';
      final resp = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/api/admin/pay/orders'),
        headers: headers,
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body);
        _orders = (data['orders'] as List).map((e) => e as Map<String, dynamic>).toList();
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  String _fmtPrice(int p) {
    final y = p / 100.0;
    return y == y.roundToDouble() ? '¥${y.toInt()}' : '¥${y.toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_orders == null) return Center(child: Text('加载失败', style: TextStyle(color: cs.error)));
    if (_orders!.isEmpty) return Center(child: Text('暂无订单', style: TextStyle(color: cs.onSurfaceVariant)));
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _orders!.length,
      itemBuilder: (_, i) {
        final o = _orders![i];
        final status = o['status'] as String? ?? '';
        final statusColor = status == 'SUCCESS' ? Colors.green : (status == 'NOTPAY' ? Colors.orange : cs.error);
        return Card(
          margin: const EdgeInsets.only(bottom: 6),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(o['plan_name'] as String? ?? o['plan_id'] as String? ?? '',
                    style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
                const SizedBox(height: 2),
                Text('${_fmtPrice(o['amount'] as int)}  ·  ${(o['created_at'] as String?)?.substring(0, 10) ?? ''}',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                Text('用户 ${o['user_id'] as String? ?? ''}',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: statusColor.withAlpha(25), borderRadius: BorderRadius.circular(4)),
                child: Text(status, style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        );
      },
    );
  }
}


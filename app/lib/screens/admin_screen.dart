import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import '../api/api_config.dart';
import '../utils/validators.dart';
import 'user_detail_screen.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> with TickerProviderStateMixin {
  // Auth
  String? _adminKey; // super admin uses X-Admin-Key
  String? _token;    // other admins use Bearer token
  String? _role;
  final _keyCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  // Register
  final _regUser = TextEditingController();
  final _regPass = TextEditingController();
  final _regName = TextEditingController();
  final _regPhone = TextEditingController();
  final _regIdNum = TextEditingController();
  final _regReason = TextEditingController();
  String _regRole = 'service';
  bool _showRegister = false;

  // User search
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _users = [];
  bool _loading = false;

  // Tabs & sub-tabs
  late TabController _mainTabCtrl;
  int _mainTab = 0;
  String _reqFilter = 'pending';
  List<Map<String, dynamic>> _requests = [];
  List<Map<String, dynamic>> _admins = [];
  List<Map<String, dynamic>> _logs = [];
  List<Map<String, dynamic>> _assignments = [];
  Map<String, dynamic>? _dashboard;
  bool _dashboardLoading = false;
  bool _selectMode = false;
  final Set<String> _selectedUserIds = {};

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
    // Tab 0 = 仪表盘（无需加载）, Tab 1 = 用户管理, then role-dependent
    if (_role == 'super') {
      if (_mainTab == 2) _loadRequests('pending');
      else if (_mainTab == 3) _loadAdmins();
      else if (_mainTab == 4) _loadAssignments();
      else if (_mainTab == 5) _loadLogs();
    } else if (_role == 'service') {
      if (_mainTab == 2) _loadAdmins();
    } else if (_role == 'observer') {
      if (_mainTab == 2) _loadLogs();
    }
  }

  @override
  void initState() {
    super.initState();
    _mainTabCtrl = TabController(length: 1, vsync: this);
    _mainTabCtrl.addListener(_onTabChanged);
  }

  int _tabCount() {
    int n = 1; // 仪表盘 always
    n++; // 用户管理 always
    if (_role == 'super') n++; // 订阅管理
    if (_role == 'super' || _role == 'service') n++; // 注册审批
    if (_role == 'super') n++; // 监护管理
    if (_role == 'super' || _role == 'observer') n++; // 操作日志
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
    _regUser.dispose(); _regPass.dispose(); _regName.dispose(); _regPhone.dispose(); _regIdNum.dispose(); _regReason.dispose();
    _mainTabCtrl.dispose(); super.dispose();
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
      setState(() { _adminKey = key; _role = 'super'; _loading = false; });
      _rebuildTabs();
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
        Future.delayed(const Duration(seconds: 1), () => context.go(role == 'tutor' ? '/teacher' : '/guardian'));
        return;
      }
      setState(() { _token = resp['token']; _role = role; _loading = false; });
      _rebuildTabs();
      _loadDashboard();
    } else { _snack(resp['error'] ?? '登录失败'); }
  }

  Future<void> _register() async {
    final u = _regUser.text.trim();
    final p = _regPass.text.trim();
    final n = _regName.text.trim();
    final ph = _regPhone.text.trim();
    final id = _regIdNum.text.trim();
    if (Validators.username(u) != null) { _snack(Validators.username(u)!); return; }
    if (Validators.password(p) != null) { _snack(Validators.password(p)!); return; }
    if (Validators.realName(n) != null) { _snack(Validators.realName(n)!); return; }
    if (Validators.phone(ph) != null) { _snack(Validators.phone(ph)!); return; }
    if (Validators.idNumber(id) != null) { _snack(Validators.idNumber(id)!); return; }

    final resp = await _api('POST', '/api/admin/register', body: {
      'username': u, 'password': p,
      'role': _regRole, 'real_name': n, 'phone': ph,
      'id_number': id, 'apply_reason': _regReason.text.trim(),
      'registered_from': 'admin',
    });
    _snack(resp.containsKey('admin_id') ? '申请已提交，等待审批' : (resp['error'] ?? '失败'));
  }

  // ── User Management ──
  Future<void> _search() async {
    final q = _searchCtrl.text.trim(); if (q.isEmpty) return;
    setState(() => _loading = true);
    final resp = await _api('GET', '/api/admin/users?q=$q');
    setState(() { _users = (resp['users'] as List?)?.cast<Map<String, dynamic>>() ?? []; _loading = false; });
  }

  Future<void> _revealPhone(String uid) async {
    // Step 1: reveal masked phone
    final resp1 = await _api('POST', '/api/admin/users/$uid/reveal-phone');
    if (resp1.containsKey('phone')) {
      final maskedPhone = resp1['phone'] as String;
      if (resp1['full'] == true) {
        // Already returned full (shouldn't happen on first call)
        showDialog(context: context, builder: (ctx) => AlertDialog(
          title: const Text('手机号'),
          content: Text(maskedPhone),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
        ));
        return;
      }
      // Show masked phone with "查看完整号码" button
      if (!context.mounted) return;
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
              if (!context.mounted) return;
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
        FilledButton(onPressed: () { Navigator.pop(ctx); _api('PUT', '/api/admin/users/$uid/subscription', body: {'subscription_expires': ctrl.text.trim()}).then((r) => _snack(r.containsKey('status')?'已设置':'失败')); }, child: const Text('保存')),
      ],
    ));
  }

  void _quickExtend(String uid, int days) {
    final now = DateTime.now();
    final exp = DateTime(now.year, now.month, now.day + days);
    final dateStr = '${exp.year}-${exp.month.toString().padLeft(2, '0')}-${exp.day.toString().padLeft(2, '0')}';
    _api('PUT', '/api/admin/users/$uid/subscription', body: {'subscription_expires': dateStr}).then((r) {
      _snack(r.containsKey('status') ? '已延长 $days 天至 $dateStr' : '失败');
      _search();
    });
  }

  void _toggleSelectMode() {
    setState(() { _selectMode = !_selectMode; if (!_selectMode) _selectedUserIds.clear(); });
  }

  void _batchExtend(int days) {
    if (_selectedUserIds.isEmpty) { _snack('请先选择用户'); return; }
    final now = DateTime.now();
    final exp = DateTime(now.year, now.month, now.day + days);
    final dateStr = '${exp.year}-${exp.month.toString().padLeft(2, '0')}-${exp.day.toString().padLeft(2, '0')}';
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
        const SizedBox(height: 12),
        DropdownButtonFormField(value: channel, items: const [
          DropdownMenuItem(value: null, child: Text('（不选）')),
          DropdownMenuItem(value: '公开课', child: Text('公开课')),
          DropdownMenuItem(value: '转介绍', child: Text('转介绍')),
          DropdownMenuItem(value: '自然流量', child: Text('自然流量')),
        ], onChanged: (v) => setSt(() => channel = v), decoration: const InputDecoration(isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: 12),
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
  Future<void> _loadLogs() async {
    final resp = await _api('GET', '/api/admin/audit-log');
    setState(() => _logs = (resp['logs'] as List?)?.cast<Map<String, dynamic>>() ?? []);
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

  void _showCreateAssignmentDialog() {
    final adminCtrl = TextEditingController();
    final studentCtrl = TextEditingController();
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('新建监护绑定'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: adminCtrl, decoration: const InputDecoration(labelText: '管理员ID (guardian/tutor)', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(controller: studentCtrl, decoration: const InputDecoration(labelText: '学生用户ID', isDense: true, border: OutlineInputBorder())),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () {
          Navigator.pop(ctx);
          _api('POST', '/api/admin/guardian/assignments', body: {'guardian_admin_id': adminCtrl.text.trim(), 'student_user_id': studentCtrl.text.trim()}).then((resp) {
            _snack(resp.containsKey('id') ? '绑定创建成功' : (resp['error'] ?? '失败'));
            _loadAssignments();
          });
        }, child: const Text('创建')),
      ],
    ));
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

    final showApproval = _role == 'super';
    final showAdminMgmt = _role == 'super' || _role == 'service';
    final showAssignment = _role == 'super';
    final showAudit = _role == 'super' || _role == 'observer';
    final tabs = <Tab>[const Tab(text: '仪表盘'), const Tab(text: '用户管理')];
    if (showApproval) tabs.add(const Tab(text: '订阅管理'));
    if (showAdminMgmt) tabs.add(const Tab(text: '注册审批'));
    if (showAssignment) tabs.add(const Tab(text: '监护管理'));
    if (showAudit) tabs.add(const Tab(text: '操作日志'));

    return Scaffold(
      appBar: AppBar(
        title: const Text('管理后台 v5.20'),
        bottom: TabBar(controller: _mainTabCtrl, isScrollable: true, tabs: tabs),
      ),
      body: _buildBody(showApproval, showAdminMgmt, showAssignment, showAudit),
      floatingActionButton: (_role == 'super' || _role == 'service') ? FloatingActionButton.small(onPressed: () => _showRegistrationDialog(), child: const Icon(Icons.person_add)) : null,
    );
  }

  Widget _buildBody(bool showApproval, bool showAdminMgmt, bool showAssignment, bool showAudit) {
    return IndexedStack(index: _mainTab, children: [
      _buildDashboardTab(),
      _buildUsersTab(),
      if (showApproval) _buildApprovalTab(),
      if (showAdminMgmt) _buildAdminMgmtTab(),
      if (showAssignment) _buildAssignmentTab(),
      if (showAudit) _buildAuditTab(),
    ]);
  }

  void _showRegistrationDialog() {
    showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) => AlertDialog(
      title: const Text('注册管理员'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: _regUser, decoration: const InputDecoration(labelText: '用户名（5位以上英文或数字）', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: 8),
        TextField(controller: _regPass, obscureText: true, decoration: const InputDecoration(labelText: '密码（6位以上英文+数字）', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: 8),
        TextField(controller: _regName, decoration: const InputDecoration(labelText: '真实姓名（中文，4字以内）', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: 8),
        TextField(controller: _regPhone, decoration: const InputDecoration(labelText: '手机号', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: 8),
        TextField(controller: _regIdNum, decoration: const InputDecoration(labelText: '身份证号', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: 8),
        DropdownButtonFormField(value: _regRole, items: const [
          DropdownMenuItem(value: 'service', child: Text('服务人员')),
          DropdownMenuItem(value: 'tutor', child: Text('辅导老师')),
        ], onChanged: (v) => setSt(() => _regRole = v!), decoration: const InputDecoration(labelText: '角色', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: 8),
        TextField(controller: _regReason, decoration: const InputDecoration(labelText: '申请理由', isDense: true, border: OutlineInputBorder())),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () { Navigator.pop(ctx); _register(); }, child: const Text('提交')),
      ],
    )));
  }

  Widget _buildLogin() {
    return Scaffold(
      appBar: AppBar(title: const Text('管理后台')),
      body: _showRegister ? _buildRegisterForm() : Center(child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.admin_panel_settings, size: 64, color: Colors.grey),
          const SizedBox(height: 24),
          TextField(controller: _keyCtrl, decoration: const InputDecoration(labelText: '管理员密钥 或 用户名', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: _passCtrl, obscureText: true, decoration: const InputDecoration(labelText: '密码（账号登录时必填）', border: OutlineInputBorder())),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            FilledButton(onPressed: _loginWithKey, child: const Text('密钥登录')),
            FilledButton.tonal(onPressed: _loginWithAccount, child: const Text('账号登录')),
          ]),
          TextButton(onPressed: () => setState(() => _showRegister = true), child: const Text('或注册账号')),
        ]),
      )),
    );
  }

  Widget _buildRegisterForm() {
    return Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('注册管理员账号', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      const SizedBox(height: 16),
      TextField(controller: _regUser, decoration: const InputDecoration(labelText: '用户名（5位以上英文或数字）', isDense: true, border: OutlineInputBorder())),
      const SizedBox(height: 8),
      TextField(controller: _regPass, obscureText: true, decoration: const InputDecoration(labelText: '密码（6位以上英文+数字）', isDense: true, border: OutlineInputBorder())),
      const SizedBox(height: 8),
      TextField(controller: _regName, decoration: const InputDecoration(labelText: '真实姓名（中文，4字以内）', isDense: true, border: OutlineInputBorder())),
      const SizedBox(height: 8),
      TextField(controller: _regPhone, decoration: const InputDecoration(labelText: '手机号', isDense: true, border: OutlineInputBorder())),
      const SizedBox(height: 8),
      TextField(controller: _regIdNum, decoration: const InputDecoration(labelText: '身份证号', isDense: true, border: OutlineInputBorder())),
      const SizedBox(height: 8),
      DropdownButtonFormField(value: _regRole, items: const [
        DropdownMenuItem(value: 'service', child: Text('服务人员')),
        DropdownMenuItem(value: 'tutor', child: Text('辅导老师')),
      ], onChanged: (v) => setState(() => _regRole = v!), decoration: const InputDecoration(labelText: '申请角色', isDense: true, border: OutlineInputBorder())),
      const SizedBox(height: 8),
      TextField(controller: _regReason, decoration: const InputDecoration(labelText: '申请理由', isDense: true, border: OutlineInputBorder())),
      const SizedBox(height: 16),
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        OutlinedButton(onPressed: () => setState(() => _showRegister = false), child: const Text('返回登录')),
        FilledButton(onPressed: _register, child: const Text('提交申请')),
      ]),
    ])));
  }

  // ── Dashboard Tab ──
  Widget _buildDashboardTab() {
    return _dashboard == null
      ? Center(child: _dashboardLoading ? const CircularProgressIndicator() : TextButton(onPressed: _loadDashboard, child: const Text('加载仪表盘')))
      : SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 12, runSpacing: 12, children: [
          _statCard('今日新用户', '${_dashboard!['today_new_users'] ?? 0}', Icons.person_add),
          _statCard('今日活跃', '${_dashboard!['today_active_users'] ?? 0}', Icons.trending_up),
          _statCard('今日复习', '${_dashboard!['today_reviews'] ?? 0}', Icons.replay),
          _statCard('总用户', '${_dashboard!['total_users'] ?? 0}', Icons.people),
          _statCard('总卡片', '${_dashboard!['total_cards'] ?? 0}', Icons.style),
        ]),
        const SizedBox(height: 24),
        Text('即将到期（7天内）', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if ((_dashboard!['expiring_soon'] as List?)?.isEmpty ?? true)
          const Text('暂无', style: TextStyle(color: Colors.grey))
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
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Icon(icon, size: 28, color: Colors.blue),
            const SizedBox(height: 8),
            Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ]),
        ),
      ),
    );
  }

  // ── User Management Tab ──
  Widget _buildUsersTab() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Expanded(child: TextField(controller: _searchCtrl, decoration: InputDecoration(hintText: '搜索用户名/ID', prefixIcon: const Icon(Icons.search, size: 20), isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(24))))),
          const SizedBox(width: 8),
          FilledButton(onPressed: _search, child: const Text('查找')),
          const SizedBox(width: 4),
          IconButton(icon: const Icon(Icons.download, size: 20), onPressed: _exportCsv, tooltip: '导出 CSV'),
          if (_role == 'super') ...[
            const SizedBox(width: 4),
            IconButton(
              icon: Icon(_selectMode ? Icons.close : Icons.checklist, size: 20),
              onPressed: _toggleSelectMode,
              tooltip: _selectMode ? '退出选择' : '批量操作',
            ),
          ],
        ]),
      ),
      if (_selectMode && _selectedUserIds.isNotEmpty)
        Container(
          color: Colors.blue.shade50,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            Text('已选 ${_selectedUserIds.length} 人', style: const TextStyle(fontSize: 13)),
            const Spacer(),
            ...[7, 30, 365].map((days) => Padding(
              padding: const EdgeInsets.only(left: 4),
              child: FilledButton.tonal(onPressed: () => _batchExtend(days), style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)), child: Text('+${days}d', style: const TextStyle(fontSize: 11))),
            )),
          ]),
        ),
      if (_loading) const LinearProgressIndicator(),
      Expanded(child: _users.isEmpty
        ? Center(child: Text(_loading ? '' : '输入搜索条件', style: TextStyle(color: Colors.grey.shade400)))
        : ListView.builder(itemCount: _users.length, itemBuilder: (_, i) {
        final u = _users[i];
        final phone = u['phone'] as String?;
        final phoneMasked = u['phone_masked'] as String? ?? phone ?? '—';
        final name = (u['real_name'] as String?) ?? u['real_name_masked'] as String? ?? '—';
        final isActive = u['subscription_expires'] != null && (u['subscription_expires'] as String).isNotEmpty;
        final isSelected = _selectedUserIds.contains(u['user_id'] as String);
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          color: isSelected ? Colors.blue.shade50 : null,
          child: _selectMode
            ? ListTile(
                leading: Checkbox(
                  value: isSelected,
                  onChanged: (_) => setState(() {
                    if (isSelected) { _selectedUserIds.remove(u['user_id']); } else { _selectedUserIds.add(u['user_id'] as String); }
                  }),
                ),
                title: Text(u['display_name'] ?? u['username'] ?? ''),
                subtitle: Text('${u['subscription_expires'] ?? '未激活'}'),
                onTap: () => setState(() {
                  if (isSelected) { _selectedUserIds.remove(u['user_id']); } else { _selectedUserIds.add(u['user_id'] as String); }
                }),
              )
            : ExpansionTile(
            title: Text(u['display_name'] ?? u['username'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('卡片:${u['card_count']} 复习:${u['review_count']} ${isActive ? "✓ 已激活" : "未激活"}'),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('姓名: $name', style: const TextStyle(fontSize: 13)),
                  Text('手机: $phoneMasked', style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, children: [
                    if (phone != null && phone.length > 8) OutlinedButton.icon(icon: const Icon(Icons.phone, size: 16), onPressed: () => _revealPhone(u['user_id']), label: const Text('看手机号', style: TextStyle(fontSize: 12))),
                    OutlinedButton.icon(icon: const Icon(Icons.open_in_new, size: 16), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => UserDetailScreen(userId: u['user_id'] as String, adminKey: _adminKey, token: _token, role: _role!))), label: const Text('详情', style: TextStyle(fontSize: 12))),
                    if (_role == 'super') ...[
                      FilledButton.tonal(onPressed: () => _showSubDialog(u), child: const Text('设置到期', style: TextStyle(fontSize: 12))),
                      // 快速延长按钮
                      ...[7, 30, 365].map((days) => TextButton(
                        onPressed: () => _quickExtend(u['user_id'] as String, days),
                        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                        child: Text('+${days}d', style: const TextStyle(fontSize: 11)),
                      )),
                    ],
                    if (_role == 'super' || _role == 'service') FilledButton.tonal(onPressed: () => _showCreateRequest(u), child: const Text('申请开通', style: TextStyle(fontSize: 12))),
                  ]),
                ]),
              ),
            ],
          ),
        );
      })),
    ]);
  }

  // ── Approval Tab ──
  Widget _buildApprovalTab() {
    return Column(children: [
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
        _filterChip('待审批', 'pending'),
        _filterChip('已通过', 'approved'),
        _filterChip('已拒绝', 'rejected'),
      ])),
      Expanded(child: _requests.isEmpty
        ? Center(child: TextButton(onPressed: () => _loadRequests(_reqFilter), child: const Text('点击加载')))
        : ListView.builder(itemCount: _requests.length, itemBuilder: (_, i) {
        final r = _requests[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ListTile(
            title: Text('${r['target_username'] ?? r['target_user_id']} · ${r['package']}'),
            subtitle: Text('${r['requester_name'] ?? r['requested_by']} · ${r['channel'] ?? ''} · ${r['requested_at'] ?? ''}'.replaceAll(RegExp(r'T.*'), '')),
            trailing: r['status'] == 'pending'
              ? Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(icon: const Icon(Icons.check_circle, color: Colors.green), onPressed: () => _approveReq(r['id'] as String)),
                  IconButton(icon: const Icon(Icons.cancel, color: Colors.red), onPressed: () => _rejectReqDialog(r['id'] as String)),
                ])
              : Chip(label: Text(r['status'] == 'approved' ? '已通过' : '已拒绝', style: const TextStyle(fontSize: 11))),
          ),
        );
      })),
    ]);
  }

  Widget _filterChip(String label, String filter) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
    child: FilterChip(
      label: Text(label, style: const TextStyle(fontSize: 13)),
      selected: _reqFilter == filter,
      onSelected: (_) => _loadRequests(filter),
    ),
  );

  // ── Admin Mgmt Tab ──
  Widget _buildAdminMgmtTab() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('${_role == "super" ? "注册审批" : "家长/辅导审批"}', style: Theme.of(context).textTheme.titleMedium),
          TextButton.icon(icon: const Icon(Icons.refresh, size: 18), onPressed: _loadAdmins, label: const Text('刷新')),
        ]),
      ),
      Expanded(child: _admins.isEmpty
        ? Center(child: TextButton(onPressed: _loadAdmins, child: const Text('点击加载')))
        : ListView.builder(itemCount: _admins.length, itemBuilder: (_, i) {
        final a = _admins[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ListTile(
            title: Text(a['real_name'] ?? a['username'] ?? ''),
            subtitle: Text('${a['role']} · ${a['status']} · ${a['phone'] ?? ''}'),
            trailing: a['status'] == 'pending'
              ? Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(icon: const Icon(Icons.check_circle, color: Colors.green, size: 22), onPressed: () => _approveAdmin(a['id'] as String)),
                  IconButton(icon: const Icon(Icons.cancel, color: Colors.red, size: 22), onPressed: () => _rejectAdminDialog(a['id'] as String)),
                ]) : null,
          ),
        );
      })),
    ]);
  }

  // ── Guardian Assignment Tab ──
  Widget _buildAssignmentTab() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
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
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          color: active ? null : Colors.grey.shade100,
          child: ListTile(
            title: Text('${a['guardian_name'] ?? a['guardian_admin_id']} → ${a['student_display_name'] ?? a['student_real_name'] ?? a['student_user_id']}', style: TextStyle(fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
            subtitle: Text('${a['assigned_at']?.toString().replaceAll(RegExp(r'T.*'), '') ?? ''}  ${active ? "有效" : "已解除"}'),
            trailing: active
              ? IconButton(icon: const Icon(Icons.link_off, color: Colors.red, size: 20), onPressed: () => _removeAssignment(a['id'] as String))
              : null,
          ),
        );
      })),
    ]);
  }

  // ── Audit Tab ──
  Widget _buildAuditTab() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: TextButton.icon(icon: const Icon(Icons.refresh, size: 18), onPressed: _loadLogs, label: const Text('加载审计日志')),
      ),
      Expanded(child: _logs.isEmpty
        ? const Center(child: Text('暂无日志'))
        : ListView.builder(itemCount: _logs.length, itemBuilder: (_, i) {
        final l = _logs[i];
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
        return ListTile(
          dense: true,
          title: Text('${l['admin_name'] ?? l['admin_id']} · ${l['action']}', style: const TextStyle(fontSize: 13)),
          subtitle: Text('${l['target_user_id'] ?? ''} ${detailText.isNotEmpty ? "· $detailText" : ""} · ${l['created_at'] ?? ''}', style: const TextStyle(fontSize: 11)),
        );
      })),
    ]);
  }
}

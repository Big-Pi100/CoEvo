// ignore_for_file: unused_element
import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../api/api_config.dart';
import '../utils/validators.dart';
import '../widgets/markdown_span_nodes.dart';

/// CoEvo parent/guardian dashboard screen
///
/// Color palette:
///   Surface: Color(0xFFF8F7F4) — warm off-white
///   Card: Colors.white with subtle border
///   Primary: Color(0xFF2D3A4A) — deep slate
///   Accent variants: Color(0xFF5B7A9A) — muted blue
class GuardianScreen extends StatefulWidget {
  const GuardianScreen({super.key});
  @override
  State<GuardianScreen> createState() => _GuardianScreenState();
}

class _GuardianScreenState extends State<GuardianScreen> {
  // ── Palette ──
  static const Color _surfaceBg = Color(0xFFF8F7F4);
  static const Color _primaryDark = Color(0xFF2D3A4A);
  static const Color _primaryMuted = Color(0xFF5B7A9A);
  static const Color _textBody = Color(0xFF2C2C2C);
  static const Color _textSecondary = Color(0xFF7A7A7A);
  static const Color _textMuted = Color(0xFFB0B0B0);
  static const Color _border = Color(0xFFE8E6E0);
  static const Color _green = Color(0xFF588157);
  static const Color _orange = Color(0xFFC77D33);
  static const Color _red = Color(0xFFB4433C);
  static const Color _grey = Color(0xFF8A8A8A);

  String? _token;
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  String _relation = '父亲';
  // 学生绑定
  final _sNameCtrl = TextEditingController();
  final _sPhoneCtrl = TextEditingController();
  String? _matchedStudentId;
  String? _matchedStudentName;
  bool _lookingUp = false;

  List<Map<String, dynamic>> _students = [];
  String? _activeStudentId;
  List<Map<String, dynamic>> _cards = [];
  bool _showAllCards = false;
  List<Map<String, dynamic>> _plans = [];
  Map<String, dynamic> _overview = {};
  List<Map<String, dynamic>> _convs = [];
  List<Map<String, dynamic>> _turns = [];
  String? _viewingConvId;
  int _page = 0; // 0=login, 1=list, 2=detail

  bool get _isTutorMode => (html.window.location.pathname ?? '').contains('/teacher');
  String get _tokenKey => _isTutorMode ? 'tutor_token' : 'guardian_token';
  void _saveToken(String t) { _token = t; html.window.localStorage[_tokenKey] = t; }
  String? _loadToken() => html.window.localStorage[_tokenKey];
  void _clearToken() { _token = null; html.window.localStorage.remove(_tokenKey); }

  Map<String, String> headers() => {'Authorization': 'Bearer $_token'};

  Future<Map<String, dynamic>> _api(String method, String path, {Map<String, dynamic>? body}) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}$path');
    final req = method == 'POST'
        ? http.post(uri, headers: {...headers(), 'Content-Type': 'application/json'}, body: jsonEncode(body ?? {}))
        : http.get(uri, headers: headers());
    final resp = await req.timeout(const Duration(seconds: 10));
    if (resp.statusCode == 200) return jsonDecode(resp.body) as Map<String, dynamic>;
    final respBody = resp.body;
    try { return jsonDecode(respBody) as Map<String, dynamic>; } catch (_) { return {'error': '${resp.statusCode} $respBody'}; }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  void _showCardDetail(Map<String, dynamic> card) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: Text(card['front'] ?? '', style: const TextStyle(fontSize: 16)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(card['back'] ?? card['source_sentence'] ?? '', style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 12),
        Text('复习: ${card['reps'] ?? 0}次 · 状态: ${['新','学习中','已掌握','重学'][(card['state'] ?? 0).clamp(0, 3)]}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        if (card['source_sentence'] != null) ...[const SizedBox(height: 4), Text('原文: ${card['source_sentence']}', style: const TextStyle(fontSize: 12, color: Colors.grey))],
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
    ));
  }

  Future<void> _login() async {
    final resp = await _api('POST', '/api/admin/login', body: {'username': _userCtrl.text.trim(), 'password': _passCtrl.text.trim()});
    if (resp.containsKey('token')) { _saveToken(resp['token'] as String); _loadStudents(); }
    else { _snack(resp['error'] ?? '登录失败'); }
  }

  Future<void> _doRegister() async {
    final u = _userCtrl.text.trim();
    final p = _passCtrl.text.trim();
    final n = _nameCtrl.text.trim();
    final ph = _phoneCtrl.text.trim();
    if (u.length < 5) { _snack('用户名至少5位'); return; }
    if (p.length < 6) { _snack('密码至少6位'); return; }
    if (n.isEmpty || n.length > 4) { _snack('姓名须为中文2-4字'); return; }
    if (ph.length != 11 || !ph.startsWith('1')) { _snack('手机号格式不正确'); return; }
    _snack('正在提交...');
    final resp = await _api('POST', '/api/admin/register', body: {
      'username': u, 'password': p,
      'role': _isTutorMode ? 'tutor' : 'guardian',
      'real_name': n, 'phone': ph,
      'registered_from': _isTutorMode ? 'teacher' : 'parent',
    });
    if (resp.containsKey('admin_id')) {
      _snack('注册成功，请登录');
      setState(() { _showRegister = false; });
    } else {
      _snack(resp['error'] ?? '注册失败');
    }
  }

  @override
  void initState() {
    super.initState();
    final saved = _loadToken();
    if (saved != null && saved.isNotEmpty) { _token = saved; _loadStudents(); }
  }

  Future<void> _lookupStudent() async {
    final n = _sNameCtrl.text.trim();
    final p = _sPhoneCtrl.text.trim();
    if (Validators.realName(n) != null) { _snack(Validators.realName(n)!); return; }
    if (Validators.phone(p) != null) { _snack(Validators.phone(p)!); return; }

    setState(() => _lookingUp = true);
    final resp = await _api('POST', '/api/user/bind-lookup', body: {'real_name': n, 'phone': p});
    setState(() => _lookingUp = false);
    if (resp['found'] == true) {
      setState(() { _matchedStudentId = resp['user_id']; _matchedStudentName = resp['display_name'] ?? n; });
      _snack('已匹配: $_matchedStudentName');
    } else {
      setState(() { _matchedStudentId = null; _matchedStudentName = null; });
      _snack('未找到匹配的学生，请学生先在App个人页完善姓名和手机号');
    }
  }

  Future<void> _register() async {
    final u = _userCtrl.text.trim();
    final p = _passCtrl.text.trim();
    final n = _nameCtrl.text.trim();
    final ph = _phoneCtrl.text.trim();
    if (Validators.username(u) != null) { _snack(Validators.username(u)!); return; }
    if (Validators.password(p) != null) { _snack(Validators.password(p)!); return; }
    if (Validators.realName(n) != null) { _snack(Validators.realName(n)!); return; }
    if (Validators.phone(ph) != null) { _snack(Validators.phone(ph)!); return; }
    if (_matchedStudentId == null) { _snack('请先查找并匹配学生账号'); return; }

    final resp = await _api('POST', '/api/admin/register', body: {
      'username': u, 'password': p,
      'role': 'guardian', 'real_name': n, 'phone': ph,
      'registered_from': 'parent',
      'guardian_declaration': jsonEncode({'relation': _relation, 'consented': true, 'student_user_id': _matchedStudentId}),
    });
    _snack(resp.containsKey('admin_id') ? '申请已提交，等待审批' : (resp['error'] ?? '失败'));
  }

  Future<void> _loadStudents() async {
    setState(() { _loading = true; _error = null; });
    final resp = await _api('GET', '/api/admin/guardian/students');
    if (resp.containsKey('students')) {
      final list = (resp['students'] as List).cast<Map<String, dynamic>>();
      setState(() { _students = list; _page = 1; _loading = false; });
    } else {
      setState(() { _loading = false; _error = resp['error'] ?? '加载失败'; });
    }
  }

  void _showBindDialog() {
    // Reset bind form
    _sNameCtrl.clear();
    _sPhoneCtrl.clear();
    _matchedStudentId = null;
    _matchedStudentName = null;
    _lookingUp = false;
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx2, setDialogState) {
          return AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
        title: Row(children: [
          Icon(Icons.person_add_rounded, size: 20, color: _primaryDark),
          const SizedBox(width: 8),
          Text('绑定学生账号', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: _textBody)),
        ]),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('输入学生姓名和手机号进行匹配', style: TextStyle(fontSize: 13, color: _textSecondary)),
            const SizedBox(height: 16),
            TextField(controller: _sNameCtrl, decoration: const InputDecoration(labelText: '学生姓名', isDense: true, border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(controller: _sPhoneCtrl, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: '学生手机号', isDense: true, border: OutlineInputBorder())),
            const SizedBox(height: 16),
            if (_matchedStudentId != null)
              Chip(avatar: Icon(Icons.check_circle, color: _green, size: 18), label: Text('已匹配: $_matchedStudentName', style: TextStyle(fontSize: 13)))
            else
              Text('未找到匹配的学生，请学生先在App个人页完善姓名和手机号', style: TextStyle(fontSize: 12, color: _textSecondary)),
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: OutlinedButton(
              onPressed: _lookingUp ? null : () async {
                await _lookupStudent();
                setDialogState(() {});
              },
              child: Text(_lookingUp ? '查找中...' : '查找学生'),
            )),
            if (_matchedStudentId != null) ...[
              const SizedBox(height: 8),
              SizedBox(width: double.infinity, child: FilledButton(
                onPressed: () { Navigator.pop(ctx); _requestBind(); },
                child: const Text('确认绑定'),
              )),
            ],
          ]),
        ),
      );
        });
      },
    );
  }

  Future<void> _requestBind() async {
    if (_matchedStudentId == null) return;
    _snack('正在提交...');
    final resp = await _api('POST', '/api/admin/guardian/bind', body: {'student_user_id': _matchedStudentId});
    if (resp.containsKey('success')) {
      _snack('绑定成功！${_matchedStudentName ?? ''} 的学习报告已开放');
      _loadStudents();
    } else {
      _snack(resp['error'] ?? '提交失败');
    }
  }

  Future<void> _revealGuardianPhone(String adminId) async {
    if (adminId.isEmpty) return;
    final resp = await _api('POST', '/api/admin/guardian/reveal-phone/$adminId');
    if (resp.containsKey('phone')) {
      _snack('家长手机号: ${resp['phone']}');
    } else {
      _snack(resp['error'] ?? '获取失败');
    }
  }

  Future<void> _viewStudent(String sid) async {
    _activeStudentId = sid;
    setState(() { _loading = true; _error = null; });
    final summary = await _api('GET', '/api/admin/guardian/students/$sid/learning-summary');
    final cards = await _api('GET', '/api/admin/guardian/students/$sid/cards');
    final convs = await _api('GET', '/api/admin/guardian/students/$sid/conversations');
    if (mounted) {
      if (summary.containsKey('error') || cards.containsKey('error') || convs.containsKey('error')) {
        setState(() { _loading = false; _error = summary['error'] ?? cards['error'] ?? convs['error'] ?? '加载失败'; });
      } else {
        setState(() {
          _overview = (summary['overview'] as Map<String, dynamic>?) ?? {};
          _plans = (summary['plans'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          _cards = (cards['cards'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          _convs = (convs['conversations'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          _showAllCards = false; _page = 2; _viewingConvId = null; _loading = false;
        });
      }
    }
  }

  Future<void> _viewConversation(String cid) async {
    final resp = await _api('GET', '/api/admin/guardian/students/$_activeStudentId/conversations/$cid');
    if (resp.containsKey('turns')) setState(() { _turns = (resp['turns'] as List).cast<Map<String, dynamic>>(); _viewingConvId = cid; });
  }

  @override
  void dispose() {
    _userCtrl.dispose(); _passCtrl.dispose(); _nameCtrl.dispose(); _phoneCtrl.dispose();
    _sNameCtrl.dispose(); _sPhoneCtrl.dispose(); super.dispose();
  }

  bool _loading = false;
  String? _error;
  bool _showRegister = false;

  @override
  Widget build(BuildContext context) {
    if (_token == null) return _buildLogin();
    if (_loading) return Scaffold(appBar: AppBar(title: const Text('加载中...')), body: const Center(child: CircularProgressIndicator()));
    if (_error != null) return Scaffold(appBar: AppBar(title: const Text('加载失败')), body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Text(_error!, style: const TextStyle(color: Colors.red)), TextButton(onPressed: () { _error = null; _refresh(); }, child: const Text('重试'))])));
    if (_page <= 1) return _buildStudentList();
    return _buildStudentDetail();
  }

  void _refresh() {
    if (_activeStudentId != null) _viewStudent(_activeStudentId!);
    else _loadStudents();
  }

  Widget _buildLogin() {
    return Scaffold(
      backgroundColor: _surfaceBg,
      appBar: AppBar(
        title: Text(_isTutorMode ? '辅导老师' : '家长', style: TextStyle(color: Color(0xFF2C2C2C))),
        centerTitle: false,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0.5,
        foregroundColor: const Color(0xFF2C2C2C),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.family_restroom_rounded, size: 48, color: _primaryMuted),
            const SizedBox(height: 24),
            // ── Login form ──
            if (!_showRegister) ...[
              TextField(controller: _userCtrl, decoration: const InputDecoration(labelText: '用户名', border: OutlineInputBorder(), prefixIcon: Icon(Icons.person_outline))),
              const SizedBox(height: 12),
              TextField(controller: _passCtrl, obscureText: true, decoration: const InputDecoration(labelText: '密码', border: OutlineInputBorder(), prefixIcon: Icon(Icons.lock_outline))),
              const SizedBox(height: 20),
              SizedBox(width: double.infinity, child: FilledButton(onPressed: _login, child: const Text('登录'))),
              const SizedBox(height: 16),
              TextButton(onPressed: () => setState(() => _showRegister = true), child: Text('没有账号？注册${_isTutorMode ? "辅导老师" : "监护账号"}')),
            ],
            // ── Register form ──
            if (_showRegister) ...[
              TextField(controller: _userCtrl, decoration: const InputDecoration(labelText: '用户名（5位以上英文数字）', border: OutlineInputBorder(), prefixIcon: Icon(Icons.person_outline))),
              const SizedBox(height: 12),
              TextField(controller: _passCtrl, obscureText: true, decoration: const InputDecoration(labelText: '密码（6位以上含英文+数字）', border: OutlineInputBorder(), prefixIcon: Icon(Icons.lock_outline))),
              const SizedBox(height: 12),
              TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: '真实姓名（中文4字以内）', border: OutlineInputBorder(), prefixIcon: Icon(Icons.badge_outlined))),
              const SizedBox(height: 12),
              TextField(controller: _phoneCtrl, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: '手机号', border: OutlineInputBorder(), prefixIcon: Icon(Icons.phone_outlined))),
              const SizedBox(height: 20),
              SizedBox(width: double.infinity, child: FilledButton(onPressed: _doRegister, child: Text('注册${_isTutorMode ? '辅导老师' : '监护账号'}'))),
              const SizedBox(height: 16),
              TextButton(onPressed: () => setState(() => _showRegister = false), child: const Text('已有账号？去登录')),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _buildStudentList() {
    return Scaffold(
      backgroundColor: _surfaceBg,
      appBar: AppBar(
        title: Text(_isTutorMode ? '我的学生' : '我的孩子', style: TextStyle(color: Color(0xFF2C2C2C))),
        centerTitle: false,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0.5,
        foregroundColor: const Color(0xFF2C2C2C),
        actions: [
          IconButton(icon: const Icon(Icons.person_add_outlined), onPressed: _showBindDialog),
          IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: _loadStudents),
        ],
      ),
      body: _students.isEmpty
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.child_care_outlined, size: 56, color: _textMuted),
                const SizedBox(height: 16),
                Text('暂无绑定的学生', style: TextStyle(fontSize: 15, color: _textSecondary)),
                const SizedBox(height: 12),
                Text('添加学生后即可查看学习报告', style: TextStyle(fontSize: 13, color: _textMuted)),
                const SizedBox(height: 24),
                FilledButton.icon(
                  icon: const Icon(Icons.person_add_rounded, size: 18),
                  label: const Text('绑定学生'),
                  onPressed: _showBindDialog,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('刷新'),
                  onPressed: _loadStudents,
                ),
              ]),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: _students.length,
              itemBuilder: (_, i) {
                final s = _students[i];
                final name = (s['real_name'] as String?) ?? (s['display_name'] as String?) ?? '学生';
                final phone = s['phone_masked'] as String? ?? '';
                final subtitleText = phone.isNotEmpty ? '$name · $phone' : name;
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _border),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: CircleAvatar(
                      backgroundColor: _primaryMuted.withOpacity(0.12),
                      child: Text(
                        name.substring(0, 1),
                        style: TextStyle(fontWeight: FontWeight.w600, color: _primaryDark, fontSize: 15),
                      ),
                    ),
                    title: Row(children: [
                      Expanded(child: Text(subtitleText, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: _textBody))),
                      _streakBadge(s['streak_days'] as int? ?? 0, s['last_active'] as String?),
                    ]),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          _chip('${s['plan_total'] ?? 0} 计划', _primaryMuted),
                          _chip('${s['plan_active_7d'] ?? 0} 活跃', _green),
                          _chip('今日 ${s['plan_today'] ?? 0}', _orange),
                        ]),
                        // Guardian info (tutor only)
                        if (_isTutorMode && s['guardian_name'] != null) ...[
                          const SizedBox(height: 6),
                          Row(children: [
                            Icon(Icons.person_outline, size: 13, color: _textMuted),
                            const SizedBox(width: 4),
                            Text('家长: ${s['guardian_name']}', style: TextStyle(fontSize: 12, color: _textSecondary)),
                            if (s['guardian_phone_masked'] != null) ...[
                              const SizedBox(width: 8),
                              Text(s['guardian_phone_masked'] as String, style: TextStyle(fontSize: 12, color: _textSecondary)),
                            ],
                            if (_isTutorMode && s['guardian_phone_masked'] != null)
                              GestureDetector(
                                onTap: () => _revealGuardianPhone(s['guardian_admin_id'] as String? ?? ''),
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: Icon(Icons.visibility_outlined, size: 14, color: _primaryMuted),
                                ),
                              ),
                          ]),
                        ],
                      ]),
                    ),
                    trailing: Icon(Icons.chevron_right, color: _textMuted, size: 22),
                    onTap: () => _viewStudent(s['student_user_id'] as String),
                  ),
                );
              },
            ),
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: color)),
    );
  }

  /// Streak badge with color signal:
  ///   🟢 7+ days — strong habit
  ///   🟡 3-6 days — forming
  ///   🟠 1-2 days — just started
  ///   🔴 0 days and recency > 3d — dropped off
  ///   🔴 0 days but recent — just started today
  Widget _streakBadge(int streak, String? lastActive) {
    // Compute days since last active
    Color color;
    String label;
    if (streak >= 7) {
      color = _green;
      label = '$streak天';
    } else if (streak >= 3) {
      color = _orange;
      label = '$streak天';
    } else if (streak >= 1) {
      color = const Color(0xFFD68A3C); // warm orange
      label = '$streak天';
    } else {
      // streak == 0
      if (lastActive != null && lastActive.isNotEmpty) {
        try {
          final dt = DateTime.parse(lastActive);
          final daysSince = DateTime.now().difference(dt).inDays;
          if (daysSince > 3) {
            color = _red;
            label = '${daysSince}d未学';
          } else {
            color = const Color(0xFFD68A3C);
            label = '今日起';
          }
        } catch (_) {
          color = _red;
          label = '未学习';
        }
      } else {
        color = _red;
        label = '未学习';
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _buildStudentDetail() {
    final states = ['新', '学习', '复习', '重学'];
    final student = _students.cast<Map<String, dynamic>>().where((s) => s['student_user_id'] == _activeStudentId).isEmpty ? null : _students.cast<Map<String, dynamic>>().firstWhere((s) => s['student_user_id'] == _activeStudentId);
    return Scaffold(
      backgroundColor: _surfaceBg,
      appBar: AppBar(
        title: Text((student?['real_name'] as String?) ?? (student?['display_name'] as String?) ?? '学习报告', style: const TextStyle(color: Color(0xFF2C2C2C))),
        centerTitle: false,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0.5,
        foregroundColor: const Color(0xFF2C2C2C),
        leading: IconButton(icon: Icon(Icons.arrow_back_rounded, color: const Color(0xFF2C2C2C)), onPressed: () => setState(() { _page = 1; _activeStudentId = null; })),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ── Overview card ──
          if (_overview.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _border),
              ),
              child: Column(children: [
                // Metric row
                Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                  _overviewStat('总计划', '${_overview['total_plans'] ?? 0}', Icons.assignment_outlined, _primaryMuted),
                  _overviewStat('7天活跃', '${_overview['active_7d'] ?? 0}', Icons.trending_up_rounded, _green),
                  _overviewStat('今日', '${_overview['today_active'] ?? 0}', Icons.today_outlined, _orange),
                  _overviewStat('已完成', '${_overview['completed_plans'] ?? 0}', Icons.check_circle_outline, _primaryDark),
                ]),
                const SizedBox(height: 16),
                // Score bar
                Row(children: [
                  Text('综合', style: TextStyle(fontSize: 13, color: _textSecondary)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: ((_overview['overall_score'] ?? 0) as num).toDouble() / 100.0,
                        backgroundColor: const Color(0xFFEEEDE8),
                        color: _primaryMuted,
                        minHeight: 8,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${_overview['overall_score'] ?? 0}', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: _primaryDark)),
                  const SizedBox(width: 4),
                  Text('分', style: TextStyle(fontSize: 12, color: _textSecondary)),
                ]),
                const SizedBox(height: 8),
                // Progress sub-labels
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  _subLabel('推进', _overview['overall_progress'] ?? '0%'),
                  const SizedBox(width: 20),
                  _subLabel('卡片', _overview['overall_cards'] ?? '0%'),
                ]),
              ]),
            ),
            const SizedBox(height: 20),
          ],

          // ── Plan groups ──
          if (_plans.isNotEmpty) ...[
            ..._buildPlanGroups(),
            const SizedBox(height: 8),
          ],

          // ── Conversations ──
          _sectionHeader(Icons.chat_outlined, '对话记录', _convs.length),
          const SizedBox(height: 8),
          if (_convs.isEmpty)
            _emptyPlaceholder('暂无对话')
          else if (_viewingConvId == null)
            ..._convs.map((conv) => _convTile(conv))
          else ...[
            _convDetailHeader(),
            const SizedBox(height: 8),
            ..._turns.map((t) => _turnBubble(t)),
          ],
          const SizedBox(height: 24),

          // ── Cards ──
          _sectionHeader(Icons.credit_card_rounded, '知识卡片', _cards.length),
          const SizedBox(height: 8),
          if (_cards.isEmpty)
            _emptyPlaceholder('暂无卡片')
          else ...[
            ...(_showAllCards ? _cards : _cards.take(10)).map((c) => _cardListTile(c, states)),
            if (_cards.length > 10)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: TextButton(
                  onPressed: () => setState(() => _showAllCards = !_showAllCards),
                  child: Text(_showAllCards ? '收起' : '查看全部 ${_cards.length} 张', style: TextStyle(fontSize: 13, color: _primaryMuted)),
                ),
              ),
          ],
        ]),
      ),
    );
  }

  // ── Sub-widgets ──

  Widget _overviewStat(String label, String value, IconData icon, Color color) {
    return Column(children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(height: 6),
      Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: _textBody)),
      Text(label, style: TextStyle(fontSize: 11, color: _textSecondary)),
    ]);
  }

  Widget _subLabel(String label, String value) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label ', style: TextStyle(fontSize: 11, color: _textSecondary)),
      Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: _textBody)),
    ]);
  }

  Widget _sectionHeader(IconData icon, String title, int count) {
    return Row(children: [
      Icon(icon, size: 18, color: _primaryDark),
      const SizedBox(width: 8),
      Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _textBody)),
      const SizedBox(width: 6),
      Text('$count', style: TextStyle(fontSize: 13, color: _textSecondary)),
    ]);
  }

  Widget _emptyPlaceholder(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(child: Text(text, style: TextStyle(fontSize: 13, color: _textMuted))),
    );
  }

  Widget _cardListTile(Map<String, dynamic> c, List<String> states) {
    final st = (c['state'] ?? 0).clamp(0, 3) as int;
    final stateColors = [_grey, _orange, _green, _red];
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        title: Text(c['front'] ?? '', style: const TextStyle(fontSize: 14, color: _textBody), maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text('${states[st]} · 复习${c['reps']}次', style: TextStyle(fontSize: 12, color: _textSecondary)),
        trailing: Container(
          width: 10, height: 10,
          decoration: BoxDecoration(color: stateColors[st], shape: BoxShape.circle),
        ),
        onTap: () => _showCardDetail(c),
      ),
    );
  }

  Widget _convTile(Map<String, dynamic> conv) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        title: Text(conv['title'] ?? '', maxLines: 2, style: const TextStyle(fontSize: 14, color: _textBody)),
        subtitle: Text('${conv['turn_count']}轮对话', style: TextStyle(fontSize: 12, color: _textSecondary)),
        trailing: Icon(Icons.chevron_right, color: _textMuted, size: 20),
        onTap: () => _viewConversation(conv['id'] as String),
      ),
    );
  }

  Widget _convDetailHeader() {
    return Row(children: [
      IconButton(
        icon: Icon(Icons.arrow_back_rounded, size: 20, color: _primaryMuted),
        onPressed: () => setState(() => _viewingConvId = null),
        visualDensity: VisualDensity.compact,
      ),
      const SizedBox(width: 4),
      Text('对话详情', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: _textBody)),
    ]);
  }

  Widget _turnBubble(Map<String, dynamic> t) {
    final isUser = t['role'] == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          decoration: BoxDecoration(
            color: isUser ? _primaryDark.withOpacity(0.06) : const Color(0xFFEEEDE8),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(14),
              topRight: const Radius.circular(14),
              bottomLeft: isUser ? const Radius.circular(14) : Radius.zero,
              bottomRight: isUser ? Radius.zero : const Radius.circular(14),
            ),
          ),
          child: RichContentBuilder(
            textColor: _textBody,
          ).build(t['content'] ?? ''),
        ),
      ),
    );
  }

  Widget _buildPlanCard(Map<String, dynamic> plan) {
    final progress = plan['progress'] as Map<String, dynamic>? ?? {};
    final cardsData = plan['cards'] as Map<String, dynamic>? ?? {};
    final total = progress['total_tasks'] ?? 0;
    final done = progress['done_tasks'] ?? 0;
    final ratio = total > 0 ? done / total : 0.0;
    final health = plan['health'] as String? ?? 'attention';
    final (healthColor, healthIcon) = switch (health) {
      'good' => (_green, Icons.check_circle_rounded),
      'attention' => (_orange, Icons.warning_amber_rounded),
      'not_started' => (_grey, Icons.radio_button_unchecked_rounded),
      _ => (_red, Icons.error_outline_rounded),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        shape: const Border(),
        collapsedShape: const Border(),
        title: Row(children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: healthColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(healthIcon, size: 18, color: healthColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(plan['goal'] ?? '', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _textBody)),
              const SizedBox(height: 2),
              Text('$done/$total 任务', style: TextStyle(fontSize: 12, color: _textSecondary)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: healthColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('${plan['score'] ?? 0}', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: healthColor)),
          ),
          const SizedBox(width: 4),
          if ((plan['reason'] as String?)?.isNotEmpty ?? false)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: _surfaceBg, borderRadius: BorderRadius.circular(4)),
              child: Text(plan['reason'] as String, style: TextStyle(fontSize: 10, color: _textSecondary)),
            ),
        ]),
        children: [
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio,
              backgroundColor: const Color(0xFFEEEDE8),
              color: healthColor,
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 12),
          // Card stats row
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _planStat('总卡片', '${cardsData['total'] ?? 0}', _primaryMuted),
            _planStat('已掌握', '${cardsData['mastered'] ?? 0}', _green),
            _planStat('学习中', '${cardsData['learning'] ?? 0}', _orange),
            _planStat('需重学', '${cardsData['relearning'] ?? 0}', _red),
          ]),
          const SizedBox(height: 8),
          Text(progress['current_stage'] as String? ?? '', style: TextStyle(fontSize: 12, color: _textSecondary)),
        ],
      ),
    );
  }

  Widget _planStat(String label, String value, Color color) {
    return Column(children: [
      Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: color)),
      const SizedBox(height: 2),
      Text(label, style: TextStyle(fontSize: 11, color: _textSecondary)),
    ]);
  }

  List<Widget> _buildPlanGroups() {
    const groups = ['good', 'attention', 'not_started', 'stale'];
    const labels = {'good': '正常', 'attention': '需关注', 'not_started': '未开始', 'stale': '停滞'};
    const icons = {'good': Icons.check_circle_rounded, 'attention': Icons.warning_amber_rounded, 'not_started': Icons.radio_button_unchecked_rounded, 'stale': Icons.error_outline_rounded};
    const colors = {'good': _green, 'attention': _orange, 'not_started': _grey, 'stale': _red};
    final result = <Widget>[];
    for (final g in groups) {
      final filtered = _plans.where((p) => p['health'] == g).toList();
      if (filtered.isEmpty) continue;
      result.add(Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          Icon(icons[g]!, size: 16, color: colors[g]),
          const SizedBox(width: 6),
          Text('${labels[g]}', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: colors[g])),
          const SizedBox(width: 6),
          Text('${filtered.length}', style: TextStyle(fontSize: 12, color: _textSecondary)),
        ]),
      ));
      result.addAll(filtered.map((p) => _buildPlanCard(p)));
      result.add(const SizedBox(height: 2));
    }
    return result;
  }
}

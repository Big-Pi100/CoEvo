import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';
import '../utils/validators.dart';
import '../theme/app_theme.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  ColorScheme get _cs => Theme.of(context).colorScheme;
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _inviteCodeController = TextEditingController();
  bool _isLogin = true;
  String? _validationError;
  String? _detectedRefCode;

  @override
  void initState() {
    super.initState();
  }

  String? _validateInputs() {
    final u = _usernameController.text.trim();
    final p = _passwordController.text.trim();
    final err = Validators.username(u) ?? Validators.password(p);
    if (err != null) return err;
    if (!_isLogin) {
      final ne = Validators.realName(_nameController.text.trim());
      if (ne != null) return ne;
      final pe = Validators.phone(_phoneController.text.trim());
      if (pe != null) return pe;
    }
    return null;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    _inviteCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);

    // 首次构建时从 URL 查询参数读取推广码 ref，自动填入邀请码输入框
    if (_detectedRefCode == null) {
      final params = GoRouterState.of(context).uri.queryParameters;
      final refCode = params['ref'];
      if (refCode != null && refCode.isNotEmpty) {
        _inviteCodeController.text = refCode;
        _detectedRefCode = refCode;
      } else {
        _detectedRefCode = '';
      }
    }

    // Redirect guard in GoRouter handles initial navigation;
    // this callback is a fallback for when auth state changes
    // AFTER the auth screen is already visible (e.g., tryRestore completes)
    if (authState.isAuthenticated && authState.isRestored) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/home');
      });
    }

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppTheme.spacingXxxl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo
              Icon(
                Icons.auto_awesome,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: AppTheme.spacingMd),
              Text(
                'CoEvo',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: AppTheme.spacingXs),
              Text(
                '刻意进化学习',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: _cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppTheme.spacingXl),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingLg, vertical: AppTheme.spacingSm),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withAlpha(8),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '如果不想被AI取代，你需要刻意进化',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.primary.withAlpha(180),
                    fontStyle: FontStyle.italic,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: AppTheme.spacingXxxxl),

              // Form
              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  labelText: '用户名',
                  prefixIcon: Icon(Icons.person),
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: AppTheme.spacingLg),
              TextField(
                controller: _passwordController,
                decoration: const InputDecoration(
                  labelText: '密码（6位以上英文+数字）',
                  prefixIcon: Icon(Icons.lock),
                ),
                obscureText: true,
                textInputAction: TextInputAction.next,
              ),
              if (!_isLogin) ...[
                const SizedBox(height: AppTheme.spacingLg),
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: '真实姓名（中文，4字以内）',
                    prefixIcon: Icon(Icons.person),
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: AppTheme.spacingLg),
                TextField(
                  controller: _phoneController,
                  decoration: const InputDecoration(
                    labelText: '手机号',
                    prefixIcon: Icon(Icons.phone),
                  ),
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                ),
                const SizedBox(height: AppTheme.spacingLg),
                TextField(
                  controller: _inviteCodeController,
                  decoration: const InputDecoration(
                    labelText: '邀请码（选填）',
                    prefixIcon: Icon(Icons.card_giftcard),
                    hintText: '填写推广者的邀请码',
                  ),
                  textInputAction: TextInputAction.done,
                ),
                if (_detectedRefCode != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('检测到推广码: $_detectedRefCode',
                        style: TextStyle(fontSize: 12, color: Colors.green[600])),
                  ),
              ],
              const SizedBox(height: AppTheme.spacingXxl),

              // 客户端校验错误
              if (_validationError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.spacingLg),
                  child: Text(
                    _validationError!,
                    style: TextStyle(color: _cs.tertiary, fontSize: 13),
                  ),
                ),

              // 服务端错误
              if (authState.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.spacingLg),
                  child: Text(
                    authState.error!,
                    style: TextStyle(color: _cs.error),
                  ),
                ),

              ElevatedButton(
                onPressed: authState.isLoading ? null : () {
                  final username = _usernameController.text.trim();
                  final password = _passwordController.text.trim();

                  // 客户端输入校验
                  final validationError = _validateInputs();
                  if (validationError != null) {
                    setState(() => _validationError = validationError);
                    return;
                  }
                  setState(() => _validationError = null);

                  if (_isLogin) {
                    ref.read(authProvider.notifier).login(username, password).then((_) {
                      checkAndShowCampaign(context, ref.read(authProvider).userId ?? '', 'login');
                    });
                  } else {
                    // 从 URL 读取推广码，绕过 TextEditingController 的 Flutter Web 兼容问题
                    final routerState = GoRouterState.of(context);
                    final refFromUrl = routerState.uri.queryParameters['ref'] ?? '';
                    final inviteCode = refFromUrl.isNotEmpty ? refFromUrl : _inviteCodeController.text.trim();
                    ref.read(authProvider.notifier).register(username, password,
                      realName: _nameController.text.trim(),
                      phone: _phoneController.text.trim(),
                      referralCode: inviteCode,
                    ).then((_) {
                      checkAndShowCampaign(context, ref.read(authProvider).userId ?? '', 'registration');
                    });
                  }
                },
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    authState.isLoading ? '处理中...' : (_isLogin ? '登录' : '注册'),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(height: AppTheme.spacingLg),
              TextButton(
                onPressed: () => setState(() {
                  _isLogin = !_isLogin;
                  _validationError = null;
                  _inviteCodeController.clear();
                }),
                child: Text(
                  _isLogin ? '没有账号？注册' : '已有账号？登录',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLogin = true;
  String? _validationError;

  /// 校验输入字段，返回 null 表示通过，否则返回错误消息
  String? _validateInputs(String username, String password) {
    if (username.isEmpty) {
      return '用户名不能为空';
    }
    if (username.length < 2) {
      return '用户名至少需要 2 个字符';
    }
    if (username.length > 32) {
      return '用户名不能超过 32 个字符';
    }
    // 只允许字母、数字、下划线和中文
    final usernameRegExp = RegExp(r'^[\w\u4e00-\u9fff]+$');
    if (!usernameRegExp.hasMatch(username)) {
      return '用户名只能包含字母、数字、下划线和中文';
    }
    if (password.isEmpty) {
      return '密码不能为空';
    }
    if (password.length < 6) {
      return '密码至少需要 6 个字符';
    }
    if (password.length > 64) {
      return '密码不能超过 64 个字符';
    }
    return null;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);

    // Auto-navigate when authenticated
    if (authState.isAuthenticated) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        context.go('/chat');
      });
    }

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo
              Icon(
                Icons.auto_awesome,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                'CoEvo',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '刻意进化学习',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
              const SizedBox(height: 48),

              // Form
              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  labelText: '用户名',
                  prefixIcon: Icon(Icons.person),
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                decoration: const InputDecoration(
                  labelText: '密码',
                  prefixIcon: Icon(Icons.lock),
                ),
                obscureText: true,
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 24),

              // 客户端校验错误
              if (_validationError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    _validationError!,
                    style: const TextStyle(color: Colors.orange, fontSize: 13),
                  ),
                ),

              // 服务端错误
              if (authState.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    authState.error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),

              ElevatedButton(
                onPressed: authState.isLoading ? null : () {
                  final username = _usernameController.text.trim();
                  final password = _passwordController.text.trim();

                  // 客户端输入校验
                  final validationError = _validateInputs(username, password);
                  if (validationError != null) {
                    setState(() => _validationError = validationError);
                    return;
                  }
                  setState(() => _validationError = null);

                  if (_isLogin) {
                    ref.read(authProvider.notifier).login(username, password);
                  } else {
                    ref.read(authProvider.notifier).register(username, password);
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
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => setState(() {
                  _isLogin = !_isLogin;
                  _validationError = null;
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/auth_provider.dart';
import '../utils/validators.dart';

/// 临时账户认领弹窗 — 与 auth_screen 登录/注册逻辑完全一致
class ClaimDialog extends ConsumerStatefulWidget {
  const ClaimDialog({super.key});

  @override
  ConsumerState<ClaimDialog> createState() => _ClaimDialogState();
}

class _ClaimDialogState extends ConsumerState<ClaimDialog> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _inviteCodeController = TextEditingController();
  bool _isLogin = true;
  bool _isSubmitting = false;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPendingRef());
  }

  Future<void> _loadPendingRef() async {
    final prefs = await SharedPreferences.getInstance();
    final refCode = prefs.getString('pending_ref_code');
    if (refCode != null && refCode.isNotEmpty && mounted) {
      _inviteCodeController.text = refCode;
    }
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

  Future<void> _submit() async {
    setState(() => _validationError = null);

    // 客户端校验
    final validationError = _validateInputs();
    if (validationError != null) {
      setState(() => _validationError = validationError);
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      if (_isLogin) {
        await ref.read(authProvider.notifier).login(
          _usernameController.text.trim(),
          _passwordController.text,
        );
      } else {
        await ref.read(authProvider.notifier).trialClaim(
          _usernameController.text.trim(),
          _passwordController.text,
          realName: _nameController.text.trim(),
          phone: _phoneController.text.trim(),
          referralCode: _inviteCodeController.text.trim(),
        );
        // 注册成功，清理缓存的推广码
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('pending_ref_code');
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${_isLogin ? "登录" : "注册"}失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final cs = Theme.of(context).colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _isLogin ? '登录' : '注册以保存进度',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _isLogin ? '已有账号？登录后继续学习' : '补全信息，永久保存你的学习记录',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),

                // 用户名
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: '用户名',
                    prefixIcon: Icon(Icons.person),
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),

                // 密码
                TextField(
                  controller: _passwordController,
                  decoration: const InputDecoration(
                    labelText: '密码（6位以上英文+数字）',
                    prefixIcon: Icon(Icons.lock),
                  ),
                  obscureText: true,
                  textInputAction: _isLogin ? TextInputAction.done : TextInputAction.next,
                ),

                // 注册模式才显示额外字段
                if (!_isLogin) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: '真实姓名（中文，4字以内）',
                      prefixIcon: Icon(Icons.person),
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _phoneController,
                    decoration: const InputDecoration(
                      labelText: '手机号',
                      prefixIcon: Icon(Icons.phone),
                    ),
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _inviteCodeController,
                    decoration: const InputDecoration(
                      labelText: '邀请码（选填）',
                      prefixIcon: Icon(Icons.card_giftcard),
                      hintText: '填写推广者的邀请码',
                    ),
                    textInputAction: TextInputAction.done,
                  ),
                ],

                const SizedBox(height: 16),

                // 客户端校验错误
                if (_validationError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _validationError!,
                      style: TextStyle(color: cs.tertiary, fontSize: 13),
                    ),
                  ),

                // 服务端错误
                if (authState.error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      authState.error!,
                      style: TextStyle(color: cs.error),
                    ),
                  ),

                // 提交按钮
                FilledButton(
                  onPressed: (_isSubmitting || authState.isLoading) ? null : _submit,
                  child: (_isSubmitting || authState.isLoading)
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_isLogin ? '登录' : '注册'),
                ),

                // 登录/注册切换
                const SizedBox(height: 12),
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
      ),
    );
  }
}

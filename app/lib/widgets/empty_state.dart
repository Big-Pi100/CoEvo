import 'package:flutter/material.dart';

/// 通用空状态组件
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final _cs = Theme.of(context).colorScheme;
    final _tt = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 56, color: _cs.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(title, style: _tt.titleMedium?.copyWith(color: _cs.onSurface)),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(subtitle!, style: _tt.bodySmall?.copyWith(color: _cs.onSurfaceVariant, fontSize: 13)),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.add, size: 18),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

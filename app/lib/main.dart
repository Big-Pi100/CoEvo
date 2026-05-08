import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'providers/auth_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final container = ProviderContainer();
  await container.read(authProvider.notifier).tryRestore();
  container.dispose();

  runApp(
    const ProviderScope(
      child: CoEvoApp(),
    ),
  );
}
